import Foundation
import Testing
@testable import PyrateCore

@Suite("Effects and routing")
struct EffectsTests {
    @Test func balanceIsLevelNeutralAndNeverBoosts() {
        #expect(SourceEffects().channelGains == (1, 1))
        let left = SourceEffects(balance: -0.4).channelGains
        #expect(left.left == 1 && abs(left.right - 0.6) < 1e-9)
        let right = SourceEffects(balance: 1).channelGains
        #expect(right.left == 0 && right.right == 1)
        #expect(SourceEffects(balance: 5).balance == 1)
        #expect(SourceEffects(balance: .nan).balance == 0)
    }

    @Test func summaryAndNeutrality() {
        #expect(SourceEffects().isNeutral)
        #expect(SourceEffects().summary == nil)
        #expect(SourceEffects(balance: -0.25, channelMode: .mono).summary == "Mono, balance 25% L")
    }

    @Test func routeResolution() {
        let airpods = RememberedDevice(id: DeviceID(uid: "airpods"), lastKnownName: "AirPods")
        let speakers = DeviceID(uid: "speakers")
        #expect(RouteResolution.resolve(route: nil, systemOutput: speakers, available: [speakers]) == .system)
        #expect(RouteResolution.resolve(route: airpods, systemOutput: speakers, available: [speakers, airpods.id]) == .routed(airpods.id))
        #expect(RouteResolution.resolve(route: airpods, systemOutput: speakers, available: [speakers]) == .fallback(missing: airpods))
        // Routed to the device that is already the system output: no tap needed.
        #expect(RouteResolution.resolve(route: airpods, systemOutput: airpods.id, available: [airpods.id]) == .system)
        #expect(RouteResolution.routed(airpods.id).needsTap)
        #expect(!RouteResolution.fallback(missing: airpods).needsTap)
    }

    @Test func rackModelAndCatalog() throws {
        let reverb = RackEffect.make("rvb2")
        #expect(reverb.presetNumber == 1 && reverb.parameters[0] == 25)
        var effects = SourceEffects(rack: [reverb, .make("dely")])
        #expect(!effects.isNeutral)
        #expect(effects.summary == "Reverb, Echo")
        effects.rack[0].isBypassed = true
        effects.rack[1].isBypassed = true
        #expect(effects.isNeutral)
        #expect(SourceEffects(rack: Array(repeating: .make("lpas"), count: 9)).rack.count == SourceEffects.maxRackSize)
        // Parameter edits don't change the structure; presets do.
        var edited = reverb
        edited.parameters[0] = 80
        #expect(edited.structureKey == reverb.structureKey)
        edited.presetNumber = 4
        #expect(edited.structureKey != reverb.structureKey)
        let loaded = try JSONDecoder().decode(SourceEffects.self, from: JSONEncoder().encode(effects))
        #expect(loaded == effects)
        #expect(AppleEffectCatalog.fourCC("rvb2") == 0x7276_6232)
    }

    @Test func effectsAndRoutesPersist() throws {
        var prefs = Preferences()
        let app = SourceID("a")
        prefs.setEffects(SourceEffects(balance: 0.3, channelMode: .swapped), for: app, name: nil)
        prefs.setRoute(RememberedDevice(id: DeviceID(uid: "x"), lastKnownName: "X"), for: app, name: nil)
        let loaded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        #expect(loaded.effects(for: app) == SourceEffects(balance: 0.3, channelMode: .swapped))
        #expect(loaded.route(for: app)?.id == DeviceID(uid: "x"))
        prefs.setEffects(.neutral, for: app, name: nil)
        #expect(prefs.apps[app]?.effects == nil)
    }
}
