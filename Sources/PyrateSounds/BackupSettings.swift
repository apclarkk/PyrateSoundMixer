import AppKit
import SwiftUI
import PyrateAudio
import PyrateCore

struct BackupSettings: View {
    @Environment(AppStore.self) private var store
    @State private var pending: PendingImport?
    @State private var backups: [URL] = []

    struct PendingImport: Identifiable {
        let id = UUID()
        var bundle: ConfigurationBundle
        var report: ImportReport
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Export Settings…") { store.exportConfiguration() }
                    Button("Import Settings…") {
                        if let (bundle, report) = store.chooseConfigurationToImport() {
                            pending = PendingImport(bundle: bundle, report: report)
                        }
                    }
                }
                Text("An export contains app levels and EQ, presets, profiles, rules, shortcuts, and interface choices. Device and app references are kept as they are; on another Mac you choose what to do with devices that aren't there.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Move settings") }

            Section {
                HStack {
                    Button("Back Up Now") { store.backUpNow(); backups = store.backups }
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: AppStore.backupsURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(AppStore.backupsURL)
                    }
                }
                if backups.isEmpty {
                    Text("No backups yet. One is made automatically before every import or restore.")
                        .foregroundStyle(.secondary)
                }
                ForEach(backups, id: \.self) { url in
                    HStack {
                        Text(label(for: url)).font(.system(size: 12).monospacedDigit())
                        Spacer()
                        Button("Restore") { store.restoreBackup(url); backups = store.backups }
                    }
                }
            } header: { Text("Backups") } footer: {
                Text("The 15 most recent backups are kept. Restoring backs up your current settings first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { backups = store.backups }
        .sheet(item: $pending) { item in
            ImportReview(bundle: item.bundle, report: item.report) { mode, remap in
                store.applyImport(item.bundle, mode: mode, remap: remap)
                backups = store.backups
            }
        }
    }

    private func label(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "settings-", with: "")
            .replacingOccurrences(of: "-before-import", with: "  (before import)")
            .replacingOccurrences(of: "-before-restore", with: "  (before restore)")
            .replacingOccurrences(of: "-manual", with: "")
    }
}

/// Shows exactly what an import contains and what won't work here, before anything changes.
struct ImportReview: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var bundle: ConfigurationBundle
    var report: ImportReport
    var onImport: (AppStore.ImportMode, [DeviceID: RememberedDevice]) -> Void

    @State private var mode: AppStore.ImportMode = .merge
    @State private var remap: [DeviceID: DeviceID] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Settings").font(.headline)
            Text("Exported \(bundle.exportedAt.formatted(date: .abbreviated, time: .shortened)) from Pyrate Sounds \(bundle.appVersion).")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, verticalSpacing: 4) {
                row("Apps with settings", report.appCount)
                row("Custom EQ presets", report.presetCount)
                row("Profiles", report.profileCount)
                row("Rules", report.ruleCount)
                row("Shortcuts", report.shortcutCount)
            }
            Picker("Import", selection: $mode) {
                Text("Add presets, profiles, and rules to mine").tag(AppStore.ImportMode.merge)
                Text("Replace all my settings").tag(AppStore.ImportMode.replace)
            }
            .pickerStyle(.radioGroup)

            if !report.missingDevices.isEmpty {
                Divider()
                Text("Devices not connected to this Mac").font(.subheadline.weight(.semibold))
                Text("Choose a device to use instead, or keep the original so it works when that device is connected. Nothing is swapped unless you choose it.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(report.missingDevices, id: \.id) { device in
                    Picker(device.lastKnownName, selection: Binding(
                        get: { remap[device.id] ?? device.id },
                        set: { remap[device.id] = $0 == device.id ? nil : $0 })
                    ) {
                        Text("Keep as is").tag(device.id)
                        ForEach(store.outputDevices + store.inputDevices) { d in Text(d.name).tag(d.id) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    let all = store.outputDevices + store.inputDevices
                    var map: [DeviceID: RememberedDevice] = [:]
                    for (from, to) in remap {
                        if let d = all.first(where: { $0.id == to }) { map[from] = RememberedDevice(id: d.id, lastKnownName: d.name) }
                    }
                    onImport(mode, map)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            Text("Your current settings are backed up first.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 440)
    }

    private func row(_ title: String, _ count: Int) -> some View {
        GridRow {
            Text(title)
            Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct IntegrationSettings: View {
    @Environment(AppStore.self) private var store

    private let examples: [(String, String)] = [
        ("pyratesounds://profile/Meetings", "Activate a profile"),
        ("pyratesounds://volume/Music?level=40", "Set an app's volume"),
        ("pyratesounds://volume/Music?change=-10", "Change an app's volume"),
        ("pyratesounds://toggle-mute/Music", "Mute or unmute an app"),
        ("pyratesounds://eq/Music?preset=R%26B", "Use an EQ preset"),
        ("pyratesounds://output/select/AirPods", "Switch output device"),
        ("pyratesounds://output?level=60", "Set output volume"),
        ("pyratesounds://undo-profile", "Undo the last profile"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Allow other apps and scripts to control Pyrate Sounds", isOn: Binding(
                    get: { store.preferences.allowURLCommands },
                    set: { store.setAllowURLCommands($0) }))
                Text("Use these links from the Shortcuts app (Open URL action), Raycast, Alfred, or the terminal (open \"pyratesounds://…\"). Apps and devices are matched by name. Every command shows up in Activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Commands") {
                ForEach(examples, id: \.0) { url, title in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                            Text(url).font(.system(size: 11).monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy")
                        .accessibilityLabel("Copy \(title) link")
                    }
                }
            }
            Section("Extensions") {
                Text("Third-party audio plug-ins aren't supported yet. Code running in the audio path has to meet strict real-time rules and would hear every processed app, so it needs isolation that isn't in place. Commands above are the supported way to build on Pyrate Sounds today.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
