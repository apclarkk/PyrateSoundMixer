import AppKit
import SwiftUI
import PyrateCore

/// Design tokens. One restrained accent (a sea-glass teal) carries the personality;
/// everything else defers to system colors so the panel feels native in both appearances.
enum Theme {
    static let accent = Color(nsColor: NSColor(name: "PyrateAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.86, blue: 0.80, alpha: 1)
            : NSColor(srgbRed: 0.00, green: 0.50, blue: 0.48, alpha: 1)
    })
    static let mutedFill = Color.secondary.opacity(0.45)
    static let track = Color.primary.opacity(0.10)
    static let panelWidth: CGFloat = 340

    struct Metrics {
        var rowSpacing: CGFloat
        var rowPadding: CGFloat
        var iconSize: CGFloat
        var twoLineRows: Bool
    }

    static func metrics(_ density: Density) -> Metrics {
        switch density {
        case .compact: return Metrics(rowSpacing: 2, rowPadding: 4, iconSize: 18, twoLineRows: false)
        case .comfortable: return Metrics(rowSpacing: 6, rowPadding: 7, iconSize: 24, twoLineRows: true)
        }
    }
}

extension Animation {
    /// Snappy, short motion; collapses to nothing when Reduce Motion is on.
    static func pyrate(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)
    }
}
