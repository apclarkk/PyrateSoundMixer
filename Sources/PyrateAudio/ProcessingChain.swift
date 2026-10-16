import Foundation
import PyrateAtomics
import PyrateCore

/// One source's realtime processing chain:
///
///     tap input -> loudness makeup -> EQ (10 biquads per channel) -> channel mode + balance
///               -> Apple effects rack -> normalizer trim -> volume ramp -> lookahead peak limiter -> output
///
/// Each tapped source owns its own chain, so EQ and effects never leak between apps.
///
/// Threading: `setGain`, `setEQ`, `setLeveling` and `setSampleRate` are called on the
/// main thread. `process` runs on the realtime IO thread and never locks or allocates.
/// Scalars cross threads through C11 atomics; sample-rate dependent designs cross
/// through a lock-free triple buffer.
public final class ProcessingChain: @unchecked Sendable {
    public static let maxBands = GraphicEQ.bandCount
    static let channels = 2

    // Slot layout (Double): header, then b0 b1 b2 a1 a2 for each EQ band.
    enum Field {
        static let eqEnabled = 0, preGain = 1, bandCount = 2, limiterRelease = 3, lookahead = 4
        static let kWeight1 = 5, kWeight2 = 10
        static let hopSamples = 15, learningSamples = 16
        static let header = 17
    }
    static let slotSize = Field.header + maxBands * 5
    static let eqStateSize = channels * maxBands * 2
    static let kStateSize = channels * 2 * 2
    /// Upper bound on lookahead samples (5 ms at 192 kHz is 960).
    static let maxLookahead = 2048
    static let limiterCeiling = Float(GraphicEQ.limiterCeiling)
    /// Last-resort safety above the limiter ceiling.
    static let clipKnee: Float = 0.95

    // Shared with the IO thread
    private let targetGain: OpaquePointer
    private let peak: OpaquePointer
    private let levelerEnabled: OpaquePointer
    private let levelerTarget: OpaquePointer
    private let levelerReport: OpaquePointer
    private let balanceLeft: OpaquePointer
    private let balanceRight: OpaquePointer
    private let channelMode: OpaquePointer
    /// The live effects rack (an unretained `EffectRack`), or nil.
    private let rackPointer: OpaquePointer
    /// Strong reference to the rack the IO thread uses; retired racks are freed a
    /// second after being swapped out, long after any render call that saw them.
    private var rack: EffectRack?
    public private(set) var rackSkipped: [String] = []
    static let maxChunk = EffectRack.maxFrames
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    private let levelerBoostOnly: OpaquePointer
    /// A trim to start from (NaN when none), e.g. what this app settled at earlier.
    private let levelerSeed: OpaquePointer
    private let triple: OpaquePointer
    private let slots: UnsafeMutablePointer<Double>

    // Main-thread side
    public private(set) var sampleRate: Double
    public private(set) var eq: SourceEQ = .off
    public private(set) var leveling: LevelingSettings?
    public private(set) var effects: SourceEffects = .neutral

