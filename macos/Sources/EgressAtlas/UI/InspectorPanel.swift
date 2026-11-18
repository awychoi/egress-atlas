import SwiftUI

struct InspectorPanel: View {
    @ObservedObject var runtime: AtlasRuntime
    let selection: Selection
    let metrics: Metrics

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    switch selection {
                    case .device(let id):
                        if let device = runtime.network.deviceById[id] {
                            deviceContent(device)
                        }
                    case .destination(let id):
                        if let destination = runtime.network.destinationById[id] {
                            destinationContent(destination)
                        }
                    case .path(let deviceId, let destinationId):
                        if let device = runtime.network.deviceById[deviceId],
                           let destination = runtime.network.destinationById[destinationId],
                           let edge = runtime.network.edges.first(where: {
                               $0.deviceId == deviceId && $0.destinationId == destinationId
                           }) {
                            pathContent(device: device, destination: destination, edge: edge)
                        }
                    }
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var title: String {
        switch selection {
        case .device(let id): return runtime.network.deviceById[id]?.name ?? ""
        case .destination(let id): return runtime.network.destinationById[id]?.domain ?? ""
        case .path(_, let destinationId): return runtime.network.destinationById[destinationId]?.domain ?? ""
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                runtime.navigateBack()
            } label: {
                HStack(spacing: 5) {
                    ChevronGlyph(left: true, size: 10, color: Palette.dim.color)
                    Text("BACK")
                        .font(.atlasMono(7, .regular))
                        .tracking(7 * 0.08)
                        .foregroundColor(Palette.dim.color)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("0d0704", 0.32)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Palette.text.opacity(0.08), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(AtlasPlainButtonStyle())
            Spacer()
            badge
        }
        .padding(.top, 16)
    }

    private var badge: some View {
        let (text, blocked) = badgeInfo
        return Text(text.uppercased())
            .font(.atlasMono(6.5, .regular))
            .tracking(6.5 * 0.12)
            .foregroundColor(blocked ? Palette.coral.color : Palette.signal.color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(blocked ? Palette.coral.opacity(0.34) : Palette.signal.opacity(0.3), lineWidth: 1))
    }

    private var badgeInfo: (String, Bool) {
        switch selection {
        case .device: return ("device", false)
        case .destination(let id):
            let blocked = runtime.network.destinationById[id]?.status == .blocked
            return (blocked ? "blocked" : "allowed", blocked)
        case .path(let deviceId, let destinationId):
            let blocked = runtime.network.destinationById[destinationId]?.status == .blocked
            _ = deviceId
            return (blocked ? "blocked path" : "path", blocked)
        }
    }

    private func titleBlock(subtitle: String, blocked: Bool, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.atlasSans(22, .medium))
                .tracking(-22 * 0.035)
                .foregroundColor(blocked ? Palette.coralHot.color : Palette.text.color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(subtitle.uppercased())
                .font(.atlasMono(7.5, .regular))
                .tracking(7.5 * 0.03)
                .lineSpacing(3)
                .foregroundColor(Palette.dim.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    private func statsGrid(_ cells: [(String, String, Bool)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: cell.0, size: 6.5, color: Palette.dim.color, trackingEm: 0.16)
                    Text(cell.1)
                        .font(.atlasMono(14, .regular))
                        .tracking(-0.42)
                        .foregroundColor(cell.2 ? Palette.coral.color : Palette.text2.color)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(Color.rgba("0b0604", 0.54))
                .overlay(alignment: .bottomLeading) {
                    Rectangle().fill(Palette.text.opacity(0.04)).frame(height: 1)
                }
            }
        }
        .background(Palette.text.opacity(0.062))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
        .padding(.top, 13)
    }

    private func blockHeader(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Eyebrow(text: title, size: 7.5, color: Palette.gold.color, trackingEm: 0.13)
            Spacer()
            Text(value)
                .font(.atlasMono(6, .regular))
                .foregroundColor(Palette.faint.color)
        }
        .padding(.bottom, 6)
    }

