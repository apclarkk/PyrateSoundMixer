import AudioToolbox
import SwiftUI
import PyrateAudio
import PyrateCore

/// The Apple effects in one app's rack, in signal order, plus "Add Effect".
struct EffectRackSection: View {
    @Environment(AppStore.self) private var store
    var row: SourceRowModel

    var body: some View {
        let rack = row.effects.rack
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apple effects").font(.system(size: 11, weight: .medium))
                Spacer()
                Menu {
                    ForEach(AppleEffectCatalog.entries) { entry in
                        let available = AppleEffectLibrary.isAvailable(entry.kind)
                        Button {
                            store.addRackEffect(entry.kind, to: row.id)
                        } label: {
                            Label(available ? "\(entry.name): \(entry.blurb)" : "\(entry.name) (not on this Mac)",
                                  systemImage: entry.symbol)
                        }
                        .disabled(!available)
                    }
                } label: {
                    Label("Add Effect", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(rack.count >= SourceEffects.maxRackSize)
                .help("Add one of the effects built into macOS")
            }
            if rack.isEmpty {
                Text("Add reverb, echo, distortion, pitch, compression, or filters. Effects run in order, only on \(row.name).")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(rack.enumerated()), id: \.element.id) { index, effect in
                EffectCard(row: row, effect: effect, index: index, count: rack.count)
            }
        }
    }
}

struct EffectCard: View {
    @Environment(AppStore.self) private var store
    var row: SourceRowModel
    var effect: RackEffect
    var index: Int
    var count: Int
    @State private var showAll = false

    var body: some View {
        let entry = AppleEffectCatalog.entry(for: effect.kind)
        let description = AppleEffectLibrary.describe(effect.kind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: entry?.symbol ?? "waveform")
                    .foregroundStyle(effect.isBypassed ? Color.secondary : Theme.accent)
                    .frame(width: 16)
                Text(entry?.name ?? effect.kind)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(effect.isBypassed ? .secondary : .primary)
                Spacer(minLength: 4)
                iconButton("chevron.up", help: "Move earlier") { store.moveRackEffect(effect.id, by: -1, in: row.id) }
                    .disabled(index == 0)
                iconButton("chevron.down", help: "Move later") { store.moveRackEffect(effect.id, by: 1, in: row.id) }
                    .disabled(index == count - 1)
                iconButton(effect.isBypassed ? "power.circle" : "power.circle.fill",
                           help: effect.isBypassed ? "Turn on" : "Bypass", tint: effect.isBypassed ? .secondary : Theme.accent) {
                    store.setRackBypass(!effect.isBypassed, effect: effect.id, in: row.id)
                }
                iconButton("xmark.circle", help: "Remove") { store.removeRackEffect(effect.id, from: row.id) }
            }

