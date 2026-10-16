import AppKit
import SwiftUI
import PyrateAudio
import PyrateCore

/// The menu bar panel: output, master level, and the application mixer.
struct PanelView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let metrics = Theme.metrics(store.preferences.interface.density)
        VStack(alignment: .leading, spacing: 10) {
            header
            OutputSection()
            Divider()
            InputSection()
            Divider()
            ApplicationsSection(metrics: metrics)
            footer
        }
        .padding(14)
        .frame(width: Theme.panelWidth)
        .onAppear { store.panelVisible = true }
        .onDisappear { store.panelVisible = false }
        .animation(.pyrate(reduceMotion), value: store.rows.map(\.id))
        .animation(.pyrate(reduceMotion), value: store.feedback)
        .animation(.pyrate(reduceMotion), value: store.expandedEQ)
    }

    private var header: some View {
        HStack {
            Text("Pyrate Sounds")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            RoutingButton()
            ProfilesMenu()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if let feedback = store.feedback {
                Label(feedback.message, systemImage: symbol(for: feedback.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(feedback.kind == .failure ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer(minLength: 8)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
    }

    private func symbol(for kind: Feedback.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .failure: return "exclamationmark.triangle"
        }
    }
}

// MARK: - Output

struct OutputSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollapsibleHeader(title: "Output", section: "output")
            if !store.isCollapsed("output") {
                deviceMenu
                masterRow
            }
            if !store.isCollapsed("output"), let note = masterNote {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deviceMenu: some View {
        Menu {
            ForEach(store.outputDevices) { device in
                Button {
                    store.selectOutput(device)
                } label: {
                    if device.id == store.selectedOutput.displayed {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
            if let missing = store.missingPreferredOutput {
                Divider()
                Text("\(missing.lastKnownName) (not connected)")
            }
            Divider()
            Button("Sound Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: displayedDevice?.transport.symbolName ?? "hifispeaker")
                    .frame(width: 18)
                    .foregroundStyle(Theme.accent)
                Text(displayedDevice?.name ?? "No output device")
                    .lineLimit(1)
                if store.selectedOutput.isPending {
                    ProgressView().controlSize(.mini)
                        .accessibilityLabel("Switching")
                }
                Spacer()
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .accessibilityLabel("Output device")
        .accessibilityValue(displayedDevice?.name ?? "None")
        .help("Choose where sound plays")
    }

    private var displayedDevice: OutputDevice? {
        guard let id = store.selectedOutput.displayed else { return nil }
        return store.outputDevices.first { $0.id == id }
    }

    private var masterRow: some View {
        let master = store.master
        let name = store.currentOutput?.name ?? "output"
        return HStack(spacing: 6) {
            MuteButton(isMuted: master?.isMuted ?? false, level: store.masterLevel, label: name) {
                store.toggleMasterMute()
            }
            .disabled(master?.capabilities.mute.isUsable != true)
            PyrateSlider(
                value: store.masterLevel,
                isMuted: master?.isMuted ?? false,
                label: "Output volume",
                onChange: { store.setMasterLevel($0) },
                onEditingChanged: { store.masterEditing($0) })
                .disabled(master?.capabilities.volume.isUsable != true)
            LevelReadout(level: store.masterLevel, isMuted: master?.isMuted ?? false)
        }
    }

    private var masterNote: String? {
        guard let master = store.master else { return nil }
        if !master.capabilities.volume.isUsable { return master.capabilities.volume.note }
        return nil
    }
}

// MARK: - Applications

struct ApplicationsSection: View {
    @Environment(AppStore.self) private var store
    var metrics: Theme.Metrics

    private let sectionName = "applications"

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            HStack(spacing: 8) {
                Button {
                    store.toggleSection(sectionName)
                } label: {
                    HStack {
                        SectionLabel("Applications")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Applications")
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
                .accessibilityHint("Shows or hides the application mixer")
            }

            if !collapsed {
                if store.showPermissionNote { PermissionNote() }
                if store.permissionSuspected { PermissionWarning() }
                if store.rows.isEmpty {
                    EmptyState()
                } else {
                    // Size the scroll view to its content, capped, so short lists
                    // don't scroll and long ones don't push the panel off screen.
                    ScrollView {
                        VStack(spacing: metrics.rowSpacing) {
                            ForEach(store.rows) { row in
                                SourceRowView(row: row, metrics: metrics)
                                    .transition(.opacity)
                                if store.expandedEQ == row.id {
                                    SourceDrawer(row: row)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(max(contentHeight, 1), maxListHeight))
                }
            }
        }
    }

    @State private var contentHeight: CGFloat = 0
    private let maxListHeight: CGFloat = 460

    private var collapsed: Bool { store.isCollapsed(sectionName) }
}

struct SourceRowView: View {
    @Environment(AppStore.self) private var store
    var row: SourceRowModel
    var metrics: Theme.Metrics

    var body: some View {
        Group {
            if metrics.twoLineRows {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        icon
                        nameLabel
                        Spacer(minLength: 4)
                        LevelReadout(level: row.volume.level, isMuted: row.volume.isMuted)
                        EQButton(row: row)
                    }
                    HStack(spacing: 8) {
                        muteButton.frame(width: metrics.iconSize)
                        slider
                    }
                    subtitle
                }
            } else {
                HStack(spacing: 6) {
                    icon
                    nameLabel.frame(width: 80, alignment: .leading)
                    muteButton
                    slider
                    LevelReadout(level: row.volume.level, isMuted: row.volume.isMuted)
                    EQButton(row: row)
                }
            }
        }
        .padding(.vertical, metrics.rowPadding)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(row.isPresent ? 0.04 : 0.0)))
        .opacity(row.isPresent || row.isPinned ? 1 : 0.6)
        .help(row.capabilities.volume.note ?? "")
        .contextMenu {
            Button(row.isPinned ? "Unpin" : "Pin to Top") { store.setPinned(!row.isPinned, for: row.id) }
            Button("Reset to 100%") { store.resetVolume(row.id) }
                .disabled(row.volume.isUnity)
            Menu("Play Through") {
                Toggle("System Output", isOn: Binding(
                    get: { store.preferences.route(for: row.id) == nil },
                    set: { _ in store.setRoute(nil, for: row.id) }))
                Divider()
                ForEach(store.outputDevices.filter(\.isAlive)) { device in
                    Toggle(device.name, isOn: Binding(
                        get: { store.preferences.route(for: row.id)?.id == device.id },
                        set: { _ in store.setRoute(device, for: row.id) }))
                }
            }
            Menu("EQ Preset") {
                ForEach(store.eqPresets) { preset in
                    EQPresetMenuItem(preset: preset, isSelected: row.eq.presetID == preset.id && !row.eq.isFlat) {
                        store.selectEQPreset(preset, for: row.id)
                    }
                }
                Divider()
                Button("Turn Off EQ") { store.resetEQ(row.id) }
                    .disabled(row.eq.isFlat)
            }
            Divider()
            Button("Forget This App") { store.forget(row.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.name)
    }

    private var icon: some View {
        Group {
            if let image = row.icon {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: metrics.iconSize, height: metrics.iconSize)
        .overlay(alignment: .bottomTrailing) { ActivityDot(row: row) }
        .accessibilityHidden(true)
    }

    private var nameLabel: some View {
        HStack(spacing: 4) {
            Text(row.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if row.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
            if row.isShared {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .help(row.capabilities.volume.note ?? "")
                    .accessibilityLabel("Shared by several apps")
            }
        }
    }

    @ViewBuilder private var subtitle: some View {
        if !row.capabilities.volume.isUsable, let note = row.capabilities.volume.note {
            Text(note).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
        } else if !row.isPresent {
            Text(UnavailableReason.notPlaying.explanation)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        } else if let status = statusLine {
            Text(status)
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                .padding(.leading, metrics.iconSize + 8)
        }
    }

    /// "EQ: R&B" style summary of what is shaping this app.
    private var statusLine: String? {
        var parts: [String] = []
        if let rule = store.ruleOwner(of: row.id) {
            parts.append("set by rule \u{201C}\(rule)\u{201D}")
        }
        switch row.route {
        case .routed(let device):
            parts.append("to \(store.outputDevices.first { $0.id == device }?.name ?? "another device")")
        case .fallback(let missing):
            parts.append("\(missing.lastKnownName) not connected, using system output")
        case .system:
            break
        }
        if let preset = row.eqPresetName {
            parts.append("EQ: \(preset)\(row.eq.isBypassed ? " (bypassed)" : "")")
        }
        if let effects = row.effects.summary { parts.append(effects) }
        guard !parts.isEmpty else { return nil }
        var line = parts.joined(separator: ", ")
        line.replaceSubrange(line.startIndex...line.startIndex, with: line.prefix(1).uppercased())
        return line
    }

    private var muteButton: some View {
        MuteButton(isMuted: row.volume.isMuted, level: row.volume.level, label: row.name) {
            store.toggleMute(row.id)
        }
        .disabled(!row.capabilities.mute.isUsable)
    }

    private var slider: some View {
        PyrateSlider(
            value: row.volume.level,
            isMuted: row.volume.isMuted,
            label: "\(row.name) volume",
            onChange: { store.setLevel($0, for: row.id) },
            onEditingChanged: { store.sourceEditing(row.id, $0) })
            .disabled(!row.capabilities.volume.isUsable)
    }
}

/// Small dot that shows a source is producing sound. Pulses with the real signal
/// level when the source is tapped; otherwise reflects Core Audio's running state.
struct ActivityDot: View {
    @Environment(AppStore.self) private var store
    var row: SourceRowModel

    var body: some View {
        let peak = store.activity[row.id]
        let active = row.isActive && (peak.map { $0 > 0.001 } ?? true)
        Circle()
            .fill(Theme.accent)
            .frame(width: 7, height: 7)
            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
            .scaleEffect(active ? CGFloat(0.85 + min(Double(peak ?? 0.3), 1) * 0.35) : 0.6)
            .opacity(active ? 1 : 0)
            .offset(x: 2, y: 2)
            .accessibilityHidden(true)
    }
}

struct SectionLabel: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text("Nothing is playing right now")
                .font(.system(size: 12, weight: .medium))
            Text("Apps appear here as soon as they make sound. Right-click a row to pin it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

struct PermissionNote: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Callout(symbol: "lock.shield", tint: Theme.accent) {
            Text("To change an app's volume, Pyrate Sounds plays that app's audio back at your level. macOS will ask once for audio recording permission. Audio never leaves your Mac and is never saved.")
        } actions: {
            Button("Got It") { store.dismissPermissionNote() }
        }
    }
}

struct PermissionWarning: View {
    var body: some View {
        Callout(symbol: "exclamationmark.triangle", tint: .orange) {
            Text("An app you adjusted is silent. If it should be playing, allow Pyrate Sounds under System Audio Recording in Privacy & Security.")
        } actions: {
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

struct Callout<Content: View, Actions: View>: View {
    var symbol: String
    var tint: Color
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                content
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                HStack { actions }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.10)))
    }
}


/// Section title that collapses its section. The collapsed state is remembered.
struct CollapsibleHeader: View {
    @Environment(AppStore.self) private var store
    var title: String
    var section: String

    var body: some View {
        let collapsed = store.isCollapsed(section)
        Button {
            store.toggleSection(section)
        } label: {
            HStack {
                SectionLabel(title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
    }
}

// MARK: - Input

struct InputSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollapsibleHeader(title: "Input", section: "input")
            if !store.isCollapsed("input") {
                deviceMenu
                gainRow
                if !store.micUsers.isEmpty {
                    Label {
                        Text("In use by \(store.micUsers.map(\.name).joined(separator: ", "))")
                    } icon: {
                        Image(systemName: "mic.fill").foregroundStyle(.orange)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help("Apps currently recording from an input. Apps can choose their own microphone, so this may not be the device selected above.")
                    .accessibilityLabel("Microphone in use by \(store.micUsers.map(\.name).joined(separator: ", "))")
                }
            }
        }
    }

    private var displayed: OutputDevice? {
        guard let id = store.selectedInput.displayed else { return nil }
        return store.inputDevices.first { $0.id == id }
    }

    private var deviceMenu: some View {
        Menu {
            ForEach(store.inputDevices) { device in
                Button {
                    store.selectInput(device)
                } label: {
                    if device.id == store.selectedInput.displayed {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .frame(width: 18)
                    .foregroundStyle(Theme.accent)
                Text(displayed?.name ?? "No input device").lineLimit(1)
                if store.selectedInput.isPending {
                    ProgressView().controlSize(.mini).accessibilityLabel("Switching")
                }
                Spacer()
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .accessibilityLabel("Input device")
        .accessibilityValue(displayed?.name ?? "None")
        .help("Choose the system microphone. Apps that pick their own microphone keep using it.")
    }

    @ViewBuilder private var gainRow: some View {
        let level = store.inputLevel
        if let level, level.capabilities.volume.isUsable || level.capabilities.mute.isUsable {
            HStack(spacing: 6) {
                Button {
                    store.toggleInputMute()
                } label: {
                    Image(systemName: level.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(level.isMuted ? Color.secondary : Theme.accent)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!level.capabilities.mute.isUsable)
                .help(level.isMuted ? "Unmute microphone" : "Mute microphone")
                .accessibilityLabel(level.isMuted ? "Unmute microphone" : "Mute microphone")
                PyrateSlider(value: level.level, isMuted: level.isMuted, label: "Input level",
                             onChange: { store.setInputGain($0) })
                    .disabled(!level.capabilities.volume.isUsable)
                LevelReadout(level: level.level, isMuted: level.isMuted)
            }
        } else if store.currentInput != nil {
            Text("This input has no adjustable level.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// Activate, save, and undo profiles from the panel.
struct ProfilesMenu: View {
    @Environment(AppStore.self) private var store
    @State private var saving = false

    var body: some View {
        Menu {
            if store.preferences.profiles.isEmpty {
                Text("No profiles yet")
            }
            ForEach(store.preferences.profiles) { profile in
                Button(profile.name) { store.activateProfile(id: profile.id) }
            }
            Divider()
            Button("Save Current Setup as Profile…") { saving = true }
            if let undo = store.lastProfileUndo {
                Button("Undo \(undo.profileName)") { store.undoLastProfile() }
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Profiles")
        .accessibilityLabel("Profiles")
        .popover(isPresented: $saving, arrowEdge: .bottom) {
            NewProfileSheet { name, aspects in store.saveProfile(named: name, aspects: aspects) }
        }
    }
}

struct RoutingButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: "routing")
        } label: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Show where every app's sound goes")
        .accessibilityLabel("Audio routing")
    }
}
