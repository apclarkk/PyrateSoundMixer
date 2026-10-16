import AppKit
import Foundation
import PyrateAudio
import PyrateCore
import UniformTypeIdentifiers

// MARK: - Commands (URL scheme and future integrations)

extension AppStore {
    /// Handles a pyratesounds:// URL if commands from other apps are allowed.
    func handle(_ url: URL) {
        guard preferences.allowURLCommands else {
            show(.info, "Another app tried to control Pyrate Sounds. Allow it in Settings > Integrations.")
            record(.failure, "Blocked URL command (integrations are off): \(url.absoluteString)")
            return
        }
        guard let command = PyrateCommand.parse(url) else {
            show(.failure, "Pyrate Sounds didn't understand \(url.absoluteString).")
            return
        }
        perform(command)
    }

    /// Runs a command, matching apps, devices, profiles, and presets by name.
    func perform(_ command: PyrateCommand) {
        func app(_ name: String) -> SourceID? {
            let candidates = Choices(store: self).apps
            return candidates.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
                ?? candidates.first { $0.id.rawValue.caseInsensitiveCompare(name) == .orderedSame }?.id
                ?? candidates.first { $0.name.localizedCaseInsensitiveContains(name) }?.id
        }
        func fail(_ what: String) { show(.failure, "Command failed: \(what) not found.") }

        switch command {
        case .activateProfile(let name):
            guard let p = preferences.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return fail("profile \(name)") }
            activateProfile(id: p.id)
            return
        case .setVolume(let name, let percent):
            guard let id = app(name) else { return fail(name) }
            var v = volume(for: id); v.setLevel(Double(percent) / 100); v.isMuted = false
            apply(v, to: id)
        case .adjustVolume(let name, let delta):
            guard let id = app(name) else { return fail(name) }
            var v = volume(for: id); v.setLevel(v.level + Double(delta) / 100)
            apply(v, to: id)
        case .mute(let name), .unmute(let name), .toggleMute(let name):
            guard let id = app(name) else { return fail(name) }
            var v = volume(for: id)
            switch command {
            case .mute: v.isMuted = true
            case .unmute: v.isMuted = false
            default: v.toggleMute()
            }
            apply(v, to: id)
        case .setOutputVolume(let percent):
            setMasterLevel(Double(percent) / 100)
            masterEditing(false)
        case .toggleOutputMute:
            toggleMasterMute()
        case .selectOutput(let name):
            guard let device = outputDevices.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? outputDevices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) else { return fail("device \(name)") }
            selectOutput(device)
        case .applyPreset(let name, let presetName):
            guard let id = app(name) else { return fail(name) }
            guard let preset = eqPresets.first(where: { $0.name.caseInsensitiveCompare(presetName) == .orderedSame }) else { return fail("preset \(presetName)") }
            selectEQPreset(preset, for: id)
        case .undoProfile:
            undoLastProfile()
            return
        }
        record(.user, "Command from another app: \(command.summary)")
    }

    func setAllowURLCommands(_ allow: Bool) {
        mutatePreferencesPublic { $0.allowURLCommands = allow }
    }
}

// MARK: - Export, import, backups

extension AppStore {
    static var backupsURL: URL {
        PreferencesStore.defaultURL().deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pyrate Sounds Settings.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ConfigurationBundle(preferences: preferences, appVersion: appVersion).encoded().write(to: url, options: .atomic)
            show(.success, "Exported settings.")
        } catch {
            show(.failure, "Couldn't export settings: \(error.localizedDescription)")
        }
    }

    /// Asks for a file and returns the decoded configuration plus a report for review.
    func chooseConfigurationToImport() -> (ConfigurationBundle, ImportReport)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let bundle = try ConfigurationBundle.decode(Data(contentsOf: url))
            let available = Set(outputDevices.map(\.id) + inputDevices.map(\.id))
            return (bundle, ImportReport.make(for: bundle.preferences, availableDevices: available))
        } catch {
            show(.failure, (error as? LocalizedError)?.errorDescription ?? "Couldn't read that file.")
            return nil
        }
    }

    enum ImportMode { case replace, merge }

    /// Applies an import after backing up the current settings.
    func applyImport(_ bundle: ConfigurationBundle, mode: ImportMode, remap: [DeviceID: RememberedDevice]) {
        guard backUpNow(reason: "before-import") else { return }
        let incoming = bundle.preferences.remappingDevices(remap)
        let result = mode == .replace ? incoming : preferences.merging(incoming)
        replacePreferences(result)
        record(.user, mode == .replace ? "Imported settings (replaced)" : "Imported presets, profiles, and rules (merged)")
        show(.success, "Imported settings. Your previous settings were backed up.")
    }

    @discardableResult
    func backUpNow(reason: String = "manual") -> Bool {
        do {
            try FileManager.default.createDirectory(at: Self.backupsURL, withIntermediateDirectories: true)
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            let url = Self.backupsURL.appendingPathComponent("settings-\(stamp)-\(reason).json")
            try ConfigurationBundle(preferences: preferences, appVersion: appVersion).encoded().write(to: url, options: .atomic)
            pruneBackups()
            return true
        } catch {
            show(.failure, "Couldn't back up settings, so nothing was changed: \(error.localizedDescription)")
            return false
        }
    }

    var backups: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.backupsURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func pruneBackups(keep: Int = 15) {
        for url in backups.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }

    func restoreBackup(_ url: URL) {
        do {
            let bundle = try ConfigurationBundle.decode(Data(contentsOf: url))
            guard backUpNow(reason: "before-restore") else { return }
            replacePreferences(bundle.preferences)
            record(.user, "Restored settings from a backup")
            show(.success, "Restored settings from the backup.")
        } catch {
            show(.failure, (error as? LocalizedError)?.errorDescription ?? "Couldn't restore that backup.")
        }
    }

    // MARK: Profile sharing

    func exportProfile(_ id: String) {
        guard let profile = preferences.profiles.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profile.name).pyrateprofile.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProfileBundle.make(profile, from: preferences).encoded().write(to: url, options: .atomic)
            show(.success, "Exported \(profile.name).")
        } catch {
            show(.failure, "Couldn't export the profile: \(error.localizedDescription)")
        }
    }

    func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bundle = try ProfileBundle.decode(Data(contentsOf: url))
            var profile = bundle.profile
            if preferences.profiles.contains(where: { $0.id == profile.id }) { profile.id = UUID().uuidString }
            if preferences.profiles.contains(where: { $0.name == profile.name }) { profile.name += " (Imported)" }
            mutatePreferencesPublic { prefs in
                let known = Set(prefs.customEQPresets.map(\.id))
                prefs.customEQPresets += bundle.presets.filter { !known.contains($0.id) }
                prefs.profiles.append(profile)
            }
            let missing = [profile.output, profile.input].compactMap { $0 }
                .filter { d in !(outputDevices + inputDevices).contains { $0.id == d.id } }
            let note = missing.isEmpty ? "" : " \(missing.map(\.lastKnownName).joined(separator: ", ")) isn't connected on this Mac; that part is skipped until it is."
            record(.profile, "Imported profile \(profile.name)")
            show(.success, "Imported \(profile.name).\(note)")
        } catch {
            show(.failure, (error as? LocalizedError)?.errorDescription ?? "Couldn't read that profile.")
        }
    }
}
