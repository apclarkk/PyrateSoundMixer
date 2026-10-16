import Foundation
import PyrateAudio
import PyrateCore

// MARK: - Profiles

extension AppStore {
    /// Saves the current setup as a profile covering the chosen aspects. App volumes
    /// and EQs are captured for apps in the mixer and apps you have adjusted before.
    @discardableResult
    func saveProfile(named name: String, aspects: Set<ProfileAspect>) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = saveProfileValues(aspects: aspects)
        profile.name = trimmed.isEmpty ? "Profile \(preferences.profiles.count + 1)" : trimmed
        mutatePreferencesPublic { $0.profiles.append(profile) }
        record(.profile, "Saved profile \(profile.name)")
        show(.success, "Saved profile \(profile.name).")
        return profile
    }

    /// Replaces a profile's captured values with the current setup, keeping its aspects.
    func updateProfileFromCurrent(_ id: String) {
        guard let existing = preferences.profiles.first(where: { $0.id == id }) else { return }
        let fresh = saveProfileValues(aspects: existing.aspects)
        mutatePreferencesPublic { prefs in
            guard let i = prefs.profiles.firstIndex(where: { $0.id == id }) else { return }
            prefs.profiles[i].apps = fresh.apps
            prefs.profiles[i].output = fresh.output
            prefs.profiles[i].input = fresh.input
        }
        show(.success, "Updated \(existing.name) from the current setup.")
    }

    private func saveProfileValues(aspects: Set<ProfileAspect>) -> Profile {
        var profile = Profile(name: "", aspects: aspects)
        for id in Set(rows.map(\.id)).union(preferences.apps.keys) {
            var setting = ProfileAppSetting()
            if aspects.contains(.appVolumes) { setting.volume = volume(for: id) }
            if aspects.contains(.appEQ), eq(for: id) != .off { setting.eq = eq(for: id) }
            if aspects.contains(.appEffects) { setting.effects = preferences.effects(for: id) }
            if aspects.contains(.appRoutes) {
                setting.route = preferences.route(for: id).map { .device($0) } ?? .system
            }
            if !setting.isEmpty { profile.apps[id] = setting }
        }
        if aspects.contains(.outputDevice), let d = currentOutput { profile.output = RememberedDevice(id: d.id, lastKnownName: d.name) }
        if aspects.contains(.inputDevice), let d = currentInput { profile.input = RememberedDevice(id: d.id, lastKnownName: d.name) }
        return profile
    }

    func renameProfile(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutatePreferencesPublic { prefs in
            if let i = prefs.profiles.firstIndex(where: { $0.id == id }) { prefs.profiles[i].name = trimmed }
        }
    }

    func setProfileAspects(_ id: String, _ aspects: Set<ProfileAspect>) {
        mutatePreferencesPublic { prefs in
            if let i = prefs.profiles.firstIndex(where: { $0.id == id }) { prefs.profiles[i].aspects = aspects }
        }
    }

    func duplicateProfile(_ id: String) {
        guard var copy = preferences.profiles.first(where: { $0.id == id }) else { return }
        copy.id = UUID().uuidString
        copy.name += " Copy"
        mutatePreferencesPublic { $0.profiles.append(copy) }
    }

    func deleteProfile(_ id: String) {
        mutatePreferencesPublic { prefs in
            prefs.profiles.removeAll { $0.id == id }
            prefs.shortcuts.set(nil, for: .activateProfile(id))
            // Rules that would activate it simply lose that action.
            for i in prefs.rules.indices {
                prefs.rules[i].actions.removeAll { $0 == .activateProfile(id) }
            }
        }
        registerShortcuts()
    }

    func moveProfiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutatePreferencesPublic { prefs in
            var items = prefs.profiles
            let moving = source.sorted().map { items[$0] }
            for index in source.sorted(by: >) { items.remove(at: index) }
            let insertAt = destination - source.filter { $0 < destination }.count
            items.insert(contentsOf: moving, at: min(max(insertAt, 0), items.count))
            prefs.profiles = items
        }
    }

    /// Applies a profile's aspects. What it replaces is kept so it can be undone.
    func activateProfile(id: String, origin: ChangeOrigin = .profile) {
        guard let profile = preferences.profiles.first(where: { $0.id == id }) else { return }
        var undo = ProfileUndo(profileName: profile.name, date: Date(), apps: [:],
                               output: currentOutput.map { RememberedDevice(id: $0.id, lastKnownName: $0.name) },
                               input: currentInput.map { RememberedDevice(id: $0.id, lastKnownName: $0.name) })
        var changes: [String] = []

        for (app, setting) in profile.apps {
            var previous = ProfileAppSetting()
            if profile.aspects.contains(.appVolumes), let v = setting.volume {
                previous.volume = volume(for: app)
                if previous.volume != v {
                    changes.append("\(name(of: app)) \(previous.volume!.isMuted ? "muted" : "\(previous.volume!.percent)%") to \(v.isMuted ? "muted" : "\(v.percent)%")")
                }
                apply(v, to: app, origin: origin)
            }
            if profile.aspects.contains(.appEQ), let e = setting.eq {
                previous.eq = eq(for: app)
                applyEQ(e, to: app, origin: origin)
            }
            if profile.aspects.contains(.appEffects), let fx = setting.effects {
                previous.effects = preferences.effects(for: app)
                setEffects(fx, for: app)
            }
            if profile.aspects.contains(.appRoutes), let route = setting.route {
                previous.route = preferences.route(for: app).map { .device($0) } ?? .system
                applyRoute(route.device, for: app)
            }
            if !previous.isEmpty { undo.apps[app] = previous }
        }
        if profile.aspects.contains(.outputDevice), let target = profile.output {
            if let device = outputDevices.first(where: { $0.id == target.id }) {
                selectOutput(device)
            } else {
                show(.info, "\(target.lastKnownName) isn't connected, so the output stays as it is.")
            }
        }
        if profile.aspects.contains(.inputDevice), let target = profile.input,
           let device = inputDevices.first(where: { $0.id == target.id }) {
            selectInput(device)
        }

        lastProfileUndo = undo
        let detail = changes.isEmpty ? "" : ". " + changes.prefix(3).joined(separator: ", ") + (changes.count > 3 ? ", and more" : "")
        record(origin == .rule ? .rule : .profile, "\(profile.name) profile activated\(detail)")
        show(.success, "\(profile.name) activated.")
    }

    /// Puts back what the last profile activation replaced.
    func undoLastProfile() {
        guard let undo = lastProfileUndo else { return }
        for (app, setting) in undo.apps {
            if let v = setting.volume { apply(v, to: app, origin: .profile) }
            if let e = setting.eq { applyEQ(e, to: app, origin: .profile) }
            if let fx = setting.effects { setEffects(fx, for: app) }
            if let route = setting.route { applyRoute(route.device, for: app) }
        }
        if let target = undo.output, target.id != selectedOutput.confirmed,
           let device = outputDevices.first(where: { $0.id == target.id }) {
            selectOutput(device)
        }
        if let target = undo.input, target.id != selectedInput.confirmed,
           let device = inputDevices.first(where: { $0.id == target.id }) {
            selectInput(device)
        }
        lastProfileUndo = nil
        record(.profile, "Undid \(undo.profileName) profile")
        show(.info, "Restored the setup from before \(undo.profileName).")
    }
}

