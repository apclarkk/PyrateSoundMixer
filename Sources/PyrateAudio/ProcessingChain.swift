import Foundation
import PyrateAtomics
import PyrateCore

/// One source's realtime processing chain:
///
///     tap input -> loudness makeup -> EQ (10 biquads per channel) -> channel mode + balance
///               -> Apple effects rack -> volume ramp -> lookahead peak limiter -> output
///
/// Each tapped source owns its own chain, so EQ and effects never leak between apps.
///
/// Threading: `setGain`, `setEQ`, `setEffects` and `setSampleRate` are called on the
/// main thread. `process` runs on the realtime IO thread and never locks or allocates.
/// Scalars cross threads through C11 atomics; sample-rate dependent designs cross
/// through a lock-free triple buffer; the effects rack crosses through an atomic pointer.
public final class ProcessingChain: @unchecked Sendable {
    public static let maxBands = GraphicEQ.bandCount
    static let channels = 2

    // Slot layout (Double): header, then b0 b1 b2 a1 a2 for each EQ band.
    enum Field {
        static let eqEnabled = 0, preGain = 1, bandCount = 2, limiterRelease = 3, lookahead = 4
        static let header = 5
    }
    static let slotSize = Field.header + maxBands * 5
    static let eqStateSize = channels * maxBands * 2
    /// Upper bound on lookahead samples (5 ms at 192 kHz is 960).
    static let maxLookahead = 2048
    static let limiterCeiling = Float(GraphicEQ.limiterCeiling)
    /// Last-resort safety above the limiter ceiling.
    static let clipKnee: Float = 0.95
    static let maxChunk = EffectRack.maxFrames

    // Shared with the IO thread
    private let targetGain: OpaquePointer
    private let peak: OpaquePointer
    private let balanceLeft: OpaquePointer
    private let balanceRight: OpaquePointer
    private let channelMode: OpaquePointer
    private let triple: OpaquePointer
    private let slots: UnsafeMutablePointer<Double>
    /// The live effects rack (an unretained `EffectRack`), or nil.
    private let rackPointer: OpaquePointer

    // Main-thread side
    public private(set) var sampleRate: Double
    public private(set) var eq: SourceEQ = .off
    public private(set) var effects: SourceEffects = .neutral
    public private(set) var rackSkipped: [String] = []
    /// Strong reference to the rack the IO thread uses; retired racks are freed a
    /// second after being swapped out, long after any render call that saw them.
    private var rack: EffectRack?

    // Realtime side (only touched inside `process`)
    private var currentGain: Float
    private var currentBalanceL: Float = 1
    private var currentBalanceR: Float = 1
    private var currentMode = 0
    private let previousSlot: UnsafeMutablePointer<Double>
    private let eqState: UnsafeMutablePointer<Double>
    private let previousEQState: UnsafeMutablePointer<Double>
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    // Lookahead limiter
    private let delayL: UnsafeMutablePointer<Float>
    private let delayR: UnsafeMutablePointer<Float>
    private let windowValues: UnsafeMutablePointer<Float>
    private let windowIndices: UnsafeMutablePointer<Int>
    private let boxRing: UnsafeMutablePointer<Float>
    private var windowHead = 0, windowTail = 0
    private var boxSum: Double = 0
    private var lookahead = 0
    private var sampleIndex = 0
    private var limiterGain: Float = 1

    public init(gain: Float, sampleRate: Double) {
        self.sampleRate = sampleRate
        targetGain = pyr_atomic_float_create(gain)
        peak = pyr_atomic_float_create(0)
        balanceLeft = pyr_atomic_float_create(1)
        balanceRight = pyr_atomic_float_create(1)
        channelMode = pyr_atomic_float_create(0)
        rackPointer = pyr_atomic_ptr_create(nil)
        triple = pyr_tb_create()
        slots = Self.buffer(Self.slotSize * 3, 0)
        previousSlot = Self.buffer(Self.slotSize, 0)
        eqState = Self.buffer(Self.eqStateSize, 0)
        previousEQState = Self.buffer(Self.eqStateSize, 0)
        scratchL = Self.buffer(Self.maxChunk, 0)
        scratchR = Self.buffer(Self.maxChunk, 0)
        delayL = Self.buffer(Self.maxLookahead, 0)
        delayR = Self.buffer(Self.maxLookahead, 0)
        windowValues = Self.buffer(Self.maxLookahead + 1, 1)
        windowIndices = Self.buffer(Self.maxLookahead + 1, 0)
        boxRing = Self.buffer(Self.maxLookahead, 1)
        currentGain = gain
        // Every slot starts with a valid design so the IO thread never reads zeros.
        for _ in 0..<3 { publish(.bypass) }
        pyr_tb_acquire(triple)
    }

