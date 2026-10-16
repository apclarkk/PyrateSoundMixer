import Foundation
import Testing
@testable import PyrateCore

@Suite("Equalizer")
struct EqualizerTests {
    @Test func builtInsAreWellFormed() {
        let ids = EQPreset.builtIns.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(EQPreset.builtIns.allSatisfy { $0.gains.count == GraphicEQ.bandCount && $0.isBuiltIn })
        #expect(EQPreset.builtIns.allSatisfy { $0.gains.allSatisfy(GraphicEQ.gainRange.contains) })
        #expect(EQPreset.builtIns.first == .flat)
    }

    @Test func flatIsInactiveAndIdentity() {
        #expect(!SourceEQ.off.isActive)
        let design = EQDesign(.off, sampleRate: 48000)
        #expect(design == .bypass)
        #expect(Biquad.peaking(frequency: 1000, gainDB: 0, q: 1.41, sampleRate: 48000) == .identity)
    }

    @Test func peakingHitsTargetAtCenter() {
        for gain in [-12.0, -6, 3, 12] {
            let q = Biquad.peaking(frequency: 1000, gainDB: gain, q: GraphicEQ.q, sampleRate: 48000)
            #expect(abs(q.magnitudeDB(at: 1000, sampleRate: 48000) - gain) < 0.01)
            #expect(abs(q.magnitudeDB(at: 20, sampleRate: 48000)) < 0.5)
        }
    }

    @Test func bandsAboveNyquistAreSkipped() {
        #expect(Biquad.peaking(frequency: 16000, gainDB: 6, q: 1.41, sampleRate: 22050) == .identity)
    }

    @Test func loudnessMatchingCompensatesBoostsAndCuts() {
        func makeup(_ id: String) -> Double {
            var eq = SourceEQ()
            eq.apply(EQPreset.builtIns.first { $0.id == id }!)
            return 20 * log10(EQDesign(eq, sampleRate: 48000).preGain)
        }
        // Boosts are pulled down, but by less than the 6 dB peak: only the
        // perceived loudness change is cancelled, not the whole boost.
        let bass = makeup("builtin.bass-boost")
        #expect(bass < -0.3 && bass > -6)
        // Cuts are brought back up instead of leaving the app quieter.
        #expect(makeup("builtin.bass-reducer") > 0.3)
        #expect(makeup("builtin.treble-reducer") > 0.3)
        // Boosting every band is fully cancelled. Overlapping bands sum to a bit
        // more than the nominal 6 dB, so the compensation is a bit larger too.
        let all6 = EQDesign(SourceEQ(gains: Array(repeating: 6, count: 10)), sampleRate: 48000)
        let all6Makeup = 20 * log10(all6.preGain)
        let measured = EQDesign.response(all6.biquads, sampleRate: 48000, points: 64).filter { (200...6000).contains($0.frequency) }.map(\.db)
        #expect(abs(all6Makeup + measured.reduce(0, +) / Double(measured.count)) < 0.5)
    }

    @Test func matchLoudnessOffMeansNoMakeup() {
        var eq = SourceEQ(matchLoudness: false)
        eq.apply(EQPreset.builtIns[1])
        #expect(EQDesign(eq, sampleRate: 48000).preGain == 1)
    }

    @Test func rnbMatchesSoundSourceValues() {
        let rnb = EQPreset.builtIns.first { $0.name == "R&B" }!
        #expect(rnb.gains == [2.62, 6.92, 5.65, 1.33, -2.19, -1.5, 2.32, 2.65, 3.0, 3.75])
    }

    @Test func bypassKeepsSettings() {
        var eq = SourceEQ()
        eq.apply(EQPreset.builtIns[1])
        eq.isBypassed = true
        #expect(!eq.isActive)
        #expect(!eq.isFlat)
        eq.isBypassed = false
        #expect(eq.gains == EQPreset.builtIns[1].gains)
    }

    @Test func editingMarksModifiedAndClamps() {
        var eq = SourceEQ()
        let preset = EQPreset.builtIns[1]
        eq.apply(preset)
        #expect(!eq.isModified(from: preset))
        eq.setGain(40, band: 9)
        #expect(eq.gains[9] == 12)
        #expect(eq.isModified(from: preset))
        eq.setGain(1, band: 99)  // out of range band is ignored
    }