    // Realtime side (only touched inside `process`)
    private var currentGain: Float
    private var currentBalanceL: Float = 1
    private var currentBalanceR: Float = 1
    private let previousSlot: UnsafeMutablePointer<Double>
    private let eqState: UnsafeMutablePointer<Double>
    private let previousEQState: UnsafeMutablePointer<Double>
    private let kState: UnsafeMutablePointer<Double>
    private var levelDB: Double = 0
    private var levelLinear: Float = 1
    private var samplesSeen = 0
    // Normalizer measurement: 100 ms hops, 400 ms blocks, 30 s window of blocks.
    private var hopEnergy: Double = 0
    private var hopCount = 0
    private let hopRing: UnsafeMutablePointer<Double>
    private var hopsDone = 0
    private let blockRing: UnsafeMutablePointer<Double>
    private var blocksDone = 0
    private var heardBlocks = 0
    private var correcting = false
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
        levelerEnabled = pyr_atomic_float_create(0)
        levelerTarget = pyr_atomic_float_create(Float(LevelingSettings.Target.balanced.lufs))
        levelerReport = pyr_atomic_float_create(0)
        balanceLeft = pyr_atomic_float_create(1)
        balanceRight = pyr_atomic_float_create(1)
        channelMode = pyr_atomic_float_create(0)
        rackPointer = pyr_atomic_ptr_create(nil)
        scratchL = .allocate(capacity: Self.maxChunk)
        scratchL.initialize(repeating: 0, count: Self.maxChunk)
        scratchR = .allocate(capacity: Self.maxChunk)
        scratchR.initialize(repeating: 0, count: Self.maxChunk)
        levelerBoostOnly = pyr_atomic_float_create(0)
        levelerSeed = pyr_atomic_float_create(.nan)
        hopRing = .allocate(capacity: LevelerTuning.blockHops)
        hopRing.initialize(repeating: 0, count: LevelerTuning.blockHops)
        blockRing = .allocate(capacity: LevelerTuning.windowBlocks)
        blockRing.initialize(repeating: 0, count: LevelerTuning.windowBlocks)
        triple = pyr_tb_create()
        slots = .allocate(capacity: Self.slotSize * 3)
        slots.initialize(repeating: 0, count: Self.slotSize * 3)
        previousSlot = .allocate(capacity: Self.slotSize)
        previousSlot.initialize(repeating: 0, count: Self.slotSize)
        eqState = .allocate(capacity: Self.eqStateSize)
        eqState.initialize(repeating: 0, count: Self.eqStateSize)
        previousEQState = .allocate(capacity: Self.eqStateSize)
        previousEQState.initialize(repeating: 0, count: Self.eqStateSize)
        kState = .allocate(capacity: Self.kStateSize)
        kState.initialize(repeating: 0, count: Self.kStateSize)
        delayL = .allocate(capacity: Self.maxLookahead)
        delayL.initialize(repeating: 0, count: Self.maxLookahead)
        delayR = .allocate(capacity: Self.maxLookahead)
        delayR.initialize(repeating: 0, count: Self.maxLookahead)
        windowValues = .allocate(capacity: Self.maxLookahead + 1)
        windowValues.initialize(repeating: 1, count: Self.maxLookahead + 1)
        windowIndices = .allocate(capacity: Self.maxLookahead + 1)
        windowIndices.initialize(repeating: 0, count: Self.maxLookahead + 1)
        boxRing = .allocate(capacity: Self.maxLookahead)
        boxRing.initialize(repeating: 1, count: Self.maxLookahead)
        currentGain = gain
        // Every slot starts with a valid design so the IO thread never reads zeros.
        let initial = EQDesign.bypass
        for _ in 0..<3 { publish(initial) }
        pyr_tb_acquire(triple)
    }

    deinit {
        [targetGain, peak, levelerEnabled, levelerTarget, levelerReport, levelerBoostOnly, levelerSeed,
         balanceLeft, balanceRight, channelMode]
            .forEach { pyr_atomic_float_destroy($0) }
        pyr_atomic_ptr_destroy(rackPointer)
        scratchL.deallocate()
        scratchR.deallocate()
        hopRing.deallocate()
        blockRing.deallocate()
        pyr_tb_destroy(triple)
        slots.deallocate()
        previousSlot.deallocate()
        eqState.deallocate()
        previousEQState.deallocate()
        kState.deallocate()
        delayL.deallocate()
        delayR.deallocate()
        windowValues.deallocate()
        windowIndices.deallocate()
        boxRing.deallocate()
    }

    /// Latency the chain adds, in seconds (the limiter's lookahead).
    public var latency: Double { GraphicEQ.limiterLookaheadSeconds }

    // MARK: Main thread

    public func setGain(_ gain: Float) {
        pyr_store_float(targetGain, gain)
    }

    public func setEQ(_ eq: SourceEQ) {
        guard eq != self.eq else { return }
        self.eq = eq
        publish(EQDesign(eq, sampleRate: sampleRate))
    }

    /// Turns loudness normalization on with its settings, or off with nil.
    public func setLeveling(_ settings: LevelingSettings?) {
        leveling = settings
        pyr_store_float(levelerTarget, Float((settings?.target ?? .balanced).lufs))
        pyr_store_float(levelerBoostOnly, settings?.boostOnly == true ? 1 : 0)
        pyr_store_float(levelerEnabled, settings == nil ? 0 : 1)
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

    /// Starts the normalizer from a known trim instead of 0 dB. Call before audio flows.
    public func seedLeveler(_ db: Float) {
        pyr_store_float(levelerSeed, db)
    }

    @MainActor
    public func setSampleRate(_ rate: Double) {
        guard rate > 0, rate != sampleRate else { return }
        sampleRate = rate
        publish(EQDesign(eq, sampleRate: rate))
        if rack != nil { installRack(effects.rack) }
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

    /// Latency the effects rack adds, in seconds.
    public var rackLatency: Double { rack?.latency ?? 0 }

    /// Input peak since the last call, then resets it. Best effort; a lost update
    /// only means one meter frame is slightly off.
    public func takePeak() -> Float {
        let value = pyr_load_float(peak)
        pyr_store_float(peak, 0)
        return value
    }

    /// The leveler's current adjustment in dB (0 when off or settled at target).
    public var levelerAdjustmentDB: Float { pyr_load_float(levelerReport) }

    func publish(_ design: EQDesign) {
        let slot = slots + Int(pyr_tb_back(triple)) * Self.slotSize
        slot[Field.eqEnabled] = design.isEnabled ? 1 : 0
        slot[Field.preGain] = design.preGain
        let count = min(design.biquads.count, Self.maxBands)
        slot[Field.bandCount] = Double(count)
        slot[Field.limiterRelease] = 1 - exp(-1 / (GraphicEQ.limiterReleaseSeconds * sampleRate))
        slot[Field.lookahead] = min(max((GraphicEQ.limiterLookaheadSeconds * sampleRate).rounded(), 1), Double(Self.maxLookahead))
        let k = LevelerTuning.kWeighting(sampleRate: sampleRate)
        Self.write(k[0], to: slot + Field.kWeight1)
        Self.write(k[1], to: slot + Field.kWeight2)
        slot[Field.hopSamples] = (LevelerTuning.hopSeconds * sampleRate).rounded()
        slot[Field.learningSamples] = LevelerTuning.learningSeconds * sampleRate
        for (i, q) in design.biquads.prefix(count).enumerated() {
            Self.write(q, to: slot + Field.header + i * 5)
        }
        pyr_tb_publish(triple)
    }

    private static func write(_ q: Biquad, to c: UnsafeMutablePointer<Double>) {
        c[0] = q.b0; c[1] = q.b1; c[2] = q.b2; c[3] = q.a1; c[4] = q.a2
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
        // filter state) to crossfade from across this buffer.
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

        let leveling = pyr_load_float(levelerEnabled) != 0
        let rackRaw = pyr_atomic_ptr_load(rackPointer)
        let protect = eqOn || leveling || rackRaw != nil || (crossfade && previousSlot[Field.eqEnabled] != 0)
        let ceiling = protect ? Self.limiterCeiling : 1
        let release = Float(slot[Field.limiterRelease])

        let wantedLookahead = Int(slot[Field.lookahead])
        if wantedLookahead != lookahead { resetLimiter(lookahead: wantedLookahead) }
        let window = lookahead
        let delay = window - 1
        let cap = Self.maxLookahead
        let windowCap = cap + 1

        let seed = pyr_load_float(levelerSeed)
        if !seed.isNaN {
            levelDB = Double(seed)
            levelLinear = Float(pow(10, levelDB / 20))
            pyr_store_float(levelerSeed, .nan)
        }

        // Volume and normalizer gains ramp across the buffer.
        let volumeStart = currentGain
        let volumeTarget = pyr_load_float(targetGain)
        let volumeStep = (volumeTarget - volumeStart) / Float(frames)
        let levelStart = levelLinear
        let levelTarget = Float(pow(10, levelDB / 20))
        let levelStep = (levelTarget - levelStart) / Float(frames)
        let hopSamples = max(Int(slot[Field.hopSamples]), 1)
        let fadeStep = 1 / Float(frames)
        let mode = Int(pyr_load_float(channelMode))
        let balLStart = currentBalanceL, balRStart = currentBalanceR
        let balLTarget = pyr_load_float(balanceLeft), balRTarget = pyr_load_float(balanceRight)
        let balLStep = (balLTarget - balLStart) / Float(frames)
        let balRStep = (balRTarget - balRStart) / Float(frames)
        var balL = balLStart, balR = balRStart

        var volume = volumeStart
        var level = levelStart
        var maxPeak: Float = 0

        // Pass 1, per sample: EQ, channel mode, balance.
        for frame in 0..<frames {
            let l = inL[frame * inLStride]
            let r = inR[frame * inRStride]
            maxPeak = max(maxPeak, abs(l), abs(r))

            var yl = Float(Self.equalize(Double(l), channel: 0, slot: slot, state: eqState))
            var yr = Float(Self.equalize(Double(r), channel: 1, slot: slot, state: eqState))
            if crossfade {
                let t = Float(frame + 1) * fadeStep
                let pl = Float(Self.equalize(Double(l), channel: 0, slot: previousSlot, state: previousEQState))
                let pr = Float(Self.equalize(Double(r), channel: 1, slot: previousSlot, state: previousEQState))
                yl = pl + (yl - pl) * t
                yr = pr + (yr - pr) * t
            }

            // Channel mode, then level-neutral balance (ramped so moves are smooth).
            if mode == 1 {
                swap(&yl, &yr)
            } else if mode == 2 {
                let m = (yl + yr) * 0.5
                yl = m
                yr = m
            }
            balL += balLStep
            balR += balRStep
            scratchL[frame] = yl * balL
            scratchR[frame] = yr * balR
        }

        // Pass 2, per block: the Apple effects rack, in place.
        if let rackRaw {
            Unmanaged<EffectRack>.fromOpaque(rackRaw)._withUnsafeGuaranteedRef {
                $0.process(left: scratchL, right: scratchR, frames: frames)
            }
        }

        // Pass 3, per sample: measurement, gains, lookahead limiter, output.
        for frame in 0..<frames {
            volume += volumeStep
            level += levelStep
            let yl = scratchL[frame]
            let yr = scratchR[frame]

            if leveling {
                // K-weighted energy of both channels (BS.1770), measured before the
                // trim so the loop is open and stable.
                let kl = Self.kWeight(Double(yl), channel: 0, slot: slot, state: kState)
                let kr = Self.kWeight(Double(yr), channel: 1, slot: slot, state: kState)
                hopEnergy += kl * kl + kr * kr
                hopCount += 1
                if hopCount >= hopSamples { completeHop(slot: slot) }
            }

            let g = volume * level
            let a = yl * g
            let b = yr * g

            // Lookahead limiter: the gain each sample needs, a sliding minimum over
            // the lookahead window, then a box average of that minimum. The average
            // reaches each peak's gain exactly when the peak leaves the delay line,
            // so the ceiling holds without the gain jumping inside a waveform.
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
        levelLinear = levelTarget
        samplesSeen += frames
        if !leveling && levelDB != 0 {
            // Turned off: glide back to unity at the normal rate.
            let step = LevelerTuning.slewDBPerSecond * Double(frames) / sampleRateFromSlot(slot)
            levelDB = abs(levelDB) <= step ? 0 : levelDB - (levelDB > 0 ? step : -step)
            correcting = false
        }
        pyr_store_float(levelerReport, Float(levelDB))
        // Keep the counters small; the modulo arithmetic only needs them consistent.
        if sampleIndex > 1 << 40 { resetLimiter(lookahead: lookahead) }
        if maxPeak > pyr_load_float(peak) { pyr_store_float(peak, maxPeak) }
    }

    private func sampleRateFromSlot(_ slot: UnsafeMutablePointer<Double>) -> Double {
        max(slot[Field.hopSamples] / LevelerTuning.hopSeconds, 1)
    }

    /// Every 100 ms: close a hop, form the latest 400 ms block, and re-evaluate.
    private func completeHop(slot: UnsafeMutablePointer<Double>) {
        let hopMS = hopEnergy / Double(hopCount)
        hopEnergy = 0
        hopCount = 0
        hopRing[hopsDone % LevelerTuning.blockHops] = hopMS
        hopsDone += 1
        guard hopsDone >= LevelerTuning.blockHops else { return }

        var block = 0.0
        for i in 0..<LevelerTuning.blockHops { block += hopRing[i] }
        block /= Double(LevelerTuning.blockHops)
        blockRing[blocksDone % LevelerTuning.windowBlocks] = block
        blocksDone += 1
        if LevelerTuning.loudnessOffset + 10 * log10(block + 1e-20) > LevelerTuning.absoluteGateLUFS {
            heardBlocks += 1
        }
        updateNormalizer(slot: slot)
    }

    /// Nudges the trim toward the target. Holds until enough real audio has been
    /// heard, does nothing inside the deadband, and never moves faster than the slew.
    private func updateNormalizer(slot: UnsafeMutablePointer<Double>) {
        let minimumBlocks = Int(LevelerTuning.minimumHeardSeconds / LevelerTuning.hopSeconds)
        guard heardBlocks >= minimumBlocks else { return }
        let window = UnsafeBufferPointer(start: blockRing, count: min(blocksDone, LevelerTuning.windowBlocks))
        guard let loudness = LevelerTuning.integratedLoudness(window) else { return }

        let desired = LevelerTuning.desiredTrim(
            loudness: loudness,
            target: Double(pyr_load_float(levelerTarget)),
            boostOnly: pyr_load_float(levelerBoostOnly) != 0)
        let error = desired - levelDB
        if !correcting && abs(error) > LevelerTuning.deadbandDB { correcting = true }
        guard correcting else { return }

        let learning = Double(samplesSeen) < slot[Field.learningSamples]
        let rate = learning ? LevelerTuning.learningSlewDBPerSecond : LevelerTuning.slewDBPerSecond
        let step = rate * LevelerTuning.hopSeconds
        if abs(error) <= step {
            levelDB = desired
            correcting = false
        } else {
            levelDB += error > 0 ? step : -step
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
            y = biquad(y, coefficients: slot + Field.header + band * 5, state: s + band * 2)
        }
        return y
    }

    @inline(__always)
    static func kWeight(_ x: Double, channel: Int, slot: UnsafeMutablePointer<Double>, state: UnsafeMutablePointer<Double>) -> Double {
        let s = state + channel * 4
        let y = biquad(x, coefficients: slot + Field.kWeight1, state: s)
        return biquad(y, coefficients: slot + Field.kWeight2, state: s + 2)
    }

    @inline(__always)
    static func biquad(_ x: Double, coefficients c: UnsafeMutablePointer<Double>, state z: UnsafeMutablePointer<Double>) -> Double {
        let y = c[0] * x + z[0]
        z[0] = c[1] * x - c[3] * y + z[1]
        z[1] = c[2] * x - c[4] * y
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
