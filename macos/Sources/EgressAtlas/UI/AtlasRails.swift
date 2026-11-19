import SwiftUI

struct AtlasRails: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Left network rail.
                NetworkRail(runtime: runtime, metrics: metrics)
                    .frame(width: metrics.railLeftWidth, height: metrics.railHeight)
                    .position(x: metrics.edge + metrics.railLeftWidth / 2,
                              y: metrics.railTop + metrics.railHeight / 2)
                    .offset(x: runtime.leftRailOpen ? 0 : -(metrics.railLeftWidth + 34))
                    .opacity(runtime.leftRailOpen ? 1 : 0)
                    .allowsHitTesting(runtime.leftRailOpen)
                    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.46), value: runtime.leftRailOpen)

                // Right traffic / inspector rail.
                TrafficRail(runtime: runtime, metrics: metrics)
                    .frame(width: metrics.railRightWidth, height: metrics.railHeight)
                    .position(x: geo.size.width - metrics.edge - metrics.railRightWidth / 2,
                              y: metrics.railTop + metrics.railHeight / 2)
                    .offset(x: runtime.rightRailOpen ? 0 : (metrics.railRightWidth + 34))
                    .opacity(runtime.rightRailOpen ? 1 : 0)
                    .allowsHitTesting(runtime.rightRailOpen)
                    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.46), value: runtime.rightRailOpen)

            }
        }
    }
}

// ── left rail ────────────────────────────────────────────────────────────

