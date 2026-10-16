import Foundation

/// A whole configuration, as exported to a file. Versioned so future builds can
/// migrate it and older builds can refuse it clearly instead of misreading it.
public struct ConfigurationBundle: Codable, Equatable, Sendable {
    public static let format = "org.pyratesounds.configuration"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var appVersion: String
    public var preferences: Preferences

    public init(preferences: Preferences, appVersion: String, exportedAt: Date = Date()) {
        self.format = Self.format
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.preferences = preferences
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ConfigurationBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw ImportError.notAConfiguration
        }
        guard header.format == format else { throw ImportError.notAConfiguration }
        guard header.version <= currentVersion else { throw ImportError.newerVersion(header.version) }
        do {
            return try decoder.decode(ConfigurationBundle.self, from: data)
        } catch {
            throw ImportError.damaged
        }
    }

    struct Header: Decodable {
        var format: String
        var version: Int
    }
}

/// One profile plus the custom EQ presets it uses, for sharing.
public struct ProfileBundle: Codable, Equatable, Sendable {
    public static let format = "org.pyratesounds.profile"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var profile: Profile
    public var presets: [EQPreset]

    public init(profile: Profile, presets: [EQPreset]) {
        self.format = Self.format
        self.version = Self.currentVersion
        self.profile = profile
        self.presets = presets
    }

    /// Bundles a profile with the custom presets its EQ settings refer to.
    public static func make(_ profile: Profile, from preferences: Preferences) -> ProfileBundle {
        let used = Set(profile.apps.values.compactMap { $0.eq?.presetID })
        return ProfileBundle(profile: profile, presets: preferences.customEQPresets.filter { used.contains($0.id) })
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ProfileBundle {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(ConfigurationBundle.Header.self, from: data), header.format == format else {
            throw ImportError.notAConfiguration
        }
        guard header.version <= currentVersion else { throw ImportError.newerVersion(header.version) }
        guard let bundle = try? decoder.decode(ProfileBundle.self, from: data) else { throw ImportError.damaged }
        return bundle
    }
}

public enum ImportError: Error, Equatable, LocalizedError {
    case notAConfiguration
    case newerVersion(Int)
    case damaged

    public var errorDescription: String? {
        switch self {
        case .notAConfiguration: return "This file isn't a Pyrate Sounds configuration."
        case .newerVersion(let v): return "This file was made by a newer version of Pyrate Sounds (format \(v)). Update Pyrate Sounds to import it."
        case .damaged: return "This file is damaged or incomplete, so nothing was imported."
        }
    }
}

/// What an import contains and what won't work on this Mac, shown before anything changes.
public struct ImportReport: Equatable, Sendable {
    public var appCount: Int
    public var presetCount: Int
    public var profileCount: Int
    public var ruleCount: Int
    public var shortcutCount: Int
    /// Devices the configuration refers to that aren't connected now.
    public var missingDevices: [RememberedDevice]

    public static func make(for preferences: Preferences, availableDevices: Set<DeviceID>) -> ImportReport {
        var missing: [DeviceID: RememberedDevice] = [:]
        for device in preferences.referencedDevices() where !availableDevices.contains(device.id) {
            missing[device.id] = missing[device.id] ?? device
        }
        return ImportReport(
            appCount: preferences.apps.count,
            presetCount: preferences.customEQPresets.count,
            profileCount: preferences.profiles.count,
            ruleCount: preferences.rules.count,
            shortcutCount: preferences.shortcuts.count,
            missingDevices: missing.values.sorted { $0.lastKnownName < $1.lastKnownName })
    }
}

extension Preferences {
    /// Every device the configuration mentions, with its last known name.
    public func referencedDevices() -> [RememberedDevice] {
        var found: [RememberedDevice] = []
        var names: [DeviceID: String] = [:]
        func add(_ d: RememberedDevice?) {
            guard let d else { return }
            names[d.id] = d.lastKnownName
            found.append(d)
        }
        add(preferredOutput)
        add(preferredInput)
        apps.values.forEach { add($0.route) }
        for profile in profiles {
            add(profile.output)
            add(profile.input)
            profile.apps.values.forEach { add($0.route?.device) }
        }
        for rule in rules {
            switch rule.trigger {
            case .deviceConnected(let id), .outputIs(let id):
                found.append(RememberedDevice(id: id, lastKnownName: names[id] ?? id.uid))
            default: break
            }
            for case .selectOutput(let id) in rule.actions {
                found.append(RememberedDevice(id: id, lastKnownName: names[id] ?? id.uid))
            }
        }
        var seen = Set<DeviceID>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// Replaces device references the user chose to remap. Devices not in the map
    /// are left exactly as they were: nothing is remapped silently.
    public func remappingDevices(_ map: [DeviceID: RememberedDevice]) -> Preferences {
        guard !map.isEmpty else { return self }
        func swap(_ d: RememberedDevice?) -> RememberedDevice? { d.map { map[$0.id] ?? $0 } }
        func swap(_ id: DeviceID) -> DeviceID { map[id]?.id ?? id }
        var p = self
        p.preferredOutput = swap(preferredOutput)
        p.preferredInput = swap(preferredInput)
        for key in Array(p.apps.keys) {
            let route = swap(p.apps[key]?.route)
            p.apps[key]?.route = route
        }
        for i in p.profiles.indices {
            p.profiles[i].output = swap(p.profiles[i].output)
            p.profiles[i].input = swap(p.profiles[i].input)
            for app in Array(p.profiles[i].apps.keys) {
                if case .device(let d)? = p.profiles[i].apps[app]?.route, let mapped = map[d.id] {
                    p.profiles[i].apps[app]?.route = .device(mapped)
                }
            }
        }
        for i in p.rules.indices {
            switch p.rules[i].trigger {
            case .deviceConnected(let id): p.rules[i].trigger = .deviceConnected(swap(id))
            case .outputIs(let id): p.rules[i].trigger = .outputIs(swap(id))
            default: break
            }
            p.rules[i].actions = p.rules[i].actions.map {
                if case .selectOutput(let id) = $0 { return .selectOutput(swap(id)) }
                return $0
            }
        }
        return p
    }

    /// Adds another configuration's presets, profiles, and rules to this one
    /// without replacing anything. Items with the same identity are skipped.
    public func merging(_ other: Preferences) -> Preferences {
        var p = self
        let presetIDs = Set(customEQPresets.map(\.id))
        p.customEQPresets += other.customEQPresets.filter { !presetIDs.contains($0.id) }
        let profileIDs = Set(profiles.map(\.id))
        p.profiles += other.profiles.filter { !profileIDs.contains($0.id) }
        let ruleIDs = Set(rules.map(\.id))
        p.rules += other.rules.filter { !ruleIDs.contains($0.id) }
        for (id, pref) in other.apps where p.apps[id] == nil { p.apps[id] = pref }
        return p
    }
}
