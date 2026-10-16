import Foundation

/// Why a control cannot be used. Every case has a user-facing explanation so the
/// interface never shows a control that silently does nothing.
public enum UnavailableReason: Equatable, Sendable {
    case notPlaying
    case permissionNeeded
    case fixedLevel
    case noHardwareMute
    case deviceDisconnected
    case unsupportedOS
    case failed(String)

    public var explanation: String {
        switch self {
        case .notPlaying:
            return "This app is not playing audio. Your setting will apply when it does."
        case .permissionNeeded:
            return "Pyrate Sounds needs audio capture permission to change app volumes."
        case .fixedLevel:
            return "This device has a fixed output level. Adjust volume on the device itself or per app."
        case .noHardwareMute:
            return "This device does not offer a mute control."
        case .deviceDisconnected:
            return "This device is not connected."
        case .unsupportedOS:
            return "Per-app volume needs macOS 14.4 or later."
        case .failed(let message):
            return message
        }
    }
}

public enum Availability: Equatable, Sendable {
    case available
    /// The control works now, with a caveat worth showing (for example a shared process).
    case availableWithNote(String)
    case unavailable(UnavailableReason)

    public var isUsable: Bool {
        switch self {
        case .available, .availableWithNote: return true
        case .unavailable: return false
        }
    }

    public var note: String? {
        switch self {
        case .available: return nil
        case .availableWithNote(let note): return note
        case .unavailable(let reason): return reason.explanation
        }
    }
}

public struct SourceCapabilities: Equatable, Sendable {
    public var volume: Availability
    public var mute: Availability

    public init(volume: Availability, mute: Availability) {
        self.volume = volume
        self.mute = mute
    }

    public static func derive(isShared: Bool, permissionDenied: Bool, engineError: String?) -> SourceCapabilities {
        if permissionDenied {
            return SourceCapabilities(volume: .unavailable(.permissionNeeded), mute: .unavailable(.permissionNeeded))
        }
        if let engineError {
            return SourceCapabilities(volume: .unavailable(.failed(engineError)), mute: .unavailable(.failed(engineError)))
        }
        if isShared {
            let note = "Safari and other apps built on WebKit share this audio. Changes affect all of them."
            return SourceCapabilities(volume: .availableWithNote(note), mute: .availableWithNote(note))
        }
        return SourceCapabilities(volume: .available, mute: .available)
    }
}

public struct DeviceCapabilities: Equatable, Sendable {
    public var volume: Availability
    public var mute: Availability

    public init(volume: Availability, mute: Availability) {
        self.volume = volume
        self.mute = mute
    }

    public static func derive(isAlive: Bool, volumeSettable: Bool, muteSettable: Bool) -> DeviceCapabilities {
        guard isAlive else {
            return DeviceCapabilities(volume: .unavailable(.deviceDisconnected), mute: .unavailable(.deviceDisconnected))
        }
        return DeviceCapabilities(
            volume: volumeSettable ? .available : .unavailable(.fixedLevel),
            mute: muteSettable ? .available : .unavailable(.noHardwareMute)
        )
    }
}
