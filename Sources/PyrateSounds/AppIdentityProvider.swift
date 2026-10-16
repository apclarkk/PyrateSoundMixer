import AppKit
import PyrateAudio
import PyrateCore

/// Resolves recognizable names and icons for sources. Cached, since icons are
/// relatively expensive and identities do not change while an app runs.
@MainActor
final class AppIdentityProvider {
    struct Identity {
        var name: String
        var icon: NSImage?
    }

    private var cache: [SourceID: Identity] = [:]

    func identity(for id: SourceID, source: DiscoveredSource?, fallbackName: String?) -> Identity {
        if let cached = cache[id], cached.icon != nil { return cached }
        let identity = resolve(id: id, source: source, fallbackName: fallbackName)
        cache[id] = identity
        return identity
    }

    private func resolve(id: SourceID, source: DiscoveredSource?, fallbackName: String?) -> Identity {
        let workspace = NSWorkspace.shared

        if id == .sharedWebKit {
            let safari = "/Applications/Safari.app"
            let icon = FileManager.default.fileExists(atPath: safari) ? workspace.icon(forFile: safari) : nil
            return Identity(name: "Safari and WebKit apps", icon: icon)
        }

        if let path = source?.appBundlePath {
            return Identity(name: Self.displayName(ofAppAt: path), icon: workspace.icon(forFile: path))
        }

        if let pid = source?.pids.first, let app = NSRunningApplication(processIdentifier: pid) {
            return Identity(name: app.localizedName ?? fallbackName ?? id.rawValue, icon: app.icon)
        }

        // Idle pinned apps: find them by bundle identifier.
        if !id.rawValue.contains(":"), let url = workspace.urlForApplication(withBundleIdentifier: id.rawValue) {
            return Identity(name: Self.displayName(ofAppAt: url.path), icon: workspace.icon(forFile: url.path))
        }

        let hint = source?.bundleIDHint.flatMap { $0.isEmpty ? nil : $0 }
        let name = fallbackName ?? hint ?? id.rawValue.components(separatedBy: "/").last ?? id.rawValue
        return Identity(name: name, icon: nil)
    }

    static func displayName(ofAppAt path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
