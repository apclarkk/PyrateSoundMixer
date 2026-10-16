import Foundation

/// Things a global keyboard shortcut can do.
public enum ShortcutAction: Codable, Hashable, Sendable {
    case volumeUp
    case volumeDown
    case toggleOutputMute
    case nextOutputDevice
    case toggleInputMute
    case activateProfile(String)

    public var title: String {
        switch self {
        case .volumeUp: return "Raise output volume"
        case .volumeDown: return "Lower output volume"
        case .toggleOutputMute: return "Mute or unmute output"
        case .nextOutputDevice: return "Switch to next output device"
        case .toggleInputMute: return "Mute or unmute microphone"
        case .activateProfile: return "Activate profile"
        }
    }

    public static let fixed: [ShortcutAction] = [.volumeUp, .volumeDown, .toggleOutputMute, .nextOutputDevice, .toggleInputMute]
}

/// A key plus modifiers, stored as Carbon virtual key code and Carbon modifier flags
/// so it can be registered as a system-wide hot key without accessibility permission.
public struct KeyShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    /// What the key prints, captured when recorded (for display only).
    public var keyLabel: String

    public init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    // Carbon modifier masks (Events.h).
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12

    /// Global shortcuts need at least one of Command, Option, or Control so they
    /// can't swallow ordinary typing.
    public var isAcceptableGlobal: Bool {
        modifiers & (Self.command | Self.option | Self.control) != 0
    }

    public var displayString: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + keyLabel.uppercased()
    }

    /// Shortcuts macOS and most apps already use; refusing them avoids breaking
    /// common commands. Matched on key code plus modifiers.
    public var isReservedBySystem: Bool {
        let cmd = Self.command
        let reserved: Set<KeyShortcut.Key> = [
            .init(12, cmd), .init(13, cmd), .init(48, cmd), .init(49, cmd),   // Q W Tab Space
            .init(8, cmd), .init(9, cmd), .init(7, cmd), .init(0, cmd),       // C V X A
            .init(6, cmd), .init(1, cmd), .init(4, cmd), .init(46, cmd),      // Z S H M
            .init(49, Self.control), .init(49, cmd | Self.option),            // ⌃Space ⌘⌥Space
        ]
        return reserved.contains(.init(keyCode, modifiers))
    }

    struct Key: Hashable {
        var code: UInt32, mods: UInt32
        init(_ code: UInt32, _ mods: UInt32) { self.code = code; self.mods = mods }
    }
}

public struct ShortcutBinding: Codable, Hashable, Sendable {
    public var action: ShortcutAction
    public var shortcut: KeyShortcut

    public init(action: ShortcutAction, shortcut: KeyShortcut) {
        self.action = action
        self.shortcut = shortcut
    }
}

public enum ShortcutValidation: Equatable, Sendable {
    case ok
    case needsModifier
    case reserved
    case duplicate(ShortcutAction)

    public var message: String? {
        switch self {
        case .ok: return nil
        case .needsModifier: return "Use Command, Option, or Control so the shortcut doesn't block typing."
        case .reserved: return "macOS or most apps already use this shortcut."
        case .duplicate(let other): return "Already assigned to \u{201C}\(other.title)\u{201D}."
        }
    }
}

extension Array where Element == ShortcutBinding {
    public func validate(_ shortcut: KeyShortcut, for action: ShortcutAction) -> ShortcutValidation {
        if !shortcut.isAcceptableGlobal { return .needsModifier }
        if shortcut.isReservedBySystem { return .reserved }
        if let other = first(where: { $0.shortcut == shortcut && $0.action != action }) { return .duplicate(other.action) }
        return .ok
    }

    public func shortcut(for action: ShortcutAction) -> KeyShortcut? {
        first { $0.action == action }?.shortcut
    }

    public mutating func set(_ shortcut: KeyShortcut?, for action: ShortcutAction) {
        removeAll { $0.action == action }
        if let shortcut { append(ShortcutBinding(action: action, shortcut: shortcut)) }
    }
}
