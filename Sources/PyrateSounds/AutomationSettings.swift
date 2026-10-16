import SwiftUI
import PyrateAudio
import PyrateCore

/// Apps and devices that can be chosen in profiles and rules: everything in the
/// mixer now, plus anything remembered from before.
@MainActor
struct Choices {
    var apps: [(id: SourceID, name: String)]
    var devices: [(id: DeviceID, name: String)]

    init(store: AppStore) {
        var seen = Set<SourceID>()
        var apps: [(SourceID, String)] = []
        for row in store.rows where seen.insert(row.id).inserted { apps.append((row.id, row.name)) }
        for (id, pref) in store.preferences.apps where seen.insert(id).inserted {
            apps.append((id, pref.lastKnownName ?? id.rawValue))
        }
        self.apps = apps.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }.map { (id: $0.0, name: $0.1) }
        var devices: [(DeviceID, String)] = []
        var seenDevices = Set<DeviceID>()
        for d in store.outputDevices + store.inputDevices where seenDevices.insert(d.id).inserted { devices.append((d.id, d.name)) }
        for d in [store.preferences.preferredOutput, store.preferences.preferredInput].compactMap({ $0 })
            where seenDevices.insert(d.id).inserted { devices.append((d.id, d.lastKnownName)) }
        self.devices = devices.map { (id: $0.0, name: $0.1) }
    }

    func appName(_ id: SourceID) -> String { apps.first { $0.id == id }?.name ?? id.rawValue }
    func deviceName(_ id: DeviceID) -> String { devices.first { $0.id == id }?.name ?? "Unknown device" }
}

// MARK: - Profiles

struct ProfileSettings: View {
    @Environment(AppStore.self) private var store
    @State private var selection: String?
    @State private var creating = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.preferences.profiles) { profile in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(profile.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(profile.id)
                    }
                    .onMove { store.moveProfiles(fromOffsets: $0, toOffset: $1) }
                }
                HStack {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .help("Save the current setup as a new profile")
                        .accessibilityLabel("New profile")
                    Button {
                        if let selection { store.deleteProfile(selection) }
                        selection = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .accessibilityLabel("Delete profile")
                    Spacer()
                    Button("Import…") { store.importProfile() }
                        .help("Import a profile someone shared with you")
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 170, maxWidth: 220)

            Group {
                if let id = selection, let profile = store.preferences.profiles.first(where: { $0.id == id }) {
                    ProfileDetail(profile: profile)
                } else {
                    ContentUnavailableView("No Profile Selected", systemImage: "square.stack.3d.up",
                        description: Text("A profile saves part of your setup (app volumes, EQ, devices) so you can switch to it in one click. Profiles only change what they include, so they can be combined."))
                }
            }
            .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $creating) {
            NewProfileSheet { name, aspects in
                selection = store.saveProfile(named: name, aspects: aspects).id
            }
        }
    }
}

