import Foundation
import Testing
@testable import PyrateAudio
import PyrateCore

/// Offline tests of the realtime chain: feed sine waves through `process` and
/// measure what comes out, exactly as the IOProc would call it.
@Suite("ProcessingChain")
@MainActor
struct ProcessingChainTests {
    let rate = 48000.0
    let block = 512

    /// Runs `seconds` of a stereo sine through the chain; returns output RMS of the final quarter.
    func rms(chain: ProcessingChain, frequency: Double, amplitude: Float = 0.25, seconds: Double = 0.5) -> Float {
        let total = Int(rate * seconds)
        var input = [Float](repeating: 0, count: block * 2)
        var output = [Float](repeating: 0, count: block * 2)
        var sum: Float = 0
        var count = 0
        var n = 0
        while n < total {
            for i in 0..<block {
                let v = amplitude * Float(sin(2 * .pi * frequency * Double(n + i) / rate))
                input[i * 2] = v
                input[i * 2 + 1] = v
            }
            input.withUnsafeMutableBufferPointer { inp in
                output.withUnsafeMutableBufferPointer { out in
                    chain.process(
                        inL: inp.baseAddress!, inLStride: 2, inR: inp.baseAddress! + 1, inRStride: 2,
                        outL: out.baseAddress!, outLStride: 2, outR: out.baseAddress! + 1, outRStride: 2,
                        mono: false, frames: block)
                }
            }
            if n > total * 3 / 4 {
                for i in 0..<block { sum += output[i * 2] * output[i * 2]; count += 1 }
            }
            n += block
        }
        return sqrt(sum / Float(max(count, 1)))
    }

    func db(_ ratio: Float) -> Double { 20 * log10(Double(ratio)) }

    let inputRMS: Float = 0.25 / sqrt(2)