    private func actions(focus: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            MiniActionButton(title: "Focus on globe", primary: true, action: focus)
        }
        .padding(.top, 14)
    }

    // ── device ───────────────────────────────────────────────────────────

    private func deviceContent(_ device: Device) -> some View {
        let visibleDestinations = device.destinations.filter(\.windowVisible).count
        let qps = runtime.source.getQps(device.id)
        let recent = runtime.recentEvents(deviceId: device.id)
        return VStack(alignment: .leading, spacing: 0) {
            titleBlock(subtitle: "\(device.kind) · \(device.ip)\(device.thisMac ? " · this mac" : "")\n\(device.os)",
                       blocked: false, title: device.name)
            statsGrid([
                ("Queries today", Format.count(device.liveQueries), false),
                ("Blocked", Format.count(device.liveBlocked), device.liveBlocked > 0),
                ("Destinations", "\(visibleDestinations)", false),
                ("Live rate", "\(Format.rate(qps))/s", false),
            ])
            VStack(alignment: .leading, spacing: 0) {
                blockHeader("Top destinations", value: Format.ago(device.lastSeen).uppercased())
                ForEach(topDestinations(device), id: \.id) { edge in
                    InspectorRouteRow(
                        dot: edge.destination.status == .blocked ? Palette.coral.color : Palette.gold.color,
                        title: edge.destination.domain,
                        value: Format.count(edge.liveQueries),
                        fraction: barFraction(edge.liveQueries, upper: topMax(device))
                    ) {
                        runtime.select(.destination(edge.destination.id))
                    }
                }
            }
            .padding(.top, 15)
            .overlay(alignment: .top) { Hairline().padding(.top, -2) }

            VStack(alignment: .leading, spacing: 0) {
                blockHeader("Recent queries", value: "\(recent.count)")
                ForEach(recent.prefix(4)) { event in
                    InspectorQueryRow(event: event) {
                        runtime.select(.path(deviceId: event.deviceId, destinationId: event.destinationId))
                    }
                }
                if recent.isEmpty { emptyRow("No recent rows.") }
            }
            .padding(.top, 15)
            .overlay(alignment: .top) { Hairline().padding(.top, -2) }

            actions { runtime.focusSelection() }
            Text("This device accounts for \(String(format: "%.1f", Double(device.liveQueries) / Double(max(1, runtime.network.totals.queries)) * 100))% of today's queries. Select a destination to see every device that uses it.")
                .font(.atlasSans(9.5, .regular))
                .lineSpacing(2)
                .foregroundColor(Palette.dim.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    // ── destination ──────────────────────────────────────────────────────

    private func destinationContent(_ destination: Destination) -> some View {
        let blocked = destination.status == .blocked
        let events = runtime.recentEvents(destinationId: destination.id)
        return VStack(alignment: .leading, spacing: 0) {
            titleBlock(
                subtitle: "\(destination.category) · first seen \(Format.shortDate(destination.firstSeen))\n\(blocked ? "gravity list · denied before reply" : "avg reply \(destination.avgLatencyMs ?? 0) ms")",
                blocked: blocked,
                title: destination.domain
            )
            statsGrid([
                ("Queries today", Format.count(destination.liveQueries), false),
                ("Blocked", Format.count(destination.liveBlocked), true),
                ("Devices", "\(destination.devices.count)", false),
                ("Last seen", Format.ago(destination.lastSeen), false),
            ])
            VStack(alignment: .leading, spacing: 0) {
                blockHeader("Seen from", value: "\(destination.devices.count) device\(destination.devices.count == 1 ? "" : "s")")
                ForEach(destination.edges.sorted { $0.liveQueries > $1.liveQueries }, id: \.id) { edge in
                    InspectorRouteRow(
                        dot: Palette.signal.color,
                        title: edge.device.name,
                        value: Format.count(edge.liveQueries),
                        fraction: barFraction(edge.liveQueries, upper: destination.edges.map(\.liveQueries).max() ?? 1)
                    ) {
                        runtime.select(.device(edge.device.id))
                    }
                }
            }
            .padding(.top, 15)
            .overlay(alignment: .top) { Hairline().padding(.top, -2) }

            VStack(alignment: .leading, spacing: 0) {
                blockHeader("Recent queries", value: "\(events.count)")
                ForEach(events.prefix(4)) { event in
                    InspectorQueryRow(event: event) {
                        runtime.select(.path(deviceId: event.deviceId, destinationId: event.destinationId))
                    }
                }
                if events.isEmpty { emptyRow("No recent rows.") }
            }
            .padding(.top, 15)
            .overlay(alignment: .top) { Hairline().padding(.top, -2) }

            actions { runtime.focusSelection() }
            Text(blocked
                 ? "A blocked destination is a different state, not a bigger blast. Hits answer with the 360° containment shield and stay anchored."
                 : "The hit plane is perpendicular to the inbound wire and centred on the destination. Orbit the globe to read the angle.")
                .font(.atlasSans(9.5, .regular))
                .lineSpacing(2)
                .foregroundColor(Palette.dim.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    // ── path ─────────────────────────────────────────────────────────────

    private func pathContent(device: Device, destination: Destination, edge: Edge) -> some View {
        let blocked = destination.status == .blocked
        let events = runtime.recentEvents(deviceId: device.id, destinationId: destination.id)
        let share = Double(edge.liveQueries) / Double(max(1, device.liveQueries)) * 100
        return VStack(alignment: .leading, spacing: 0) {
            titleBlock(subtitle: "via \(device.name) · \(device.ip)\nlast seen \(Format.ago(edge.lastSeen))",
                       blocked: blocked, title: destination.domain)
            HStack(spacing: 8) {
                Text(device.name)
                    .font(.atlasMono(8, .regular))
                    .foregroundColor(Palette.text2.color)
                Text("→")
                    .font(.atlasMono(8, .regular))
                    .foregroundColor(Palette.faint.color)
                Text(destination.domain)
                    .font(.atlasMono(8, .regular))
                    .foregroundColor(blocked ? Palette.coral.color : Palette.gold.color)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.signal.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.signal.opacity(0.14), lineWidth: 1))
            .padding(.top, 13)

            statsGrid([
                ("Queries", Format.count(edge.liveQueries), false),
                ("Blocked", Format.count(edge.liveBlocked), edge.liveBlocked > 0),
                ("Share of device", String(format: "%.1f%%", share), false),
                ("Reply", blocked ? "denied" : "\(destination.avgLatencyMs ?? 0) ms", false),
            ])

            VStack(alignment: .leading, spacing: 0) {
                blockHeader("Recent on this path", value: "\(events.count)")
                ForEach(events.prefix(6)) { event in
                    InspectorQueryRow(event: event) {
                        runtime.select(.path(deviceId: event.deviceId, destinationId: event.destinationId))
                    }
                }
                if events.isEmpty { emptyRow("No recent rows.") }
            }
            .padding(.top, 15)
            .overlay(alignment: .top) { Hairline().padding(.top, -2) }

            actions { runtime.focusSelection() }
            Text("This line is the relationship, not a one-off packet: \(Format.count(edge.liveQueries)) queries from this device to this destination today.")
                .font(.atlasSans(9.5, .regular))
                .lineSpacing(2)
                .foregroundColor(Palette.dim.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    private func topDestinations(_ device: Device) -> [Edge] {
        device.edges.filter { $0.destination.windowVisible }
            .sorted { $0.liveQueries > $1.liveQueries }
            .prefix(5)
            .map { $0 }
    }

    private func topMax(_ device: Device) -> Int {
        max(1, topDestinations(device).map(\.liveQueries).max() ?? 1)
    }

    private func barFraction(_ value: Int, upper: Int) -> CGFloat {
        Swift.max(0.02, Swift.min(1, CGFloat(value) / CGFloat(Swift.max(1, upper))))
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.atlasMono(7.5, .regular))
            .foregroundColor(Palette.faint.color)
            .padding(.vertical, 10)
    }
}

struct InspectorRouteRow: View {
    var dot: Color
    var title: String
    var value: String
    var fraction: CGFloat
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(dot).frame(width: 5, height: 5)
                        .shadow(color: dot.opacity(0.5), radius: 3)
                    Text(title)
                        .font(.atlasMono(8, .regular))
                        .foregroundColor(Palette.text2.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(value)
                        .font(.atlasMono(7, .regular))
                        .foregroundColor(Palette.faint.color)
                        .monospacedDigit()
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.text.opacity(0.06))
                        LinearGradient(colors: [Palette.signal2.color, Palette.gold.color], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * fraction)
                            .clipShape(Capsule())
                            .opacity(0.7)
                    }
                }
                .frame(height: 2)
                .padding(.leading, 12)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Palette.text.opacity(0.038) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .onHover { hover = $0 }
    }
}

struct InspectorQueryRow: View {
    let event: QueryEvent
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle().fill(event.status == .blocked ? Palette.coral.color : Palette.gold.color)
                    .frame(width: 5, height: 5)
                Text("\(event.device.name) → \(event.destination.domain)")
                    .font(.atlasMono(8, .regular))
                    .foregroundColor(Palette.text2.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Format.clock(event.ts))
                    .font(.atlasMono(7, .regular))
                    .foregroundColor(Palette.faint.color)
                    .monospacedDigit()
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Palette.text.opacity(0.038) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .onHover { hover = $0 }
    }
}
