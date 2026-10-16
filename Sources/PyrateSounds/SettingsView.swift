import ServiceManagement
import SwiftUI
import PyrateCore

/// Settings configure how the app behaves; the panel is for doing things.
/// Sidebar layout like System Settings, since there are more panes than fit in tabs.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, audio, interface, applications, shortcuts, profiles, automation, activity, backup, integrations, privacy, diagnostics
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .audio: return "Audio"
            case .interface: return "Interface"
            case .applications: return "Applications"
            case .shortcuts: return "Shortcuts"
            case .profiles: return "Profiles"
            case .automation: return "Automation"
            case .activity: return "Activity"
            case .backup: return "Backup"
            case .integrations: return "Integrations"
            case .privacy: return "Privacy"
            case .diagnostics: return "Diagnostics"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .audio: return "waveform"
            case .interface: return "rectangle.3.group"
            case .applications: return "square.grid.2x2"
            case .shortcuts: return "command"
            case .profiles: return "square.stack.3d.up"
            case .automation: return "wand.and.stars"
            case .activity: return "clock"
            case .backup: return "externaldrive"
            case .integrations: return "link"
            case .privacy: return "lock.shield"
            case .diagnostics: return "stethoscope"
            }
        }

        static let groups: [[Pane]] = [
            [.general, .audio, .interface, .applications, .shortcuts],
            [.profiles, .automation, .activity],
            [.backup, .integrations, .privacy, .diagnostics],
        ]
    }

    @State private var pane: Pane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.groups.indices, id: \.self) { i in
                    Section {
                        ForEach(Pane.groups[i]) { p in
                            Label(p.title, systemImage: p.symbol).tag(p)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            detail(pane ?? .general)
                .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 720, minHeight: 500)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    @ViewBuilder
    private func detail(_ pane: Pane) -> some View {
        switch pane {
        case .general: GeneralSettings()
        case .audio: AudioSettings()
        case .interface: InterfaceSettings()
        case .applications: ApplicationSettings()
        case .shortcuts: ShortcutSettings()
        case .profiles: ProfileSettings()
        case .automation: AutomationSettings()
        case .activity: ActivitySettings()
        case .backup: BackupSettings()
        case .integrations: IntegrationSettings()
        case .privacy: PrivacySettings()
        case .diagnostics: DiagnosticsView()
        }
    }
}

struct GeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        Form {
            Toggle("Open Pyrate Sounds at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        error = nil
                    } catch {
                        self.error = "Couldn't change login item: \(error.localizedDescription). This works when Pyrate Sounds runs from its app bundle."
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

struct AudioSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section("Processing") {
                Text("Apps with EQ or a volume below 100% run through a peak limiter with 5 ms of lookahead, which keeps them from clipping without audible distortion. Apps you have not adjusted are not processed at all.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct InterfaceSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Picker("Density", selection: Binding(
                get: { store.preferences.interface.density },
                set: { value in store.updateInterface { $0.density = value } })
            ) {
                Text("Comfortable").tag(Density.comfortable)
                Text("Compact").tag(Density.compact)
            }
            .pickerStyle(.segmented)
            Picker("Sort apps by", selection: Binding(
                get: { store.preferences.interface.sort },
                set: { value in store.updateInterface { $0.sort = value } })
            ) {
                ForEach(SourceSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Show pinned apps when they aren't playing", isOn: Binding(
                get: { store.preferences.interface.showIdlePinnedApps },
                set: { value in store.updateInterface { $0.showIdlePinnedApps = value } }))
            Text("Pinned apps stay at the top of the mixer, so you can set their level before they start playing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct ApplicationSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section {
                Toggle("Remember each app's volume", isOn: Binding(
                    get: { store.preferences.rememberAppVolumes },
                    set: { store.setRememberAppVolumes($0) }))
                Text("When on, an app returns to the level you last set the next time it plays. Pinned apps are always remembered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !store.preferences.pinned.isEmpty {
                Section {
                    List {
                        ForEach(store.preferences.pinned, id: \.self) { id in
                            HStack {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                if let icon = store.icon(for: id) {
                                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                }
                                Text(store.preferences.apps[id]?.lastKnownName ?? id.rawValue)
                            }
                        }
                        .onMove { store.movePinned(fromOffsets: $0, toOffset: $1) }
                    }
                    .frame(minHeight: CGFloat(store.preferences.pinned.count) * 28)
                } header: {
                    Text("Pinned order")
                } footer: {
                    Text("Drag to reorder. Pinned apps stay at the top of the mixer in this order.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Remembered apps") {
                if store.rememberedApps.isEmpty {
                    Text("Apps you adjust or pin will appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.rememberedApps, id: \.id) { app in
                    HStack {
                        if let icon = store.icon(for: app.id) {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Text(app.name)
                        Spacer()
                        Text(app.pref.volume.isMuted ? "Muted" : "\(app.pref.volume.percent)%")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Toggle("Pinned", isOn: Binding(
                            get: { store.preferences.isPinned(app.id) },
                            set: { store.setPinned($0, for: app.id) }))
                            .toggleStyle(.checkbox)
                        Button("Forget") { store.forget(app.id) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacySettings: View {
    var body: some View {
        Form {
            Section("Audio recording permission") {
                Text("Changing an app's volume works by tapping that app's audio and playing it back at your chosen level. macOS treats this as audio recording, so it asks for permission the first time.")
                Text("Pyrate Sounds never saves, analyzes, or sends audio anywhere. Apps you leave at 100% are not tapped at all.")
                Button("Open Privacy & Security") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("What is stored") {
                Text("Your settings live in ~/Library/Application Support/Pyrate Sounds/preferences.json on this Mac: app levels, pinned apps, interface choices, and your preferred output. Nothing leaves your device.")
            }
        }
        .formStyle(.grouped)
    }
}
