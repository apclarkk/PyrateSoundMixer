import Foundation

/// Durable per-app configuration. Separate from live audio state: a source
/// disappearing never erases its preference.
public struct AppPreference: Codable, Equatable, Sendable {
    public var volume: VolumeState
    public var lastKnownName: String?
    /// Per-app EQ. Always remembered, independent of the "remember volumes" setting.
    public var eq: SourceEQ?
    /// Balance and channel mode.
    public var effects: SourceEffects?
    /// Output this app plays through instead of the system output (nil = follow the system).
    public var route: RememberedDevice?

    public init(volume: VolumeState = .unity, lastKnownName: String? = nil, eq: SourceEQ? = nil) {
        self.volume = volume
        self.lastKnownName = lastKnownName
        self.eq = eq
    }
}

public enum Density: String, Codable, CaseIterable, Sendable {
    case compact
    case comfortable
}

public enum SourceSort: String, Codable, CaseIterable, Sendable {
    /// Order apps first appeared in. Stable: rows never jump around.
    case firstSeen
    case name

    public var title: String {
        switch self {
        case .firstSeen: return "Order they started playing"
        case .name: return "Name"
        }
    }
}

public struct InterfacePreferences: Codable, Equatable, Sendable {
    public var density: Density = .comfortable
    public var sort: SourceSort = .firstSeen
    /// Show pinned apps even when they are not playing, so their level can be set ahead of time.
    public var showIdlePinnedApps: Bool = true
    public var collapsedSections: Set<String> = []

    public init() {}
}

public struct RememberedDevice: Codable, Equatable, Sendable {
    public var id: DeviceID
    public var lastKnownName: String

    public init(id: DeviceID, lastKnownName: String) {
        self.id = id
        self.lastKnownName = lastKnownName
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = Preferences.currentSchemaVersion
    /// When true, an app's level and mute are restored the next time it plays.
    public var rememberAppVolumes: Bool = true
    public var apps: [SourceID: AppPreference] = [:]
    public var pinned: [SourceID] = []
    public var interface = InterfacePreferences()
    public var preferredOutput: RememberedDevice?
    public var hasSeenPermissionExplanation: Bool = false
    public var customEQPresets: [EQPreset] = []
    public var shortcuts: [ShortcutBinding] = []
    public var preferredInput: RememberedDevice?
    public var profiles: [Profile] = []
    public var rules: [Rule] = []
    public var keepActivityHistory: Bool = true
    /// Allow other apps and scripts to send commands through pyratesounds:// URLs.
    public var allowURLCommands: Bool = false

    public init() {}

    /// Reorders pinned apps (as from a list's move gesture).
    public mutating func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        var items = pinned
        let moving = source.sorted().map { items[$0] }
        for index in source.sorted(by: >) { items.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        items.insert(contentsOf: moving, at: min(max(insertAt, 0), items.count))
        pinned = items
    }

    public func effects(for id: SourceID) -> SourceEffects { apps[id]?.effects ?? .neutral }

    public mutating func setEffects(_ effects: SourceEffects, for id: SourceID, name: String?) {
        var pref = apps[id] ?? AppPreference(volume: volume(for: id))
        pref.effects = effects.isNeutral ? nil : effects
        if let name { pref.lastKnownName = name }
        apps[id] = pref
    }

    public func route(for id: SourceID) -> RememberedDevice? { apps[id]?.route }

    public mutating func setRoute(_ device: RememberedDevice?, for id: SourceID, name: String?) {
        var pref = apps[id] ?? AppPreference(volume: volume(for: id))
        pref.route = device
        if let name { pref.lastKnownName = name }
        apps[id] = pref
    }


    public var allEQPresets: [EQPreset] { EQPreset.builtIns + customEQPresets }

    public func eqPreset(id: String?) -> EQPreset? {
        guard let id else { return nil }
        return allEQPresets.first { $0.id == id }
    }

    public func eq(for id: SourceID) -> SourceEQ {
        apps[id]?.eq ?? .off
    }

    public mutating func setEQ(_ eq: SourceEQ, for id: SourceID, name: String?) {
        var pref = apps[id] ?? AppPreference(volume: volume(for: id))
        pref.eq = eq
        if let name { pref.lastKnownName = name }
        apps[id] = pref
    }

    /// Saves a custom preset. A blank or duplicate name gets a numbered suffix.
    @discardableResult
    public mutating func addCustomPreset(named name: String, gains: [Double]) -> EQPreset {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = base
        var n = 2
        while allEQPresets.contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(base) \(n)"
            n += 1
        }
        let preset = EQPreset(name: candidate, gains: gains)
        customEQPresets.append(preset)
        return preset
    }