struct NetworkRail: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics
    @State private var index: Int = 0
    @State private var hoverDevice: String?
    @State private var hoverDestination: String?

    private var visibleDestinations: [Destination] {
        runtime.windowVisibleDestinations()
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Eyebrow(text: "Network", size: 8, color: Palette.gold.color, trackingEm: 0.12)
                        Spacer(minLength: 4)
                    }
                    Text(runtime.devicePresenceText)
                        .font(.atlasMono(7, .regular))
                        .tracking(7 * 0.08)
                        .foregroundColor(Palette.faint.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
                    RailCloseButton(left: true) { runtime.leftRailOpen = false }
                }
                Text(index == 0 ? "Devices" : "Destinations")
                    .font(.atlasSans(metrics.railHeadTitleSize, .medium))
                    .tracking(-metrics.railHeadTitleSize * 0.032)
                    .foregroundColor(Palette.text.color)
                    .padding(.top, 8)
                if metrics.showIndexCopy {
                    Text(index == 0
                         ? "Blue orbs are devices on this network. Select one to trace its DNS paths or set an alias."
                         : "Gold is allowed, coral is blocked. Select a destination to see its devices or set an alias.")
                        .font(.atlasSans(10.5, .regular))
                        .tracking(-0.05)
                        .lineSpacing(2)
                        .foregroundColor(Palette.muted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                HStack(spacing: 2) {
                    indexTab("Devices", count: runtime.network.devices.count, active: index == 0) { index = 0 }
                    indexTab("Destinations", count: visibleDestinations.count, active: index == 1) { index = 1 }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.rgba("090503", 0.32)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
                .padding(.top, 13)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 2) {
                    if index == 0 {
                        ForEach(deviceOrder, id: \.id) { device in
                            DeviceIndexRow(runtime: runtime, device: device,
                                           selected: runtime.selection?.deviceId == device.id,
                                           hovered: hoverDevice == device.id)
                                .onHover { hoverDevice = $0 ? device.id : nil }
                                .onTapGesture {
                                    if runtime.selection?.deviceId == device.id { runtime.clearSelection() }
                                    else { runtime.select(.device(device.id)) }
                                }
                                .onTapGesture(count: 2) {
                                    runtime.focus(on: .device(device.id))
                                }
                        }
                    } else {
                        ForEach(destinationOrder, id: \.id) { destination in
                            let filtered = runtime.filter != .all && destination.status != runtime.filter.status
                            DestinationIndexRow(runtime: runtime, destination: destination,
                                                selected: runtime.selection?.destinationId == destination.id,
                                                dimmed: filtered,
                                                hovered: hoverDestination == destination.id)
                                .onHover { hoverDestination = $0 ? destination.id : nil }
                                .onTapGesture {
                                    if runtime.selection?.destinationId == destination.id { runtime.clearSelection() }
                                    else { runtime.select(.destination(destination.id)) }
                                }
                                .onTapGesture(count: 2) {
                                    runtime.focus(on: .destination(destination.id))
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if metrics.compact || metrics.short {
                    LinearGradient(colors: [.clear, Color.rgba("0b0604", 0.94)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                        .allowsHitTesting(false)
                }
            }

            HStack(alignment: .top, spacing: 7) {
                Text("↳")
                    .font(.atlasMono(9, .regular))
                    .foregroundColor(Palette.gold.opacity(0.7))
                Text(index == 0
                     ? "Positions reflect traffic relationships, not location."
                     : "Gold is allowed · coral is blocked · size follows volume.")
                    .font(.atlasMono(6.7, .regular))
                    .tracking(6.7 * 0.07)
                    .lineSpacing(1)
                    .foregroundColor(Palette.faint.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(Color.rgba("0b0604", 0.55))
            .overlay(alignment: .top) { Hairline() }
        }
        .background(WarmGlass(radius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 35, x: 0, y: 24)
    }

    private var deviceOrder: [Device] {
        runtime.network.devices.sorted { $0.weight > $1.weight }
    }

    private var destinationOrder: [Destination] {
        visibleDestinations.sorted {
            if $0.status != $1.status { return $0.status == .allowed }
            return $0.liveQueries > $1.liveQueries
        }
    }

    private func indexTab(_ label: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(label.uppercased())
                    .font(.atlasMono(7.5, .regular))
                    .tracking(7.5 * 0.09)
                    .foregroundColor(active ? Palette.gold.color : Palette.dim.color)
                Text(" \(Format.compact(count))")
                    .font(.atlasMono(6.5, .regular))
                    .foregroundColor(Palette.faint.color)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(active ? Palette.gold.opacity(0.075) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(active ? Palette.gold.opacity(0.12) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(AtlasPlainButtonStyle())
    }
}

struct RailCloseButton: View {
    var action: () -> Void
    var left: Bool = true
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            ChevronGlyph(left: left, size: 12, color: hover ? Palette.gold.color : Palette.dim.color)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("090503", 0.28)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(hover ? Palette.gold.opacity(0.28) : Palette.text.opacity(0.062), lineWidth: 1))
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .onHover { hover = $0 }
        .accessibilityLabel(left ? "Close network panel" : "Close queries panel")
    }
}

struct DeviceIndexRow: View {
    @ObservedObject var runtime: AtlasRuntime
    let device: Device
    let selected: Bool
    let hovered: Bool

    private var qps: Float { runtime.source.getQps(device.id) }
    private var lastSeenText: String { Format.ago(device.lastSeen) }
    private var displayName: String { runtime.deviceDisplayName(device) }
    private var addressText: String? { runtime.deviceAddressText(device) }
    private var subtitle: String {
        [device.kind, addressText].compactMap { $0 }.joined(separator: " · ")
    }
    private var maxQps: Float {
        max(1.2, runtime.network.devices.map { runtime.source.getQps($0.id) }.max() ?? 1)
    }

    var body: some View {
        HStack(spacing: 9) {
            AtlasDeviceMark(color: Palette.signal.color)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(displayName)
                        .font(.atlasSans(12, .medium))
                        .tracking(-0.15)
                        .foregroundColor(selected ? Palette.text.color : Palette.text2.color)
                        .lineLimit(1)
                    if device.thisMac {
                        Text("THIS MAC")
                            .font(.atlasMono(5.8, .regular))
                            .tracking(5.8 * 0.08)
                            .foregroundColor(Palette.signal.color)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Palette.signal.opacity(0.32), lineWidth: 1))
                    }
                }
                Text(subtitle)
                    .font(.atlasMono(7, .regular))
                    .foregroundColor(Palette.dim.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 1) {
                    Text(Format.rate(qps))
                        .font(.atlasMono(8, .regular))
                        .foregroundColor(Palette.text2.color)
                    Text("/s")
                        .font(.atlasMono(6, .regular))
                        .foregroundColor(Palette.faint.color)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.text.opacity(0.07))
                    Capsule().fill(Palette.signal.opacity(0.6))
                        .frame(width: 38 * max(0.02, min(1, CGFloat(qps / maxQps))))
                }
                .frame(width: 38, height: 2)
                Text("last: \(lastSeenText)")
                    .font(.atlasMono(6.4, .regular))
                    .foregroundColor(device.windowVisible ? Palette.dim.color : Palette.coral.opacity(0.82))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .opacity(device.windowVisible ? 1 : 0.68)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected
                      ? LinearGradient(colors: [Palette.signal.opacity(0.1), Palette.signal.opacity(0.02)],
                                       startPoint: .leading, endPoint: .trailing)
                      : LinearGradient(colors: [hovered ? Palette.text.opacity(0.035) : .clear,
                                                hovered ? Palette.text.opacity(0.035) : .clear],
                                       startPoint: .leading, endPoint: .trailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Palette.signal.opacity(0.24)
                              : (hovered ? Palette.text.opacity(0.062) : .clear), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(displayName), \(device.kind), \(addressText ?? device.ip), last seen \(lastSeenText)\(device.liveBlocked > 0 ? ", \(Format.count(device.liveBlocked)) blocked" : "")")
        .help("\(device.name) · \(device.ip)")
    }
}

struct DestinationIndexRow: View {
    @ObservedObject var runtime: AtlasRuntime
    let destination: Destination
    let selected: Bool
    let dimmed: Bool
    let hovered: Bool

    private var blocked: Bool { destination.status == .blocked }
    private var accent: Color { blocked ? Palette.coral.color : Palette.gold.color }
    private var displayName: String { runtime.destinationDisplayName(destination) }
    private var originalText: String? { runtime.destinationOriginalText(destination) }
    private var subtitle: String {
        [destination.category,
         "\(destination.devices.count) device\(destination.devices.count == 1 ? "" : "s")",
         originalText].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 9) {
            AtlasDestinationMark(color: accent)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.atlasSans(12, .medium))
                    .tracking(-0.15)
                    .foregroundColor(blocked ? Palette.coralHot.color : Palette.text2.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.atlasMono(7, .regular))
                    .foregroundColor(blocked ? Palette.coral.opacity(0.72) : Palette.dim.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Format.count(blocked && destination.liveBlocked > 0 ? destination.liveBlocked : destination.liveQueries))
                    .font(.atlasMono(8, .regular))
                    .foregroundColor(Palette.text2.color)
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.text.opacity(0.07))
                    Capsule().fill(accent.opacity(0.6))
                        .frame(width: 38 * max(0.02, min(1, CGFloat(destination.liveQueries) / CGFloat(maxDest))))
                }
                .frame(width: 38, height: 2)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .opacity(dimmed ? 0.42 : 1)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected
                      ? LinearGradient(colors: [Palette.signal.opacity(0.1), Palette.signal.opacity(0.02)],
                                       startPoint: .leading, endPoint: .trailing)
                      : LinearGradient(colors: [hovered ? Palette.text.opacity(0.035) : .clear,
                                                hovered ? Palette.text.opacity(0.035) : .clear],
                                       startPoint: .leading, endPoint: .trailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Palette.signal.opacity(0.24)
                              : (hovered ? Palette.text.opacity(0.062) : .clear), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(displayName), \(destination.domain), \(destination.category), \(destination.status.rawValue), \(destination.devices.count) devices")
        .help(destination.domain)
    }

    private var maxDest: Float {
        Swift.max(1, Float(runtime.network.destinations.map(\.liveQueries).max() ?? 1))
    }
}

struct WindowControl: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "History window", size: 6.5, color: Palette.dim.color, trackingEm: 0.16)
                Spacer()
                Text(Windows.label(hours: runtime.windowHours).uppercased())
                    .font(.atlasMono(8, .regular))
                    .foregroundColor(Palette.gold.color)
            }
            AtlasSlider(value: Binding(
                get: { Double(Windows.index(hours: runtime.windowHours)) },
                set: { newValue in
                    let idx = Int(newValue.rounded())
                    if Windows.stops.indices.contains(idx) {
                        runtime.setWindowHours(Windows.stops[idx].hours)
                    }
                }
            ), range: 0...18, step: 1, label: "History window")
            .padding(.top, 3)

            GeometryReader { geo in
                let span = CGFloat(max(1, Windows.stops.count - 1))
                let insetWidth = max(1, geo.size.width - 12)
                ZStack(alignment: .topLeading) {
                    Text("1h").position(x: 6, y: 3)
                    Text("1d").position(
                        x: 6 + insetWidth * CGFloat(Windows.index(hours: 24)) / span,
                        y: 3
                    )
                    Text("7d").position(x: geo.size.width - 6, y: 3)
                }
                .font(.atlasMono(5.6, .regular))
                .foregroundColor(Palette.faint.color)
            }
            .frame(height: 9)

            if metrics.showWindowCopy {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Devices and destination orbs active in the last \(Windows.label(hours: runtime.windowHours)) stay on the globe.")
                        .font(.atlasSans(8.2, .regular))
                        .foregroundColor(Palette.dim.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(Format.compact(runtime.windowStats.devices)) devices · \(Format.compact(runtime.windowStats.destinations)) destinations present")
                        .font(.atlasMono(7, .regular))
                        .foregroundColor(Palette.faint.color)
                }
                .padding(.top, 5)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [Color.rgba("100906", 0.94), Color.rgba("0b0604", 0.97)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .top) { Hairline() }
    }
}