            if let description {
                if !description.presets.isEmpty {
                    Picker("Preset", selection: Binding(
                        get: { effect.presetNumber ?? -1 },
                        set: { store.setRackPreset($0 < 0 ? nil : $0, effect: effect.id, in: row.id) })
                    ) {
                        if effect.presetNumber == nil { Text("Custom").tag(-1) }
                        ForEach(description.presets, id: \.number) { Text($0.name).tag($0.number) }
                    }
                    .controlSize(.small)
                    .font(.system(size: 11))
                }
                let key = entry?.keyParameters ?? []
                ForEach(description.parameters.filter { key.contains($0.id) }) { parameter in
                    parameterControl(parameter, description: description, entry: entry)
                }
                let others = description.parameters.filter { !key.contains($0.id) }
                if !others.isEmpty {
                    DisclosureGroup(isExpanded: $showAll) {
                        ForEach(others) { parameter in
                            parameterControl(parameter, description: description, entry: entry)
                        }
                        Button("Reset to Starting Settings") { store.resetRackEffect(effect.id, in: row.id) }
                            .controlSize(.small)
                    } label: {
                        Text("More controls").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("This effect isn't available on this Mac, so it's skipped.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(effect.isBypassed ? 0.03 : 0.06)))
        .opacity(effect.isBypassed ? 0.75 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry?.name ?? effect.kind)\(effect.isBypassed ? ", bypassed" : "")")
    }

    private func iconButton(_ symbol: String, help: String, tint: Color = .secondary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint).frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func value(_ p: EffectParameter, _ description: EffectDescription) -> Float {
        effect.parameters[p.id]
            ?? effect.presetNumber.flatMap { description.presetValues[$0]?[p.id] }
            ?? p.defaultValue
    }

    @ViewBuilder
    private func parameterControl(_ p: EffectParameter, description: EffectDescription, entry: AppleEffectCatalog.Entry?) -> some View {
        let current = value(p, description)
        let set: (Float) -> Void = { store.setRackParameter(p.id, to: $0, effect: effect.id, in: row.id) }
        if p.isBoolean {
            Toggle(p.name, isOn: Binding(get: { current >= 0.5 }, set: { set($0 ? 1 : 0) }))
                .font(.system(size: 11)).controlSize(.small)
        } else if p.isIndexed {
            Stepper("\(p.name): \(Int(current))", value: Binding(get: { Int(current) }, set: { set(Float($0)) }),
                    in: Int(p.minValue)...Int(p.maxValue))
                .font(.system(size: 11)).controlSize(.small)
        } else {
            let semitones = entry?.semitoneParameters.contains(p.id) == true
            ParameterSlider(parameter: p, value: current, semitones: semitones, onChange: set)
        }
    }
}

/// A labeled slider for one Audio Unit parameter, logarithmic for frequencies.
struct ParameterSlider: View {
    var parameter: EffectParameter
    var value: Float
    var semitones: Bool
    var onChange: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(parameter.name).font(.system(size: 10))
                Spacer()
                Text(formatted).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { position(value) }, set: { onChange(self.value(at: $0)) }), in: 0...1)
                .controlSize(.mini)
                .accessibilityLabel(parameter.name)
                .accessibilityValue(formatted)
        }
        .help("\(parameter.name): \(formatted)")
    }

    // Slider position 0...1 <-> parameter value.
    private func position(_ v: Float) -> Double {
        let lo = parameter.minValue, hi = parameter.maxValue
        guard hi > lo else { return 0 }
        if parameter.isLogarithmic {
            return Double((log(max(v, lo)) - log(lo)) / (log(hi) - log(lo)))
        }
        return Double((v - lo) / (hi - lo))
    }

    private func value(at position: Double) -> Float {
        let lo = parameter.minValue, hi = parameter.maxValue
        let t = Float(min(max(position, 0), 1))
        var v = parameter.isLogarithmic ? exp(log(lo) + (log(hi) - log(lo)) * t) : lo + (hi - lo) * t
        if semitones { v = (v / 100).rounded() * 100 }
        return v
    }

    private var formatted: String {
        let v = value
        if semitones {
            let st = Int((v / 100).rounded())
            return st == 0 ? "0 semitones" : "\(st > 0 ? "+" : "")\(st) semitone\(abs(st) == 1 ? "" : "s")"
        }
        switch parameter.unit {
        case .hertz: return v >= 1000 ? String(format: "%.1f kHz", v / 1000) : "\(Int(v.rounded())) Hz"
        case .seconds: return v < 1 ? "\(Int((v * 1000).rounded())) ms" : String(format: "%.2f s", v)
        case .milliseconds: return String(format: "%.0f ms", v)
        case .percent, .equalPowerCrossfade: return "\(Int(v.rounded()))%"
        case .decibels: return String(format: "%+.1f dB", v)
        case .cents: return "\(Int(v.rounded())) cents"
        case .ratio: return String(format: "%.2f:1", v)
        case .octaves: return String(format: "%.2f oct", v)
        default: return abs(v) < 10 ? String(format: "%.2f", v) : String(format: "%.0f", v)
        }
    }
}