    @Test func unityPassesThrough() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        #expect(abs(db(rms(chain: chain, frequency: 1000) / inputRMS)) < 0.05)
    }

    @Test func gainApplies() {
        let chain = ProcessingChain(gain: 0.5, sampleRate: rate)
        #expect(abs(db(rms(chain: chain, frequency: 1000) / inputRMS) - (-6.02)) < 0.1)
    }

    @Test func eqBoostsItsBandWithoutHeadroom() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        var eq = SourceEQ(matchLoudness: false)
        eq.setGain(6, band: 5)  // 1 kHz
        chain.setEQ(eq)
        #expect(abs(db(rms(chain: chain, frequency: 1000) / inputRMS) - 6) < 0.3)
        // A distant band is untouched.
        let far = ProcessingChain(gain: 1, sampleRate: rate)
        far.setEQ(eq)
        #expect(abs(db(rms(chain: far, frequency: 60) / inputRMS)) < 0.3)
    }

    /// RMS and peak of a broadband signal (equal-amplitude tones, one per third
    /// octave, roughly the spectrum of music) after the chain settles.
    func broadband(chain: ProcessingChain, amplitude: Float) -> (rms: Float, peak: Float, inputRMS: Float) {
        let tones = stride(from: 0, to: 27, by: 1).map { 40 * pow(2, Double($0) / 3) }
        let total = Int(rate * 0.6)
        var input = [Float](repeating: 0, count: block * 2)
        var output = [Float](repeating: 0, count: block * 2)
        var sum: Float = 0, inSum: Float = 0, peak: Float = 0
        var n = 0
        while n < total {
            for i in 0..<block {
                var v: Float = 0
                for (k, f) in tones.enumerated() { v += Float(sin(2 * .pi * f * Double(n + i) / rate + Double(k))) }
                v *= amplitude / Float(tones.count)
                input[i * 2] = v; input[i * 2 + 1] = v
            }
            input.withUnsafeMutableBufferPointer { inp in
                output.withUnsafeMutableBufferPointer { out in
                    chain.process(
                        inL: inp.baseAddress!, inLStride: 2, inR: inp.baseAddress! + 1, inRStride: 2,
                        outL: out.baseAddress!, outLStride: 2, outR: out.baseAddress! + 1, outRStride: 2,
                        mono: false, frames: block)
                }
            }
            if n > total / 2 {
                for i in 0..<block {
                    sum += output[i * 2] * output[i * 2]
                    inSum += input[i * 2] * input[i * 2]
                    peak = max(peak, abs(output[i * 2]))
                }
            }
            n += block
        }
        return (sqrt(sum), peak, sqrt(inSum))
    }

    @Test func loudnessMatchingKeepsPresetsNearOriginalLevel() {
        for id in ["builtin.loudness", "builtin.bass-boost", "builtin.bass-reducer", "builtin.rnb"] {
            let preset = EQPreset.builtIns.first { $0.id == id }!
            var eq = SourceEQ()
            eq.apply(preset)
            let matched = ProcessingChain(gain: 1, sampleRate: rate)
            matched.setEQ(eq)
            let m = broadband(chain: matched, amplitude: 0.2)
            eq.matchLoudness = false
            let raw = ProcessingChain(gain: 1, sampleRate: rate)
            raw.setEQ(eq)
            let r = broadband(chain: raw, amplitude: 0.2)
            let matchedDB = abs(db(m.rms / m.inputRMS))
            #expect(matchedDB < 2.5, "\(preset.name): \(matchedDB) dB from original")
            #expect(matchedDB <= abs(db(r.rms / r.inputRMS)) + 0.1, "\(preset.name) matching should not be further off than raw")
        }
    }

    @Test func limiterHoldsCeilingOnHotSignals() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        var eq = SourceEQ(matchLoudness: false)
        eq.apply(EQPreset.builtIns.first { $0.id == "builtin.bass-boost" }!)
        chain.setEQ(eq)
        let result = broadband(chain: chain, amplitude: 0.95)
        #expect(result.peak <= Float(GraphicEQ.limiterCeiling) + 0.001)
    }

    @Test func bypassRestoresOriginal() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        var eq = SourceEQ(matchLoudness: false)
        eq.setGain(-12, band: 5)
        chain.setEQ(eq)
        #expect(db(rms(chain: chain, frequency: 1000) / inputRMS) < -11)
        eq.isBypassed = true
        chain.setEQ(eq)
        #expect(abs(db(rms(chain: chain, frequency: 1000) / inputRMS)) < 0.05)
    }

    @Test func softClipIsTransparentBelowKnee() {
        #expect(ProcessingChain.softClip(3) <= 1)
        #expect(ProcessingChain.softClip(-3) >= -1)
        #expect(ProcessingChain.softClip(0.5) == 0.5)
    }

    @Test func sampleRateChangeRecomputes() {
        let chain = ProcessingChain(gain: 1, sampleRate: 44100)
        var eq = SourceEQ(matchLoudness: false)
        eq.setGain(6, band: 5)
        chain.setEQ(eq)
        chain.setSampleRate(rate)
        #expect(chain.sampleRate == rate)
        #expect(abs(db(rms(chain: chain, frequency: 1000) / inputRMS) - 6) < 0.3)
    }

    @Test func rapidUpdatesAlwaysLandOnLatest() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        var eq = SourceEQ(matchLoudness: false)
        for g in stride(from: -12.0, through: 6, by: 1.5) {
            eq.setGain(g, band: 5)
            chain.setEQ(eq)
        }
        #expect(abs(db(rms(chain: chain, frequency: 1000) / inputRMS) - 6) < 0.3)
    }

    @Test func outputIsFiniteForEveryPreset() {
        for preset in EQPreset.builtIns {
            let chain = ProcessingChain(gain: 1, sampleRate: rate)
            var eq = SourceEQ()
            eq.apply(preset)
            chain.setEQ(eq)
            for f in [32.0, 1000, 15000] {
                let out = rms(chain: chain, frequency: f, seconds: 0.2)
                #expect(out.isFinite && out < 1, "\(preset.name) at \(f) Hz")
            }
        }
    }
}

