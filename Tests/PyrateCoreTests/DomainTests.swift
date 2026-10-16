import Foundation
import Testing
@testable import PyrateCore

@Suite("VolumeState")
struct VolumeStateTests {
    @Test func muteKeepsLevel() {
        var v = VolumeState(level: 0.55)
        v.toggleMute()
        #expect(v.isMuted)
        #expect(v.level == 0.55)
        #expect(v.gain == 0)
        v.toggleMute()
        #expect(!v.isMuted)
        #expect(v.level == 0.55)
    }

    @Test func raisingLevelWhileMutedUnmutes() {
        var v = VolumeState(level: 0.4, isMuted: true)
        v.setLevel(0.6)
        #expect(!v.isMuted)
    }

    @Test func settingZeroWhileMutedStaysMuted() {
        var v = VolumeState(level: 0.4, isMuted: true)
        v.setLevel(0)
        #expect(v.isMuted)
    }

    @Test func clampsAndRejectsNonFinite() {
        #expect(VolumeState(level: 2).level == 1)
        #expect(VolumeState(level: -1).level == 0)
        #expect(VolumeState(level: .nan).level == 1)
    }

    @Test func unityAndTaper() {
        #expect(VolumeState.unity.isUnity)
        #expect(!VolumeState(level: 0.99).isUnity)
        #expect(!VolumeState(level: 1, isMuted: true).isUnity)
        #expect(abs(VolumeState(level: 0.5).gain - 0.25) < 0.0001)
    }
}

@Suite("TrackedValue")
struct TrackedValueTests {
    @Test func requestThenConfirm() {
        var t = TrackedValue(confirmed: "speakers")
        t.request("headphones")
        #expect(t.displayed == "headphones")
        #expect(t.isPending)
        t.confirm("headphones")
        #expect(!t.isPending)
        #expect(t.displayed == "headphones")
    }

    @Test func unrelatedConfirmKeepsRequest() {
        var t = TrackedValue(confirmed: "speakers")
        t.request("headphones")
        t.confirm("display")
        #expect(t.isPending)
        #expect(t.confirmed == "display")
        #expect(t.displayed == "headphones")
    }

    @Test func failureRevertsToConfirmed() {
        var t = TrackedValue(confirmed: "speakers")
        t.request("headphones")
        t.fail("Couldn't switch")
        #expect(t.displayed == "speakers")
        #expect(t.failure == "Couldn't switch")
    }

    @Test func expiry() {
        var t = TrackedValue(confirmed: 1)
        let start = Date(timeIntervalSince1970: 0)
        t.request(2, at: start)
        let early = t.expire(now: start.addingTimeInterval(1), timeout: 5, message: "slow")
        #expect(!early)
        let late = t.expire(now: start.addingTimeInterval(6), timeout: 5, message: "slow")
        #expect(late)
        #expect(t.displayed == 1)
    }

    @Test func requestingConfirmedValueIsNoOp() {
        var t = TrackedValue(confirmed: 3)
        t.request(3)
        #expect(!t.isPending)
    }
}

@Suite("SourceIdentityResolver")
struct ResolverTests {
    let resolver = SourceIdentityResolver(bundleIdentifierAtPath: { path in
        [
            "/Applications/Google Chrome.app": "com.google.Chrome",
            "/Applications/Music.app": "com.apple.Music",
        ][path]
    }, isBackgroundOnlyApp: { _ in false })

