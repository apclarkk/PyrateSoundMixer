import Foundation

/// The 10-band graphic equalizer layout: ISO octave centers, one-octave peaking filters.
public enum GraphicEQ {
    public static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let bandCount = frequencies.count
    public static let q = 1.41
    public static let gainRange: ClosedRange<Double> = -12...12
    /// Largest loudness compensation applied in either direction.
    public static let maxMakeupDB = 12.0
    /// Limiter ceiling (-1 dBFS), lookahead, and release time.
    public static let limiterCeiling = 0.891
    public static let limiterLookaheadSeconds = 0.005
    public static let limiterReleaseSeconds = 0.12

    public static func label(for frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }

    public static var flatGains: [Double] { Array(repeating: 0, count: bandCount) }
}

/// A named EQ curve. Built-ins are read-only starting points, not claims about
/// what sounds correct; users duplicate them to make their own.
public struct EQPreset: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var gains: [Double]
    public var isBuiltIn: Bool

    public init(id: String = UUID().uuidString, name: String, gains: [Double], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.gains = EQPreset.normalized(gains)
        self.isBuiltIn = isBuiltIn
    }

    static func normalized(_ gains: [Double]) -> [Double] {
        var g = Array(gains.prefix(GraphicEQ.bandCount))
        g += Array(repeating: 0, count: GraphicEQ.bandCount - g.count)
        return g.map { $0.isFinite ? min(max($0, GraphicEQ.gainRange.lowerBound), GraphicEQ.gainRange.upperBound) : 0 }
    }

    private static func builtIn(_ id: String, _ name: String, _ gains: [Double]) -> EQPreset {
        EQPreset(id: "builtin." + id, name: name, gains: gains, isBuiltIn: true)
    }

    //                                              32    64   125   250   500    1k    2k    4k    8k   16k
    public static let flat           = builtIn("flat", "Flat",                 [ 0,    0,    0,    0,    0,    0,    0,    0,    0,    0])
    public static let builtIns: [EQPreset] = [
        flat,
        builtIn("bass-boost",     "Bass Boost",        [ 6,  5.5,  4.5,  2.5,    1,    0,    0,    0,    0,    0]),
        builtIn("bass-reducer",   "Bass Reducer",      [-6,   -5,   -4,   -2,   -1,    0,    0,    0,    0,    0]),
        builtIn("treble-boost",   "Treble Boost",      [ 0,    0,    0,    0,    0,    1,  2.5,    4,    5,    6]),
        builtIn("treble-reducer", "Treble Reducer",    [ 0,    0,    0,    0,    0,   -1, -2.5,   -4,   -5,   -6]),
        builtIn("vocal-clarity",  "Vocal Clarity",     [-2,   -2,   -1,    0,  1.5,    3,  3.5,  2.5,    1,    0]),
        builtIn("spoken-word",    "Spoken Word",       [-6,   -4,   -1,    1,    2,    3,    3,    2,    0,   -2]),
        builtIn("loudness",       "Loudness",          [ 5,    4,    2,    0,   -1,    0,   -1,    1,    4,    5]),
        builtIn("late-night",     "Late Night",        [-4,   -3,   -2,    0,    1,    2,    2,    1,   -1,   -2]),
        builtIn("acoustic",       "Acoustic",          [ 3,    3,    2,  0.5,    1,    1,    2,  2.5,    2,  1.5]),
        builtIn("classical",      "Classical",         [ 4,    3,  2.5,    2,   -1,   -1,    0,    2,    3,  3.5]),
        builtIn("electronic",     "Electronic",        [4.5,   4,  1.5,    0,   -2,  1.5,  0.5,    1,    4,    5]),
        builtIn("hip-hop",        "Hip-Hop",           [ 5,  4.5,    2,    3,   -1,   -1,    1, -0.5,    2,    3]),
        builtIn("rnb",            "R&B",               [2.62, 6.92, 5.65, 1.33, -2.19, -1.5, 2.32, 2.65,  3.0, 3.75]),
        builtIn("rock",           "Rock",              [ 5,    4,    3,  1.5, -0.5,   -1,  0.5,  2.5,  3.5,  4.5]),
        builtIn("laptop",         "Laptop Speakers",   [-4,   -2,    1,    3,    2,    1,  1.5,    2,    1,    0]),
    ]
}

/// One source's EQ. `gains` are the live values (possibly edited from the preset);
/// `presetID` remembers which preset they started from.
public struct SourceEQ: Codable, Equatable, Sendable {
    public var presetID: String?
    public var gains: [Double]
    public var isBypassed: Bool
    /// When true, the EQ'd sound is kept at the same perceived loudness as the
    /// original: boosts don't make it louder, cuts don't make it quieter. A peak
    /// limiter, always on while EQ is active, catches anything that would clip.
    public var matchLoudness: Bool

    public init(presetID: String? = EQPreset.flat.id, gains: [Double] = GraphicEQ.flatGains,
                isBypassed: Bool = false, matchLoudness: Bool = true) {
        self.presetID = presetID
        self.gains = EQPreset.normalized(gains)
        self.isBypassed = isBypassed
        self.matchLoudness = matchLoudness
    }

    public static let off = SourceEQ()

    public var isFlat: Bool { gains.allSatisfy { abs($0) < 0.05 } }

