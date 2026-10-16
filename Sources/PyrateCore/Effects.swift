import Foundation

/// How a source's two channels reach the output.
public enum ChannelMode: String, Codable, CaseIterable, Sendable {
    case stereo
    /// Left and right exchanged (for reversed speakers or recordings).
    case swapped
    /// Both channels summed, so nothing is lost with one earbud or a hearing difference.
    case mono

    public var title: String {
        switch self {
        case .stereo: return "Stereo"
        case .swapped: return "Swap L/R"
        case .mono: return "Mono"
        }
    }
}

/// Per-source effects beyond EQ. Isolated to the source like everything else in
/// its chain.
public struct SourceEffects: Codable, Hashable, Sendable {
    public static let maxRackSize = 6

    /// -1 is fully left, 0 centered, 1 fully right.
    public var balance: Double
    public var channelMode: ChannelMode
    /// Apple Audio Unit effects, in signal order.
    public var rack: [RackEffect]

    public init(balance: Double = 0, channelMode: ChannelMode = .stereo, rack: [RackEffect] = []) {
        self.balance = min(max(balance.isFinite ? balance : 0, -1), 1)
        self.channelMode = channelMode
        self.rack = Array(rack.prefix(Self.maxRackSize))
    }

    public static let neutral = SourceEffects()

    /// True when nothing here changes the sound (bypassed rack effects don't count).
    public var isNeutral: Bool {
        abs(balance) < 0.005 && channelMode == .stereo && rack.allSatisfy(\.isBypassed)
    }

    /// Level-neutral balance: centered leaves both sides untouched, and moving
    /// toward one side only lowers the other. Nothing is ever boosted, so balance
    /// can't cause clipping or act like a volume control.
    public var channelGains: (left: Double, right: Double) {
        (left: balance > 0 ? 1 - balance : 1, right: balance < 0 ? 1 + balance : 1)
    }

    public var summary: String? {
        var parts: [String] = []
        parts += rack.filter { !$0.isBypassed }.map { AppleEffectCatalog.entry(for: $0.kind)?.name ?? $0.kind }
        if channelMode != .stereo { parts.append(channelMode.title) }
        if abs(balance) >= 0.005 {
            parts.append("balance \(Int((abs(balance) * 100).rounded()))% \(balance < 0 ? "L" : "R")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(balance: try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0,
                  channelMode: try c.decodeIfPresent(ChannelMode.self, forKey: .channelMode) ?? .stereo,
                  rack: try c.decodeIfPresent([RackEffect].self, forKey: .rack) ?? [])
    }
}

/// Where a source's audio should go, given its route preference and what is connected.
public enum RouteResolution: Equatable, Sendable {
    /// Follows the system output.
    case system
    /// Plays through its chosen device.
    case routed(DeviceID)
    /// Its chosen device isn't available, so it falls back to the system output.
    case fallback(missing: RememberedDevice)

    public static func resolve(route: RememberedDevice?, systemOutput: DeviceID?, available: Set<DeviceID>) -> RouteResolution {
        guard let route else { return .system }
        guard available.contains(route.id) else { return .fallback(missing: route) }
        return route.id == systemOutput ? .system : .routed(route.id)
    }

    /// True when the source must be tapped to honor the route.
    public var needsTap: Bool {
        if case .routed = self { return true }
        return false
    }
}

/// One Apple Audio Unit effect in a source's rack.
public struct RackEffect: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// The Audio Unit subtype as a four-character code, for example "rvb2".
    public var kind: String
    public var isBypassed: Bool
    /// Factory preset applied first, if any.
    public var presetNumber: Int?
    /// Parameter values set by the user, applied over the preset.
    public var parameters: [UInt32: Float]

    public init(id: String = UUID().uuidString, kind: String, isBypassed: Bool = false,
                presetNumber: Int? = nil, parameters: [UInt32: Float] = [:]) {
        self.id = id
        self.kind = kind
        self.isBypassed = isBypassed
        self.presetNumber = presetNumber
        self.parameters = parameters
    }

