import Foundation

// MARK: - Profiles

/// The parts of the audio setup a profile can control. A profile only touches
/// the aspects it includes, so profiles layer: "Meeting volumes" can be combined
/// with "Headphone EQ" without one overwriting the other.
public enum ProfileAspect: String, Codable, CaseIterable, Sendable {
    case appVolumes, appEQ, appEffects, appRoutes, outputDevice, inputDevice

    public var title: String {
        switch self {
        case .appVolumes: return "App volumes and mutes"
        case .appEQ: return "App EQ"
        case .appEffects: return "App effects (balance, channels, Apple effects)"
        case .appRoutes: return "Which output each app plays through"
        case .outputDevice: return "Output device"
        case .inputDevice: return "Input device"
        }
    }
}

/// Where a profile sends an app: the system output or a specific device.
public enum ProfileRoute: Codable, Hashable, Sendable {
    case system
    case device(RememberedDevice)

    public var device: RememberedDevice? {
        if case .device(let d) = self { return d }
        return nil
    }
}

public struct ProfileAppSetting: Codable, Hashable, Sendable {
    public var volume: VolumeState?
    public var eq: SourceEQ?
    public var effects: SourceEffects?
    public var route: ProfileRoute?

    public init(volume: VolumeState? = nil, eq: SourceEQ? = nil, effects: SourceEffects? = nil, route: ProfileRoute? = nil) {
        self.volume = volume
        self.eq = eq
        self.effects = effects
        self.route = route
    }

    public var isEmpty: Bool { volume == nil && eq == nil && effects == nil && route == nil }
}

extension SourceEQ: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(presetID); hasher.combine(gains); hasher.combine(isBypassed); hasher.combine(matchLoudness)
    }
}

extension VolumeState: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(level); hasher.combine(isMuted) }
}

public struct Profile: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var aspects: Set<ProfileAspect>
    public var apps: [SourceID: ProfileAppSetting]
    public var output: RememberedDevice?
    public var input: RememberedDevice?

    public init(id: String = UUID().uuidString, name: String, aspects: Set<ProfileAspect>,
                apps: [SourceID: ProfileAppSetting] = [:], output: RememberedDevice? = nil, input: RememberedDevice? = nil) {
        self.id = id
        self.name = name
        self.aspects = aspects
        self.apps = apps
        self.output = output
        self.input = input
    }

    /// One line describing what activating this profile changes.
    public var summary: String {
        var parts: [String] = []
        if aspects.contains(.appVolumes) {
            let n = apps.values.filter { $0.volume != nil }.count
            parts.append("\(n) app volume\(n == 1 ? "" : "s")")
        }
        if aspects.contains(.appEQ) {
            let n = apps.values.filter { $0.eq != nil }.count
            parts.append("\(n) app EQ\(n == 1 ? "" : "s")")
        }
        if aspects.contains(.appEffects) {
            let n = apps.values.filter { $0.effects.map { !$0.isNeutral } ?? false }.count
            parts.append("effects on \(n) app\(n == 1 ? "" : "s")")
        }
        if aspects.contains(.appRoutes) {
            let n = apps.values.filter { $0.route?.device != nil }.count
            parts.append("\(n) app route\(n == 1 ? "" : "s")")
        }
        if aspects.contains(.outputDevice), let output { parts.append("output \(output.lastKnownName)") }
        if aspects.contains(.inputDevice), let input { parts.append("input \(input.lastKnownName)") }
        return parts.isEmpty ? "Changes nothing yet" : parts.joined(separator: ", ")
    }
}

extension RememberedDevice: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What a profile activation replaced, so it can be undone.
public struct ProfileUndo: Codable, Equatable, Sendable {
    public var profileName: String
    public var date: Date
    public var apps: [SourceID: ProfileAppSetting]
    public var output: RememberedDevice?
    public var input: RememberedDevice?

    public init(profileName: String, date: Date, apps: [SourceID: ProfileAppSetting],
                output: RememberedDevice?, input: RememberedDevice?) {
        self.profileName = profileName
        self.date = date
        self.apps = apps
        self.output = output
        self.input = input
    }
}