// MARK: - Rules

extension AppStore {
    func addRule(_ rule: Rule) {
        mutatePreferencesPublic { $0.rules.append(rule) }
        evaluateRules()
    }

    func updateRule(_ rule: Rule) {
        mutatePreferencesPublic { prefs in
            if let i = prefs.rules.firstIndex(where: { $0.id == rule.id }) { prefs.rules[i] = rule }
        }
        evaluateRules()
    }

    func deleteRule(_ id: String) {
        mutatePreferencesPublic { $0.rules.removeAll { $0.id == id } }
        evaluateRules()
    }

    func moveRules(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutatePreferencesPublic { prefs in
            var items = prefs.rules
            let moving = source.sorted().map { items[$0] }
            for index in source.sorted(by: >) { items.remove(at: index) }
            let insertAt = destination - source.filter { $0 < destination }.count
            items.insert(contentsOf: moving, at: min(max(insertAt, 0), items.count))
            prefs.rules = items
        }
        evaluateRules()
    }

    func isRuleActive(_ id: String) -> Bool { ruleEngine.active.contains(id) }

    /// Name of the rule currently controlling an app's volume or EQ, if any.
    func ruleOwner(of id: SourceID) -> String? {
        let rules = preferences.rules
        let owner = ruleEngine.owner(of: .volume(id), rules: rules) ?? ruleEngine.owner(of: .eq(id), rules: rules)
        return owner.flatMap { o in rules.first { $0.id == o }?.name }
    }

