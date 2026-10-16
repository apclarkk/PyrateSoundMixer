import Foundation
import Testing
@testable import PyrateCore

@Suite("Configuration import and export")
struct ConfigurationTests {
    let airpods = RememberedDevice(id: DeviceID(uid: "airpods"), lastKnownName: "AirPods")
    let speakers = RememberedDevice(id: DeviceID(uid: "speakers"), lastKnownName: "Speakers")

    func sample() -> Preferences {
        var p = Preferences()
        p.preferredOutput = airpods
        p.setRoute(airpods, for: SourceID("music"), name: "Music")
        p.profiles = [Profile(name: "Commute", aspects: [.outputDevice], output: airpods)]
        p.rules = [Rule(name: "Duck", trigger: .outputIs(airpods.id), actions: [.selectOutput(airpods.id)])]
        p.addCustomPreset(named: "Mine", gains: [3])
        return p
    }

    @Test func roundTrips() throws {
        let bundle = ConfigurationBundle(preferences: sample(), appVersion: "0.1.0", exportedAt: Date(timeIntervalSince1970: 1_000_000))
        let decoded = try ConfigurationBundle.decode(bundle.encoded())
        #expect(decoded == bundle)
    }

    @Test func refusesForeignNewerAndDamagedFiles() throws {
        #expect(throws: ImportError.notAConfiguration) { try ConfigurationBundle.decode(Data("{}".utf8)) }
        #expect(throws: ImportError.notAConfiguration) { try ConfigurationBundle.decode(Data("not json".utf8)) }
        let newer = #"{"format":"org.pyratesounds.configuration","version":99}"#
        #expect(throws: ImportError.newerVersion(99)) { try ConfigurationBundle.decode(Data(newer.utf8)) }
        let damaged = #"{"format":"org.pyratesounds.configuration","version":1,"preferences":7}"#
        #expect(throws: ImportError.damaged) { try ConfigurationBundle.decode(Data(damaged.utf8)) }
    }

    @Test func reportListsMissingDevicesOnce() {
        let report = ImportReport.make(for: sample(), availableDevices: [speakers.id])
        #expect(report.missingDevices.map(\.id) == [airpods.id])
        #expect(report.missingDevices.first?.lastKnownName == "AirPods")
        #expect(report.profileCount == 1 && report.ruleCount == 1 && report.presetCount == 1)
        #expect(ImportReport.make(for: sample(), availableDevices: [airpods.id]).missingDevices.isEmpty)
    }

    @Test func remapReplacesEveryReferenceButOnlyWhenAsked() {
        let p = sample()
        #expect(p.remappingDevices([:]) == p)
        let mapped = p.remappingDevices([airpods.id: speakers])
        #expect(mapped.preferredOutput == speakers)
        #expect(mapped.route(for: SourceID("music"))?.id == speakers.id)
        #expect(mapped.profiles[0].output?.id == speakers.id)
        #expect(mapped.rules[0].trigger == .outputIs(speakers.id))
        #expect(mapped.rules[0].actions == [.selectOutput(speakers.id)])
        #expect(!mapped.referencedDevices().contains { $0.id == airpods.id })
    }

    @Test func mergeAddsWithoutReplacing() {
        var mine = Preferences()
        mine.profiles = [Profile(id: "same", name: "Mine", aspects: [])]
        var theirs = sample()
        theirs.profiles.append(Profile(id: "same", name: "Theirs", aspects: []))
        let merged = mine.merging(theirs)
        #expect(merged.profiles.count == 2)
        #expect(merged.profiles.first { $0.id == "same" }?.name == "Mine")
        #expect(merged.rules.count == 1 && merged.customEQPresets.count == 1)
        #expect(merged.preferredOutput == nil)  // merge never changes device choices
    }

    @Test func profileBundleCarriesOnlyItsPresets() throws {
        var prefs = Preferences()
        let used = prefs.addCustomPreset(named: "Used", gains: [1])
        _ = prefs.addCustomPreset(named: "Unused", gains: [2])
        var eq = SourceEQ(); eq.apply(used)
        let profile = Profile(name: "P", aspects: [.appEQ], apps: [SourceID("a"): ProfileAppSetting(eq: eq)])
        let bundle = ProfileBundle.make(profile, from: prefs)
        #expect(bundle.presets.map(\.name) == ["Used"])
        #expect(try ProfileBundle.decode(bundle.encoded()) == bundle)
        #expect(throws: ImportError.notAConfiguration) { try ProfileBundle.decode(ConfigurationBundle(preferences: prefs, appVersion: "x").encoded()) }
    }
}

@Suite("URL commands")
struct CommandTests {
    func parse(_ s: String) -> PyrateCommand? { PyrateCommand.parse(URL(string: s)!) }

    @Test func parsesEveryCommand() {
        #expect(parse("pyratesounds://profile/Meetings") == .activateProfile(name: "Meetings"))
        #expect(parse("pyratesounds://volume/Music?level=40") == .setVolume(app: "Music", percent: 40))
        #expect(parse("pyratesounds://volume/Music?level=400") == .setVolume(app: "Music", percent: 100))
        #expect(parse("pyratesounds://volume/Music?change=-10") == .adjustVolume(app: "Music", deltaPercent: -10))
        #expect(parse("pyratesounds://mute/Google%20Chrome") == .mute(app: "Google Chrome"))
        #expect(parse("pyratesounds://unmute/Music") == .unmute(app: "Music"))
        #expect(parse("pyratesounds://toggle-mute/Music") == .toggleMute(app: "Music"))
        #expect(parse("pyratesounds://output?level=60") == .setOutputVolume(percent: 60))
        #expect(parse("pyratesounds://output/mute") == .toggleOutputMute)
        #expect(parse("pyratesounds://output/select/AirPods%20Pro") == .selectOutput(name: "AirPods Pro"))
        #expect(parse("pyratesounds://eq/Music?preset=R%26B") == .applyPreset(app: "Music", preset: "R&B"))
        #expect(parse("pyratesounds://undo-profile") == .undoProfile)
    }

    @Test func rejectsMalformedCommands() {
        #expect(parse("https://volume/Music?level=40") == nil)
        #expect(parse("pyratesounds://volume/Music") == nil)
        #expect(parse("pyratesounds://profile") == nil)
        #expect(parse("pyratesounds://eq/Music") == nil)
        #expect(parse("pyratesounds://explode") == nil)
    }
}