    @Test func helperAttributedToOutermostApp() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let r = resolver.resolve(ProcessFacts(pid: 10, bundleID: "com.google.Chrome.helper", executablePath: path))
        #expect(r.id == .bundle("com.google.Chrome"))
        #expect(r.appBundlePath == "/Applications/Google Chrome.app")
        #expect(!r.isShared)
    }

    @Test func webKitIsShared() {
        let r = resolver.resolve(ProcessFacts(
            pid: 11, bundleID: "com.apple.WebKit.GPU",
            executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU"))
        #expect(r.id == .sharedWebKit)
        #expect(r.isShared)
    }

    @Test func routingEnginesAreInfrastructure() {
        let r = resolver.resolve(ProcessFacts(pid: 5, bundleID: "com.rogueamoeba.arkaudiod", executablePath: "/Library/Application Support/x/arkaudiod"))
        #expect(r.hiddenReason == .infrastructure)
    }

    @Test func systemComponentsAndUtilitiesAreHidden() {
        let hidden = [
            "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            "/System/Library/CoreServices/PowerChime.app/Contents/MacOS/PowerChime",
            "/System/Library/CoreServices/Siri.app/Contents/XPCServices/SiriNCService.xpc/Contents/MacOS/SiriNCService",
            "/usr/sbin/systemsoundserverd",
            "/usr/libexec/avconferenced",
            "/usr/bin/afplay",
            "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            "/Applications/Utilities/LogiPluginService.app/Contents/MacOS/LogiPluginService",
            "/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent",
        ]
        for path in hidden {
            #expect(resolver.resolve(ProcessFacts(pid: 1, bundleID: nil, executablePath: path)).hiddenReason == .system, "\(path)")
        }
        let visible = [
            "/Applications/Arc.app/Contents/Frameworks/ArcCore.framework/Helpers/Browser Helper.app/Contents/MacOS/Browser Helper",
            "/System/Applications/Music.app/Contents/MacOS/Music",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
            "/Users/x/Downloads/Player.app/Contents/MacOS/Player",
        ]
        for path in visible {
            #expect(!resolver.resolve(ProcessFacts(pid: 1, bundleID: "x", executablePath: path)).isHidden, "\(path)")
        }
        // The shared WebKit process lives in /System/Library but plays Safari's audio.
        #expect(!resolver.resolve(ProcessFacts(
            pid: 1, bundleID: "com.apple.WebKit.GPU",
            executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU")).isHidden)
    }

    @Test func backgroundOnlyAppsAreHidden() {
        let r = SourceIdentityResolver(bundleIdentifierAtPath: { _ in nil }, isBackgroundOnlyApp: { $0.hasSuffix("Agent.app") })
        #expect(r.resolve(ProcessFacts(pid: 1, bundleID: "a", executablePath: "/Applications/Agent.app/Contents/MacOS/a")).isHidden)
        #expect(!r.resolve(ProcessFacts(pid: 1, bundleID: "a", executablePath: "/Applications/Player.app/Contents/MacOS/a")).isHidden)
    }

    @Test func fallsBackToBundleIDThenPath() {
        #expect(resolver.resolve(ProcessFacts(pid: 1, bundleID: "com.example.cli", executablePath: "/usr/local/bin/x")).id == .bundle("com.example.cli"))
        #expect(resolver.resolve(ProcessFacts(pid: 1, bundleID: "", executablePath: "/usr/local/bin/x")).id == .path("/usr/local/bin/x"))
        #expect(resolver.resolve(ProcessFacts(pid: 7, bundleID: nil, executablePath: nil)).id == SourceID("pid:7"))
    }

    @Test func unknownAppBundleUsesProcessBundleID() {
        let r = resolver.resolve(ProcessFacts(pid: 2, bundleID: "com.example.app", executablePath: "/Users/x/Apps/Example.app/Contents/MacOS/Example"))
        #expect(r.id == .bundle("com.example.app"))
        #expect(r.appBundlePath == "/Users/x/Apps/Example.app")
    }
}

@Suite("SourceListStabilizer")
struct StabilizerTests {
    let a = SourceID("a"), b = SourceID("b"), c = SourceID("c")
    let t0 = Date(timeIntervalSince1970: 0)

    @Test func newRowsAppendInStableOrder() {
        var s = SourceListStabilizer()
        s.update(discovered: [b, a], now: t0)
        s.update(discovered: [c, a, b], now: t0)
        #expect(s.rows().map(\.id) == [b, a, c])
    }

    @Test func vanishedRowLingersThroughGracePeriod() {
        var s = SourceListStabilizer(gracePeriod: 4)
        s.update(discovered: [a, b], now: t0)
        s.update(discovered: [b], now: t0.addingTimeInterval(1))
        #expect(s.rows().map(\.id) == [a, b])
        #expect(!s.isPresent(a))
        s.update(discovered: [a, b], now: t0.addingTimeInterval(2))
        #expect(s.isPresent(a))
        s.update(discovered: [b], now: t0.addingTimeInterval(3))
        s.prune(now: t0.addingTimeInterval(8))
        #expect(s.rows().map(\.id) == [b])
    }

    @Test func interactingRowIsNeverRemoved() {
        var s = SourceListStabilizer(gracePeriod: 1)
        s.update(discovered: [a], now: t0)
        s.interacting = a
        s.update(discovered: [], now: t0)
        s.prune(now: t0.addingTimeInterval(10))
        #expect(s.rows().map(\.id) == [a])
        s.interacting = nil
        s.prune(now: t0.addingTimeInterval(11))
        #expect(s.rows().isEmpty)
    }

    @Test func pinnedComeFirst() {
        #expect(SourceOrdering.arrange(visible: [a, b, c], pinned: [c], includeIdlePinned: true) == [c, a, b])
        let idle = SourceID("idle")
        #expect(SourceOrdering.arrange(visible: [a], pinned: [idle], includeIdlePinned: true) == [idle, a])
        #expect(SourceOrdering.arrange(visible: [a], pinned: [idle], includeIdlePinned: false) == [a])
    }
}

@Suite("Preferences")
struct PreferencesTests {
    @Test func roundTripsThroughStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PreferencesStore(fileURL: dir.appendingPathComponent("preferences.json"))

        var prefs = Preferences()
        prefs.setVolume(VolumeState(level: 0.3, isMuted: true), for: .bundle("com.apple.Music"), name: "Music")
        prefs.setPinned(true, for: .bundle("com.apple.Music"), name: "Music")
        prefs.interface.density = .compact
        prefs.preferredOutput = RememberedDevice(id: DeviceID(uid: "BuiltInSpeakerDevice"), lastKnownName: "MacBook Pro Speakers")
        try store.save(prefs)

        let loaded = store.load()
        #expect(loaded == prefs)
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(json.contains("\"com.apple.Music\""))
    }

    @Test func corruptFileIsMovedAsideNotLost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("preferences.json")
        try Data("{ not json".utf8).write(to: url)

        let loaded = PreferencesStore(fileURL: url).load()
        #expect(loaded == Preferences())
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.contains { $0.hasPrefix("preferences.corrupt-") })
    }

    @Test func missingKeysUseDefaults() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"schemaVersion":1,"pinned":["x"]}"#.utf8))
        #expect(prefs.pinned == [SourceID("x")])
        #expect(prefs.rememberAppVolumes)
        #expect(prefs.interface.density == .comfortable)
    }

    @Test func forgettingRemovesPinAndVolume() {
        var prefs = Preferences()
        let id = SourceID("x")
        prefs.setVolume(VolumeState(level: 0.2), for: id, name: nil)
        prefs.setPinned(true, for: id, name: nil)
        prefs.forget(id)
        #expect(prefs.apps[id] == nil)
        #expect(!prefs.isPinned(id))
    }

    @Test func rememberOffMeansUnity() {
        var prefs = Preferences()
        prefs.setVolume(VolumeState(level: 0.2), for: SourceID("x"), name: nil)
        prefs.rememberAppVolumes = false
        #expect(prefs.volume(for: SourceID("x")) == .unity)
    }
}

@Suite("Capabilities")
struct CapabilityTests {
    @Test func deviceCapabilities() {
        let fixed = DeviceCapabilities.derive(isAlive: true, volumeSettable: false, muteSettable: false)
        #expect(fixed.volume == .unavailable(.fixedLevel))
        #expect(fixed.mute == .unavailable(.noHardwareMute))
        let gone = DeviceCapabilities.derive(isAlive: false, volumeSettable: true, muteSettable: true)
        #expect(!gone.volume.isUsable)
    }

    @Test func sourceCapabilities() {
        #expect(SourceCapabilities.derive(isShared: false, permissionDenied: false, engineError: nil).volume == .available)
        #expect(SourceCapabilities.derive(isShared: true, permissionDenied: false, engineError: nil).volume.note != nil)
        #expect(!SourceCapabilities.derive(isShared: false, permissionDenied: true, engineError: nil).mute.isUsable)
        #expect(!SourceCapabilities.derive(isShared: false, permissionDenied: false, engineError: "x").volume.isUsable)
    }
}