    private static func buffer<T>(_ count: Int, _ value: T) -> UnsafeMutablePointer<T> {
        let p = UnsafeMutablePointer<T>.allocate(capacity: count)
        p.initialize(repeating: value, count: count)
        return p
    }

    deinit {
        [targetGain, peak, balanceLeft, balanceRight, channelMode].forEach { pyr_atomic_float_destroy($0) }
        pyr_atomic_ptr_destroy(rackPointer)
        pyr_tb_destroy(triple)
        slots.deallocate()
        previousSlot.deallocate()
        eqState.deallocate()
        previousEQState.deallocate()
        scratchL.deallocate()
        scratchR.deallocate()
        delayL.deallocate()
        delayR.deallocate()
        windowValues.deallocate()
        windowIndices.deallocate()
        boxRing.deallocate()
    }

    /// Latency the chain adds, in seconds (the limiter's lookahead).
    public var latency: Double { GraphicEQ.limiterLookaheadSeconds }

    /// Latency the effects rack adds, in seconds.
    public var rackLatency: Double { rack?.latency ?? 0 }

    // MARK: Main thread

    public func setGain(_ gain: Float) {
        pyr_store_float(targetGain, gain)
    }

    public func setEQ(_ eq: SourceEQ) {
        guard eq != self.eq else { return }
        self.eq = eq
        publish(EQDesign(eq, sampleRate: sampleRate))
    }

    /// Balance, channel mode, and the Apple effects rack for this source.
    @MainActor
    public func setEffects(_ effects: SourceEffects) {
        guard effects != self.effects else { return }
        self.effects = effects
        updateRack(effects.rack)
        let gains = effects.channelGains
        pyr_store_float(balanceLeft, Float(gains.left))
        pyr_store_float(balanceRight, Float(gains.right))
        let mode: Float
        switch effects.channelMode {
        case .stereo: mode = 0
        case .swapped: mode = 1
        case .mono: mode = 2
        }
        pyr_store_float(channelMode, mode)
    }

    @MainActor
    public func setSampleRate(_ rate: Double) {
        guard rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        publish(EQDesign(eq, sampleRate: rate))
        if rack != nil { installRack(effects.rack) }
    }

    /// Input peak since the last call, then resets it. Best effort; a lost update
    /// only means one meter frame is slightly off.
    public func takePeak() -> Float {
        let value = pyr_load_float(peak)
        pyr_store_float(peak, 0)
        return value
    }

    /// Parameter and bypass changes go to the running units; anything structural
    /// (effects added, removed, reordered, or a preset change) builds a new rack.
    @MainActor
    private func updateRack(_ wanted: [RackEffect]) {
        let structure = wanted.map(\.structureKey)
        if let rack, rack.structureKey == structure {
            rack.update(wanted)
        } else {
            installRack(wanted)
        }
    }

    @MainActor
    private func installRack(_ wanted: [RackEffect]) {
        let fresh = wanted.isEmpty ? nil : EffectRack(effects: wanted, sampleRate: sampleRate)
        rackSkipped = fresh?.skipped ?? []
        let raw = fresh.map { UnsafeMutableRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
        _ = pyr_atomic_ptr_exchange(rackPointer, raw)
        if let old = rack {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withExtendedLifetime(old) {} }
        }
        rack = fresh
    }

    func publish(_ design: EQDesign) {
        let slot = slots + Int(pyr_tb_back(triple)) * Self.slotSize
        slot[Field.eqEnabled] = design.isEnabled ? 1 : 0
        slot[Field.preGain] = design.preGain
        let count = min(design.biquads.count, Self.maxBands)
        slot[Field.bandCount] = Double(count)
        slot[Field.limiterRelease] = 1 - exp(-1 / (GraphicEQ.limiterReleaseSeconds * sampleRate))
        slot[Field.lookahead] = min(max((GraphicEQ.limiterLookaheadSeconds * sampleRate).rounded(), 1), Double(Self.maxLookahead))
        for (i, q) in design.biquads.prefix(count).enumerated() {
            let c = slot + Field.header + i * 5
            c[0] = q.b0; c[1] = q.b1; c[2] = q.b2; c[3] = q.a1; c[4] = q.a2
        }
        pyr_tb_publish(triple)
    }

    // MARK: Realtime thread

