import SwiftUI
import PyrateAudio
import PyrateCore

/// A map of where every app's sound goes: app, what processes it, and the device
/// it reaches. Lines reflect what is actually configured; a dashed orange line
/// means the chosen device is missing and the app has fallen back.
struct RoutingWorkspace: View {
    @Environment(AppStore.self) private var store

    private let rowHeight: CGFloat = 54
    private let nodeWidth: CGFloat = 210

    var body: some View {
        let apps = store.rows
        let devices = deviceNodes
        let height = max(CGFloat(max(apps.count, devices.count)) * rowHeight + 40, 260)
        ScrollView {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for (i, row) in apps.enumerated() {
                            guard let target = destinationIndex(for: row, in: devices) else { continue }
                            let start = CGPoint(x: nodeWidth + 20, y: y(i))
                            let end = CGPoint(x: w - nodeWidth - 20, y: y(target))
                            var path = Path()
                            path.move(to: start)
                            let dx = (end.x - start.x) * 0.5
                            path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
                            let style = lineStyle(for: row)
                            context.stroke(path, with: .color(style.color), style: StrokeStyle(lineWidth: style.width, lineCap: .round, dash: style.dash))
                        }
                    }
                    ForEach(Array(apps.enumerated()), id: \.element.id) { i, row in
                        appNode(row)
                            .frame(width: nodeWidth, height: rowHeight - 10)
                            .position(x: 20 + nodeWidth / 2, y: y(i))
                    }
                    ForEach(Array(devices.enumerated()), id: \.element.id) { i, device in
                        deviceNode(device)
                            .frame(width: nodeWidth, height: rowHeight - 10)
                            .position(x: w - 20 - nodeWidth / 2, y: y(i))
                    }
                }
            }
            .frame(height: height)
        }
        .overlay(alignment: .bottomLeading) { legend.padding(10) }
        .overlay {
            if apps.isEmpty {
                ContentUnavailableView("Nothing to Route", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Apps appear here when they play sound or are pinned."))
            }
        }
        .frame(minWidth: 620, minHeight: 340)
    }

    private func y(_ index: Int) -> CGFloat { 30 + CGFloat(index) * rowHeight }

    struct DeviceNode: Identifiable {
        var id: DeviceID
        var name: String
        var symbol: String
        var isSystem: Bool
        var isMissing: Bool
    }

    /// Connected outputs, plus any device an app is set to that isn't connected.
    private var deviceNodes: [DeviceNode] {
        var nodes = store.outputDevices.filter(\.isAlive).map {
            DeviceNode(id: $0.id, name: $0.name, symbol: $0.transport.symbolName,
                       isSystem: $0.id == store.selectedOutput.confirmed, isMissing: false)
        }
        for row in store.rows {
            if case .fallback(let missing) = row.route, !nodes.contains(where: { $0.id == missing.id }) {
                nodes.append(DeviceNode(id: missing.id, name: missing.lastKnownName, symbol: "questionmark.circle", isSystem: false, isMissing: true))
            }
        }
        return nodes
    }

    private func destinationIndex(for row: SourceRowModel, in devices: [DeviceNode]) -> Int? {
        switch row.route {
        case .routed(let id): return devices.firstIndex { $0.id == id }
        case .system, .fallback: return devices.firstIndex { $0.isSystem }
        }
    }

    private func isProcessed(_ row: SourceRowModel) -> Bool {
        !row.volume.isUnity || row.eq.isActive || !row.effects.isNeutral || row.route.needsTap
    }

    private func lineStyle(for row: SourceRowModel) -> (color: Color, width: CGFloat, dash: [CGFloat]) {
        if case .fallback = row.route { return (.orange, 1.5, [5, 4]) }
        if !row.isPresent { return (.secondary.opacity(0.35), 1, [2, 4]) }
        return isProcessed(row) ? (Theme.accent, 2, []) : (.secondary.opacity(0.6), 1.5, [])
    }

    private func appNode(_ row: SourceRowModel) -> some View {
        Menu {
            Toggle("System Output", isOn: Binding(
                get: { store.preferences.route(for: row.id) == nil },
                set: { _ in store.setRoute(nil, for: row.id) }))
            Divider()
            ForEach(store.outputDevices.filter(\.isAlive)) { device in
                Toggle(device.name, isOn: Binding(
                    get: { store.preferences.route(for: row.id)?.id == device.id },
                    set: { _ in store.setRoute(device, for: row.id) }))
            }
        } label: {
            HStack(spacing: 8) {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable().frame(width: 24, height: 24)
                } else {
                    Image(systemName: "app.dashed").frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(chain(row)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isProcessed(row) ? Theme.accent.opacity(0.6) : .clear))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Choose where \(row.name) plays")
        .accessibilityLabel("\(row.name), \(chain(row)), plays through \(destinationName(row))")
    }

    private func destinationName(_ row: SourceRowModel) -> String {
        switch row.route {
        case .routed(let id): return store.outputDevices.first { $0.id == id }?.name ?? "another device"
        case .system, .fallback: return store.currentOutput?.name ?? "the system output"
        }
    }

    /// The processing this app passes through, in signal order.
    private func chain(_ row: SourceRowModel) -> String {
        guard isProcessed(row) else { return row.isPresent ? "Native, not processed" : "Not playing" }
        var stages: [String] = []
        if let eq = row.eqPresetName { stages.append("EQ \(eq)") }
        if let fx = row.effects.summary { stages.append(fx) }
        stages.append(row.volume.isMuted ? "muted" : "\(row.volume.percent)%")
        stages.append("limiter")
        return stages.joined(separator: " › ")
    }

    private func deviceNode(_ node: DeviceNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: node.symbol).frame(width: 20).foregroundStyle(node.isMissing ? Color.orange : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(node.isMissing ? "Not connected" : (node.isSystem ? "System output" : "Available"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(node.isMissing ? Color.orange : .clear, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .combine)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: Theme.accent, dash: [], text: "Processed by Pyrate Sounds")
            legendItem(color: .secondary.opacity(0.6), dash: [], text: "Native")
            legendItem(color: .orange, dash: [5, 4], text: "Device missing, fell back")
        }
        .font(.system(size: 10))
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private func legendItem(color: Color, dash: [CGFloat], text: String) -> some View {
        HStack(spacing: 4) {
            Canvas { context, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: dash))
            }
            .frame(width: 22, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
}