    /// A new effect with the catalog's starting settings.
    public static func make(_ kind: String) -> RackEffect {
        let entry = AppleEffectCatalog.entry(for: kind)
        return RackEffect(kind: kind, presetNumber: entry?.initialPreset, parameters: entry?.initial ?? [:])
    }

    /// What requires building new Audio Unit instances when it changes. Parameter
    /// and bypass changes apply to running units instead.
    public var structureKey: String { "\(id)|\(kind)|\(presetNumber.map(String.init) ?? "-")" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        kind = try c.decode(String.self, forKey: .kind)
        isBypassed = try c.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
        presetNumber = try c.decodeIfPresent(Int.self, forKey: .presetNumber)
        parameters = try c.decodeIfPresent([UInt32: Float].self, forKey: .parameters) ?? [:]
    }
}

/// The Apple effects Pyrate Sounds offers, with friendly names, the parameters
/// shown up front, and sensible starting points. Other parameters stay available
/// under "More controls". Units are found on the Mac at run time; an entry whose
/// unit is missing is shown as unavailable.
public enum AppleEffectCatalog {
    public struct Entry: Sendable, Identifiable {
        public var kind: String
        public var name: String
        public var symbol: String
        public var blurb: String
        public var keyParameters: [UInt32]
        public var initial: [UInt32: Float]
        public var initialPreset: Int?
        /// Parameters shown in semitones although the unit reports cents.
        public var semitoneParameters: Set<UInt32> = []
        public var id: String { kind }
    }

    public static let entries: [Entry] = [
        Entry(kind: "rvb2", name: "Reverb", symbol: "building.columns",
              blurb: "Room and hall ambience", keyParameters: [0, 4, 5], initial: [0: 25], initialPreset: 1),
        Entry(kind: "mrev", name: "Room Reverb", symbol: "cube.transparent",
              blurb: "Dense, smooth spaces", keyParameters: [0, 1], initial: [0: 30], initialPreset: 0),
        Entry(kind: "dely", name: "Echo", symbol: "dot.radiowaves.right",
              blurb: "Repeating delay", keyParameters: [0, 1, 2], initial: [0: 30, 1: 0.35, 2: 35], initialPreset: nil),
        Entry(kind: "dist", name: "Distortion", symbol: "bolt",
              blurb: "Grit, lo-fi, and radio sounds", keyParameters: [15], initial: [:], initialPreset: 3),
        Entry(kind: "nutp", name: "Pitch Shift", symbol: "arrow.up.arrow.down",
              blurb: "Higher or lower, same speed", keyParameters: [1], initial: [1: 0], initialPreset: nil,
              semitoneParameters: [1]),
        Entry(kind: "dcmp", name: "Compressor", symbol: "rectangle.compress.vertical",
              blurb: "Evens out loud and quiet parts", keyParameters: [0, 1, 6], initial: [:], initialPreset: 2),
        Entry(kind: "mcmp", name: "Multiband Compressor", symbol: "slider.horizontal.below.rectangle",
              blurb: "Compression per frequency range", keyParameters: [0, 1], initial: [:], initialPreset: 3),
        Entry(kind: "lpas", name: "Low-pass Filter", symbol: "line.diagonal.arrow",
              blurb: "Muffles highs", keyParameters: [0, 1], initial: [0: 2000], initialPreset: nil),
        Entry(kind: "hpas", name: "High-pass Filter", symbol: "line.diagonal",
              blurb: "Removes bass and rumble", keyParameters: [0, 1], initial: [0: 300], initialPreset: nil),
        Entry(kind: "bpas", name: "Band-pass Filter", symbol: "waveform.path",
              blurb: "Keeps one band, like a phone line", keyParameters: [0, 1], initial: [0: 1500, 1: 1800], initialPreset: nil),
        Entry(kind: "rogr", name: "Walkie-Talkie Beep", symbol: "antenna.radiowaves.left.and.right",
              blurb: "Beeps when speech starts and stops", keyParameters: [6], initial: [:], initialPreset: 2),
    ]

    public static func entry(for kind: String) -> Entry? { entries.first { $0.kind == kind } }

    public static func fourCC(_ kind: String) -> UInt32 {
        kind.utf8.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