    /// Processes one stereo buffer. Inputs and outputs may have any stride.
    /// When `mono` is true the result is summed into `outL` only. Long buffers are
    /// processed in chunks the effects rack can take.
    func process(
        inL: UnsafeMutablePointer<Float>, inLStride: Int,
        inR: UnsafeMutablePointer<Float>, inRStride: Int,
        outL: UnsafeMutablePointer<Float>, outLStride: Int,
        outR: UnsafeMutablePointer<Float>, outRStride: Int,
        mono: Bool, frames: Int
    ) {
        var offset = 0
        while offset < frames {
            let n = min(Self.maxChunk, frames - offset)
            processChunk(inL: inL + offset * inLStride, inLStride: inLStride,
                         inR: inR + offset * inRStride, inRStride: inRStride,
                         outL: outL + offset * outLStride, outLStride: outLStride,
                         outR: outR + offset * outRStride, outRStride: outRStride,
                         mono: mono, frames: n)
            offset += n
        }
    }

    private func processChunk(
        inL: UnsafeMutablePointer<Float>, inLStride: Int,
        inR: UnsafeMutablePointer<Float>, inRStride: Int,
        outL: UnsafeMutablePointer<Float>, outLStride: Int,
        outR: UnsafeMutablePointer<Float>, outRStride: Int,
        mono: Bool, frames: Int
    ) {
        // Take a new design if one was published, keeping the old one (and its
        // filter state) to crossfade from across this chunk.
        var crossfade = false
        if pyr_tb_has_fresh(triple) {
            previousSlot.update(from: slots + Int(pyr_tb_front(triple)) * Self.slotSize, count: Self.slotSize)
            previousEQState.update(from: eqState, count: Self.eqStateSize)
            pyr_tb_acquire(triple)
            crossfade = true
        }
        let slot = slots + Int(pyr_tb_front(triple)) * Self.slotSize
        let eqOn = slot[Field.eqEnabled] != 0
        if crossfade && !eqOn && previousSlot[Field.eqEnabled] == 0 { crossfade = false }

        let rackRaw = pyr_atomic_ptr_load(rackPointer)
        // The ceiling guards anything that can add level; untouched audio only gets
        // the full-scale safety.
        let protect = eqOn || rackRaw != nil || (crossfade && previousSlot[Field.eqEnabled] != 0)
        let ceiling = protect ? Self.limiterCeiling : 1
        let release = Float(slot[Field.limiterRelease])

        let wantedLookahead = Int(slot[Field.lookahead])
        if wantedLookahead != lookahead { resetLimiter(lookahead: wantedLookahead) }
        let window = lookahead
        let delay = window - 1
        let cap = Self.maxLookahead
        let windowCap = cap + 1

        let fadeStep = 1 / Float(frames)
        let volumeStart = currentGain
        let volumeTarget = pyr_load_float(targetGain)
        let volumeStep = (volumeTarget - volumeStart) / Float(frames)
        // A channel mode change crossfades from the old mode to the new one.
        let mode = Int(pyr_load_float(channelMode))
        let oldMode = currentMode
        let balLTarget = pyr_load_float(balanceLeft), balRTarget = pyr_load_float(balanceRight)
        let balLStep = (balLTarget - currentBalanceL) / Float(frames)
        let balRStep = (balRTarget - currentBalanceR) / Float(frames)
        var balL = currentBalanceL, balR = currentBalanceR
        var maxPeak: Float = 0

        // Pass 1, per sample: EQ, channel mode, balance.
        for frame in 0..<frames {
            let l = inL[frame * inLStride]
            let r = inR[frame * inRStride]
            maxPeak = max(maxPeak, abs(l), abs(r))

            var yl = Float(Self.equalize(Double(l), channel: 0, slot: slot, state: eqState))
            var yr = Float(Self.equalize(Double(r), channel: 1, slot: slot, state: eqState))
            let t = Float(frame + 1) * fadeStep
            if crossfade {
                let pl = Float(Self.equalize(Double(l), channel: 0, slot: previousSlot, state: previousEQState))
                let pr = Float(Self.equalize(Double(r), channel: 1, slot: previousSlot, state: previousEQState))
                yl = pl + (yl - pl) * t
                yr = pr + (yr - pr) * t
            }

            var (ml, mr) = Self.applyMode(mode, yl, yr)
            if oldMode != mode {
                let (ol, or) = Self.applyMode(oldMode, yl, yr)
                ml = ol + (ml - ol) * t
                mr = or + (mr - or) * t
            }
            balL += balLStep
            balR += balRStep
            scratchL[frame] = ml * balL
            scratchR[frame] = mr * balR
        }

        // Pass 2, per block: the Apple effects rack, in place.
        if let rackRaw {
            Unmanaged<EffectRack>.fromOpaque(rackRaw)._withUnsafeGuaranteedRef {
                $0.process(left: scratchL, right: scratchR, frames: frames)
            }
        }

        // Pass 3, per sample: volume and the lookahead limiter. The limiter takes the
        // gain each sample needs, a sliding minimum over the lookahead window, then a
        // box average of that minimum. The average reaches each peak's gain exactly
        // when the peak leaves the delay line, so the ceiling holds without the gain
        // jumping inside a waveform.
        var volume = volumeStart
        for frame in 0..<frames {
            volume += volumeStep
            let a = scratchL[frame] * volume
            let b = scratchR[frame] * volume

            let lvl = max(abs(a), abs(b))
            let need = lvl > ceiling ? ceiling / lvl : 1
            while windowTail > windowHead && windowValues[(windowTail - 1) % windowCap] >= need {
                windowTail -= 1
            }
            windowValues[windowTail % windowCap] = need
            windowIndices[windowTail % windowCap] = sampleIndex
            windowTail += 1
            while windowIndices[windowHead % windowCap] <= sampleIndex - window {
                windowHead += 1
            }
            let held = windowValues[windowHead % windowCap]
            let boxSlot = sampleIndex % window
            boxSum += Double(held - boxRing[boxSlot])
            boxRing[boxSlot] = held
            let smoothed = Float(boxSum / Double(window))
            limiterGain = smoothed < limiterGain ? smoothed : limiterGain + (smoothed - limiterGain) * release

            delayL[sampleIndex % cap] = a
            delayR[sampleIndex % cap] = b
            let readIndex = (sampleIndex - delay + cap * 2) % cap
            let ol = Self.softClip(delayL[readIndex] * limiterGain)
            let or = Self.softClip(delayR[readIndex] * limiterGain)
            sampleIndex += 1

            if mono {
                outL[frame * outLStride] = (ol + or) * 0.5
            } else {
                outL[frame * outLStride] = ol
                outR[frame * outRStride] = or
            }
        }

        currentGain = volumeTarget
        currentBalanceL = balLTarget
        currentBalanceR = balRTarget
        currentMode = mode
        // Keep the counters small; the modulo arithmetic only needs them consistent.
        if sampleIndex > 1 << 40 { resetLimiter(lookahead: lookahead) }
        if maxPeak > pyr_load_float(peak) { pyr_store_float(peak, maxPeak) }
    }

