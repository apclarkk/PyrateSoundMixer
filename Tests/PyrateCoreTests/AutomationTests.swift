import Foundation
import Testing
@testable import PyrateCore

@Suite("RuleEngine")
struct RuleEngineTests {
    let music = SourceID("com.apple.Music")
    let zoom = SourceID("us.zoom.xos")
    let browser = SourceID("company.thebrowser.Browser")
    let headphones = DeviceID(uid: "headphones")

    /// A tiny world: settings live in a dictionary and effects are applied to it.
    struct World {
        var values: [RuleEngine.Setting: RuleEngine.Value] = [:]
        var engine = RuleEngine()
        var log: [RuleEngine.Effect] = []

        mutating func run(_ rules: [Rule], _ facts: RuleEngine.Facts) {
            let snapshot = values
            let effects = engine.evaluate(
                rules: rules, facts: facts,
                current: { snapshot[$0] ?? .volume(.unity) },
                resolve: { action, current in
                    guard case .volume(var v) = current else { return nil }
                    switch action {
                    case .setVolume(_, let level): v.setLevel(level); v.isMuted = false; return .volume(v)
                    case .mute: v.isMuted = true; return .volume(v)
                    default: return nil
                    }
                })
            for effect in effects {
                if case .set(let setting, let value, _) = effect { values[setting] = value }
            }
            log += effects
        }

        func level(_ id: SourceID) -> Double? {
            if case .volume(let v)? = values[.volume(id)] { return v.isMuted ? -1 : v.level }
            return nil
        }
    }

    func duck(_ name: String, while trigger: RuleTrigger, to level: Double, revert: Bool = true) -> Rule {
        Rule(id: name, name: name, trigger: trigger, actions: [.setVolume(music, level: level)], revertWhenEnds: revert)
    }

    @Test func ducksAndRestores() {
        var w = World()
        w.values[.volume(music)] = .volume(VolumeState(level: 0.45))
        let rules = [duck("meeting", while: .appUsingMicrophone(zoom), to: 0.25)]
        w.run(rules, .init(usingMicrophone: [zoom]))
        #expect(w.level(music) == 0.25)
        w.run(rules, .init())
        #expect(w.level(music) == 0.45)
    }

    @Test func higherPriorityWinsAndHandsOver() {
        var w = World()
        w.values[.volume(music)] = .volume(VolumeState(level: 0.45))
        let rules = [
            duck("meeting", while: .appUsingMicrophone(zoom), to: 0.20),
            duck("headphones", while: .deviceConnected(headphones), to: 0.50),
        ]
        w.run(rules, .init(usingMicrophone: [zoom], connected: [headphones]))
        #expect(w.level(music) == 0.20)
        w.run(rules, .init(connected: [headphones]))
        #expect(w.level(music) == 0.50)
        w.run(rules, .init())
        #expect(w.level(music) == 0.45)
    }

    @Test func lowerPriorityStartingLaterDoesNotOverride() {
        var w = World()
        w.values[.volume(music)] = .volume(VolumeState(level: 0.45))
        let rules = [
            duck("meeting", while: .appUsingMicrophone(zoom), to: 0.20),
            duck("headphones", while: .deviceConnected(headphones), to: 0.50),
        ]
        w.run(rules, .init(usingMicrophone: [zoom]))
        w.run(rules, .init(usingMicrophone: [zoom], connected: [headphones]))
        #expect(w.level(music) == 0.20)
        // Restoring after both end returns to the value from before any rule.
        w.run(rules, .init())
        #expect(w.level(music) == 0.45)
    }

    @Test func manualChangeWinsUntilNextActivation() {
        var w = World()
        w.values[.volume(music)] = .volume(VolumeState(level: 0.45))
        let rules = [duck("meeting", while: .appUsingMicrophone(zoom), to: 0.25)]
        w.run(rules, .init(usingMicrophone: [zoom]))
        // User drags Music to 60% during the meeting.
        w.values[.volume(music)] = .volume(VolumeState(level: 0.60))
        w.engine.userChanged(.volume(music))
        #expect(w.engine.owner(of: .volume(music), rules: rules) == nil)
        w.run(rules, .init())
        #expect(w.level(music) == 0.60)  // not reverted over the user's choice
        // Next meeting ducks again and later restores the user's 60%.
        w.run(rules, .init(usingMicrophone: [zoom]))
        #expect(w.level(music) == 0.25)
        w.run(rules, .init())
        #expect(w.level(music) == 0.60)
    }

    @Test func oneShotRulesDoNotRevert() {
        var w = World()
        w.values[.volume(music)] = .volume(VolumeState(level: 0.45))
        let rules = [duck("set", while: .appPlaying(browser), to: 0.3, revert: false)]
        w.run(rules, .init(playing: [browser]))
        #expect(w.level(music) == 0.3)
        w.run(rules, .init())
        #expect(w.level(music) == 0.3)
    }

    @Test func profileAndOutputActionsFireOnceOnStart() {
        var w = World()
        let rules = [Rule(id: "r", name: "r", trigger: .deviceConnected(headphones),
                          actions: [.activateProfile("p"), .selectOutput(headphones)])]
        w.run(rules, .init(connected: [headphones]))
        w.run(rules, .init(connected: [headphones]))
        let fired = w.log.filter {
            if case .activateProfile = $0 { return true }
            if case .selectOutput = $0 { return true }
            return false
        }
        #expect(fired.count == 2)
    }