    /// Re-evaluates every rule against what is happening now and applies the result.
    func evaluateRules() {
        let rules = preferences.rules
        guard !rules.isEmpty || !ruleEngine.active.isEmpty else { return }
        let effects = ruleEngine.evaluate(
            rules: rules, facts: ruleFacts,
            current: { [self] setting in
                switch setting {
                case .volume(let id): return .volume(volume(for: id))
                case .eq(let id): return .eq(eq(for: id))
                }
            },
            resolve: { [self] action, current in
                switch (action, current) {
                case (.setVolume(_, let level), .volume(var v)):
                    v.setLevel(level)
                    v.isMuted = false
                    return .volume(v)
                case (.mute, .volume(var v)):
                    v.isMuted = true
                    return .volume(v)
                case (.applyEQPreset(_, let presetID), .eq(var e)):
                    guard let preset = preferences.eqPreset(id: presetID) else { return nil }
                    e.apply(preset)
                    e.isBypassed = false
                    return .eq(e)
                default:
                    return nil
                }
            })

        let names = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0.name) })
        for effect in effects {
            switch effect {
            case .set(.volume(let id), .volume(let v), let rule):
                let before = volume(for: id)
                apply(v, to: id, origin: .rule)
                let what = "\(name(of: id)) \(before.isMuted ? "muted" : "\(before.percent)%") to \(v.isMuted ? "muted" : "\(v.percent)%")"
                record(.rule, rule.map { "\(names[$0] ?? "Rule"): \(what)" } ?? "Rules ended: \(what) restored")
            case .set(.eq(let id), .eq(let e), let rule):
                applyEQ(e, to: id, origin: .rule)
                let label = preferences.eqPreset(id: e.presetID)?.name ?? (e.isFlat ? "off" : "custom")
                record(.rule, rule.map { "\(names[$0] ?? "Rule"): \(name(of: id)) EQ \(label)" } ?? "Rules ended: \(name(of: id)) EQ restored")
            case .activateProfile(let profile, _):
                activateProfile(id: profile, origin: .rule)
            case .selectOutput(let deviceID, let rule):
                if let device = outputDevices.first(where: { $0.id == deviceID }) {
                    selectOutput(device)
                    record(.rule, "\(names[rule] ?? "Rule"): output to \(device.name)")
                }
            case .ruleStarted(let id):
                record(.rule, "\(names[id] ?? "Rule") started")
            case .ruleEnded(let id):
                record(.rule, "\(names[id] ?? "Rule") ended")
            default:
                break
            }
        }
    }
}

// MARK: - Activity history

extension AppStore {
    static var activityURL: URL {
        PreferencesStore.defaultURL().deletingLastPathComponent().appendingPathComponent("activity.json")
    }

    static func loadActivity() -> ActivityLog {
        guard let data = try? Data(contentsOf: activityURL),
              var log = try? JSONDecoder().decode(ActivityLog.self, from: data) else { return ActivityLog() }
        log.prune()
        return log
    }

    func record(_ kind: ActivityEntry.Kind, _ message: String) {
        guard preferences.keepActivityHistory else { return }
        var log = activityLog
        log.record(ActivityEntry(kind: kind, message: message))
        setActivity(log)
    }

    func clearActivity() {
        setActivity(ActivityLog())
    }

    func setKeepActivityHistory(_ keep: Bool) {
        mutatePreferencesPublic { $0.keepActivityHistory = keep }
        if !keep { clearActivity() }
    }
}