// MARK: - Rules

/// A condition that is either true or false at any moment. Rules act when it
/// becomes true and can revert when it becomes false. Every trigger is something
/// public macOS APIs can actually observe.
public enum RuleTrigger: Codable, Hashable, Sendable {
    /// While an app is producing sound (with a short grace period across gaps).
    case appPlaying(SourceID)
    /// While an app is recording from a microphone (calls, meetings).
    case appUsingMicrophone(SourceID)
    /// While a device is connected.
    case deviceConnected(DeviceID)
    /// While the system output is a particular device.
    case outputIs(DeviceID)
}

public enum RuleAction: Codable, Hashable, Sendable {
    case setVolume(SourceID, level: Double)
    case mute(SourceID)
    case applyEQPreset(SourceID, presetID: String)
    case activateProfile(String)
    case selectOutput(DeviceID)

    /// Actions that claim a setting and can be reverted when the rule ends.
    public var setting: RuleEngine.Setting? {
        switch self {
        case .setVolume(let id, _), .mute(let id): return .volume(id)
        case .applyEQPreset(let id, _): return .eq(id)
        case .activateProfile, .selectOutput: return nil
        }
    }
}

public struct Rule: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var isEnabled: Bool
    public var trigger: RuleTrigger
    public var actions: [RuleAction]
    /// Put volume, mute, and EQ changes back when the condition ends.
    public var revertWhenEnds: Bool

    public init(id: String = UUID().uuidString, name: String, isEnabled: Bool = true,
                trigger: RuleTrigger, actions: [RuleAction], revertWhenEnds: Bool = true) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.actions = actions
        self.revertWhenEnds = revertWhenEnds
    }
}

/// Evaluates rules against observed facts and decides what to change.
///
/// - Rules earlier in the list have priority. When several active rules claim the
///   same setting, the highest one wins; when it ends, the next active claimant
///   takes over, and when none remain the value from before any rule is restored.
/// - A manual change to a claimed setting releases it: the user's value stands
///   until a rule claiming that setting newly activates.
/// - Effects are only emitted when the wanted value differs from the last one
///   applied, so re-evaluating with unchanged facts does nothing.
public struct RuleEngine: Sendable {
    public enum Setting: Hashable, Sendable {
        case volume(SourceID)
        case eq(SourceID)
    }

    public enum Value: Equatable, Sendable {
        case volume(VolumeState)
        case eq(SourceEQ)
    }

    public struct Facts: Equatable, Sendable {
        public var playing: Set<SourceID>
        public var usingMicrophone: Set<SourceID>
        public var connected: Set<DeviceID>
        public var output: DeviceID?

        public init(playing: Set<SourceID> = [], usingMicrophone: Set<SourceID> = [],
                    connected: Set<DeviceID> = [], output: DeviceID? = nil) {
            self.playing = playing
            self.usingMicrophone = usingMicrophone
            self.connected = connected
            self.output = output
        }

        public func satisfies(_ trigger: RuleTrigger) -> Bool {
            switch trigger {
            case .appPlaying(let id): return playing.contains(id)
            case .appUsingMicrophone(let id): return usingMicrophone.contains(id)
            case .deviceConnected(let id): return connected.contains(id)
            case .outputIs(let id): return output == id
            }
        }
    }

    public enum Effect: Equatable, Sendable {
        case set(Setting, Value, rule: String?)
        case activateProfile(String, rule: String)
        case selectOutput(DeviceID, rule: String)
        /// A rule began or ended (for the activity history).
        case ruleStarted(String)
        case ruleEnded(String)
    }

    public private(set) var active: Set<String> = []
    private var claims: [Setting: [String: Value]] = [:]
    private var base: [Setting: Value] = [:]
    private var released: Set<Setting> = []
    private var applied: [Setting: Value] = [:]

    public init() {}

