import CoreAudio
import Foundation
import PyrateCore

/// Owns all tap engines and keeps them in line with what the domain wants.
///
/// Taps are only engaged for sources that need processing (volume not at 100%,
/// muted, or EQ active), so untouched apps keep their native, zero-latency path. An engine returning to
/// unity lingers briefly before teardown, so dragging through 100% does not
/// repeatedly rebuild it.
@MainActor
public final class TapCoordinator {
    public struct Request: Equatable {
        public var name: String
        public var processObjectIDs: [AudioObjectID]
        public var destinationUID: String
        public var gain: Float
        public var eq: SourceEQ
        public var effects: SourceEffects

        public init(name: String, processObjectIDs: [AudioObjectID], destinationUID: String, gain: Float,
                    eq: SourceEQ, effects: SourceEffects = .neutral) {
            self.name = name
            self.processObjectIDs = processObjectIDs
            self.destinationUID = destinationUID
            self.gain = gain
            self.eq = eq
            self.effects = effects
        }

        /// Whether a source with these settings needs a tap at all.
        public static func needsTap(volume: VolumeState, eq: SourceEQ,
                                    effects: SourceEffects = .neutral, routed: Bool = false) -> Bool {
            !volume.isUnity || eq.isActive || !effects.isNeutral || routed
        }
    }

    public private(set) var errors: [SourceID: String] = [:]
    /// How long an engine that is no longer needed keeps running before teardown,
    /// so brief pauses (between tracks, dragging through 100%) don't rebuild it.
    public var lingerInterval: TimeInterval = 8

    private var engines: [SourceID: TapEngine] = [:]
    private var engineStarted: [SourceID: Date] = [:]
    private var lingerTasks: [SourceID: Task<Void, Never>] = [:]

    public init() {}

    public var isTapAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    public func isEngaged(_ id: SourceID) -> Bool { engines[id] != nil }

    public struct EngineInfo: Sendable {
        public var sourceID: SourceID
        public var processCount: Int
        public var destinationUID: String
        public var sampleRate: Double
        public var latency: Double
        public var eqActive: Bool
        public var effects: SourceEffects
        public var rackLatency: Double = 0
        public var rackSkipped: [String] = []
        public var since: Date?
    }

    /// What is being processed right now, for diagnostics.
    public var engineInfo: [EngineInfo] {
        engines.map { id, engine in
            EngineInfo(sourceID: id, processCount: engine.processObjectIDs.count, destinationUID: engine.destinationUID,
                       sampleRate: engine.chain.sampleRate, latency: engine.chain.latency,
                       eqActive: engine.chain.eq.isActive, effects: engine.chain.effects,
                       rackLatency: engine.chain.rackLatency, rackSkipped: engine.chain.rackSkipped, since: engineStarted[id])
        }.sorted { $0.sourceID.rawValue < $1.sourceID.rawValue }
    }

    public func engagedSince(_ id: SourceID) -> Date? { engineStarted[id] }

    /// Input peak since the last call, for activity display. Nil when not tapped.
    public func takePeak(_ id: SourceID) -> Float? { engines[id]?.chain.takePeak() }

    /// Sample rate a source is being processed at, when tapped.
    public func sampleRate(_ id: SourceID) -> Double? { engines[id]?.chain.sampleRate }


    /// - Parameters:
    ///   - desired: sources that need a tap now, with their target gain.
    ///   - present: sources whose processes still exist (engines for others are torn down at once).
    public func reconcile(desired: [SourceID: Request], present: Set<SourceID>) {
        for (id, request) in desired {
            lingerTasks[id]?.cancel()
            lingerTasks[id] = nil

            if let engine = engines[id],
               engine.processObjectIDs == request.processObjectIDs,
               engine.destinationUID == request.destinationUID {
                engine.chain.setGain(request.gain)
                engine.chain.setEQ(request.eq)
                engine.chain.setEffects(request.effects)
                continue
            }

            engines[id]?.stop()
            engines[id] = nil
            do {
                engines[id] = try TapEngine(
                    sourceID: id, name: request.name, processObjectIDs: request.processObjectIDs,
                    destinationUID: request.destinationUID, gain: request.gain, eq: request.eq)
                engines[id]?.chain.setEffects(request.effects)
                engineStarted[id] = Date()
                errors[id] = nil
            } catch {
                errors[id] = "Couldn't control this app's volume. \(error)"
                engineStarted[id] = nil
            }
        }

        for id in engines.keys where desired[id] == nil {
            guard present.contains(id) else {
                tearDown(id)
                continue
            }
            engines[id]?.chain.setGain(1)
            engines[id]?.chain.setEQ(.off)
            engines[id]?.chain.setEffects(.neutral)
            guard lingerTasks[id] == nil else { continue }
            let delay = lingerInterval
            lingerTasks[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.tearDown(id)
            }
        }

        for id in errors.keys where desired[id] == nil {
            errors[id] = nil
        }
    }

    public func tearDownAll() {
        for id in Array(engines.keys) { tearDown(id) }
    }

    private func tearDown(_ id: SourceID) {
        lingerTasks[id]?.cancel()
        lingerTasks[id] = nil
        engines[id]?.stop()
        engines[id] = nil
        engineStarted[id] = nil
    }
}
