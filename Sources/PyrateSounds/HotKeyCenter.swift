import AppKit
import Carbon.HIToolbox
import PyrateCore

/// System-wide keyboard shortcuts through Carbon hot keys. Needs no accessibility
/// permission, and macOS refuses a combination another app has already claimed,
/// which is reported back so Settings can say so.
@MainActor
final class HotKeyCenter {
    var onAction: ((ShortcutAction) -> Void)?
    /// Bindings macOS refused to register (usually because another app owns them).
    private(set) var failures: Set<ShortcutAction> = []

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: ShortcutAction] = [:]
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x5059_5253  // 'PYRS'

    func install() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { center.fire(id.id) }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }

    /// Replaces all registered shortcuts with these bindings.
    func register(_ bindings: [ShortcutBinding]) {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
        failures.removeAll()
        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(binding.shortcut.keyCode, binding.shortcut.modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[id] = binding.action
            } else {
                failures.insert(binding.action)
            }
        }
    }

    private func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        onAction?(action)
    }

    /// Converts AppKit modifier flags to Carbon's.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= KeyShortcut.command }
        if flags.contains(.shift) { m |= KeyShortcut.shift }
        if flags.contains(.option) { m |= KeyShortcut.option }
        if flags.contains(.control) { m |= KeyShortcut.control }
        return m
    }

    /// A readable label for a key, including keys that print nothing.
    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        default: break
        }
        let fKeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let f = fKeys[Int(event.keyCode)] { return f }
        return event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }
}