    /// - Parameters:
    ///   - current: the setting's value right now (used to remember what to restore).
    ///   - resolve: turns an action into the concrete value it sets, given the current value.
    public mutating func evaluate(
        rules: [Rule], facts: Facts,
        current: (Setting) -> Value,
        resolve: (RuleAction, Value) -> Value?
    ) -> [Effect] {
        var effects: [Effect] = []
        let priority = Dictionary(uniqueKeysWithValues: rules.enumerated().map { ($1.id, $0) })
        let nowActive = Set(rules.filter { $0.isEnabled && facts.satisfies($0.trigger) }.map(\.id))
        let started = rules.filter { nowActive.contains($0.id) && !active.contains($0.id) }
        let ended = active.subtracting(nowActive)
        var touched: Set<Setting> = []

        for id in ended {
            effects.append(.ruleEnded(id))
            for setting in Array(claims.keys) where claims[setting]?[id] != nil {
                claims[setting]?[id] = nil
                touched.insert(setting)
            }
        }

        for rule in started {
            effects.append(.ruleStarted(rule.id))
            for action in rule.actions {
                guard let setting = action.setting else {
                    switch action {
                    case .activateProfile(let profile): effects.append(.activateProfile(profile, rule: rule.id))
                    case .selectOutput(let device): effects.append(.selectOutput(device, rule: rule.id))
                    default: break
                    }
                    continue
                }
                let now = current(setting)
                // Build on the value this rule already claims for the setting (mute + volume combine).
                guard let value = resolve(action, claims[setting]?[rule.id] ?? now) else { continue }
                if rule.revertWhenEnds {
                    // A new activation takes the setting back from a manual override.
                    if released.contains(setting) || base[setting] == nil {
                        released.remove(setting)
                        if claims[setting]?.isEmpty ?? true { base[setting] = now }
                    }
                    claims[setting, default: [:]][rule.id] = value
                    touched.insert(setting)
                } else {
                    effects.append(.set(setting, value, rule: rule.id))
                }
            }
        }

        for setting in touched where !released.contains(setting) {
            let claimants = claims[setting] ?? [:]
            let winner = claimants.keys.min { (priority[$0] ?? .max) < (priority[$1] ?? .max) }
            let ruleID = winner
            let wanted: Value?
            if let winner {
                wanted = claimants[winner]
            } else {
                wanted = base.removeValue(forKey: setting)
                claims[setting] = nil
            }
            guard let wanted, applied[setting] != wanted else {
                if winner == nil { applied[setting] = nil }
                continue
            }
            effects.append(.set(setting, wanted, rule: ruleID))
            applied[setting] = winner == nil ? nil : wanted
        }

        active = nowActive
        return effects
    }

    /// The user changed a setting by hand: their value wins over any rule claim
    /// until a rule claiming it newly activates.
    public mutating func userChanged(_ setting: Setting) {
        guard claims[setting]?.isEmpty == false || base[setting] != nil else { return }
        released.insert(setting)
        base[setting] = nil
        applied[setting] = nil
    }

    /// Which active rule currently controls a setting, if any.
    public func owner(of setting: Setting, rules: [Rule]) -> String? {
        guard !released.contains(setting), let claimants = claims[setting], !claimants.isEmpty else { return nil }
        let priority = Dictionary(uniqueKeysWithValues: rules.enumerated().map { ($1.id, $0) })
        return claimants.keys.min { (priority[$0] ?? .max) < (priority[$1] ?? .max) }
    }
}

// MARK: - Activity history

/// One meaningful change, kept so the app can explain why something happened.
/// Metadata only: app names and levels, never audio or listening history beyond that.
public struct ActivityEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user, profile, rule, device, failure
    }

    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var message: String

    public init(id: UUID = UUID(), date: Date = Date(), kind: Kind, message: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.message = message
    }
}

public struct ActivityLog: Codable, Equatable, Sendable {
    public static let maxEntries = 500
    public static let retention: TimeInterval = 7 * 24 * 3600

    public private(set) var entries: [ActivityEntry] = []

    public init(entries: [ActivityEntry] = []) {
        self.entries = entries
    }

    public mutating func record(_ entry: ActivityEntry) {
        entries.append(entry)
        prune(now: entry.date)
    }

    public mutating func prune(now: Date = Date()) {
        entries.removeAll { now.timeIntervalSince($0.date) > Self.retention }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    public mutating func clear() { entries.removeAll() }
}