struct NewProfileSheet: View {
    var onSave: (String, Set<ProfileAspect>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var aspects: Set<ProfileAspect> = [.appVolumes]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Profile from Current Setup").font(.headline)
            TextField("Name, for example Meetings", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Include").font(.subheadline).foregroundStyle(.secondary)
            ForEach(ProfileAspect.allCases, id: \.self) { aspect in
                Toggle(aspect.title, isOn: Binding(
                    get: { aspects.contains(aspect) },
                    set: { on in
                        if on { aspects.insert(aspect) } else { aspects.remove(aspect) }
                    }))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(name, aspects)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(aspects.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

struct ProfileDetail: View {
    @Environment(AppStore.self) private var store
    var profile: Profile
    @State private var name = ""

    var body: some View {
        let choices = Choices(store: store)
        Form {
            Section {
                TextField("Name", text: $name)
                    .onSubmit { store.renameProfile(profile.id, to: name) }
                HStack {
                    Button("Activate") { store.activateProfile(id: profile.id) }
                        .keyboardShortcut(.defaultAction)
                    Button("Update from Current Setup") { store.updateProfileFromCurrent(profile.id) }
                    Button("Duplicate") { store.duplicateProfile(profile.id) }
                    Button("Export…") { store.exportProfile(profile.id) }
                }
            }
            Section("Controls") {
                ForEach(ProfileAspect.allCases, id: \.self) { aspect in
                    Toggle(aspect.title, isOn: Binding(
                        get: { profile.aspects.contains(aspect) },
                        set: { on in
                            var a = profile.aspects
                            if on { a.insert(aspect) } else { a.remove(aspect) }
                            store.setProfileAspects(profile.id, a)
                        }))
                }
                Text("Turning on an aspect that wasn't captured does nothing until you choose Update from Current Setup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Captured values") {
                if profile.aspects.contains(.outputDevice), let output = profile.output {
                    LabeledContent("Output", value: output.lastKnownName)
                }
                if profile.aspects.contains(.inputDevice), let input = profile.input {
                    LabeledContent("Input", value: input.lastKnownName)
                }
                ForEach(profile.apps.keys.sorted { choices.appName($0) < choices.appName($1) }, id: \.self) { app in
                    let setting = profile.apps[app]!
                    LabeledContent(choices.appName(app)) {
                        Text(describe(setting)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { name = profile.name }
        .onChange(of: profile.id) { name = profile.name }
    }

    private func describe(_ setting: ProfileAppSetting) -> String {
        var parts: [String] = []
        if profile.aspects.contains(.appVolumes), let v = setting.volume {
            parts.append(v.isMuted ? "muted" : "\(v.percent)%")
        }
        if profile.aspects.contains(.appEQ), let e = setting.eq {
            parts.append("EQ " + (store.preferences.eqPreset(id: e.presetID)?.name ?? "custom"))
        }
        if profile.aspects.contains(.appEffects), let fx = setting.effects, let summary = fx.summary {
            parts.append(summary)
        }
        if profile.aspects.contains(.appRoutes), let device = setting.route?.device {
            parts.append("to \(device.lastKnownName)")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Automation

struct AutomationSettings: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Rule?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(store.preferences.rules) { rule in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { var r = rule; r.isEnabled = $0; store.updateRule(r) }))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Enable \(rule.name)")
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(rule.name)
                                if store.isRuleActive(rule.id) {
                                    Text("Active").font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Theme.accent.opacity(0.2)))
                                }
                            }
                            Text(RuleText.describe(rule, choices: Choices(store: store), store: store))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Edit") { editing = rule }
                    }
                }
                .onMove { store.moveRules(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in offsets.map { store.preferences.rules[$0].id }.forEach(store.deleteRule) }
            }
            .overlay {
                if store.preferences.rules.isEmpty {
                    ContentUnavailableView("No Rules", systemImage: "wand.and.stars",
                        description: Text("Rules change your audio when something happens, for example: while Zoom is using the microphone, set Music to 25%."))
                }
            }
            HStack {
                Button { editing = Rule(name: "New Rule", trigger: .appPlaying(SourceID("")), actions: []) } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                Spacer()
                Text("Rules higher in the list win when two change the same thing. Drag to reorder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, isNew: !store.preferences.rules.contains { $0.id == rule.id }) { saved in
                if store.preferences.rules.contains(where: { $0.id == saved.id }) {
                    store.updateRule(saved)
                } else {
                    store.addRule(saved)
                }
            } onDelete: { store.deleteRule(rule.id) }
        }
    }
}

enum RuleText {
    @MainActor
    static func describe(_ rule: Rule, choices: Choices, store: AppStore) -> String {
        let when: String
        switch rule.trigger {
        case .appPlaying(let id): when = "While \(choices.appName(id)) is playing"
        case .appUsingMicrophone(let id): when = "While \(choices.appName(id)) is using the microphone"
        case .deviceConnected(let id): when = "While \(choices.deviceName(id)) is connected"
        case .outputIs(let id): when = "While the output is \(choices.deviceName(id))"
        }
        let actions = rule.actions.map { action -> String in
            switch action {
            case .setVolume(let id, let level): return "set \(choices.appName(id)) to \(Int((level * 100).rounded()))%"
            case .mute(let id): return "mute \(choices.appName(id))"
            case .applyEQPreset(let id, let preset): return "use \(store.preferences.eqPreset(id: preset)?.name ?? "an EQ preset") on \(choices.appName(id))"
            case .activateProfile(let id): return "activate \(store.preferences.profiles.first { $0.id == id }?.name ?? "a profile")"
            case .selectOutput(let id): return "switch output to \(choices.deviceName(id))"
            }
        }
        let tail = actions.isEmpty ? "do nothing yet" : actions.joined(separator: ", ")
        return "\(when), \(tail)\(rule.revertWhenEnds ? "; undo afterwards" : "")."
    }
}

struct RuleEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var rule: Rule
    var isNew: Bool
    var onSave: (Rule) -> Void
    var onDelete: () -> Void

    enum TriggerKind: String, CaseIterable { case playing, microphone, connected, output }
    enum ActionKind: String, CaseIterable { case volume, mute, eq, profile, output }

    var body: some View {
        let choices = Choices(store: store)
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $rule.name)
                Section("When") {
                    Picker("Condition", selection: triggerKind) {
                        Text("An app is playing").tag(TriggerKind.playing)
                        Text("An app is using the microphone").tag(TriggerKind.microphone)
                        Text("A device is connected").tag(TriggerKind.connected)
                        Text("The output is a device").tag(TriggerKind.output)
                    }
                    switch rule.trigger {
                    case .appPlaying(let id), .appUsingMicrophone(let id):
                        appPicker("App", selection: id, choices: choices) { new in
                            if case .appPlaying = rule.trigger { rule.trigger = .appPlaying(new) } else { rule.trigger = .appUsingMicrophone(new) }
                        }
                    case .deviceConnected(let id), .outputIs(let id):
                        devicePicker("Device", selection: id, choices: choices) { new in
                            if case .deviceConnected = rule.trigger { rule.trigger = .deviceConnected(new) } else { rule.trigger = .outputIs(new) }
                        }
                    }
                }
                Section("Do") {
                    ForEach(rule.actions.indices, id: \.self) { index in
                        actionRow(index, choices: choices)
                    }
                    Menu("Add Action") {
                        Button("Set an app's volume") { rule.actions.append(.setVolume(choices.apps.first?.id ?? SourceID(""), level: 0.25)) }
                        Button("Mute an app") { rule.actions.append(.mute(choices.apps.first?.id ?? SourceID(""))) }
                        Button("Use an EQ preset on an app") {
                            rule.actions.append(.applyEQPreset(choices.apps.first?.id ?? SourceID(""), presetID: EQPreset.builtIns[1].id))
                        }
                        Button("Activate a profile") { rule.actions.append(.activateProfile(store.preferences.profiles.first?.id ?? "")) }
                            .disabled(store.preferences.profiles.isEmpty)
                        Button("Switch output device") { rule.actions.append(.selectOutput(store.outputDevices.first?.id ?? DeviceID(uid: ""))) }
                    }
                    Toggle("Undo volume, mute, and EQ changes when the condition ends", isOn: $rule.revertWhenEnds)
                }
                Text(RuleText.describe(rule, choices: choices, store: store))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Delete Rule", role: .destructive) { onDelete(); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { onSave(rule); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 520, height: 520)
    }

    private var isValid: Bool {
        let triggerOK: Bool
        switch rule.trigger {
        case .appPlaying(let id), .appUsingMicrophone(let id): triggerOK = !id.rawValue.isEmpty
        case .deviceConnected(let id), .outputIs(let id): triggerOK = !id.uid.isEmpty
        }
        return triggerOK && !rule.actions.isEmpty && !rule.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var triggerKind: Binding<TriggerKind> {
        Binding(get: {
            switch rule.trigger {
            case .appPlaying: return .playing
            case .appUsingMicrophone: return .microphone
            case .deviceConnected: return .connected
            case .outputIs: return .output
            }
        }, set: { kind in
            let app: SourceID
            let device: DeviceID
            switch rule.trigger {
            case .appPlaying(let id), .appUsingMicrophone(let id): app = id; device = DeviceID(uid: "")
            case .deviceConnected(let id), .outputIs(let id): app = SourceID(""); device = id
            }
            switch kind {
            case .playing: rule.trigger = .appPlaying(app)
            case .microphone: rule.trigger = .appUsingMicrophone(app)
            case .connected: rule.trigger = .deviceConnected(device)
            case .output: rule.trigger = .outputIs(device)
            }
        })
    }

    private func appPicker(_ title: String, selection: SourceID, choices: Choices, set: @escaping @MainActor @Sendable (SourceID) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: { value in MainActor.assumeIsolated { set(value) } })) {
            if selection.rawValue.isEmpty { Text("Choose…").tag(SourceID("")) }
            ForEach(choices.apps, id: \.id) { Text($0.name).tag($0.id) }
        }
    }

    private func devicePicker(_ title: String, selection: DeviceID, choices: Choices, set: @escaping @MainActor @Sendable (DeviceID) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: { value in MainActor.assumeIsolated { set(value) } })) {
            if selection.uid.isEmpty { Text("Choose…").tag(DeviceID(uid: "")) }
            ForEach(choices.devices, id: \.id) { Text($0.name).tag($0.id) }
        }
    }

    @ViewBuilder
    private func actionRow(_ index: Int, choices: Choices) -> some View {
        let action = rule.actions[index]
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                switch action {
                case .setVolume(let id, let level):
                    appPicker("Set volume of", selection: id, choices: choices) { rule.actions[index] = .setVolume($0, level: level) }
                    HStack {
                        Slider(value: Binding(get: { level }, set: { rule.actions[index] = .setVolume(id, level: $0) }), in: 0...1)
                        Text("\(Int((level * 100).rounded()))%").monospacedDigit().frame(width: 40)
                    }
                case .mute(let id):
                    appPicker("Mute", selection: id, choices: choices) { rule.actions[index] = .mute($0) }
                case .applyEQPreset(let id, let preset):
                    appPicker("EQ for", selection: id, choices: choices) { rule.actions[index] = .applyEQPreset($0, presetID: preset) }
                    Picker("Preset", selection: Binding(get: { preset }, set: { rule.actions[index] = .applyEQPreset(id, presetID: $0) })) {
                        ForEach(store.eqPresets) { Text($0.name).tag($0.id) }
                    }
                case .activateProfile(let id):
                    Picker("Activate profile", selection: Binding(get: { id }, set: { rule.actions[index] = .activateProfile($0) })) {
                        ForEach(store.preferences.profiles) { Text($0.name).tag($0.id) }
                    }
                case .selectOutput(let id):
                    devicePicker("Switch output to", selection: id, choices: choices) { rule.actions[index] = .selectOutput($0) }
                }
            }
            Button {
                rule.actions.remove(at: index)
            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove action")
        }
    }
}


