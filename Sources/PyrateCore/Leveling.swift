import Foundation

/// Cross-app loudness normalization: each app's long-term loudness is measured the
/// way streaming services do it, and a small, slow trim brings outliers toward one
/// shared target, so a quiet podcast and a loud video end up at a similar volume.
/// It follows programs, not moments: it never rides the level within a song. Off by default.
public struct LevelingSettings: Codable, Equatable, Sendable {
    public enum Target: String, Codable, CaseIterable, Sendable {
        case quieter, balanced, louder

        /// Target loudness in LUFS (BS.1770 style, K-weighted).
        public var lufs: Double {
            switch self {
            case .quieter: return -18
            case .balanced: return -14
            case .louder: return -11
            }
        }

        public var title: String {
            switch self {
            case .quieter: return "Quieter"
            case .balanced: return "Balanced"
            case .louder: return "Louder"
            }
        }
    }

    public var isEnabled: Bool = false
    public var target: Target = .balanced
    /// Only raise quiet apps; never turn anything down.
    public var boostOnly: Bool = false

    public init(isEnabled: Bool = false, target: Target = .balanced, boostOnly: Bool = false) {
        self.isEnabled = isEnabled
        self.target = target
        self.boostOnly = boostOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        target = try c.decodeIfPresent(Target.self, forKey: .target) ?? .balanced
        boostOnly = try c.decodeIfPresent(Bool.self, forKey: .boostOnly) ?? false
    }
}

/// Fixed normalizer behavior. Deliberately slow and conservative.
public enum LevelerTuning {
    /// Most the normalizer will boost or cut.
    public static let maxAdjustDB = 6.0
    /// No correction while the trim is within this distance of where it should be.
    public static let deadbandDB = 2.0
    /// Fastest the trim moves, normally and while learning a newly playing app.
    public static let slewDBPerSecond = 1.0
    public static let learningSlewDBPerSecond = 3.0
    public static let learningSeconds = 10.0
    /// Loudness is measured in 400 ms blocks every 100 ms (BS.1770 gating blocks)...
    public static let hopSeconds = 0.1
    public static let blockHops = 4
    /// ...over a sliding window this long...
    public static let windowSeconds = 30.0
    /// ...and nothing is changed until this much gated audio has been heard.
    public static let minimumHeardSeconds = 3.0
    /// BS.1770 gates: blocks below the absolute gate, or more than the relative gate
    /// below the ungated average, are ignored. Silence and quiet passages don't count.
    public static let absoluteGateLUFS = -70.0
    public static let relativeGateLU = -10.0
    /// Constant term of BS.1770 loudness.
    public static let loudnessOffset = -0.691

    public static var windowBlocks: Int { Int(windowSeconds / hopSeconds) }

    /// BS.1770 integrated loudness of a set of block mean squares, or nil when
    /// nothing passes the gates.
    public static func integratedLoudness<C: Collection>(_ blocks: C) -> Double? where C.Element == Double {
        func lufs(_ ms: Double) -> Double { loudnessOffset + 10 * log10(ms + 1e-20) }
        var sum = 0.0, count = 0
        for ms in blocks where lufs(ms) > absoluteGateLUFS { sum += ms; count += 1 }
        guard count > 0 else { return nil }
        let relativeGate = lufs(sum / Double(count)) + relativeGateLU
        var gatedSum = 0.0, gatedCount = 0
        for ms in blocks where lufs(ms) > absoluteGateLUFS && lufs(ms) > relativeGate {
            gatedSum += ms; gatedCount += 1
        }
        guard gatedCount > 0 else { return nil }
        return lufs(gatedSum / Double(gatedCount))
    }

    /// The trim the normalizer wants for a measured loudness.
    public static func desiredTrim(loudness: Double, target: Double, boostOnly: Bool) -> Double {
        let trim = min(max(target - loudness, -maxAdjustDB), maxAdjustDB)
        return boostOnly ? max(trim, 0) : trim
    }

    /// The two K-weighting stages (high shelf, then high pass) at a sample rate.
    public static func kWeighting(sampleRate: Double) -> [Biquad] {
        [
            .highShelf(frequency: 1681.97, gainDB: 3.99984, q: 0.7071752, sampleRate: sampleRate),
            .highPass(frequency: 38.13547, q: 0.5003270, sampleRate: sampleRate),
        ]
    }
}

extension Biquad {
    /// RBJ Audio EQ Cookbook high shelf.
    public static func highShelf(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let sq = 2 * sqrt(a) * alpha
        let a0 = (a + 1) - (a - 1) * cosw + sq
        return Biquad(
            b0: a * ((a + 1) + (a - 1) * cosw + sq) / a0,
            b1: -2 * a * ((a - 1) + (a + 1) * cosw) / a0,
            b2: a * ((a + 1) + (a - 1) * cosw - sq) / a0,
            a1: 2 * ((a - 1) - (a + 1) * cosw) / a0,
            a2: ((a + 1) - (a - 1) * cosw - sq) / a0)
    }

    /// RBJ Audio EQ Cookbook high pass.
    public static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        return Biquad(
            b0: ((1 + cosw) / 2) / a0,
            b1: -(1 + cosw) / a0,
            b2: ((1 + cosw) / 2) / a0,
            a1: (-2 * cosw) / a0,
            a2: (1 - alpha) / a0)
    }
}