/// Lookahead limiter and loudness leveler, driven offline like the IOProc would.
@Suite("Limiter and leveler")
struct LimiterLevelerTests {
    let rate = 48000.0
    let block = 512

    /// Streams a mono signal (duplicated to stereo) through the chain and returns the left output.
    func run(_ chain: ProcessingChain, seconds: Double, signal: (Int) -> Float) -> [Float] {
        let total = Int(rate * seconds)
        var result = [Float]()
        result.reserveCapacity(total)
        var input = [Float](repeating: 0, count: block * 2)
        var output = [Float](repeating: 0, count: block * 2)
        var n = 0
        while n < total {
            for i in 0..<block { let v = signal(n + i); input[i * 2] = v; input[i * 2 + 1] = v }
            input.withUnsafeMutableBufferPointer { inp in
                output.withUnsafeMutableBufferPointer { out in
                    chain.process(
                        inL: inp.baseAddress!, inLStride: 2, inR: inp.baseAddress! + 1, inRStride: 2,
                        outL: out.baseAddress!, outLStride: 2, outR: out.baseAddress! + 1, outRStride: 2,
                        mono: false, frames: block)
                }
            }
            for i in 0..<block { result.append(output[i * 2]) }
            n += block
        }
        return result
    }

    func sine(_ f: Double, _ amplitude: Float) -> (Int) -> Float {
        { n in amplitude * Float(sin(2 * .pi * f * Double(n) / 48000)) }
    }

    /// Magnitude of one frequency in a signal (Goertzel).
    func magnitude(_ x: ArraySlice<Float>, frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / rate
        let coeff = 2 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for v in x { let s = Double(v) + coeff * s1 - s2; s2 = s1; s1 = s }
        return sqrt(s1 * s1 + s2 * s2 - coeff * s1 * s2)
    }