    @inline(__always)
    static func applyMode(_ mode: Int, _ l: Float, _ r: Float) -> (Float, Float) {
        switch mode {
        case 1: return (r, l)
        case 2: let m = (l + r) * 0.5; return (m, m)
        default: return (l, r)
        }
    }

    private func resetLimiter(lookahead newValue: Int) {
        lookahead = min(max(newValue, 1), Self.maxLookahead)
        delayL.update(repeating: 0, count: Self.maxLookahead)
        delayR.update(repeating: 0, count: Self.maxLookahead)
        boxRing.update(repeating: 1, count: Self.maxLookahead)
        boxSum = Double(lookahead)
        windowHead = 0
        windowTail = 0
        sampleIndex = 0
        limiterGain = 1
    }

    /// Loudness makeup plus the EQ biquad cascade for one sample (Direct Form II
    /// Transposed, double precision). Pass-through when the EQ is off.
    @inline(__always)
    static func equalize(_ x: Double, channel: Int, slot: UnsafeMutablePointer<Double>, state: UnsafeMutablePointer<Double>) -> Double {
        guard slot[Field.eqEnabled] != 0 else { return x }
        var y = x * slot[Field.preGain]
        let count = Int(slot[Field.bandCount])
        let s = state + channel * maxBands * 2
        for band in 0..<count {
            let c = slot + Field.header + band * 5
            let z = s + band * 2
            let out = c[0] * y + z[0]
            z[0] = c[1] * y - c[3] * out + z[1]
            z[1] = c[2] * y - c[4] * out
            y = out
        }
        return y
    }

    /// Transparent below the knee, smoothly approaches full scale above it.
    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        let a = abs(x)
        guard a > clipKnee else { return x }
        let range = 1 - clipKnee
        let shaped = clipKnee + range * tanhf((a - clipKnee) / range)
        return x < 0 ? -shaped : shaped
    }
}
