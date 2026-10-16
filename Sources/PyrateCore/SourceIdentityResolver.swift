import Foundation

/// Facts about one audio-producing process, as reported by the audio service layer.
public struct ProcessFacts: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var executablePath: String?

    public init(pid: Int32, bundleID: String?, executablePath: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.executablePath = executablePath
    }
}

/// How a process maps onto a user-facing source.
public struct ResolvedSource: Equatable, Sendable {
    public var id: SourceID
    /// Path to the application bundle the user would recognize, when known.
    public var appBundlePath: String?
    /// True when one process plays audio on behalf of several apps, so controlling
    /// it affects all of them (for example the system WebKit GPU process).
    public var isShared: Bool
    /// Why a process is kept out of the mixer, or nil when it is a user-facing app.
    public var hiddenReason: HiddenReason?

    public var isHidden: Bool { hiddenReason != nil }
}

public enum HiddenReason: Equatable, Sendable {
    /// Another utility's routing engine replaying audio it captured. Adjusting it
    /// would change many apps at once in a way the row could not explain.
    case infrastructure
    /// macOS services, daemons, command-line tools, and utilities.
    case system
}

/// Processes that move other apps' audio around rather than producing their own.
public enum AudioInfrastructure {
    public static let bundleIDs: Set<String> = [
        "com.rogueamoeba.arkaudiod",   // Rogue Amoeba Audio Routing Kit (SoundSource, Audio Hijack)
    ]

    public static func contains(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }
}

/// Maps processes to sources. Helper processes (browser renderers, GPU processes,
/// XPC services nested inside an app bundle) are attributed to the outermost app.
public struct SourceIdentityResolver: Sendable {
    /// Reads the bundle identifier of the app at a path. Injected for testing.
    public var bundleIdentifierAtPath: @Sendable (String) -> String?
    /// True when the app at a path declares itself background-only. Injected for testing.
    public var isBackgroundOnlyApp: @Sendable (String) -> Bool

    public init(
        bundleIdentifierAtPath: @escaping @Sendable (String) -> String? = { path in
            Bundle(path: path)?.bundleIdentifier
        },
        isBackgroundOnlyApp: @escaping @Sendable (String) -> Bool = { path in
            (Bundle(path: path)?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) ?? false
        }
    ) {
        self.bundleIdentifierAtPath = bundleIdentifierAtPath
        self.isBackgroundOnlyApp = isBackgroundOnlyApp
    }

    /// Folders whose apps are system components or utilities, not things you listen to.
    static let systemPrefixes = ["/System/Library/", "/Library/", "/usr/", "/private/", "/sbin/", "/bin/", "/opt/"]
    static let utilityFolders = ["/Applications/Utilities/", "/System/Applications/Utilities/"]

    /// Whether an outermost app bundle (or bare executable, when nil) is a system component.
    func isSystem(appPath: String?, executablePath: String?) -> Bool {
        guard let appPath else { return true }  // daemons and command-line tools
        if Self.systemPrefixes.contains(where: appPath.hasPrefix) { return true }
        if Self.utilityFolders.contains(where: { appPath.contains($0) }) { return true }
        return isBackgroundOnlyApp(appPath)
    }

    public func resolve(_ facts: ProcessFacts) -> ResolvedSource {
        let bundleID = facts.bundleID.flatMap { $0.isEmpty ? nil : $0 }

        if AudioInfrastructure.contains(bundleID) {
            return ResolvedSource(id: .bundle(bundleID!), appBundlePath: nil, isShared: false, hiddenReason: .infrastructure)
        }

        if Self.isSharedWebKit(bundleID: bundleID, path: facts.executablePath) {
            return ResolvedSource(id: .sharedWebKit, appBundlePath: nil, isShared: true)
        }

        var resolved = identify(facts, bundleID: bundleID)
        if isSystem(appPath: resolved.appBundlePath, executablePath: facts.executablePath) {
            resolved.hiddenReason = .system
        }
        return resolved
    }

    private func identify(_ facts: ProcessFacts, bundleID: String?) -> ResolvedSource {

        if let path = facts.executablePath, let appPath = Self.outermostAppBundle(in: path) {
            if let outerID = bundleIdentifierAtPath(appPath) {
                return ResolvedSource(id: .bundle(outerID), appBundlePath: appPath, isShared: false)
            }
            if let bundleID {
                return ResolvedSource(id: .bundle(bundleID), appBundlePath: appPath, isShared: false)
            }
            return ResolvedSource(id: .path(appPath), appBundlePath: appPath, isShared: false)
        }

        if let bundleID {
            return ResolvedSource(id: .bundle(bundleID), appBundlePath: nil, isShared: false)
        }
        if let path = facts.executablePath {
            return ResolvedSource(id: .path(path), appBundlePath: nil, isShared: false)
        }
        return ResolvedSource(id: SourceID("pid:\(facts.pid)"), appBundlePath: nil, isShared: false)
    }

    /// Returns the outermost `.app` directory in a path, or nil.
    /// "/Applications/Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper.app/Contents/MacOS/x"
    /// resolves to "/Applications/Google Chrome.app".
    public static func outermostAppBundle(in path: String) -> String? {
        var result: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            result.append(component)
            if component.hasSuffix(".app") {
                return result.joined(separator: "/")
            }
        }
        return nil
    }

    static func isSharedWebKit(bundleID: String?, path: String?) -> Bool {
        if let bundleID, bundleID.hasPrefix("com.apple.WebKit") { return true }
        if let path, path.contains("/WebKit.framework/") && !path.contains(".app/") { return true }
        return false
    }
}