    func rmsDB(_ x: ArraySlice<Float>) -> Double {
        let ms = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)
        return 10 * log10(ms + 1e-20)
    }

    @Test func bassUnderHeavyLimitingStaysClean() {
        // The case that sounded crunchy: a boosted low end pushed hard into the limiter.
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        var eq = SourceEQ(matchLoudness: false)
        eq.setGain(12, band: 1)  // 64 Hz
        chain.setEQ(eq)
        let out = run(chain, seconds: 1.5, signal: sine(60, 0.9))
        let tail = out[out.count / 2..<out.count]
        #expect(tail.map(abs).max()! <= Float(GraphicEQ.limiterCeiling) + 0.001)
        let fundamental = magnitude(tail, frequency: 60)
        let third = magnitude(tail, frequency: 180)
        let distortionDB = 20 * log10(third / fundamental)
        #expect(distortionDB < -40, "3rd harmonic at \(distortionDB) dB")
    }

    @Test func latencyIsTheLookahead() {
        let chain = ProcessingChain(gain: 0.5, sampleRate: rate)
        let out = run(chain, seconds: 0.05) { $0 == 1000 ? 1 : 0 }
        let expected = 1000 + Int((GraphicEQ.limiterLookaheadSeconds * rate).rounded()) - 1
        #expect(out.firstIndex { abs($0) > 0.01 } == expected)
    }

    func normalizer(_ target: LevelingSettings.Target = .balanced, boostOnly: Bool = false) -> LevelingSettings {
        LevelingSettings(isEnabled: true, target: target, boostOnly: boostOnly)
    }

    /// Amplitude of a 1 kHz sine (both channels) with a given BS.1770 loudness.
    func amplitude(lufs: Double) -> Float {
        Float(sqrt(pow(10, (lufs - LevelerTuning.loudnessOffset) / 10)))
    }

    @Test func quietSourcesAreRaisedUpToTheCap() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.setLeveling(normalizer())
        _ = run(chain, seconds: 15, signal: sine(1000, amplitude(lufs: -30)))
        #expect(abs(chain.levelerAdjustmentDB - Float(LevelerTuning.maxAdjustDB)) < 0.05)
    }

    @Test func loudSourcesAreLoweredByAtMostTheCap() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.setLeveling(normalizer())
        _ = run(chain, seconds: 15, signal: sine(1000, amplitude(lufs: -4)))
        #expect(abs(chain.levelerAdjustmentDB + Float(LevelerTuning.maxAdjustDB)) < 0.05)
    }

    @Test func modestOffsetsReachTheExactTrim() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.setLeveling(normalizer())
        _ = run(chain, seconds: 15, signal: sine(1000, amplitude(lufs: -18)))
        // K-weighting shifts a 1 kHz tone slightly, so the measured loudness differs a little.
        let k = LevelerTuning.kWeighting(sampleRate: rate).reduce(0) { $0 + $1.magnitudeDB(at: 1000, sampleRate: rate) }
        #expect(abs(Double(chain.levelerAdjustmentDB) - (4 - k)) < 0.15)
    }

    @Test func nothingChangesInsideTheDeadband() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.setLeveling(normalizer())
        _ = run(chain, seconds: 15, signal: sine(1000, amplitude(lufs: -12.8)))
        #expect(chain.levelerAdjustmentDB == 0)
    }

    @Test func waitsForEnoughAudioBeforeActing() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.setLeveling(normalizer())
        _ = run(chain, seconds: 2.5, signal: sine(1000, amplitude(lufs: -30)))
        #expect(chain.levelerAdjustmentDB == 0)
    }

    @Test func dynamicMusicGetsOneSteadyTrimNotRiding() {
        // Loud chorus and quiet verse alternating every 2 s, 10 dB apart.
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.setLeveling(normalizer())
        let loud = amplitude(lufs: -6), quiet = amplitude(lufs: -16)
        let signal: (Int) -> Float = { n in
            let section = (n / 96000) % 2 == 0 ? loud : quiet
            return section * Float(sin(2 * .pi * 1000 * Double(n) / 48000))
        }
        _ = run(chain, seconds: 20, signal: signal)
        var readings: [Float] = []
        var offset = Int(rate * 20)
        for _ in 0..<12 {
            let start = offset
            _ = run(chain, seconds: 1) { signal(start + $0) }
            offset += Int(rate)
            readings.append(chain.levelerAdjustmentDB)
        }
        #expect(readings.max()! - readings.min()! < 0.5, "trim moved: \(readings)")
        #expect(readings.last! < -3)
    }

    @Test func silenceHoldsTheTrim() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.setLeveling(normalizer())
        _ = run(chain, seconds: 15, signal: sine(1000, amplitude(lufs: -18)))
        let settled = chain.levelerAdjustmentDB
        _ = run(chain, seconds: 10) { _ in 0 }
        #expect(chain.levelerAdjustmentDB == settled)
    }

    @Test func boostOnlyNeverCuts() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.setLeveling(normalizer(boostOnly: true))
        _ = run(chain, seconds: 15, signal: sine(1000, amplitude(lufs: -4)))
        #expect(chain.levelerAdjustmentDB == 0)
    }

    @Test func turningOffGlidesBackToUnity() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.setLeveling(normalizer())
        _ = run(chain, seconds: 15, signal: sine(1000, amplitude(lufs: -4)))
        chain.setLeveling(nil)
        _ = run(chain, seconds: 3, signal: sine(1000, amplitude(lufs: -4)))
        #expect(chain.levelerAdjustmentDB < -2)  // gliding, not jumping
        _ = run(chain, seconds: 5, signal: sine(1000, amplitude(lufs: -4)))
        #expect(chain.levelerAdjustmentDB == 0)
    }

    @Test func seededTrimIsUsedImmediately() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.seedLeveler(-4)
        chain.setLeveling(normalizer())
        _ = run(chain, seconds: 1, signal: sine(1000, amplitude(lufs: -10)))
        #expect(chain.levelerAdjustmentDB == -4)
    }
}

