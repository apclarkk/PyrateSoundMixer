import AppKit
import SwiftUI
import PyrateAudio
import PyrateCore

/// A read-only look under the hood: devices, what is being processed, and which
/// processes were found or deliberately hidden. "Copy Report" puts it all on the
/// clipboard as plain text; nothing is sent anywhere.
struct DiagnosticsView: View {
    @Environment(AppStore.self) private var store
    @State private var report = DiagnosticsReport.empty
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Snapshot taken \(report.taken.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { refresh() }
                Button(copied ? "Copied" : "Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                    copied = true
                }
            }
            ScrollView {
                Text(report.text)
                    .font(.system(size: 11).monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
        .padding()
        .onAppear { refresh() }
    }

    private func refresh() {
        report = DiagnosticsReport.build(store: store)
        copied = false
    }
}

struct DiagnosticsReport {
    var taken: Date
    var text: String

    static let empty = DiagnosticsReport(taken: Date(), text: "")

    @MainActor
    static func build(store: AppStore) -> DiagnosticsReport {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        lines.append("Pyrate Sounds \(info?["CFBundleShortVersionString"] as? String ?? "dev") on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")

        func device(_ d: OutputDevice, selected: Bool) -> String {
            let x = DeviceControl.details(of: d.objectID)
            return "\(selected ? "*" : " ") \(d.name) [\(d.transport.rawValue)] uid=\(d.id.uid) \(Int(x.sampleRate)) Hz, out \(x.outputChannels)ch, in \(x.inputChannels)ch, stereo pair \(x.stereoPair.map(String.init).joined(separator: "+"))\(d.isAlive ? "" : " (not alive)")"
        }
        lines.append("OUTPUT DEVICES (* = system default)")
        for d in store.outputDevices { lines.append(device(d, selected: d.id == store.selectedOutput.confirmed)) }
        if let master = store.master {
            lines.append("  master volume \(Int(master.level * 100))%\(master.isMuted ? ", muted" : ""); volume \(master.capabilities.volume.isUsable ? "settable" : "fixed"), mute \(master.capabilities.mute.isUsable ? "available" : "unavailable")")
        }
        lines.append("")
        lines.append("INPUT DEVICES")
        for d in store.inputDevices { lines.append(device(d, selected: d.id == store.selectedInput.confirmed)) }
        lines.append("")

        lines.append("PROCESSING (tapped sources)")
        let engines = store.tapsForDiagnostics.engineInfo
        if engines.isEmpty { lines.append("  none: every app plays natively") }
        for e in engines {
            let since = e.since.map { "\(Int(Date().timeIntervalSince($0)))s" } ?? "?"
            var fx = e.effects.summary ?? "none"
            if e.rackLatency > 0 { fx += " (+\(Int(e.rackLatency * 1000))ms)" }
            if !e.rackSkipped.isEmpty { fx += " skipped: \(e.rackSkipped.joined(separator: ", "))" }
            let destName = store.outputDevices.first { $0.id.uid == e.destinationUID }?.name ?? e.destinationUID
            lines.append("  \(e.sourceID) processes=\(e.processCount) -> \(destName) \(Int(e.sampleRate)) Hz latency=\(Int(e.latency * 1000))ms eq=\(e.eqActive ? "on" : "off") effects=\(fx) up \(since)")
        }
        for (id, error) in store.tapsForDiagnostics.errors { lines.append("  ERROR \(id): \(error)") }
        lines.append("")

        lines.append("APPS IN MIXER")
        for row in store.rows {
            var flags: [String] = []
            if row.isActive { flags.append("playing") }
            if !row.isPresent { flags.append("not running") }
            if row.isPinned { flags.append("pinned") }
            if row.isShared { flags.append("shared") }
            if row.eq.isActive { flags.append("eq \(row.eqPresetName ?? "custom")") }
            lines.append("  \(row.name) (\(row.id)) \(row.volume.isMuted ? "muted" : "\(row.volume.percent)%") \(flags.joined(separator: ", "))")
        }
        if !store.micUsers.isEmpty {
            lines.append("  using microphone: \(store.micUsers.map(\.name).joined(separator: ", "))")
        }
        lines.append("")

        lines.append("HIDDEN PROCESSES (system services, utilities, routing engines)")
        for h in store.processMonitorForDiagnostics.hidden {
            let name = h.bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? h.path?.components(separatedBy: "/").last ?? "pid \(h.pid)"
            lines.append("  \(name) pid=\(h.pid) \(h.reason == .infrastructure ? "routing engine" : "system")\(h.isRunningOutput ? ", playing" : "")")
        }
        return DiagnosticsReport(taken: Date(), text: lines.joined(separator: "\n"))
    }
}
