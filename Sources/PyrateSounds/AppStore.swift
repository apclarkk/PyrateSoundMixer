import AppKit
import CoreAudio
import Observation
import os
import PyrateAudio
import PyrateCore

/// One row in the applications list, ready to display.
struct SourceRowModel: Identifiable, Equatable {
    var id: SourceID
    var name: String
    var icon: NSImage?
    var volume: VolumeState
    /// Sending audio right now, according to Core Audio.
    var isActive: Bool
    /// Its processes exist (it can be controlled now), as opposed to a pinned idle app or a departing row.
    var isPresent: Bool
    var isPinned: Bool
    var isShared: Bool
    var capabilities: SourceCapabilities
    var eq: SourceEQ
    var eqPresetName: String?
    var isLeveled: Bool
    var effects: SourceEffects = .neutral
    var route: RouteResolution = .system
}

struct Feedback: Equatable, Identifiable {
    enum Kind { case info, success, failure }
    let id = UUID()
    var kind: Kind
    var message: String
}

/// The application's domain state. Views express intent through its methods; it
/// decides what to ask of the audio services and reconciles with what they report.
private let log = Logger(subsystem: "org.pyratesounds.PyrateSounds", category: "store")

@MainActor
@Observable
final class AppStore {
    // MARK: Published state

