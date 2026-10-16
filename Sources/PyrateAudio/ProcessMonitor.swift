import CoreAudio
import Darwin
import Foundation
import PyrateCore

/// One Core Audio process object, plus the source it belongs to.
public struct AudioProcess: Equatable, Sendable {
    public var objectID: AudioObjectID
    public var facts: ProcessFacts
    public var isRunningOutput: Bool
    public var isRunningInput: Bool = false
}

/// A user-facing source assembled from one or more processes.
public struct DiscoveredSource: Equatable, Sendable {
    public var id: SourceID
    public var appBundlePath: String?
    public var bundleIDHint: String?
    public var isShared: Bool
    public var processObjectIDs: [AudioObjectID]
    public var pids: [Int32]
    /// True when any of its processes is currently sending audio to an output.
    public var isActive: Bool
    /// True when any of its processes is currently recording from an input (microphone).
    public var isUsingInput: Bool = false
}

public struct HiddenProcess: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var path: String?
    public var reason: HiddenReason
    public var isRunningOutput: Bool
}

/// Discovers audio-producing processes through Core Audio's process objects.
/// Pyrate Sounds' own process is always excluded.
///
/// Core Audio does not post change notifications for `IsRunningOutput` (verified on
/// macOS 15.6). It does post them for `IsRunning` when a process starts IO, so that
/// is the primary signal, followed by two short re-checks while the output flag
/// settles. Stopping is not reliably notified, so a light safety poll re-reads the
/// flags: fast while the panel is open, slow while it is closed.
@MainActor
public final class ProcessMonitor {
    public var onChange: (([DiscoveredSource]) -> Void)?
    public private(set) var sources: [DiscoveredSource] = []
    /// Processes deliberately kept out of the mixer, for diagnostics.
    public private(set) var hidden: [HiddenProcess] = []

    private let resolver: SourceIdentityResolver
    private var listListener: PropertyListener?
    private var runningListeners: [AudioObjectID: [PropertyListener]] = [:]
    private var followUps: [Task<Void, Never>] = []
    private var pollTimer: Timer?
    private var factsCache: [AudioObjectID: ProcessFacts] = [:]
    private let ownPID = getpid()
    private static let processList = CAProperty.address(kAudioHardwarePropertyProcessObjectList)
    private static let runningOutput = CAProperty.address(kAudioProcessPropertyIsRunningOutput)
    private static let running = CAProperty.address(kAudioProcessPropertyIsRunning)
    private static let runningInput = CAProperty.address(kAudioProcessPropertyIsRunningInput)

    /// Seconds between safety polls. Set shorter while the panel is visible.
    public var pollInterval: TimeInterval = 3 {
        didSet { if pollInterval != oldValue { schedulePoll() } }
    }

    public init(resolver: SourceIdentityResolver = SourceIdentityResolver()) {
        self.resolver = resolver
    }

    public func start() {
        listListener = PropertyListener(object: AudioObjectID(kAudioObjectSystemObject), address: Self.processList) { [weak self] in
            self?.refresh()
        }
        refresh()
        schedulePoll()
    }

    private func schedulePoll() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = pollInterval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// A process started or stopped IO. Refresh now, then twice more while
    /// `IsRunningOutput` catches up with `IsRunning`.
    private func ioStateChanged() {
        refresh()
        followUps.forEach { $0.cancel() }
        followUps = [0.15, 0.6].map { delay in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    public func refresh() {
        let ids = (try? CAProperty.array(AudioObjectID(kAudioObjectSystemObject), Self.processList, of: AudioObjectID.self)) ?? []
        let idSet = Set(ids)

        for gone in factsCache.keys where !idSet.contains(gone) {
            factsCache[gone] = nil
            runningListeners[gone] = nil
        }

        var processes: [AudioProcess] = []
        for id in ids {
            guard let facts = facts(for: id), facts.pid != ownPID else { continue }
            if runningListeners[id] == nil {
                runningListeners[id] = [Self.running, Self.runningOutput].compactMap { address in
                    PropertyListener(object: id, address: address) { [weak self] in self?.ioStateChanged() }
                }
            }
            let running = (try? CAProperty.get(id, Self.runningOutput, default: UInt32(0))) ?? 0
            let input = (try? CAProperty.get(id, Self.runningInput, default: UInt32(0))) ?? 0
            processes.append(AudioProcess(objectID: id, facts: facts, isRunningOutput: running != 0, isRunningInput: input != 0))
        }

        hidden = processes.compactMap { process in
            let resolved = resolver.resolve(process.facts)
            guard let reason = resolved.hiddenReason else { return nil }
            return HiddenProcess(pid: process.facts.pid, bundleID: process.facts.bundleID,
                                 path: process.facts.executablePath, reason: reason, isRunningOutput: process.isRunningOutput)
        }
        let grouped = Self.group(processes, resolver: resolver)
        if grouped != sources {
            sources = grouped
            onChange?(grouped)
        }
    }

    private func facts(for id: AudioObjectID) -> ProcessFacts? {
        if let cached = factsCache[id] { return cached }
        guard let pid = try? CAProperty.get(id, CAProperty.address(kAudioProcessPropertyPID), default: Int32(-1)), pid > 0 else {
            return nil
        }
        let bundleID = try? CAProperty.string(id, CAProperty.address(kAudioProcessPropertyBundleID))
        let facts = ProcessFacts(pid: pid, bundleID: bundleID, executablePath: Self.executablePath(of: pid))
        factsCache[id] = facts
        return facts
    }

    static func executablePath(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func group(_ processes: [AudioProcess], resolver: SourceIdentityResolver) -> [DiscoveredSource] {
        var order: [SourceID] = []
        var byID: [SourceID: DiscoveredSource] = [:]
        for process in processes {
            let resolved = resolver.resolve(process.facts)
            guard !resolved.isHidden else { continue }
            if var existing = byID[resolved.id] {
                existing.processObjectIDs.append(process.objectID)
                existing.pids.append(process.facts.pid)
                existing.isActive = existing.isActive || process.isRunningOutput
                existing.isUsingInput = existing.isUsingInput || process.isRunningInput
                existing.appBundlePath = existing.appBundlePath ?? resolved.appBundlePath
                byID[resolved.id] = existing
            } else {
                order.append(resolved.id)
                byID[resolved.id] = DiscoveredSource(
                    id: resolved.id,
                    appBundlePath: resolved.appBundlePath,
                    bundleIDHint: process.facts.bundleID,
                    isShared: resolved.isShared,
                    processObjectIDs: [process.objectID],
                    pids: [process.facts.pid],
                    isActive: process.isRunningOutput,
                    isUsingInput: process.isRunningInput
                )
            }
        }
        return order.compactMap { id in
            byID[id].map { source in
                var s = source
                s.processObjectIDs.sort()
                s.pids.sort()
                return s
            }
        }
    }
}
