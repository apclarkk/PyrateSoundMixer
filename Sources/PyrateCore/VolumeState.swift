import Foundation

/// Volume and mute are separate pieces of state. Muting keeps the level, so
/// unmuting returns to exactly where the user left it.
public struct VolumeState: Equatable, Codable, Sendable {
    public private(set) var level: Double
    public var isMuted: Bool

    public init(level: Double = 1.0, isMuted: Bool = false) {
        self.level = Self.clamp(level)
        self.isMuted = isMuted
    }

    public static let unity = VolumeState()

    /// Setting a level above zero while muted unmutes, matching macOS behavior
    /// when you move the system volume slider.
    public mutating func setLevel(_ newLevel: Double) {
        level = Self.clamp(newLevel)
        if isMuted && level > 0 { isMuted = false }
    }

    public mutating func toggleMute() { isMuted.toggle() }

    /// Linear amplitude to apply to samples. Uses a squared taper so the slider
    /// feels even to the ear instead of crowding all the change into the bottom.
    public var gain: Float {
        isMuted ? 0 : Float(level * level)
    }

    /// True when the source would sound exactly as it does without us.
    public var isUnity: Bool { !isMuted && level >= 1.0 }

    public var percent: Int { Int((level * 100).rounded()) }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), 1)
    }
}