// MARK: - Activity

struct ActivitySettings: View {
    @Environment(AppStore.self) private var store
    @State private var filter: ActivityEntry.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Show", selection: $filter) {
                    Text("Everything").tag(ActivityEntry.Kind?.none)
                    Text("My changes").tag(ActivityEntry.Kind?.some(.user))
                    Text("Profiles").tag(ActivityEntry.Kind?.some(.profile))
                    Text("Rules").tag(ActivityEntry.Kind?.some(.rule))
                    Text("Devices").tag(ActivityEntry.Kind?.some(.device))
                    Text("Problems").tag(ActivityEntry.Kind?.some(.failure))
                }
                .frame(width: 220)
                Spacer()
                Toggle("Keep history", isOn: Binding(
                    get: { store.preferences.keepActivityHistory },
                    set: { store.setKeepActivityHistory($0) }))
                Button("Clear") { store.clearActivity() }
                    .disabled(store.activityLog.entries.isEmpty)
            }
            .padding(8)
            List(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(entry.kind))
                        .foregroundStyle(entry.kind == .failure ? Color.red : Theme.accent)
                        .frame(width: 16)
                        .accessibilityLabel(entry.kind.rawValue)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .leading)
                    Text(entry.message)
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No Activity", systemImage: "clock",
                        description: Text("Changes you make, profiles, rules, and device events appear here, so you can see why the sound changed."))
                }
            }
            Text("Kept on this Mac for 7 days (at most 500 entries). Only app names, levels, and devices are recorded, never audio.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
    }

    private var entries: [ActivityEntry] {
        store.activityLog.entries.reversed().filter { filter == nil || $0.kind == filter }
    }

    private func symbol(_ kind: ActivityEntry.Kind) -> String {
        switch kind {
        case .user: return "hand.point.up.left"
        case .profile: return "square.stack.3d.up"
        case .rule: return "wand.and.stars"
        case .device: return "hifispeaker"
        case .failure: return "exclamationmark.triangle"
        }
    }
}
