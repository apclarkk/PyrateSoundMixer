import SwiftUI

/// A tactile level slider. Click anywhere on the track to jump, drag for continuous
/// control, arrow keys for 5% steps (Option for 1%). Muted state is shown by a
/// desaturated fill as well as by the mute button, never by color alone.
struct PyrateSlider: View {
    var value: Double
    var isMuted: Bool = false
    var label: String
    var onChange: (Double) -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var dragging = false
    @State private var hovering = false

    private let trackHeight: CGFloat = 5
    private let thumbSize: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let x = CGFloat(value) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.track)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(fillColor)
                    .frame(width: max(trackHeight, x), height: trackHeight)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: dragging ? 2.5 : 1, y: 0.5)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
                    .frame(width: thumbSize, height: thumbSize)
                    .scaleEffect(dragging ? 1.15 : (hovering ? 1.05 : 1))
                    .offset(x: min(max(x - thumbSize / 2, 0), width - thumbSize))
                    .opacity(isEnabled ? 1 : 0.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        onChange(Double(min(max(gesture.location.x / width, 0), 1)))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
            .animation(.pyrate(reduceMotion), value: dragging)
            .animation(.pyrate(reduceMotion), value: hovering)
        }
        .frame(height: 18)
        .onHover { hovering = $0 && isEnabled }
        .focusable(isEnabled)
        .focused($focused)
        .focusEffectDisabled()
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent.opacity(focused ? 0.8 : 0), lineWidth: 2)
                .padding(-3)
        )
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let step = press.modifiers.contains(.option) ? 0.01 : 0.05
            let up = press.key == .rightArrow || press.key == .upArrow
            onChange(min(max(value + (up ? step : -step), 0), 1))
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(isMuted ? "Muted, \(percent) percent" : "\(percent) percent")
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(value + 0.05, 1))
            case .decrement: onChange(max(value - 0.05, 0))
            @unknown default: break
            }
        }
    }

    private var percent: Int { Int((value * 100).rounded()) }

    private var fillColor: Color {
        if !isEnabled { return Theme.mutedFill.opacity(0.5) }
        return isMuted ? Theme.mutedFill : Theme.accent
    }
}

/// Speaker button that reflects level and mute by shape, not just color.
struct MuteButton: View {
    var isMuted: Bool
    var level: Double
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isMuted ? Color.secondary : Theme.accent)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute \(label)" : "Mute \(label)")
        .accessibilityLabel(isMuted ? "Unmute \(label)" : "Mute \(label)")
        .accessibilityValue(isMuted ? "Muted" : "Not muted")
    }

    private var symbol: String {
        if isMuted { return "speaker.slash.fill" }
        switch level {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// Fixed-width numeric readout so values don't jitter the layout.
struct LevelReadout: View {
    var level: Double
    var isMuted: Bool

    var body: some View {
        Text(isMuted ? "Muted" : "\(Int((level * 100).rounded()))%")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 40, alignment: .trailing)
            .accessibilityHidden(true)
    }
}