struct RailSummary: View {
    @ObservedObject var runtime: AtlasRuntime
    var body: some View {
        let totals = runtime.totals
        let blockedShare = totals.queries > 0 ? Double(totals.blocked) / Double(totals.queries) * 100 : 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow(text: "Today", size: 6.5, color: Palette.dim.color, trackingEm: 0.16)
                Spacer()
                Text(String(format: "%.1f%% BLOCKED", blockedShare))
                    .font(.atlasMono(6.3, .regular))
                    .foregroundColor(Palette.faint.color)
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    LinearGradient(colors: [Palette.gold.opacity(0.5), Palette.gold.color],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * max(0.01, CGFloat(100 - blockedShare) / 100))
                    Palette.coral.color
                }
            }
            .frame(height: 3)
            .clipShape(Capsule())
            .padding(.top, 6)
            HStack {
                HStack(spacing: 4) {
                    Circle().fill(Palette.gold.color).frame(width: 3.5, height: 3.5)
                    Text(Format.count(totals.allowed))
                        .font(.atlasMono(6.2, .regular))
                        .foregroundColor(Palette.text2.color)
                    Text("ALLOWED")
                        .font(.atlasMono(6.2, .regular))
                        .foregroundColor(Palette.faint.color)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Palette.coral.color).frame(width: 3.5, height: 3.5)
                    Text(Format.count(totals.blocked))
                        .font(.atlasMono(6.2, .regular))
                        .foregroundColor(Palette.text2.color)
                    Text("BLOCKED")
                        .font(.atlasMono(6.2, .regular))
                        .foregroundColor(Palette.faint.color)
                }
            }
            .padding(.top, 7)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [Color.rgba("100906", 0.92), Color.rgba("0b0604", 0.96)],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(alignment: .top) { Hairline() }
    }
}

