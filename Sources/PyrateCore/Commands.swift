import Foundation

/// The one way outside triggers (keyboard shortcuts, the URL scheme, and future
/// integrations) ask Pyrate Sounds to do something. Keeping a single command set
/// is the stable internal interface new integrations plug into.
public enum PyrateCommand: Equatable, Sendable {
    case activateProfile(name: String)
    case setVolume(app: String, percent: Int)
    case adjustVolume(app: String, deltaPercent: Int)
    case mute(app: String)
    case unmute(app: String)
    case toggleMute(app: String)
    case setOutputVolume(percent: Int)
    case toggleOutputMute
    case selectOutput(name: String)
    case applyPreset(app: String, preset: String)
    case undoProfile

    /// Parses `pyratesounds://` URLs. Apps are matched by name or bundle ID,
    /// devices and profiles by name, all case-insensitively.
    ///
    ///     pyratesounds://profile/Meetings
    ///     pyratesounds://volume/Music?level=40      (or ?change=-10)
    ///     pyratesounds://mute/Music   unmute/…   toggle-mute/…
    ///     pyratesounds://output?level=60   pyratesounds://output/mute
    ///     pyratesounds://output/select/AirPods%20Pro
    ///     pyratesounds://eq/Music?preset=R%26B
    ///     pyratesounds://undo-profile
    public static func parse(_ url: URL) -> PyrateCommand? {
        guard url.scheme?.lowercased() == "pyratesounds",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = (components.host ?? "").lowercased()
        let path = components.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name.lowercased(), $0) } },
                               uniquingKeysWith: { a, _ in a })
        func percent(_ key: String, range: ClosedRange<Int>) -> Int? {
            query[key].flatMap(Int.init).map { min(max($0, range.lowerBound), range.upperBound) }
        }
        let target = path.first

        switch host {
        case "profile":
            return target.map { .activateProfile(name: $0) }
        case "volume":
            guard let app = target else { return nil }
            if let level = percent("level", range: 0...100) { return .setVolume(app: app, percent: level) }
            if let change = percent("change", range: -100...100) { return .adjustVolume(app: app, deltaPercent: change) }
            return nil
        case "mute": return target.map { .mute(app: $0) }
        case "unmute": return target.map { .unmute(app: $0) }
        case "toggle-mute": return target.map { .toggleMute(app: $0) }
        case "output":
            if path.first == "mute" { return .toggleOutputMute }
            if path.first == "select", path.count > 1 { return .selectOutput(name: path[1]) }
            return percent("level", range: 0...100).map { .setOutputVolume(percent: $0) }
        case "eq":
            guard let app = target, let preset = query["preset"] else { return nil }
            return .applyPreset(app: app, preset: preset)
        case "undo-profile":
            return .undoProfile
        default:
            return nil
        }
    }

    /// Short description for the activity history.
    public var summary: String {
        switch self {
        case .activateProfile(let name): return "activate profile \(name)"
        case .setVolume(let app, let p): return "set \(app) to \(p)%"
        case .adjustVolume(let app, let d): return "change \(app) by \(d > 0 ? "+" : "")\(d)%"
        case .mute(let app): return "mute \(app)"
        case .unmute(let app): return "unmute \(app)"
        case .toggleMute(let app): return "toggle mute for \(app)"
        case .setOutputVolume(let p): return "set output volume to \(p)%"
        case .toggleOutputMute: return "toggle output mute"
        case .selectOutput(let name): return "switch output to \(name)"
        case .applyPreset(let app, let preset): return "use \(preset) EQ on \(app)"
        case .undoProfile: return "undo last profile"
        }
    }
}