    public mutating func renameCustomPreset(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = customEQPresets.firstIndex(where: { $0.id == id }) else { return }
        customEQPresets[index].name = trimmed
    }

    /// Deletes a custom preset. Apps using it keep their curve; they just lose the name.
    public mutating func deleteCustomPreset(id: String) {
        customEQPresets.removeAll { $0.id == id }
        for key in apps.keys where apps[key]?.eq?.presetID == id {
            apps[key]?.eq?.presetID = nil
        }
    }

    public func volume(for id: SourceID) -> VolumeState {
        guard rememberAppVolumes else { return .unity }
        return apps[id]?.volume ?? .unity
    }

    public mutating func setVolume(_ volume: VolumeState, for id: SourceID, name: String?) {
        var pref = apps[id] ?? AppPreference()
        pref.volume = volume
        if let name { pref.lastKnownName = name }
        apps[id] = pref
    }

    public func isPinned(_ id: SourceID) -> Bool { pinned.contains(id) }

    public mutating func setPinned(_ pin: Bool, for id: SourceID, name: String?) {
        pinned.removeAll { $0 == id }
        if pin {
            pinned.append(id)
            if apps[id] == nil { apps[id] = AppPreference(lastKnownName: name) }
        }
    }

    public mutating func forget(_ id: SourceID) {
        apps[id] = nil
        pinned.removeAll { $0 == id }
    }

    // Decode leniently so a preferences file from a newer or older build never wipes settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Preferences.currentSchemaVersion
        rememberAppVolumes = try c.decodeIfPresent(Bool.self, forKey: .rememberAppVolumes) ?? true
        apps = try c.decodeIfPresent([SourceID: AppPreference].self, forKey: .apps) ?? [:]
        pinned = try c.decodeIfPresent([SourceID].self, forKey: .pinned) ?? []
        interface = try c.decodeIfPresent(InterfacePreferences.self, forKey: .interface) ?? InterfacePreferences()
        preferredOutput = try c.decodeIfPresent(RememberedDevice.self, forKey: .preferredOutput)
        hasSeenPermissionExplanation = try c.decodeIfPresent(Bool.self, forKey: .hasSeenPermissionExplanation) ?? false
        customEQPresets = try c.decodeIfPresent([EQPreset].self, forKey: .customEQPresets) ?? []
        shortcuts = try c.decodeIfPresent([ShortcutBinding].self, forKey: .shortcuts) ?? []
        preferredInput = try c.decodeIfPresent(RememberedDevice.self, forKey: .preferredInput)
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        keepActivityHistory = try c.decodeIfPresent(Bool.self, forKey: .keepActivityHistory) ?? true
        allowURLCommands = try c.decodeIfPresent(Bool.self, forKey: .allowURLCommands) ?? false
    }
}

extension InterfacePreferences {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        density = try c.decodeIfPresent(Density.self, forKey: .density) ?? .comfortable
        sort = try c.decodeIfPresent(SourceSort.self, forKey: .sort) ?? .firstSeen
        showIdlePinnedApps = try c.decodeIfPresent(Bool.self, forKey: .showIdlePinnedApps) ?? true
        collapsedSections = try c.decodeIfPresent(Set<String>.self, forKey: .collapsedSections) ?? []
    }
}

/// Loads and saves preferences as versioned JSON. A corrupt file is moved aside,
/// never silently overwritten, so it can be recovered.
public final class PreferencesStore: @unchecked Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Pyrate Sounds", isDirectory: true)
            .appendingPathComponent("preferences.json")
    }

    public func load() -> Preferences {
        guard let data = try? Data(contentsOf: fileURL) else { return Preferences() }
        do {
            return try JSONDecoder().decode(Preferences.self, from: data)
        } catch {
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return Preferences()
        }
    }

    public func save(_ preferences: Preferences) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: fileURL, options: .atomic)
    }
}