// ── right rail ───────────────────────────────────────────────────────────

struct TrafficRail: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        VStack(spacing: 0) {
            if let selection = runtime.selection {
                InspectorPanel(runtime: runtime, selection: selection, metrics: metrics)
            } else {
                trafficPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WarmGlass(radius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 35, x: 0, y: 24)
    }

    private var trafficPanel: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Eyebrow(text: "Queries", size: 8, color: Palette.gold.color, trackingEm: 0.12)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Circle().fill(Palette.sage.color).frame(width: 3.5, height: 3.5)
                            .shadow(color: Palette.sage.opacity(0.8), radius: 3)
                        Text("LIVE")
                            .font(.atlasMono(7, .regular))
                            .tracking(7 * 0.12)
                            .foregroundColor(Palette.sage.color)
                    }
                    RailCloseButton(left: false) { runtime.rightRailOpen = false }
                }
                Text("Recent queries")
                    .font(.atlasSans(metrics.railHeadTitleSize, .medium))
                    .tracking(-metrics.railHeadTitleSize * 0.032)
                    .foregroundColor(Palette.text.color)
                    .padding(.top, 8)
                if metrics.showRailCopy {
                    Text("Every query on this network, newest first. Select a row to follow the path.")
                        .font(.atlasSans(10.5, .regular))
                        .lineSpacing(2)
                        .foregroundColor(Palette.muted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 16)

            summaryGrid
                .padding(.horizontal, 15)
                .padding(.top, 13)

            if !metrics.tiny {
                RailSummary(runtime: runtime)
            }

            HStack {
                Eyebrow(text: "Latest", size: 7.5, color: Palette.gold.color, trackingEm: 0.14)
                Spacer()
                Text("\(runtime.feedCount)")
                    .font(.atlasMono(6.5, .regular))
                    .foregroundColor(Palette.faint.color)
            }
            .padding(.horizontal, 15)
            .padding(.top, 15)
            .overlay(alignment: .top) { Hairline().padding(.horizontal, 15).padding(.top, 12) }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    if runtime.feed.isEmpty {
                        Text("WAITING FOR MATCHING TRAFFIC…")
                            .font(.atlasMono(8, .regular))
                            .foregroundColor(Palette.faint.color)
                            .padding(.vertical, 30)
                    } else {
                        ForEach(runtime.feed) { row in
                            FeedIndexRow(runtime: runtime, row: row)
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if metrics.compact || metrics.short {
                    LinearGradient(colors: [.clear, Color.rgba("0b0604", 0.94)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 20)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 7) {
                Circle().fill(runtime.paused ? Palette.coral.color : Palette.sage.color)
                    .frame(width: 4, height: 4)
                    .shadow(color: (runtime.paused ? Palette.coral : Palette.sage).opacity(0.8), radius: 3)
                Text(runtime.paused ? "STREAM PAUSED · PRESS LIVE OR SPACE"
                     : (runtime.isLiveSource
                        ? "PI-HOLE LIVE · \(runtime.sourceEndpoint ?? "connected") · \(String(format: "%.1f", runtime.source.effectiveRate))/S"
                        : "DEMO SOURCE · \(String(format: "%.1f", runtime.source.effectiveRate))/S · LOCAL ONLY"))
                    .font(.atlasMono(6.7, .regular))
                    .tracking(6.7 * 0.07)
                    .foregroundColor(Palette.faint.color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Hairline() }
        }
    }

    private var summaryGrid: some View {
        let cells: [(String, String, String, Bool)] = [
            ("Queries today", Format.count(runtime.totals.queries), "", false),
            ("Blocked", Format.count(runtime.totals.blocked), "", true),
            ("Live rate", Format.rate(runtime.qps), "/s", false),
            ("Destinations", "\(runtime.windowStats.destinations)", "", false),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: cell.0, size: 6.5, color: Palette.dim.color, trackingEm: 0.1)
                    HStack(alignment: .firstTextBaseline, spacing: 1) {
                        Text(cell.1)
                            .font(.atlasMono(15, .regular))
                            .tracking(-0.45)
                            .foregroundColor(cell.3 ? Palette.coral.color : Palette.text2.color)
                            .monospacedDigit()
                        if !cell.2.isEmpty {
                            Text(cell.2)
                                .font(.atlasMono(8, .regular))
                                .foregroundColor(Palette.faint.color)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(Color.rgba("0b0604", 0.54))
            }
        }
        .background(Palette.text.opacity(0.062))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
    }
}

struct FeedIndexRow: View {
    @ObservedObject var runtime: AtlasRuntime
    let row: FeedRow
    @State private var hover = false

    private var selected: Bool {
        if case .path(let deviceId, let destinationId) = runtime.selection {
            return deviceId == row.deviceId && destinationId == row.destinationId
        }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(row.status == .blocked ? Palette.coral.color : Palette.gold.color)
                .frame(width: 5, height: 5)
                .shadow(color: (row.status == .blocked ? Palette.coral : Palette.gold).opacity(0.6), radius: 3.5)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(row.deviceName)
                        .font(.atlasMono(8, .regular))
                        .foregroundColor(Palette.signal.color)
                        .lineLimit(1)
                    Text("→")
                        .font(.atlasMono(7, .regular))
                        .foregroundColor(Palette.faint.color)
                    Text(row.domain)
                        .font(.atlasMono(8, .regular))
                        .foregroundColor(row.status == .blocked ? Palette.coralHot.color : Palette.text2.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(row.clock)
                    Circle().fill(Palette.faint.color).frame(width: 2, height: 2)
                    Text(row.status == .blocked ? "BLOCKED" : "ALLOWED")
                        .foregroundColor(row.status == .blocked ? Palette.coral.color : Palette.sage.opacity(0.8))
                    if let latency = row.latency {
                        Circle().fill(Palette.faint.color).frame(width: 2, height: 2)
                        Text("\(latency) MS")
                    }
                }
                .font(.atlasMono(6.5, .regular))
                .tracking(6.5 * 0.04)
                .foregroundColor(Palette.faint.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(selected ? Palette.signal.opacity(0.075)
                      : (hover ? Palette.signal.opacity(0.055) : .clear))
        )
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.text.opacity(0.045)).frame(height: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(row.deviceName) to \(row.domain), \(row.status.rawValue), \(row.clock)")
        .onHover { h in
            hover = h
            if h {
                runtime.hoveredPath = (row.deviceId, row.destinationId)
            } else if runtime.hoveredPath?.deviceId == row.deviceId,
                      runtime.hoveredPath?.destinationId == row.destinationId {
                runtime.hoveredPath = nil
            }
        }
        .onTapGesture {
            runtime.select(.path(deviceId: row.deviceId, destinationId: row.destinationId), toggle: false)
        }
    }
}