    private(set) var preferences: Preferences
    private(set) var outputDevices: [OutputDevice] = []
    private(set) var selectedOutput = TrackedValue<DeviceID>()
    private(set) var inputDevices: [OutputDevice] = []
    private(set) var selectedInput = TrackedValue<DeviceID>()
    private(set) var inputLevel: DeviceVolume?
    /// Apps currently recording from an input, from Core Audio process metadata only.
    private(set) var micUsers: [(id: SourceID, name: String)] = []
    /// Shortcuts macOS refused to register.
    private(set) var shortcutFailures: Set<ShortcutAction> = []
    private(set) var master: DeviceVolume?
    /// While the master slider is being dragged, the drag value wins over device echoes.
    private(set) var masterDragLevel: Double?
    private(set) var rows: [SourceRowModel] = []
    private(set) var activity: [SourceID: Float] = [:]
    /// Live leveler adjustment per source in dB, refreshed while the panel is open.
    private(set) var levelerAdjustments: [SourceID: Float] = [:]
    private(set) var feedback: Feedback?
    private(set) var permissionSuspected = false
    private(set) var showPermissionNote = false
    /// The source whose EQ drawer is open in the panel. Presentation state only.
    var expandedEQ: SourceID?
    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            panelVisible ? startMeters() : stopMeters()
            processMonitor.pollInterval = panelVisible ? 0.5 : 3
            if panelVisible { processMonitor.refresh() }
        }
    }

    // MARK: Dependencies

    @ObservationIgnored private let preferencesStore: PreferencesStore
    @ObservationIgnored private let deviceMonitor = DeviceMonitor()
    @ObservationIgnored private let processMonitor = ProcessMonitor()
    @ObservationIgnored private let taps = TapCoordinator()
    @ObservationIgnored private let identities = AppIdentityProvider()
    @ObservationIgnored let hotKeys = HotKeyCenter()
    @ObservationIgnored var processMonitorForDiagnostics: ProcessMonitor { processMonitor }
    @ObservationIgnored var tapsForDiagnostics: TapCoordinator { taps }

    // MARK: Internal state

    @ObservationIgnored private var discovered: [SourceID: DiscoveredSource] = [:]
    @ObservationIgnored private var sessionVolumes: [SourceID: VolumeState] = [:]
    @ObservationIgnored private var stabilizer = SourceListStabilizer()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var lastHeard: [SourceID: Date] = [:]
    @ObservationIgnored private var feedbackTask: Task<Void, Never>?
    // Phase 3 state (logic lives in AppStore+Profiles.swift)
    @ObservationIgnored var ruleEngine = RuleEngine()
    @ObservationIgnored var editStartVolume: [SourceID: VolumeState] = [:]
    @ObservationIgnored var activitySaveTask: Task<Void, Never>?
    private(set) var activityLog = ActivityLog()
    var lastProfileUndo: ProfileUndo?

    init(preferencesStore: PreferencesStore = PreferencesStore(fileURL: PreferencesStore.defaultURL())) {
        self.preferencesStore = preferencesStore
        var loaded = preferencesStore.load()
        // Loudness normalizing has no UI; the DSP stays available but is never engaged.
        loaded.leveling.isEnabled = false
        self.preferences = loaded
        self.activityLog = Self.loadActivity()
    }

    func start() {
        deviceMonitor.onChange = { [weak self] in self?.refreshDevices() }
        processMonitor.onChange = { [weak self] sources in self?.sourcesChanged(sources) }
        deviceMonitor.start()
        refreshDevices()
        processMonitor.start()
        hotKeys.onAction = { [weak self] action in self?.perform(action) }
        hotKeys.install()
        registerShortcuts()
    }

    func shutdown() {
        taps.tearDownAll()
        saveNow()
    }

    // MARK: Output devices

    var currentOutput: OutputDevice? {
        guard let id = selectedOutput.confirmed else { return nil }
        return outputDevices.first { $0.id == id }
    }

    /// The remembered preferred device, when it is not currently connected.
    var missingPreferredOutput: RememberedDevice? {
        guard let preferred = preferences.preferredOutput,
              !outputDevices.contains(where: { $0.id == preferred.id }) else { return nil }
        return preferred
    }

    func selectOutput(_ device: OutputDevice) {
        guard device.id != selectedOutput.displayed else { return }
        selectedOutput.request(device.id)
        mutatePreferences { $0.preferredOutput = RememberedDevice(id: device.id, lastKnownName: device.name) }
        do {
            try DeviceControl.setDefaultOutput(device.objectID)
        } catch {
            selectedOutput.fail("Couldn't switch to \(device.name).")
            show(.failure, "Couldn't switch to \(device.name).")
            return
        }
        // Bluetooth devices can take a few seconds to accept a route.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self else { return }
            if self.selectedOutput.expire(timeout: 6, message: "\(device.name) didn't respond.") {
                self.show(.failure, "\(device.name) didn't respond. Still using \(self.currentOutput?.name ?? "the previous output").")
            }
        }
    }

    private func refreshDevices() {
        let previous = currentOutput
        outputDevices = DeviceControl.outputDevices()
        let defaultID = DeviceControl.defaultOutputID()
        let current = outputDevices.first { $0.objectID == defaultID }
        let wasPending = selectedOutput.isPending
        selectedOutput.confirm(current?.id)

        if wasPending, !selectedOutput.isPending, let current {
            show(.success, "Now playing through \(current.name).")
            record(.user, "Output switched to \(current.name)")
        } else if let previous, previous.id != current?.id, !outputDevices.contains(where: { $0.id == previous.id }) {
            show(.info, "\(previous.name) disconnected. Now playing through \(current?.name ?? "another output").")
            record(.device, "\(previous.name) disconnected; output moved to \(current?.name ?? "another device")")
        } else if let previous, let current, previous.id != current.id {
            record(.device, "Output changed to \(current.name) outside Pyrate Sounds")
        }

        master = current.map { DeviceControl.volume(of: $0.objectID) }

        inputDevices = DeviceControl.inputDevices()
        let defaultInput = DeviceControl.defaultInputID()
        let currentInput = inputDevices.first { $0.objectID == defaultInput }
        let inputWasPending = selectedInput.isPending
        selectedInput.confirm(currentInput?.id)
        if inputWasPending, !selectedInput.isPending, let currentInput {
            show(.success, "Now recording from \(currentInput.name).")
        }
        inputLevel = currentInput.map { DeviceControl.inputLevel(of: $0.objectID) }
        reconcileTaps()
        evaluateRules()
    }

    // MARK: Input

    var currentInput: OutputDevice? {
        guard let id = selectedInput.confirmed else { return nil }
        return inputDevices.first { $0.id == id }
    }

    func selectInput(_ device: OutputDevice) {
        guard device.id != selectedInput.displayed else { return }
        selectedInput.request(device.id)
        mutatePreferences { $0.preferredInput = RememberedDevice(id: device.id, lastKnownName: device.name) }
        do {
            try DeviceControl.setDefaultInput(device.objectID)
        } catch {
            selectedInput.fail("Couldn't switch to \(device.name).")
            show(.failure, "Couldn't switch to \(device.name).")
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self else { return }
            if self.selectedInput.expire(timeout: 6, message: "\(device.name) didn't respond.") {
                self.show(.failure, "\(device.name) didn't respond.")
            }
        }
    }

    func setInputGain(_ level: Double) {
        guard let device = currentInput, inputLevel?.capabilities.volume.isUsable == true else { return }
        do {
            try DeviceControl.setInputLevel(level, of: device.objectID)
            inputLevel?.level = level
        } catch {
            show(.failure, "Couldn't change the input level of \(device.name).")
        }
    }

    func toggleInputMute() {
        guard let device = currentInput, let inputLevel, inputLevel.capabilities.mute.isUsable else {
            show(.info, "\(currentInput?.name ?? "This microphone") has no mute control.")
            return
        }
        do {
            try DeviceControl.setInputMuted(!inputLevel.isMuted, of: device.objectID)
            show(.info, inputLevel.isMuted ? "Microphone unmuted." : "Microphone muted.")
        } catch {
            show(.failure, "Couldn't mute \(device.name).")
        }
    }

    // MARK: Shortcuts

    func registerShortcuts() {
        hotKeys.register(preferences.shortcuts)
        shortcutFailures = hotKeys.failures
    }

    func setShortcut(_ shortcut: KeyShortcut?, for action: ShortcutAction) {
        mutatePreferences { $0.shortcuts.set(shortcut, for: action) }
        registerShortcuts()
    }

    func perform(_ action: ShortcutAction) {
        switch action {
        case .volumeUp: stepMaster(by: 1.0 / 16)
        case .volumeDown: stepMaster(by: -1.0 / 16)
        case .toggleOutputMute: toggleMasterMute()
        case .nextOutputDevice: selectNextOutput()
        case .toggleInputMute: toggleInputMute()
        case .activateProfile(let id): activateProfile(id: id)
        }
    }

    private func stepMaster(by delta: Double) {
        guard master?.capabilities.volume.isUsable == true else {
            show(.info, master?.capabilities.volume.note ?? "No output to adjust.")
            return
        }
        setMasterLevel(min(max(masterLevel + delta, 0), 1))
        masterEditing(false)
    }

    func selectNextOutput() {
        let candidates = outputDevices.filter(\.isAlive)
        guard candidates.count > 1 else { return }
        let index = candidates.firstIndex { $0.id == selectedOutput.displayed } ?? -1
        selectOutput(candidates[(index + 1) % candidates.count])
    }

    // MARK: Master volume

    var masterLevel: Double { masterDragLevel ?? master?.level ?? 0 }

    func setMasterLevel(_ level: Double) {
        guard let device = currentOutput, master?.capabilities.volume.isUsable == true else { return }
        masterDragLevel = level
        do {
            try DeviceControl.setVolume(level, of: device.objectID)
            if master?.isMuted == true, level > 0, master?.capabilities.mute.isUsable == true {
                try DeviceControl.setMuted(false, of: device.objectID)
            }
        } catch {
            show(.failure, "Couldn't change the volume of \(device.name).")
        }
    }

    func masterEditing(_ editing: Bool) {
        if !editing {
            masterDragLevel = nil
            if let device = currentOutput { master = DeviceControl.volume(of: device.objectID) }
        }
    }

    func toggleMasterMute() {
        guard let device = currentOutput, let master, master.capabilities.mute.isUsable else { return }
        do {
            try DeviceControl.setMuted(!master.isMuted, of: device.objectID)
        } catch {
            show(.failure, "Couldn't mute \(device.name).")
        }
    }

    var menuBarSymbol: String {
        guard let master else { return "speaker.wave.2" }
        if master.isMuted { return "speaker.slash" }
        switch masterLevel {
        case ..<0.01: return "speaker"
        case ..<0.34: return "speaker.wave.1"
        case ..<0.67: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }

    var menuBarAccessibilityLabel: String {
        guard let master else { return "Pyrate Sounds" }
        return master.isMuted ? "Pyrate Sounds, output muted" : "Pyrate Sounds, volume \(Int((masterLevel * 100).rounded())) percent"
    }

    // MARK: Applications

    func volume(for id: SourceID) -> VolumeState {
        sessionVolumes[id] ?? preferences.volume(for: id)
    }

    func setLevel(_ level: Double, for id: SourceID) {
        var v = volume(for: id)
        v.setLevel(level)
        apply(v, to: id)
    }

    func toggleMute(_ id: SourceID) {
        var v = volume(for: id)
        v.toggleMute()
        apply(v, to: id)
        record(.user, "\(name(of: id)) \(v.isMuted ? "muted" : "unmuted")")
    }

    func resetVolume(_ id: SourceID) {
        apply(.unity, to: id)
        record(.user, "\(name(of: id)) reset to 100%")
    }

    func sourceEditing(_ id: SourceID, _ editing: Bool) {
        stabilizer.interacting = editing ? id : nil
        if editing {
            editStartVolume[id] = volume(for: id)
        } else {
            if let start = editStartVolume.removeValue(forKey: id), start.percent != volume(for: id).percent {
                record(.user, "\(name(of: id)) volume \(start.percent)% to \(volume(for: id).percent)%")
            }
            stabilizer.prune()
            rebuildRows()
        }
    }

    func name(of id: SourceID) -> String {
        rows.first { $0.id == id }?.name
            ?? preferences.apps[id]?.lastKnownName
            ?? identities.identity(for: id, source: discovered[id], fallbackName: nil).name
    }

    func setPinned(_ pinned: Bool, for id: SourceID) {
        let name = rows.first { $0.id == id }?.name
        mutatePreferences { $0.setPinned(pinned, for: id, name: name) }
        rebuildRows()
    }

    func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutatePreferences { $0.movePinned(fromOffsets: source, toOffset: destination) }
        rebuildRows()
    }

    func forget(_ id: SourceID) {
        sessionVolumes[id] = nil
        mutatePreferences { $0.forget(id) }
        rebuildRows()
        reconcileTaps()
    }

    func apply(_ volume: VolumeState, to id: SourceID, origin: ChangeOrigin = .user) {
        sessionVolumes[id] = volume
        if origin == .user { ruleEngine.userChanged(.volume(id)) }
        let name = rows.first { $0.id == id }?.name
        // Rules make temporary changes; they never overwrite the level you chose to remember.
        if origin != .rule && (preferences.rememberAppVolumes || preferences.isPinned(id)) {
            mutatePreferences { $0.setVolume(volume, for: id, name: name) }
        }
        if !volume.isUnity && !preferences.hasSeenPermissionExplanation {
            showPermissionNote = true
            mutatePreferences { $0.hasSeenPermissionExplanation = true }
        }
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].volume = volume
        }
        reconcileTaps()
    }

    func dismissPermissionNote() { showPermissionNote = false }

    // MARK: Equalizer (per source)

    var eqPresets: [EQPreset] { preferences.allEQPresets }

    func eq(for id: SourceID) -> SourceEQ { preferences.eq(for: id) }

    /// "Bass Boost", "Bass Boost (edited)", "Custom", or nil when EQ is off.
    func eqLabel(for id: SourceID) -> String? {
        let eq = preferences.eq(for: id)
        guard eq.isActive || eq.isBypassed && !eq.isFlat else { return nil }
        guard let preset = preferences.eqPreset(id: eq.presetID) else { return "Custom" }
        return eq.isModified(from: preset) ? "\(preset.name) (edited)" : preset.name
    }

    func selectEQPreset(_ preset: EQPreset, for id: SourceID) {
        var eq = preferences.eq(for: id)
        eq.apply(preset)
        eq.isBypassed = false
        applyEQ(eq, to: id)
        record(.user, "\(name(of: id)) EQ set to \(preset.name)")
    }

    func setEQGain(_ db: Double, band: Int, for id: SourceID) {
        var eq = preferences.eq(for: id)
        eq.setGain((db * 2).rounded() / 2, band: band)
        applyEQ(eq, to: id)
    }

    func toggleEQBypass(_ id: SourceID) {
        var eq = preferences.eq(for: id)
        eq.isBypassed.toggle()
        applyEQ(eq, to: id)
    }

    func setEQMatchLoudness(_ on: Bool, for id: SourceID) {
        var eq = preferences.eq(for: id)
        eq.matchLoudness = on
        applyEQ(eq, to: id)
    }

    func resetEQ(_ id: SourceID) {
        applyEQ(.off, to: id)
    }

    func saveEQPreset(named name: String, from id: SourceID) {
        var created: EQPreset?
        mutatePreferences { created = $0.addCustomPreset(named: name, gains: $0.eq(for: id).gains) }
        if let created {
            var eq = preferences.eq(for: id)
            eq.presetID = created.id
            applyEQ(eq, to: id)
            show(.success, "Saved preset \(created.name).")
        }
    }

    func renameEQPreset(_ presetID: String, to name: String) {
        mutatePreferences { $0.renameCustomPreset(id: presetID, to: name) }
        rebuildRows()
    }

    func deleteEQPreset(_ presetID: String) {
        let name = preferences.eqPreset(id: presetID)?.name ?? "preset"
        mutatePreferences { $0.deleteCustomPreset(id: presetID) }
        rebuildRows()
        show(.info, "Deleted \(name). Apps using it keep their current sound.")
    }

    func applyEQ(_ eq: SourceEQ, to id: SourceID, origin: ChangeOrigin = .user) {
        if origin == .user { ruleEngine.userChanged(.eq(id)) }
        let name = rows.first { $0.id == id }?.name
        mutatePreferences { $0.setEQ(eq, for: id, name: name) }
        if eq.isActive && !preferences.hasSeenPermissionExplanation {
            showPermissionNote = true
            mutatePreferences { $0.hasSeenPermissionExplanation = true }
        }
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].eq = eq
            rows[index].eqPresetName = eqLabel(for: id)
        }
        reconcileTaps()
    }

    private func sourcesChanged(_ sources: [DiscoveredSource]) {
        discovered = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        micUsers = sources.filter(\.isUsingInput).map { source in
            (id: source.id, name: identities.identity(for: source.id, source: source, fallbackName: preferences.apps[source.id]?.lastKnownName).name)
        }
        let active = sources.filter(\.isActive).map(\.id)
        stabilizer.update(discovered: active)
        log.debug("sources: \(sources.count, privacy: .public) discovered, active: \(active.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        rebuildRows()
        log.debug("rows: \(self.rows.map(\.name).joined(separator: ", "), privacy: .public)")
        reconcileTaps()
        schedulePrune()
        evaluateRules()
    }

    private func schedulePrune() {
        pruneTask?.cancel()
        let delay = stabilizer.gracePeriod + 0.1
        pruneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            if self.stabilizer.prune() { self.rebuildRows() }
            self.evaluateRules()
        }
    }

    /// Facts the rule engine sees. "Playing" uses the stabilized list, so a short
    /// gap between tracks doesn't end a rule.
    var ruleFacts: RuleEngine.Facts {
        RuleEngine.Facts(
            playing: Set(stabilizer.rows().map(\.id)),
            usingMicrophone: Set(micUsers.map(\.id)),
            connected: Set(outputDevices.filter(\.isAlive).map(\.id) + inputDevices.filter(\.isAlive).map(\.id)),
            output: selectedOutput.confirmed)
    }

    /// Replaces the activity log and saves it shortly after (coalescing bursts).
    func setActivity(_ log: ActivityLog) {
        activityLog = log
        activitySaveTask?.cancel()
        activitySaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(log) else { return }
            try? FileManager.default.createDirectory(at: Self.activityURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.activityURL, options: .atomic)
        }
    }

    // MARK: Routing and effects (Phase 4)

    func routeResolution(for id: SourceID) -> RouteResolution {
        RouteResolution.resolve(
            route: preferences.route(for: id),
            systemOutput: selectedOutput.confirmed,
            available: Set(outputDevices.filter(\.isAlive).map(\.id)))
    }

    /// Sends an app to a specific output, or back to the system output with nil.
    func setRoute(_ device: OutputDevice?, for id: SourceID) {
        let remembered = device.map { RememberedDevice(id: $0.id, lastKnownName: $0.name) }
        mutatePreferences { $0.setRoute(remembered, for: id, name: self.rows.first { $0.id == id }?.name) }
        rebuildRows()
        reconcileTaps()
        if let device {
            record(.user, "\(name(of: id)) routed to \(device.name)")
            show(.success, "\(name(of: id)) now plays through \(device.name).")
        } else {
            record(.user, "\(name(of: id)) follows the system output again")
        }
    }

    func setEffects(_ effects: SourceEffects, for id: SourceID) {
        mutatePreferences { $0.setEffects(effects, for: id, name: self.rows.first { $0.id == id }?.name) }
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].effects = effects }
        reconcileTaps()
    }

    /// Swaps in a whole configuration (import or restore) and brings every
    /// service in line with it. Session-only state is reset so the new settings apply.
    func replacePreferences(_ new: Preferences) {
        var p = new
        p.leveling.isEnabled = false
        preferences = p
        sessionVolumes = [:]
        ruleEngine = RuleEngine()
        lastProfileUndo = nil
        saveNow()
        registerShortcuts()
        rebuildRows()
        reconcileTaps()
        evaluateRules()
    }

    // MARK: Apple effects rack

    private func editRack(_ id: SourceID, _ change: (inout [RackEffect]) -> Void) {
        var effects = preferences.effects(for: id)
        change(&effects.rack)
        effects.rack = Array(effects.rack.prefix(SourceEffects.maxRackSize))
        setEffects(effects, for: id)
    }

    func addRackEffect(_ kind: String, to id: SourceID) {
        guard preferences.effects(for: id).rack.count < SourceEffects.maxRackSize else {
            show(.info, "An app can have up to \(SourceEffects.maxRackSize) effects.")
            return
        }
        editRack(id) { $0.append(.make(kind)) }
        let name = AppleEffectCatalog.entry(for: kind)?.name ?? kind
        record(.user, "\(self.name(of: id)): added \(name)")
    }

    func removeRackEffect(_ effectID: String, from id: SourceID) {
        editRack(id) { $0.removeAll { $0.id == effectID } }
    }

    func moveRackEffect(_ effectID: String, by offset: Int, in id: SourceID) {
        editRack(id) { rack in
            guard let i = rack.firstIndex(where: { $0.id == effectID }) else { return }
            let j = min(max(i + offset, 0), rack.count - 1)
            guard i != j else { return }
            rack.swapAt(i, j)
        }
    }

    func setRackBypass(_ bypassed: Bool, effect effectID: String, in id: SourceID) {
        editRack(id) { rack in
            if let i = rack.firstIndex(where: { $0.id == effectID }) { rack[i].isBypassed = bypassed }
        }
    }

    /// Choosing a preset replaces the effect's settings with the preset's.
    func setRackPreset(_ number: Int?, effect effectID: String, in id: SourceID) {
        editRack(id) { rack in
            guard let i = rack.firstIndex(where: { $0.id == effectID }) else { return }
            rack[i].presetNumber = number
            rack[i].parameters = [:]
        }
    }

    func setRackParameter(_ parameter: UInt32, to value: Float, effect effectID: String, in id: SourceID) {
        editRack(id) { rack in
            if let i = rack.firstIndex(where: { $0.id == effectID }) { rack[i].parameters[parameter] = value }
        }
    }

    func resetRackEffect(_ effectID: String, in id: SourceID) {
        editRack(id) { rack in
            guard let i = rack.firstIndex(where: { $0.id == effectID }) else { return }
            let fresh = RackEffect.make(rack[i].kind)
            rack[i].presetNumber = fresh.presetNumber
            rack[i].parameters = fresh.parameters
        }
    }

    func rebuildRowsPublic() { rebuildRows() }
    func reconcileTapsPublic() { reconcileTaps() }
    func mutatePreferencesPublic(_ change: (inout Preferences) -> Void) { mutatePreferences(change) }

    private func rebuildRows() {
        let visible = stabilizer.rows().map(\.id)
        let ids = SourceOrdering.arrange(
            visible: visible, pinned: preferences.pinned,
            includeIdlePinned: preferences.interface.showIdlePinnedApps,
            sort: preferences.interface.sort,
            name: { [identities, discovered, preferences] id in
                identities.identity(for: id, source: discovered[id], fallbackName: preferences.apps[id]?.lastKnownName).name
            })

        rows = ids.map { id in
            let source = discovered[id]
            let identity = identities.identity(
                for: id, source: source, fallbackName: preferences.apps[id]?.lastKnownName)
            let present = source != nil
            var capabilities = SourceCapabilities.derive(
                isShared: source?.isShared ?? (id == .sharedWebKit),
                permissionDenied: false,
                engineError: taps.errors[id])
            if !taps.isTapAvailable {
                capabilities = SourceCapabilities(volume: .unavailable(.unsupportedOS), mute: .unavailable(.unsupportedOS))
            }
            return SourceRowModel(
                id: id, name: identity.name, icon: identity.icon,
                volume: volume(for: id),
                isActive: source?.isActive ?? false,
                isPresent: present,
                isPinned: preferences.isPinned(id),
                isShared: source?.isShared ?? (id == .sharedWebKit),
                capabilities: capabilities,
                eq: preferences.eq(for: id),
                eqPresetName: eqLabel(for: id),
                isLeveled: preferences.isLeveled(id),
                effects: preferences.effects(for: id),
                route: routeResolution(for: id))
        }
    }

    // MARK: Taps

    private func reconcileTaps() {
        guard taps.isTapAvailable else { return }
        var desired: [SourceID: TapCoordinator.Request] = [:]
        if let systemOutput = currentOutput, systemOutput.isAlive {
            for (id, source) in discovered {
                let v = volume(for: id)
                let eq = preferences.eq(for: id)
                let leveled = preferences.isLeveled(id)
                let effects = preferences.effects(for: id)
                let route = routeResolution(for: id)
                guard TapCoordinator.Request.needsTap(volume: v, eq: eq, leveled: leveled, isActive: source.isActive,
                                                      effects: effects, routed: route.needsTap) else { continue }
                var destinationUID = systemOutput.id.uid
                if case .routed(let device) = route { destinationUID = device.uid }
                let name = rows.first { $0.id == id }?.name ?? id.rawValue
                desired[id] = .init(name: name, processObjectIDs: source.processObjectIDs,
                                    destinationUID: destinationUID, gain: v.gain, eq: eq,
                                    leveling: leveled ? preferences.leveling : nil, effects: effects)
            }
        }
        let errorsBefore = taps.errors
        taps.reconcile(desired: desired, present: Set(discovered.keys))
        if taps.errors != errorsBefore { rebuildRows() }
    }

    // MARK: Meters (only while the panel is open)

    private func startMeters() {
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        activity = [:]
        levelerAdjustments = [:]
    }

    private func tickMeters() {
        var next: [SourceID: Float] = [:]
        var suspect = false
        let now = Date()
        for row in rows where row.isPresent {
            guard let peak = taps.takePeak(row.id) else { continue }
            let previous = activity[row.id] ?? 0
            next[row.id] = max(peak, previous * 0.8)
            if peak > 0 { lastHeard[row.id] = now }
            // A tap that only ever delivers silence while the app reports playing
            // usually means macOS has not granted audio capture permission.
            if row.isActive, let since = taps.engagedSince(row.id), now.timeIntervalSince(since) > 4,
               now.timeIntervalSince(lastHeard[row.id] ?? since) > 4 {
                suspect = true
            }
        }
        if next != activity { activity = next }
        var adjustments: [SourceID: Float] = [:]
        for row in rows where row.isLeveled {
            if let db = taps.levelerAdjustment(row.id) { adjustments[row.id] = (db * 2).rounded() / 2 }
        }
        if adjustments != levelerAdjustments { levelerAdjustments = adjustments }
        if suspect != permissionSuspected { permissionSuspected = suspect }
    }

    // MARK: Preferences

    func updateInterface(_ change: (inout InterfacePreferences) -> Void) {
        mutatePreferences { change(&$0.interface) }
        rebuildRows()
    }

    // MARK: Leveling

    func setLevelingEnabled(_ on: Bool) {
        mutatePreferences { $0.leveling.isEnabled = on }
        if on && !preferences.hasSeenPermissionExplanation {
            showPermissionNote = true
            mutatePreferences { $0.hasSeenPermissionExplanation = true }
        }
        rebuildRows()
        reconcileTaps()
        show(.info, on ? "Normalizing app loudness. Adjustments are small and take a few seconds." : "Loudness normalizing off.")
    }

    func setLevelingTarget(_ target: LevelingSettings.Target) {
        mutatePreferences { $0.leveling.target = target }
        taps.resetLevelerMemory()
        reconcileTaps()
    }

    func setLevelingBoostOnly(_ on: Bool) {
        mutatePreferences { $0.leveling.boostOnly = on }
        taps.resetLevelerMemory()
        reconcileTaps()
    }

    func setExcludedFromLeveling(_ excluded: Bool, for id: SourceID) {
        let name = rows.first { $0.id == id }?.name
        mutatePreferences { $0.setExcludedFromLeveling(excluded, for: id, name: name) }
        rebuildRows()
        reconcileTaps()
    }

    func setRememberAppVolumes(_ remember: Bool) {
        mutatePreferences { $0.rememberAppVolumes = remember }
    }

    func toggleSection(_ name: String) {
        updateInterface { prefs in
            if prefs.collapsedSections.contains(name) {
                prefs.collapsedSections.remove(name)
            } else {
                prefs.collapsedSections.insert(name)
            }
        }
    }

    func isCollapsed(_ name: String) -> Bool { preferences.interface.collapsedSections.contains(name) }

    var rememberedApps: [(id: SourceID, name: String, pref: AppPreference)] {
        preferences.apps.map { (id: $0.key, name: $0.value.lastKnownName ?? $0.key.rawValue, pref: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func icon(for id: SourceID) -> NSImage? {
        identities.identity(for: id, source: discovered[id], fallbackName: nil).icon
    }

    private func mutatePreferences(_ change: (inout Preferences) -> Void) {
        change(&preferences)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try preferencesStore.save(preferences)
        } catch {
            show(.failure, "Couldn't save settings: \(error.localizedDescription)")
        }
    }

    // MARK: Feedback

    func show(_ kind: Feedback.Kind, _ message: String) {
        if kind == .failure { record(.failure, message) }
        feedback = Feedback(kind: kind, message: message)
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .failure ? 6 : 3))
            guard !Task.isCancelled else { return }
            self?.feedback = nil
        }
    }
}