    @Test func unchangedFactsProduceNoEffects() {
        var w = World()
        w.values[.volume(music)] = .volume(VolumeState(level: 0.45))
        let rules = [duck("meeting", while: .appUsingMicrophone(zoom), to: 0.25)]
        w.run(rules, .init(usingMicrophone: [zoom]))
        let before = w.log.count
        w.run(rules, .init(usingMicrophone: [zoom]))
        #expect(w.log.count == before)
    }

    @Test func disabledRulesNeverFire() {
        var w = World()
        var rule = duck("meeting", while: .appUsingMicrophone(zoom), to: 0.25)
        rule.isEnabled = false
        w.run([rule], .init(usingMicrophone: [zoom]))
        #expect(w.level(music) == nil)
    }

    @Test func muteAndVolumeInOneRuleCombine() {
        var w = World()
        w.values[.volume(music)] = .volume(VolumeState(level: 0.45))
        let rule = Rule(id: "r", name: "r", trigger: .appPlaying(browser), actions: [.setVolume(music, level: 0.3), .mute(music)])
        w.run([rule], .init(playing: [browser]))
        guard case .volume(let v)? = w.values[.volume(music)] else { Issue.record("no value"); return }
        #expect(v.isMuted && v.level == 0.3)
        w.run([rule], .init())
        #expect(w.level(music) == 0.45)
    }
}

@Suite("Profiles and history")
struct ProfileHistoryTests {
    @Test func summaryDescribesWhatChanges() {
        let p = Profile(name: "Focus", aspects: [.appVolumes, .outputDevice],
                        apps: [SourceID("a"): ProfileAppSetting(volume: VolumeState(level: 0.2))],
                        output: RememberedDevice(id: DeviceID(uid: "x"), lastKnownName: "Speakers"))
        #expect(p.summary == "1 app volume, output Speakers")
        #expect(Profile(name: "Empty", aspects: []).summary == "Changes nothing yet")
    }

    @Test func profilesAndRulesPersist() throws {
        var prefs = Preferences()
        prefs.profiles = [Profile(name: "Night", aspects: [.appEQ], apps: [SourceID("a"): ProfileAppSetting(eq: SourceEQ(gains: [1]))])]
        prefs.rules = [Rule(name: "Duck", trigger: .appUsingMicrophone(SourceID("z")), actions: [.setVolume(SourceID("a"), level: 0.2)])]
        let loaded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(loaded.profiles == prefs.profiles)
        #expect(loaded.rules == prefs.rules)
    }

    @Test func activityLogKeepsRecentBoundedHistory() {
        var log = ActivityLog()
        let now = Date()
        log.record(ActivityEntry(date: now.addingTimeInterval(-8 * 24 * 3600), kind: .user, message: "old"))
        log.record(ActivityEntry(date: now, kind: .user, message: "new"))
        #expect(log.entries.map(\.message) == ["new"])
        for i in 0..<(ActivityLog.maxEntries + 10) { log.record(ActivityEntry(date: now, kind: .rule, message: "\(i)")) }
        #expect(log.entries.count == ActivityLog.maxEntries)
        #expect(log.entries.last?.message == "\(ActivityLog.maxEntries + 9)")
    }
}

@Suite("Profile effects and routes")
struct ProfileEffectsRoutesTests {
    let airpods = RememberedDevice(id: DeviceID(uid: "airpods"), lastKnownName: "AirPods")
    let speakers = RememberedDevice(id: DeviceID(uid: "speakers"), lastKnownName: "Speakers")

    @Test func summaryCountsEffectsAndRoutes() {
        let p = Profile(name: "Night", aspects: [.appEffects, .appRoutes], apps: [
            SourceID("a"): ProfileAppSetting(effects: SourceEffects(rack: [.make("rvb2")]), route: .device(airpods)),
            SourceID("b"): ProfileAppSetting(effects: .neutral, route: .system),
        ])
        #expect(p.summary == "effects on 1 app, 1 app route")
    }

    @Test func profileRoutesRoundTripAndRemap() throws {
        var prefs = Preferences()
        prefs.profiles = [Profile(name: "Commute", aspects: [.appRoutes],
                                  apps: [SourceID("music"): ProfileAppSetting(route: .device(airpods))])]
        let loaded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(loaded.profiles == prefs.profiles)
        #expect(prefs.referencedDevices().contains { $0.id == airpods.id })
        let mapped = prefs.remappingDevices([airpods.id: speakers])
        #expect(mapped.profiles[0].apps[SourceID("music")]?.route == .device(speakers))
    }

    @Test func oldProfilesWithoutNewAspectsStillLoad() throws {
        let json = #"{"profiles":[{"id":"p","name":"Old","aspects":["appVolumes"],"apps":{"x":{"volume":{"level":0.4,"isMuted":false}}}}]}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(prefs.profiles.first?.apps[SourceID("x")]?.effects == nil)
        #expect(prefs.profiles.first?.apps[SourceID("x")]?.volume?.level == 0.4)
    }
}