@Suite("Channel effects")
@MainActor
struct ChannelEffectTests {
    /// Feeds a constant left=0.5, right=0.1 and returns the settled output pair.
    func settle(_ effects: SourceEffects) -> (Float, Float) {
        let chain = ProcessingChain(gain: 0.9, sampleRate: 48000)
        chain.setEffects(effects)
        var input = [Float](repeating: 0, count: 1024)
        var output = [Float](repeating: 0, count: 1024)
        for i in 0..<512 { input[i * 2] = 0.5; input[i * 2 + 1] = 0.1 }
        for _ in 0..<4 {
            input.withUnsafeMutableBufferPointer { inp in
                output.withUnsafeMutableBufferPointer { out in
                    chain.process(inL: inp.baseAddress!, inLStride: 2, inR: inp.baseAddress! + 1, inRStride: 2,
                                  outL: out.baseAddress!, outLStride: 2, outR: out.baseAddress! + 1, outRStride: 2,
                                  mono: false, frames: 512)
                }
            }
        }
        return (output[1022] / 0.9, output[1023] / 0.9)
    }

    @Test func stereoPassesThrough() {
        let (l, r) = settle(.neutral)
        #expect(abs(l - 0.5) < 1e-4 && abs(r - 0.1) < 1e-4)
    }

    @Test func swapExchangesChannels() {
        let (l, r) = settle(SourceEffects(channelMode: .swapped))
        #expect(abs(l - 0.1) < 1e-4 && abs(r - 0.5) < 1e-4)
    }

    @Test func monoSumsChannels() {
        let (l, r) = settle(SourceEffects(channelMode: .mono))
        #expect(abs(l - 0.3) < 1e-4 && abs(r - 0.3) < 1e-4)
    }

    @Test func balanceLowersOnlyTheOppositeSide() {
        let (l, r) = settle(SourceEffects(balance: 0.5))
        #expect(abs(l - 0.25) < 1e-4 && abs(r - 0.1) < 1e-4)
    }
}

@Suite("Apple effects rack")
@MainActor
struct EffectRackTests {
    let rate = 48000.0

    /// Runs a mono signal through a chain and returns the left output.
    func render(_ chain: ProcessingChain, frames total: Int, signal: (Int) -> Float) -> [Float] {
        var out: [Float] = []
        var input = [Float](repeating: 0, count: 1024)
        var output = [Float](repeating: 0, count: 1024)
        var n = 0
        while n < total {
            for i in 0..<512 { let v = signal(n + i); input[i * 2] = v; input[i * 2 + 1] = v }
            input.withUnsafeMutableBufferPointer { inp in
                output.withUnsafeMutableBufferPointer { o in
                    chain.process(inL: inp.baseAddress!, inLStride: 2, inR: inp.baseAddress! + 1, inRStride: 2,
                                  outL: o.baseAddress!, outLStride: 2, outR: o.baseAddress! + 1, outRStride: 2,
                                  mono: false, frames: 512)
                }
            }
            for i in 0..<512 { out.append(output[i * 2]) }
            n += 512
        }
        return out
    }

    func energy(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { $0 + $1 * $1 } }

    @Test func catalogEffectsExistOnThisMac() {
        for entry in AppleEffectCatalog.entries {
            let d = AppleEffectLibrary.describe(entry.kind)
            #expect(d != nil, "\(entry.name) missing")
            for id in entry.keyParameters {
                #expect(d?.parameters.contains { $0.id == id } == true, "\(entry.name) parameter \(id)")
            }
            if let preset = entry.initialPreset {
                #expect(d?.presets.contains { $0.number == preset } == true, "\(entry.name) preset \(preset)")
            }
        }
        #expect(AppleEffectLibrary.describe("rvb2")?.presets.first?.name == "Small Room")
        #expect(AppleEffectLibrary.describe("dist")?.presets.contains { $0.name == "Cellphone Concert" } == true)
    }