    /// True when the EQ changes the sound, so the source needs processing.
    public var isActive: Bool { !isBypassed && !isFlat }

    public mutating func apply(_ preset: EQPreset) {
        presetID = preset.id
        gains = preset.gains
    }

    public mutating func setGain(_ db: Double, band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = min(max(db, GraphicEQ.gainRange.lowerBound), GraphicEQ.gainRange.upperBound)
    }

    /// True when the gains no longer match the preset they came from.
    public func isModified(from preset: EQPreset?) -> Bool {
        guard let preset else { return !isFlat }
        return zip(gains, preset.gains).contains { abs($0 - $1) > 0.05 }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        gains = EQPreset.normalized(try c.decodeIfPresent([Double].self, forKey: .gains) ?? GraphicEQ.flatGains)
        isBypassed = try c.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
        matchLoudness = try c.decodeIfPresent(Bool.self, forKey: .matchLoudness) ?? true
    }
}

/// Normalized biquad coefficients (a0 == 1), Direct Form II Transposed.
public struct Biquad: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// RBJ Audio EQ Cookbook peaking filter.
    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        guard abs(gainDB) > 0.001, sampleRate > 0, frequency < sampleRate * 0.45 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return Biquad(
            b0: (1 + alpha * a) / a0,
            b1: (-2 * cosw) / a0,
            b2: (1 - alpha * a) / a0,
            a1: (-2 * cosw) / a0,
            a2: (1 - alpha / a) / a0)
    }

    /// Magnitude response in dB at a frequency.
    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let numRe = b0 + b1 * c1 + b2 * c2
        let numIm = -(b1 * s1 + b2 * s2)
        let denRe = 1 + a1 * c1 + a2 * c2
        let denIm = -(a1 * s1 + a2 * s2)
        let mag = sqrt((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm))
        return 20 * log10(max(mag, 1e-9))
    }
}

/// Everything the DSP needs for one EQ state, computed off the audio thread.
public struct EQDesign: Equatable, Sendable {
    public var isEnabled: Bool
    public var preGain: Double
    public var biquads: [Biquad]

    public static let bypass = EQDesign(isEnabled: false, preGain: 1, biquads: [])

    public init(isEnabled: Bool, preGain: Double, biquads: [Biquad]) {
        self.isEnabled = isEnabled
        self.preGain = preGain
        self.biquads = biquads
    }

    public init(_ eq: SourceEQ, sampleRate: Double) {
        guard eq.isActive else { self = .bypass; return }
        let filters = zip(GraphicEQ.frequencies, eq.gains).map { f, g in
            Biquad.peaking(frequency: f, gainDB: g, q: GraphicEQ.q, sampleRate: sampleRate)
        }
        let makeup = eq.matchLoudness ? EQDesign.loudnessMakeupDB(filters, sampleRate: sampleRate) : 0
        self.init(isEnabled: true, preGain: pow(10, makeup / 20), biquads: filters)
    }

    /// Gain in dB that cancels the EQ's change in perceived loudness.
    ///
    /// Averages the curve's power gain over log-spaced frequencies, which treats each
    /// octave equally (music and speech carry roughly equal energy per octave), and
    /// weights it toward the range the ear is most sensitive to. Deep bass and the top
    /// octave still count, just less, so a bass boost is partly compensated rather
    /// than fully cancelled, which is how it is heard.
    public static func loudnessMakeupDB(_ filters: [Biquad], sampleRate: Double) -> Double {
        let points = response(filters, sampleRate: sampleRate, points: 128)
        var weighted = 0.0, total = 0.0
        for p in points {
            let w = perceptualWeight(p.frequency)
            weighted += w * pow(10, p.db / 10)
            total += w
        }
        guard total > 0, weighted > 0 else { return 0 }
        let change = 10 * log10(weighted / total)
        return min(max(-change, -GraphicEQ.maxMakeupDB), GraphicEQ.maxMakeupDB)
    }

    /// 1.0 from 200 Hz to 6 kHz, easing to 0.25 at 20 Hz and 20 kHz.
    static func perceptualWeight(_ f: Double) -> Double {
        let x = log10(f)
        if f < 200 { return 0.25 + 0.75 * max(0, (x - log10(20)) / (log10(200) - log10(20))) }
        if f > 6000 { return 0.25 + 0.75 * max(0, (log10(20000) - x) / (log10(20000) - log10(6000))) }
        return 1
    }

    /// The combined response at log-spaced frequencies from 20 Hz to 20 kHz.
    public static func response(_ filters: [Biquad], sampleRate: Double, points: Int) -> [(frequency: Double, db: Double)] {
        let lo = log10(20.0), hi = log10(min(20000.0, sampleRate * 0.49))
        return (0..<points).map { i in
            let f = pow(10, lo + (hi - lo) * Double(i) / Double(max(points - 1, 1)))
            return (f, filters.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: sampleRate) })
        }
    }

    /// Response curve of an EQ setting for display, including headroom.
    public static func displayCurve(_ eq: SourceEQ, sampleRate: Double = 48000, points: Int = 96) -> [(frequency: Double, db: Double)] {
        let filters = zip(GraphicEQ.frequencies, eq.gains).map { f, g in
            Biquad.peaking(frequency: f, gainDB: g, q: GraphicEQ.q, sampleRate: sampleRate)
        }
        return response(filters, sampleRate: sampleRate, points: points)
    }
}
