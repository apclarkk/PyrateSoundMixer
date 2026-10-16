import AppKit
import SwiftUI
import PyrateCore

/// A tiny line through a preset's band gains, so presets can be compared at a glance.
struct EQSparkline: View {
    var gains: [Double]
    var lineWidth: CGFloat = 1.5

    var body: some View {
        Canvas { context, size in
            let range = GraphicEQ.gainRange
            let insetY: CGFloat = 2
            let h = size.height - insetY * 2
            func point(_ i: Int, _ g: Double) -> CGPoint {
                let x = size.width * CGFloat(i) / CGFloat(max(gains.count - 1, 1))
                let n = (min(max(g, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
                return CGPoint(x: x, y: insetY + h * CGFloat(1 - n))
            }
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(baseline, with: .foreground, style: StrokeStyle(lineWidth: 0.5))

            var line = Path()
            for (i, g) in gains.enumerated() {
                i == 0 ? line.move(to: point(i, g)) : line.addLine(to: point(i, g))
            }
            context.stroke(line, with: .foreground, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 26, height: 16)
        .accessibilityHidden(true)
    }
}

/// Plain menu item for a preset, used in context menus where custom drawing isn't possible.
struct EQPresetMenuItem: View {
    var preset: EQPreset
    var isSelected: Bool
    var select: () -> Void

    var body: some View {
        Toggle(preset.name, isOn: Binding(get: { isSelected }, set: { _ in select() }))
    }
}

/// Custom preset dropdown: each preset shows a sparkline of its curve. Arrow keys
/// move the highlight, Return chooses, Escape closes.
struct EQPresetPicker: View {
    var builtIns: [EQPreset]
    var custom: [EQPreset]
    var selectedID: String?
    var onSelect: (EQPreset) -> Void

    @State private var highlighted: String?
    @FocusState private var focused: Bool

    private var all: [EQPreset] { builtIns + custom }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    header("Presets")
                    ForEach(builtIns) { row($0) }
                    if !custom.isEmpty {
                        Divider().padding(.vertical, 4)
                        header("My Presets")
                        ForEach(custom) { row($0) }
                    }
                }
                .padding(6)
            }
            .frame(width: 210, height: min(CGFloat(all.count) * 25 + (custom.isEmpty ? 30 : 70), 400))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onAppear {
                highlighted = selectedID
                focused = true
                if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                move(press.key == .downArrow ? 1 : -1)
                if let highlighted { proxy.scrollTo(highlighted) }
                return .handled
            }
            .onKeyPress(.return) {
                if let preset = all.first(where: { $0.id == highlighted }) { onSelect(preset) }
                return .handled
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ preset: EQPreset) -> some View {
        let selected = preset.id == selectedID
        let lit = preset.id == highlighted
        return Button {
            onSelect(preset)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                EQSparkline(gains: preset.gains)
                    .foregroundStyle(lit ? Color.white : (selected ? Theme.accent : Color.primary.opacity(0.75)))
                Text(preset.name)
                    .font(.system(size: 12))
                    .foregroundStyle(lit ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(lit ? Theme.accent : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(preset.id)
        .onHover { if $0 { highlighted = preset.id } }
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(_ delta: Int) {
        guard !all.isEmpty else { return }
        let index = all.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : all.count)
        highlighted = all[min(max(index + delta, 0), all.count - 1)].id
    }
}

/// Inline equalizer for one source. Lives under the source's row, so it is
/// always clear which app it shapes.
struct EQDrawer: View {
    @Environment(AppStore.self) private var store
    var row: SourceRowModel

    @State private var naming: NamingMode?
    @State private var showingPresets = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private enum NamingMode { case save, rename(String) }

    var body: some View {
        let eq = row.eq
        let current = store.preferences.eqPreset(id: eq.presetID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                presetMenu(current: current)
                Spacer()
                Toggle("EQ", isOn: Binding(
                    get: { !eq.isBypassed },
                    set: { _ in store.toggleEQBypass(row.id) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help(eq.isBypassed ? "Turn EQ back on" : "Bypass EQ to compare with the original sound")
                    .accessibilityLabel("Equalizer for \(row.name)")
            }

            EQCurve(eq: eq)
                .frame(height: 54)
                .accessibilityHidden(true)

            HStack(spacing: 0) {
                ForEach(0..<GraphicEQ.bandCount, id: \.self) { band in
                    EQBandSlider(
                        gain: eq.gains[band],
                        frequency: GraphicEQ.frequencies[band],
                        isBypassed: eq.isBypassed,
                        appName: row.name,
                        onChange: { store.setEQGain($0, band: band, for: row.id) })
                    .frame(maxWidth: .infinity)
                }
            }

            if let naming {
                namingField(naming)
            } else {
                footer(current: current)
            }

            Text("Only affects \(row.name).\(eq.isActive ? (eq.matchLoudness ? " Loudness matches the original; a limiter catches peaks." : " A limiter catches peaks.") : "")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!row.capabilities.volume.isUsable)
    }

    private func presetMenu(current: EQPreset?) -> some View {
        Button {
            showingPresets.toggle()
        } label: {
            HStack(spacing: 6) {
                EQSparkline(gains: row.eq.gains)
                    .foregroundStyle(row.eq.isBypassed ? Color.secondary : Theme.accent)
                Text(row.eqPresetName ?? current?.name ?? "Flat")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(showingPresets ? 0.1 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPresets, arrowEdge: .bottom) {
            EQPresetPicker(
                builtIns: EQPreset.builtIns,
                custom: store.preferences.customEQPresets,
                selectedID: current?.id,
                onSelect: { preset in
                    store.selectEQPreset(preset, for: row.id)
                    showingPresets = false
                })
        }
        .help("Choose an EQ preset for \(row.name)")
        .accessibilityLabel("EQ preset")
        .accessibilityValue(row.eqPresetName ?? "Flat")
    }

    private func footer(current: EQPreset?) -> some View {
        HStack(spacing: 10) {
            Button("Reset") { store.resetEQ(row.id) }
                .disabled(row.eq.isFlat)
            Toggle("Match loudness", isOn: Binding(
                get: { row.eq.matchLoudness },
                set: { store.setEQMatchLoudness($0, for: row.id) }))
                .toggleStyle(.checkbox)
                .help("Keeps this app as loud as it was before EQ: boosts don't make it louder and cuts don't make it quieter. A limiter catches peaks either way.")
            Spacer()
            Menu {
                Button("Save as New Preset…") { begin(.save, prefill: "") }
                    .disabled(row.eq.isFlat)
                if let current, !current.isBuiltIn {
                    Button("Rename “\(current.name)”…") { begin(.rename(current.id), prefill: current.name) }
                    Button("Delete “\(current.name)”", role: .destructive) { store.deleteEQPreset(current.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Preset actions")
        }
        .font(.system(size: 11))
        .controlSize(.small)
    }

    private func namingField(_ mode: NamingMode) -> some View {
        HStack(spacing: 6) {
            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { commit(mode) }
            Button("Cancel") { naming = nil }
            Button(isRename(mode) ? "Rename" : "Save") { commit(mode) }
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .onExitCommand { naming = nil }
    }

    private func isRename(_ mode: NamingMode) -> Bool {
        if case .rename = mode { return true }
        return false
    }

    private func begin(_ mode: NamingMode, prefill: String) {
        name = prefill
        naming = mode
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commit(_ mode: NamingMode) {
        switch mode {
        case .save: store.saveEQPreset(named: name, from: row.id)
        case .rename(let id): store.renameEQPreset(id, to: name)
        }
        naming = nil
    }
}

/// Frequency response of the current EQ, drawn from the exact filter math.
struct EQCurve: View {
    var eq: SourceEQ

    var body: some View {
        Canvas { context, size in
            let range = GraphicEQ.gainRange
            func y(_ db: Double) -> CGFloat {
                let clamped = min(max(db, range.lowerBound), range.upperBound)
                return size.height * CGFloat((range.upperBound - clamped) / (range.upperBound - range.lowerBound))
            }
            // Grid: 0 dB line and band positions.
            var grid = Path()
            grid.move(to: CGPoint(x: 0, y: y(0)))
            grid.addLine(to: CGPoint(x: size.width, y: y(0)))
            context.stroke(grid, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

            let points = EQDesign.displayCurve(eq)
            guard let first = points.first, let last = points.last else { return }
            let lo = log10(first.frequency), hi = log10(last.frequency)
            func x(_ f: Double) -> CGFloat { size.width * CGFloat((log10(f) - lo) / (hi - lo)) }

            var line = Path()
            for (i, p) in points.enumerated() {
                let pt = CGPoint(x: x(p.frequency), y: y(p.db))
                i == 0 ? line.move(to: pt) : line.addLine(to: pt)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: y(0)))
            fill.addLine(to: CGPoint(x: 0, y: y(0)))
            fill.closeSubpath()

            let color: Color = eq.isBypassed ? .secondary : Theme.accent
            context.fill(fill, with: .color(color.opacity(eq.isBypassed ? 0.08 : 0.18)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: eq.isBypassed ? [3, 3] : []))
        }
    }
}

/// One vertical EQ band. Drag or click to set, double-click to zero, arrow keys
/// for 1 dB steps (Option for 0.5 dB).
struct EQBandSlider: View {
    var gain: Double
    var frequency: Double
    var isBypassed: Bool
    var appName: String
    var onChange: (Double) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool
    @State private var active = false
    @State private var hovering = false

    private let trackHeight: CGFloat = 84
    private let thumb: CGFloat = 10

    var body: some View {
        VStack(spacing: 3) {
            Text(valueText)
                .font(.system(size: 8, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .opacity(active || hovering || focused ? 1 : 0)
                .frame(height: 10)

            GeometryReader { geo in
                let h = geo.size.height
                let range = GraphicEQ.gainRange
                let norm = (gain - range.lowerBound) / (range.upperBound - range.lowerBound)
                let yValue = h * CGFloat(1 - norm)
                let yZero = h / 2
                ZStack(alignment: .top) {
                    Capsule().fill(Theme.track).frame(width: 3)
                    Rectangle()
                        .fill(isBypassed ? Theme.mutedFill : Theme.accent)
                        .frame(width: 3, height: abs(yValue - yZero))
                        .offset(y: min(yValue, yZero))
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 0.5).offset(y: yZero)
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: active ? 2 : 1, y: 0.5)
                        .frame(width: thumb, height: thumb)
                        .offset(y: yValue - thumb / 2)
                        .opacity(isEnabled ? 1 : 0.5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            active = true
                            let n = 1 - Double(min(max(g.location.y / h, 0), 1))
                            onChange(range.lowerBound + n * (range.upperBound - range.lowerBound))
                        }
                        .onEnded { _ in active = false })
                .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
            }
            .frame(height: trackHeight)

            Text(GraphicEQ.label(for: frequency))
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .onHover { hovering = $0 }
        .focusable(isEnabled)
        .focused($focused)
        .focusEffectDisabled()
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent.opacity(focused ? 0.8 : 0), lineWidth: 1.5))
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            let step = press.modifiers.contains(.option) ? 0.5 : 1
            onChange(gain + (press.key == .upArrow ? step : -step))
            return .handled
        }
        .help("\(GraphicEQ.label(for: frequency))Hz: \(valueText). Double-click to reset.")
        .accessibilityElement()
        .accessibilityLabel("\(GraphicEQ.label(for: frequency)) hertz band for \(appName)")
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(gain + 1)
            case .decrement: onChange(gain - 1)
            @unknown default: break
            }
        }
    }

    private var valueText: String {
        let rounded = (gain * 2).rounded() / 2
        if rounded == 0 { return "0 dB" }
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return (rounded > 0 ? "+" : "") + text + " dB"
    }
}

/// Small toggle on each row that opens its EQ drawer.
struct EQButton: View {
    @Environment(AppStore.self) private var store
    var row: SourceRowModel

    var body: some View {
        let open = store.expandedEQ == row.id
        Button {
            store.expandedEQ = open ? nil : row.id
        } label: {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(row.eq.isActive || !row.effects.isNeutral || row.route != .system || open ? Theme.accent : Color.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.accent.opacity(open ? 0.15 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("EQ, effects, and output for \(row.name)")
        .accessibilityLabel("Sound settings for \(row.name)")
        .accessibilityValue(row.eqPresetName ?? "Off")
        .accessibilityHint(open ? "Closes EQ, effects, and output" : "Opens EQ, effects, and output")
    }
}

/// Per-app drawer: EQ, effects, and output routing, all isolated to this app.
struct SourceDrawer: View {
    @Environment(AppStore.self) private var store
    var row: SourceRowModel

    enum Tab: String, CaseIterable { case eq = "EQ", effects = "Effects", output = "Output" }
    @State private var tab: Tab = .eq

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            switch tab {
            case .eq: EQDrawer(row: row)
            case .effects: EffectsPane(row: row)
            case .output: RoutePane(row: row)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct EffectsPane: View {
    @Environment(AppStore.self) private var store
    var row: SourceRowModel

    var body: some View {
        let effects = row.effects
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Balance").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(balanceText(effects.balance)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("L").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    BalanceSlider(value: effects.balance, appName: row.name) { value in
                        var e = effects
                        e.balance = abs(value) < 0.03 ? 0 : value
                        store.setEffects(e, for: row.id)
                    }
                    Text("R").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Channels").font(.system(size: 11, weight: .medium))
                Picker("Channels", selection: Binding(
                    get: { effects.channelMode },
                    set: { var e = effects; e.channelMode = $0; store.setEffects(e, for: row.id) })
                ) {
                    ForEach(ChannelMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            HStack {
                Button("Reset Balance and Channels") {
                    var e = effects
                    e.balance = 0
                    e.channelMode = .stereo
                    store.setEffects(e, for: row.id)
                }
                .controlSize(.small)
                .disabled(abs(effects.balance) < 0.005 && effects.channelMode == .stereo)
                Spacer()
            }
            Text("Balance lowers the opposite side and never boosts. Mono sums both channels, useful with one earbud.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            EffectRackSection(row: row)
        }
        .disabled(!row.capabilities.volume.isUsable)
    }

    private func balanceText(_ b: Double) -> String {
        abs(b) < 0.005 ? "Center" : "\(Int((abs(b) * 100).rounded()))% \(b < 0 ? "left" : "right")"
    }
}

/// Centered slider: -1 (left) to 1 (right). Double-click to center.
struct BalanceSlider: View {
    var value: Double
    var appName: String
    var onChange: (Double) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let x = CGFloat((value + 1) / 2) * w
            let mid = w / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track).frame(height: 5)
                Rectangle().fill(Theme.accent).frame(width: abs(x - mid), height: 5).offset(x: min(x, mid))
                Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1, height: 10).offset(x: mid)
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: 14, height: 14)
                    .offset(x: min(max(x - 7, 0), w - 14))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onChange(Double(min(max(g.location.x / w, 0), 1)) * 2 - 1)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
        }
        .frame(height: 18)
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            onChange(min(max(value + (press.key == .rightArrow ? 0.05 : -0.05), -1), 1))
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Balance for \(appName)")
        .accessibilityValue(abs(value) < 0.005 ? "Center" : "\(Int((abs(value) * 100).rounded())) percent \(value < 0 ? "left" : "right")")
        .accessibilityAdjustableAction { direction in
            onChange(min(max(value + (direction == .increment ? 0.05 : -0.05), -1), 1))
        }
    }
}

struct RoutePane: View {
    @Environment(AppStore.self) private var store
    var row: SourceRowModel

    var body: some View {
        let chosen = store.preferences.route(for: row.id)
        VStack(alignment: .leading, spacing: 6) {
            Text("Play \(row.name) through").font(.system(size: 11, weight: .medium))
            routeButton(title: "System output (\(store.currentOutput?.name ?? "none"))", symbol: "speaker.wave.2",
                        selected: chosen == nil) { store.setRoute(nil, for: row.id) }
            ForEach(store.outputDevices.filter(\.isAlive)) { device in
                routeButton(title: device.name, symbol: device.transport.symbolName,
                            selected: chosen?.id == device.id) { store.setRoute(device, for: row.id) }
            }
            if case .fallback(let missing) = row.route {
                Label("\(missing.lastKnownName) isn't connected, so \(row.name) is using the system output. It moves back when the device returns.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Routing works by playing this app's audio on the chosen device. Video on a different device than its picture can drift slightly out of sync, especially over Bluetooth.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!row.capabilities.volume.isUsable)
    }

    private func routeButton(title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                Image(systemName: symbol).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