    @Test func echoRepeatsAtTheDelayTime() {
        let chain = ProcessingChain(gain: 0.5, sampleRate: rate)
        let echo = RackEffect(kind: "dely", parameters: [0: 50, 1: 0.1, 2: 0, 3: 20000])
        chain.setEffects(SourceEffects(rack: [echo]))
        let impulseAt = 2048
        let out = render(chain, frames: 16384) { $0 == impulseAt ? 1 : 0 }
        let lookahead = Int((GraphicEQ.limiterLookaheadSeconds * rate).rounded()) - 1
        let repeatAt = impulseAt + Int(0.1 * rate) + lookahead
        let window = out[(repeatAt - 64)..<(repeatAt + 64)]
        let quiet = out[(repeatAt - 2000)..<(repeatAt - 1000)]
        #expect(energy(window) > 0.01)
        #expect(energy(quiet) < energy(window) / 100)
    }

    @Test func reverbLeavesATail() {
        let dry = ProcessingChain(gain: 0.5, sampleRate: rate)
        let wet = ProcessingChain(gain: 0.5, sampleRate: rate)
        wet.setEffects(SourceEffects(rack: [.make("rvb2")]))
        let burst: (Int) -> Float = { n in n < 4800 ? 0.3 * Float(sin(Double(n) * 0.2)) : 0 }
        let a = render(dry, frames: 24000, signal: burst)
        let b = render(wet, frames: 24000, signal: burst)
        let tail = 9600..<19200
        #expect(energy(b[tail]) > energy(a[tail]) * 100 + 1e-6)
    }

    @Test func bypassedEffectsPassAudioThrough() {
        let chain = ProcessingChain(gain: 0.5, sampleRate: rate)
        var echo = RackEffect.make("dely")
        echo.isBypassed = true
        let effects = SourceEffects(rack: [echo])
        #expect(effects.isNeutral)
        chain.setEffects(effects)
        let out = render(chain, frames: 8192) { $0 == 1000 ? 1 : 0 }
        let lookahead = Int((GraphicEQ.limiterLookaheadSeconds * rate).rounded()) - 1
        #expect(abs(out[1000 + lookahead] - 0.5) < 1e-4)
        #expect(energy(out[(1000 + lookahead + 10)...]) < 1e-8)
    }

    @Test func unknownEffectsAreSkippedNotFatal() {
        let chain = ProcessingChain(gain: 1, sampleRate: rate)
        chain.setEffects(SourceEffects(rack: [RackEffect(kind: "zzzz"), .make("lpas")]))
        #expect(chain.rackSkipped == ["zzzz"])
        let out = render(chain, frames: 4096) { _ in 0.1 }
        let finite = out.allSatisfy { $0.isFinite }
        #expect(finite)
    }

    @Test func rackSurvivesLargeBuffersAndSampleRateChanges() {
        let chain = ProcessingChain(gain: 0.5, sampleRate: 44100)
        chain.setEffects(SourceEffects(rack: [.make("rvb2"), .make("dely")]))
        chain.setSampleRate(rate)
        var input = [Float](repeating: 0.1, count: 10000 * 2)
        var output = [Float](repeating: 0, count: 10000 * 2)
        input.withUnsafeMutableBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { o in
                chain.process(inL: inp.baseAddress!, inLStride: 2, inR: inp.baseAddress! + 1, inRStride: 2,
                              outL: o.baseAddress!, outLStride: 2, outR: o.baseAddress! + 1, outRStride: 2,
                              mono: false, frames: 10000)
            }
        }
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }
}
