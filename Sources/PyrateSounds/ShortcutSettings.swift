import AppKit
import SwiftUI
import PyrateCore

struct ShortcutSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.fixed, id: \.self) { action in
                    row(action, title: action.title)
                }
            } footer: {
                Text("Shortcuts work in any app. They need Command, Option, or Control so they don't block typing. Press Delete while recording to clear one, Escape to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !store.preferences.profiles.isEmpty {
                Section("Profiles") {
                    ForEach(store.preferences.profiles) { profile in
                        row(.activateProfile(profile.id), title: profile.name)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ action: ShortcutAction, title: String) -> some View {
        LabeledContent(title) {
            ShortcutRecorder(
                shortcut: store.preferences.shortcuts.shortcut(for: action),
                failed: store.shortcutFailures.contains(action),
                validate: { store.preferences.shortcuts.validate($0, for: action) },
                onChange: { store.setShortcut($0, for: action) })
        }
    }
}

/// Click, then press a key combination. Validates before accepting.
struct ShortcutRecorder: View {
    var shortcut: KeyShortcut?
    var failed: Bool
    var validate: (KeyShortcut) -> ShortcutValidation
    var onChange: (KeyShortcut?) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? "Type shortcut…" : (shortcut?.displayString ?? "Record Shortcut"))
                        .font(.system(size: 12, weight: shortcut == nil ? .regular : .medium).monospaced())
                        .frame(minWidth: 110)
                }
                .accessibilityLabel(recording ? "Recording shortcut" : (shortcut.map { "Shortcut \($0.displayString)" } ?? "Record shortcut"))
                if shortcut != nil && !recording {
                    Button {
                        onChange(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                    .accessibilityLabel("Clear shortcut")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if failed {
                Text("Another app is already using this shortcut.").font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        error = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53:  // Escape
                stop()
            case 51, 117:  // Delete, Forward Delete
                onChange(nil)
                stop()
            default:
                let candidate = KeyShortcut(
                    keyCode: UInt32(event.keyCode),
                    modifiers: HotKeyCenter.carbonModifiers(event.modifierFlags),
                    keyLabel: HotKeyCenter.label(for: event))
                let result = validate(candidate)
                if let message = result.message {
                    error = message
                } else {
                    onChange(candidate)
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