    @Test func customPresetLifecycle() {
        var prefs = Preferences()
        let app = SourceID("com.apple.Music")
        let a = prefs.addCustomPreset(named: "Headphones", gains: [1, 2, 3])
        let b = prefs.addCustomPreset(named: "headphones", gains: [])
        #expect(a.gains.count == GraphicEQ.bandCount)
        #expect(b.name == "headphones 2")
        #expect(prefs.addCustomPreset(named: "Bass Boost", gains: []).name == "Bass Boost 2")

        var eq = SourceEQ()
        eq.apply(a)
        prefs.setEQ(eq, for: app, name: "Music")
        prefs.renameCustomPreset(id: a.id, to: "  Studio  ")
        #expect(prefs.eqPreset(id: a.id)?.name == "Studio")

        prefs.deleteCustomPreset(id: a.id)
        #expect(prefs.eqPreset(id: a.id) == nil)
        #expect(prefs.eq(for: app).presetID == nil)
        #expect(prefs.eq(for: app).gains == a.gains)
    }

    @Test func eqIsPerSourceAndPersists() throws {
        var prefs = Preferences()
        var eq = SourceEQ()
        eq.apply(EQPreset.builtIns[3])
        prefs.setEQ(eq, for: SourceID("a"), name: nil)
        #expect(prefs.eq(for: SourceID("b")) == .off)

        let data = try JSONEncoder().encode(prefs)
        let loaded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(loaded.eq(for: SourceID("a")) == eq)
    }

    @Test func oldPreferencesWithoutEQStillLoad() throws {
        let json = #"{"apps":{"x":{"volume":{"level":0.5,"isMuted":false}}}}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(prefs.eq(for: SourceID("x")) == .off)
        #expect(prefs.customEQPresets.isEmpty)
    }
}

@Suite("Leveling")
struct LevelingTests {
    @Test func kWeightingShape() {
        let k = LevelerTuning.kWeighting(sampleRate: 48000)
        func response(_ f: Double) -> Double { k.reduce(0) { $0 + $1.magnitudeDB(at: f, sampleRate: 48000) } }
        #expect(abs(response(1000)) < 0.8)
        #expect(abs(response(10000) - 4) < 0.6)
        #expect(response(20) < -10)
    }

    func ms(_ lufs: Double) -> Double { pow(10, (lufs - LevelerTuning.loudnessOffset) / 10) }

    @Test func integratedLoudnessGatesSilenceAndQuietPassages() {
        let program = Array(repeating: ms(-14), count: 100)
        #expect(abs(LevelerTuning.integratedLoudness(program)! + 14) < 0.01)
        // Silence and a much quieter passage do not drag the measurement down.
        let withGaps = program + Array(repeating: 0, count: 100) + Array(repeating: ms(-40), count: 100)
        #expect(abs(LevelerTuning.integratedLoudness(withGaps)! + 14) < 0.01)
        #expect(LevelerTuning.integratedLoudness([0, 0, ms(-80)]) == nil)
    }

    @Test func desiredTrimIsCappedAndCanBeBoostOnly() {
        #expect(LevelerTuning.desiredTrim(loudness: -30, target: -14, boostOnly: false) == 6)
        #expect(LevelerTuning.desiredTrim(loudness: -4, target: -14, boostOnly: false) == -6)
        #expect(LevelerTuning.desiredTrim(loudness: -10, target: -14, boostOnly: false) == -4)
        #expect(LevelerTuning.desiredTrim(loudness: -4, target: -14, boostOnly: true) == 0)
    }

    @Test func oldTargetsStillDecode() throws {
        let s = try JSONDecoder().decode(LevelingSettings.self, from: Data(#"{"isEnabled":true,"target":"quieter"}"#.utf8))
        #expect(s.target.lufs == -18)
        #expect(!s.boostOnly)
    }

    @Test func settingsPersistAndExclusionWorks() throws {
        var prefs = Preferences()
        let app = SourceID("com.apple.Music")
        #expect(!prefs.isLeveled(app))
        prefs.leveling = LevelingSettings(isEnabled: true, target: .louder)
        #expect(prefs.isLeveled(app))
        prefs.setExcludedFromLeveling(true, for: app, name: "Music")
        #expect(!prefs.isLeveled(app))
        let loaded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(loaded.leveling.target == .louder)
        #expect(!loaded.isLeveled(app))
        prefs.setExcludedFromLeveling(false, for: app, name: nil)
        #expect(prefs.isLeveled(app))
    }
}
