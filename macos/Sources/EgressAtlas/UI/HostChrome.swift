import SwiftUI
import AppKit

// MARK: - Host rails

struct HostRails: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                HostNetworkRail(runtime: runtime, metrics: metrics)
                    .frame(width: metrics.railLeftWidth, height: metrics.railHeight)
                    .position(x: metrics.edge + metrics.railLeftWidth / 2,
                              y: metrics.railTop + metrics.railHeight / 2)
                    .offset(x: runtime.leftRailOpen ? 0 : -(metrics.railLeftWidth + 34))
                    .opacity(runtime.leftRailOpen ? 1 : 0)
                    .allowsHitTesting(runtime.leftRailOpen)
                    .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.46), value: runtime.leftRailOpen)

                HostTrafficRail(runtime: runtime, metrics: metrics)
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

struct HostNetworkRail: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics
    @State private var tab = 0
    @State private var hover: String?

    private var apps: [HostAppStat] { runtime.hostSnapshot.apps }
    private var domains: [HostDomainStat] { runtime.hostSnapshot.domains }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Eyebrow(text: "Host", size: 8, color: Palette.host.color, trackingEm: 0.12)
                    Spacer(minLength: 4)
                    Text(runtime.hostSnapshot.date == .distantPast ? "WAITING" : "THIS MAC")
                        .font(.atlasMono(7, .regular))
                        .tracking(7 * 0.08)
                        .foregroundColor(Palette.hostFaint.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Palette.host.opacity(0.18), lineWidth: 1))
                    RailCloseButton(left: true) { runtime.leftRailOpen = false }
                }
                Text(tab == 0 ? "Apps" : "Domains")
                    .font(.atlasSans(metrics.railHeadTitleSize, .medium))
                    .tracking(-metrics.railHeadTitleSize * 0.032)
                    .foregroundColor(Palette.hostText.color)
                    .padding(.top, 8)
                if metrics.showIndexCopy {
                    Text(tab == 0
                         ? "Processes moving bytes through this Mac. Select one to see its domains."
                         : "Domains inferred from this Mac's Pi-hole queries. IP:port means no domain was resolved.")
                        .font(.atlasSans(10.5, .regular))
                        .tracking(-0.05)
                        .lineSpacing(2)
                        .foregroundColor(Palette.hostMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
                HStack(spacing: 2) {
                    hostTab("Apps", count: apps.count, active: tab == 0,
                            accent: Palette.hostApp) { tab = 0 }
                    hostTab("Domains", count: domains.count, active: tab == 1,
                            accent: Palette.hostRemote) { tab = 1 }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.rgba("050d11", 0.45)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.hostText.opacity(0.062), lineWidth: 1))
                .padding(.top, 13)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            if !runtime.hostAvailable {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(Palette.hostFault.color)
                        Text("HOST MONITOR UNAVAILABLE")
                            .font(.atlasMono(6.6, .regular))
                            .tracking(6.6 * 0.1)
                            .foregroundColor(Palette.hostFault.color)
                    }
                    Text(runtime.hostNote ?? "macOS denied network statistics for this process.")
                        .font(.atlasSans(8.5, .regular))
                        .lineSpacing(2)
                        .foregroundColor(Palette.hostMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        let text = "Host monitor unavailable\n\(runtime.hostNote ?? "no note")"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Text("COPY DIAGNOSTICS")
                            .font(.atlasMono(6.4, .regular))
                            .tracking(0.4)
                            .foregroundColor(Palette.hostText2.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Palette.hostFaint.color.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(AtlasPlainButtonStyle())
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.rgba("14080a", 0.62)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Palette.hostFault.color.opacity(0.24), lineWidth: 1))
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 2) {
                    if runtime.hostSnapshot.apps.isEmpty {
                        Text(runtime.hostAvailable
                             ? (runtime.hostSnapshot.domains.isEmpty ? "WAITING FOR HOST TRAFFIC…"
                                : "NO APPS IN THIS SCOPE…")
                             : "MONITOR UNAVAILABLE")
                            .font(.atlasMono(8, .regular))
                            .foregroundColor(Palette.hostFaint.color)
                            .padding(.vertical, 34)
                    } else if tab == 0 {
                        ForEach(apps) { app in
                            HostAppRow(runtime: runtime, app: app,
                                       selected: runtime.hostSelection == .app(app.id),
                                       hovered: hover == app.id)
                                .onHover { hover = $0 ? app.id : nil }
                                .onTapGesture { runtime.selectHost(.app(app.id)) }
                                .onTapGesture(count: 2) {
                                    runtime.selectHost(.app(app.id))
                                    runtime.focusHostSelection()
                                }
                        }
                    } else {
                        ForEach(domains) { domain in
                            HostDomainRow(runtime: runtime, domain: domain,
                                          selected: runtime.hostSelection == .domain(domain.id),
                                          hovered: hover == domain.id)
                                .onHover { hover = $0 ? domain.id : nil }
                                .onTapGesture { runtime.selectHost(.domain(domain.id)) }
                                .onTapGesture(count: 2) {
                                    runtime.selectHost(.domain(domain.id))
                                    runtime.focusHostSelection()
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 46)
            }
            .frame(maxHeight: .infinity)

            Text(tab == 0
                 ? "Apps on this Mac · \(domainFooter)"
                 : "Remotes on this Mac · \(domainFooter)")
                .font(.atlasMono(6.7, .regular))
                .tracking(6.7 * 0.07)
                .lineSpacing(1)
                .foregroundColor(Palette.hostFaint.color)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.rgba("040a0d", 0.7))
                .overlay(alignment: .top) { Hairline() }
        }
        .background(CoolGlass(radius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 35, x: 0, y: 24)
    }

    private var domainFooter: String {
        if !runtime.isLiveSource && runtime.hostSnapshot.domains.contains(where: \.isDomain) {
            return "demo host sample · names are synthetic"
        }
        if runtime.hostDomainStatus != nil { return "Pi-hole names unavailable · IP:port only" }
        if !runtime.isLiveSource { return "connect a live Pi-hole for domain names" }
        if runtime.hostSnapshot.domains.contains(where: \.isDomain) {
            return "domain names inferred from Pi-hole"
        }
        return "waiting for the Pi-hole DNS log"
    }

    private func hostTab(_ label: String, count: Int, active: Bool,
                         accent: SRGB, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(label.uppercased())
                    .font(.atlasMono(7.5, .regular))
                    .tracking(7.5 * 0.09)
                    .foregroundColor(active ? accent.color : Palette.hostMeta.color)
                Text(" \(Format.compact(count))")
                    .font(.atlasMono(6.5, .regular))
                    .foregroundColor(Palette.hostFaint.color)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(active ? accent.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(active ? accent.opacity(0.16) : .clear, lineWidth: 1))
        }
        .buttonStyle(AtlasPlainButtonStyle())
    }
}

struct HostAppRow: View {
    @ObservedObject var runtime: AtlasRuntime
    let app: HostAppStat
    let selected: Bool
    let hovered: Bool

    private var maxRate: Double {
        max(1, runtime.hostSnapshot.apps.map(\.totalPerSecond).max() ?? 1)
    }

    var body: some View {
        HStack(spacing: 9) {
            HostAppGlyph(app: app)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.name)
                        .font(.atlasSans(12, .medium))
                        .tracking(-0.15)
                        .foregroundColor(selected ? Palette.hostText.color : Palette.hostText2.color)
                        .lineLimit(1)
                    if app.isSystem {
                        Text("SVC")
                            .font(.atlasMono(5.6, .regular))
                            .tracking(0.4)
                            .foregroundColor(Palette.hostApp.color)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(Palette.hostApp.opacity(0.3), lineWidth: 1))
                    }
                }
                Text(app.detail)
                    .font(.atlasMono(6.7, .regular))
                    .foregroundColor(Palette.hostMeta.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    Text("↓\(Format.rateCompact(app.rxPerSecond))")
                        .font(.atlasMono(6.8, .regular))
                        .foregroundColor(app.rxPerSecond > 0 ? Palette.hostGlow.color : Palette.hostFaint.color)
                    Text("↑\(Format.rateCompact(app.txPerSecond))")
                        .font(.atlasMono(6.8, .regular))
                        .foregroundColor(app.txPerSecond > 0 ? Palette.hostOut.color : Palette.hostFaint.color)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hostText.opacity(0.07))
                    Capsule().fill(Palette.hostApp.opacity(0.7))
                        .frame(width: 52 * max(0.02, min(1, CGFloat(app.totalPerSecond / maxRate))))
                }
                .frame(width: 52, height: 2)
                Text("\(app.socketCount) socket\(app.socketCount == 1 ? "" : "s")")
                    .font(.atlasMono(6.2, .regular))
                    .foregroundColor(Palette.hostFaint.color)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected
                  ? LinearGradient(colors: [Palette.hostApp.opacity(0.14), Palette.hostApp.opacity(0.02)],
                                   startPoint: .leading, endPoint: .trailing)
                  : LinearGradient(colors: [hovered ? Palette.hostText.opacity(0.035) : .clear,
                                            hovered ? Palette.hostText.opacity(0.035) : .clear],
                                   startPoint: .leading, endPoint: .trailing)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(selected ? Palette.hostApp.opacity(0.34)
                          : (hovered ? Palette.hostText.opacity(0.062) : .clear), lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(app.name), \(Format.dataRate(app.rxPerSecond)) in, \(Format.dataRate(app.txPerSecond)) out")
        .help("\(app.name) · \(app.detail)")
    }
}

struct HostDomainRow: View {
    @ObservedObject var runtime: AtlasRuntime
    let domain: HostDomainStat
    let selected: Bool
    let hovered: Bool

    private var maxRate: Double {
        max(1, runtime.hostSnapshot.domains.map(\.totalPerSecond).max() ?? 1)
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Palette.hostRemote.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.hostRemote.opacity(0.22), lineWidth: 1))
                Image(systemName: domain.isDomain ? "globe" : "network")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Palette.hostRemote.color)
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(domain.name)
                        .font(.atlasSans(12, .medium))
                        .tracking(-0.15)
                        .foregroundColor(selected ? Palette.hostText.color : Palette.hostText2.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if domain.confidence != .none || !domain.isDomain {
                        let confidenceTone = (domain.confidence == .none || domain.confidence == .service)
                            ? Palette.hostMuted : Palette.hostRemote
                        Text(domain.confidence.label.uppercased())
                            .font(.atlasMono(5.4, .regular))
                            .tracking(0.4)
                            .foregroundColor(confidenceTone.color)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(confidenceTone.opacity(0.32), lineWidth: 1))
                    }
                }
                Text("\(domain.service) · \(domain.appIDs.count) app\(domain.appIDs.count == 1 ? "" : "s")\(domain.isDomain ? "" : " · no DNS")")
                    .font(.atlasMono(6.7, .regular))
                    .foregroundColor(Palette.hostMeta.color)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    Text("↓\(Format.rateCompact(domain.rxPerSecond))")
                        .font(.atlasMono(6.8, .regular))
                        .foregroundColor(domain.rxPerSecond > 0 ? Palette.hostGlow.color : Palette.hostFaint.color)
                    Text("↑\(Format.rateCompact(domain.txPerSecond))")
                        .font(.atlasMono(6.8, .regular))
                        .foregroundColor(domain.txPerSecond > 0 ? Palette.hostOut.color : Palette.hostFaint.color)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.hostText.opacity(0.07))
                    Capsule().fill(Palette.hostRemote.opacity(0.7))
                        .frame(width: 52 * max(0.02, min(1, CGFloat(domain.totalPerSecond / maxRate))))
                }
                .frame(width: 52, height: 2)
                Text(domain.confidence.label.uppercased())
                    .font(.atlasMono(6.2, .regular))
                    .foregroundColor((domain.confidence == .none || domain.confidence == .service)
                                     ? Palette.hostFaint.color : Palette.hostRemote.opacity(0.8))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected
                  ? LinearGradient(colors: [Palette.hostRemote.opacity(0.15), Palette.hostRemote.opacity(0.02)],
                                   startPoint: .leading, endPoint: .trailing)
                  : LinearGradient(colors: [hovered ? Palette.hostText.opacity(0.035) : .clear,
                                            hovered ? Palette.hostText.opacity(0.035) : .clear],
                                   startPoint: .leading, endPoint: .trailing)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(selected ? Palette.hostRemote.opacity(0.36)
                          : (hovered ? Palette.hostText.opacity(0.062) : .clear), lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(domain.name), \(domain.confidence.label), \(Format.dataRate(domain.rxPerSecond)) in")
    }
}

struct HostAppGlyph: View {
    let app: HostAppStat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Palette.hostApp.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Palette.hostApp.opacity(0.2), lineWidth: 1))
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: app.isSystem ? "gearshape.2" : "app.dashed")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Palette.hostApp.color)
            }
        }
    }
}

// MARK: - Right rail

struct HostTrafficRail: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        VStack(spacing: 0) {
            if let selection = runtime.hostSelection {
                HostInspectorPanel(runtime: runtime, selection: selection, metrics: metrics)
            } else {
                feed
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CoolGlass(radius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.38), radius: 35, x: 0, y: 24)
    }

    private var feed: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Eyebrow(text: "Host traffic", size: 8, color: Palette.host.color, trackingEm: 0.12)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Circle().fill(runtime.hostPaused ? Palette.hostOut.color : Palette.hostMint.color)
                            .frame(width: 3.5, height: 3.5)
                            .shadow(color: Palette.hostMint.opacity(0.8), radius: 3)
                        Text(runtime.hostPaused ? "PAUSED" : "LIVE")
                            .font(.atlasMono(7, .regular))
                            .tracking(7 * 0.12)
                            .foregroundColor(runtime.hostPaused ? Palette.hostOut.color : Palette.hostMint.color)
                    }
                    RailCloseButton(left: false) { runtime.rightRailOpen = false }
                }
                Text("This Mac")
                    .font(.atlasSans(metrics.railHeadTitleSize, .medium))
                    .tracking(-metrics.railHeadTitleSize * 0.032)
                    .foregroundColor(Palette.hostText.color)
                    .padding(.top, 8)
                if metrics.showRailCopy {
                    Text("Byte flow from this Mac's sockets. Apps are processes; domains are inferred from Pi-hole queries.")
                        .font(.atlasSans(10.5, .regular))
                        .lineSpacing(2)
                        .foregroundColor(Palette.hostMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 16)

            HStack(spacing: 0) {
                hostStat("IN", Format.dataRate(runtime.hostSnapshot.rxPerSecond), Palette.hostIce)
                hostStat("OUT", Format.dataRate(runtime.hostSnapshot.txPerSecond), Palette.hostOut)
                hostStat("APPS", "\(runtime.hostSnapshot.apps.count)", Palette.hostApp)
                hostStat("DOMAINS", "\(runtime.hostSnapshot.domains.count)", Palette.hostRemote)
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)

            if runtime.hostDomainStatus != nil
                || (runtime.isLiveSource && !runtime.hostSnapshot.domains.contains(where: \.isDomain)) {
                HStack(spacing: 5) {
                    Circle().fill(Palette.hostFault.color).frame(width: 3.5, height: 3.5)
                    Text(runtime.hostDomainStatus == nil
                         ? "WAITING FOR PI-HOLE DNS LOG · IP:PORT FALLBACK"
                         : "PI-HOLE NAMES UNAVAILABLE · IP:PORT FALLBACK")
                        .font(.atlasMono(6.2, .regular))
                        .tracking(6.2 * 0.06)
                        .foregroundColor(Palette.hostFault.color)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 15)
                .padding(.top, 9)
            }

            HostRateChart(history: runtime.hostSnapshot.history,
                          maxRate: max(1, runtime.hostSnapshot.history.map { $0.rx + $0.tx }.max() ?? 1))
                .frame(height: 24)
                .padding(.horizontal, 15)
                .padding(.top, 8)

            HStack {
                Eyebrow(text: "Transfers", size: 7.5, color: Palette.host.color, trackingEm: 0.14)
                Spacer()
                Text("\(runtime.hostSnapshot.transfers.count)")
                    .font(.atlasMono(6.5, .regular))
                    .foregroundColor(Palette.hostFaint.color)
            }
            .padding(.horizontal, 15)
            .padding(.top, 15)
            .overlay(alignment: .top) { Hairline().padding(.horizontal, 15).padding(.top, 12) }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 0) {
                    if runtime.hostSnapshot.transfers.isEmpty {
                        Text("NO ATTRIBUTED TRANSFERS IN THIS SCOPE…")
                            .font(.atlasMono(8, .regular))
                            .foregroundColor(Palette.hostFaint.color)
                            .padding(.vertical, 30)
                    } else {
                        ForEach(Array(runtime.hostSnapshot.transfers.prefix(40))) { transfer in
                            HostFeedRow(runtime: runtime, transfer: transfer)
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.top, 4)
                .padding(.bottom, 42)
            }
            .frame(maxHeight: .infinity)

            Text(!runtime.isLiveSource && runtime.hostSnapshot.domains.contains(where: \.isDomain)
                 ? "DEMO HOST SAMPLE · NAMES ARE SYNTHETIC · THIS MAC ONLY"
                 : (runtime.hostDomainStatus == nil
                    ? (runtime.isLiveSource ? "DOMAIN NAMES INFERRED · THIS MAC ONLY"
                       : "CONNECT A LIVE PI-HOLE FOR DOMAIN NAMES · THIS MAC ONLY")
                    : "PI-HOLE NAMES UNAVAILABLE · IP:PORT ONLY"))
                .font(.atlasMono(6.4, .regular))
                .tracking(6.4 * 0.09)
                .foregroundColor(Palette.hostFaint.color)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.rgba("040a0d", 0.7))
                .overlay(alignment: .top) { Hairline() }
        }
    }

    private func hostStat(_ label: String, _ value: String, _ tone: SRGB) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.atlasMono(6.3, .regular))
                .tracking(6.3 * 0.1)
                .foregroundColor(Palette.hostMeta.color)
            Text(value)
                .font(.atlasMono(11.5, .regular))
                .tracking(-0.2)
                .foregroundColor(tone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HostFeedRow: View {
    @ObservedObject var runtime: AtlasRuntime
    let transfer: HostTransfer

    private var appName: String {
        runtime.hostSnapshot.apps.first { $0.id == transfer.appID }?.name ?? "App"
    }
    private var domainName: String {
        runtime.hostSnapshot.domains.first { $0.id == transfer.domainID }?.name
            ?? transfer.domain ?? "IP:port"
    }
    private var inbound: Bool { transfer.bytesIn > transfer.bytesOut }
    private var domainStat: HostDomainStat? {
        runtime.hostSnapshot.domains.first { $0.id == transfer.domainID }
    }
    private var endpoint: HostEndpointStat? {
        runtime.hostSnapshot.endpoints.first { $0.id == transfer.endpointID }
    }
    private var endpointText: String {
        guard let endpoint else { return "" }
        return "\(endpoint.remoteHost):\(endpoint.remotePort)"
    }

    var body: some View {
        Button {
            runtime.selectHost(.domain(transfer.domainID))
        } label: {
            HStack(spacing: 8) {
                Text(inbound ? "↓" : "↑")
                    .font(.atlasMono(8.5, .regular))
                    .foregroundColor(inbound ? Palette.hostGlow.color : Palette.hostOut.color)
                    .frame(width: 10)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(appName)
                            .font(.atlasSans(10, .medium))
                            .foregroundColor(Palette.hostApp.color)
                            .lineLimit(1)
                        Text("→")
                            .font(.atlasMono(7, .regular))
                            .foregroundColor(Palette.hostFaint.color)
                        Text(domainName)
                            .font(.atlasSans(10, .regular))
                            .foregroundColor(Palette.hostRemote.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 4) {
                        Text(transfer.service)
                            .font(.atlasMono(6.2, .regular))
                            .foregroundColor(Palette.hostFaint.color)
                        Text("·")
                            .font(.atlasMono(6.2, .regular))
                            .foregroundColor(Palette.hostFaint.color)
                        Text(inbound ? "IN" : "OUT")
                            .font(.atlasMono(6.2, .regular))
                            .foregroundColor(inbound ? Palette.hostGlow.color : Palette.hostOut.color)
                        if !endpointText.isEmpty {
                            Text(endpointText)
                                .font(.atlasMono(6.0, .regular))
                                .foregroundColor(Palette.hostMeta.color)
                                .lineLimit(1)
                        }
                        let confidence = domainStat?.confidence ?? .none
                        let confidenceTone = (confidence == .none || confidence == .service)
                            ? Palette.hostMuted : Palette.hostRemote
                        Text(confidence.label.uppercased())
                            .font(.atlasMono(5.6, .regular))
                            .tracking(0.3)
                            .foregroundColor(confidenceTone.color)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(confidenceTone.opacity(0.3), lineWidth: 1))
                    }
                }
                Spacer(minLength: 4)
                Text(Format.bytes(transfer.bytesIn + transfer.bytesOut))
                    .font(.atlasMono(7, .regular))
                    .foregroundColor(Palette.hostText2.color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .accessibilityLabel("\(appName) to \(domainName), \(Format.bytes(transfer.bytesIn + transfer.bytesOut))")
        .overlay(alignment: .bottom) { Hairline().padding(.leading, 26) }
    }
}

// MARK: - Inspector

struct HostInspectorPanel: View {
    @ObservedObject var runtime: AtlasRuntime
    let selection: HostSelection
    let metrics: Metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: "Inspector", size: 7.5, color: Palette.host.color, trackingEm: 0.14)
                Spacer()
                Button { runtime.clearHostSelection() } label: {
                    Text("CLOSE")
                        .font(.atlasMono(6.5, .regular))
                        .tracking(0.4)
                        .foregroundColor(Palette.hostMeta.color)
                }
                .buttonStyle(AtlasPlainButtonStyle())
            }
            .padding(.horizontal, 15)
            .padding(.top, 16)
            if let app = appContent {
                app
            } else if let domain = domainContent {
                domain
            } else {
                Text("Selection no longer present.")
                    .font(.atlasSans(10, .regular))
                    .foregroundColor(Palette.hostMeta.color)
                    .padding(15)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var appContent: AnyView? {
        guard case .app(let id) = selection,
              let app = runtime.hostScene.app(for: id) ?? runtime.hostSnapshot.apps.first(where: { $0.id == id })
        else { return nil }
        let domains = app.endpoints.compactMap { endpoint -> (String, Double)? in
            guard let name = endpoint.domain else { return nil }
            return (name, endpoint.rxPerSecond + endpoint.txPerSecond)
        }
        var grouped: [String: Double] = [:]
        for (name, rate) in domains { grouped[name, default: 0] += rate }
        let top = grouped.sorted { $0.value > $1.value }.prefix(6)
        let maxRate = max(1, top.map(\.value).max() ?? 1)
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                HostAppGlyph(app: app).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.atlasSans(17, .medium))
                        .foregroundColor(Palette.hostText.color)
                        .lineLimit(1)
                    Text(app.detail)
                        .font(.atlasMono(7, .regular))
                        .foregroundColor(Palette.hostMeta.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(app.isSystem ? "SERVICE" : "APP")
                    .font(.atlasMono(6, .regular))
                    .tracking(0.4)
                    .foregroundColor(Palette.hostApp.color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Palette.hostApp.opacity(0.3), lineWidth: 1))
            }
            .padding(.horizontal, 15)
            .padding(.top, 12)
            stats([
                ("In now", Format.dataRate(app.rxPerSecond), true),
                ("Out now", Format.dataRate(app.txPerSecond), false),
                ("Session in", Format.bytes(app.rxTotal), true),
                ("Session out", Format.bytes(app.txTotal), false),
            ])
            block("Top domains", value: "\(top.count)") {
                if top.isEmpty {
                    Text("No resolved domains yet.")
                        .font(.atlasSans(9.5, .regular))
                        .foregroundColor(Palette.hostMeta.color)
                } else {
                    ForEach(Array(top.enumerated()), id: \.offset) { pair in
                        HStack(spacing: 7) {
                            Text(pair.element.key)
                                .font(.atlasSans(10, .regular))
                                .foregroundColor(Palette.hostRemote.color)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(Format.dataRate(pair.element.value))
                                .font(.atlasMono(6.8, .regular))
                                .foregroundColor(Palette.hostText2.color)
                                .frame(width: 64, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            block("Endpoints", value: "\(app.endpoints.count)") {
                ForEach(app.endpoints.prefix(8)) { endpoint in
                    HStack(spacing: 7) {
                        Text(endpoint.displayName)
                            .font(.atlasMono(7.2, .regular))
                            .foregroundColor(Palette.hostRemote.color)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(endpoint.service)
                            .font(.atlasMono(6.2, .regular))
                            .foregroundColor(Palette.hostFaint.color)
                        Text(Format.dataRate(endpoint.rxPerSecond + endpoint.txPerSecond))
                            .font(.atlasMono(6.4, .regular))
                            .foregroundColor(Palette.hostMeta.color)
                    }
                    .padding(.vertical, 2)
                }
            }
            Button { runtime.focusHostSelection() } label: {
                Text("FOCUS")
                    .font(.atlasMono(7, .regular))
                    .tracking(0.6)
                    .foregroundColor(Palette.host.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.host.opacity(0.28), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .padding(.horizontal, 15)
            .padding(.top, 12)
        })
    }

    private var domainContent: AnyView? {
        guard case .domain(let id) = selection,
              let domain = runtime.hostScene.domain(for: id) ?? runtime.hostSnapshot.domains.first(where: { $0.id == id })
        else { return nil }
        let appNames = domain.appIDs.compactMap { appID in
            runtime.hostSnapshot.apps.first(where: { $0.id == appID })
        }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            Text(domain.name)
                .font(.atlasSans(17, .medium))
                .foregroundColor(Palette.hostText.color)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 15)
                .padding(.top, 12)
            HStack(spacing: 5) {
                Text("\(domain.service) · \(domain.scope.title)")
                    .font(.atlasMono(7, .regular))
                    .foregroundColor(Palette.hostMeta.color)
                if domain.confidence != .none || !domain.isDomain {
                    Text(domain.confidence.label.uppercased())
                        .font(.atlasMono(5.8, .regular))
                        .foregroundColor(Palette.hostRemote.color)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Palette.hostRemote.opacity(0.3), lineWidth: 1))
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 4)
            stats([
                ("In now", Format.dataRate(domain.rxPerSecond), true),
                ("Out now", Format.dataRate(domain.txPerSecond), false),
                ("Session in", Format.bytes(domain.rxTotal), true),
                ("Session out", Format.bytes(domain.txTotal), false),
            ])
            block("Apps", value: "\(appNames.count)") {
                ForEach(appNames) { app in
                    HStack(spacing: 7) {
                        HostAppGlyph(app: app).frame(width: 16, height: 16)
                        Text(app.name)
                            .font(.atlasSans(10, .regular))
                            .foregroundColor(Palette.hostApp.color)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.dataRate(app.rxPerSecond + app.txPerSecond))
                            .font(.atlasMono(6.6, .regular))
                            .foregroundColor(Palette.hostMeta.color)
                    }
                    .padding(.vertical, 3)
                }
            }
            block("Endpoints", value: "\(domain.endpointIDs.count)") {
                let endpoints = runtime.hostSnapshot.endpoints.filter { domain.endpointIDs.contains($0.id) }
                ForEach(endpoints.prefix(8)) { endpoint in
                    HStack(spacing: 7) {
                        Text("\(endpoint.remoteHost):\(endpoint.remotePort)")
                            .font(.atlasMono(7, .regular))
                            .foregroundColor(Palette.hostRemote.opacity(0.82))
                        Spacer(minLength: 4)
                        Text(Format.dataRate(endpoint.rxPerSecond + endpoint.txPerSecond))
                            .font(.atlasMono(6.4, .regular))
                            .foregroundColor(Palette.hostText2.color)
                    }
                    .padding(.vertical, 2)
                }
            }
            Text(domain.isDomain
                 ? "Domain inferred from this Mac's Pi-hole query timing and local resolution. It is not read from the packet."
                 : "No domain was resolved for this endpoint; showing IP:port.")
                .font(.atlasSans(9, .regular))
                .lineSpacing(2)
                .foregroundColor(Palette.hostMeta.color)
                .padding(.horizontal, 15)
                .padding(.top, 12)
            Button { runtime.focusHostSelection() } label: {
                Text("FOCUS")
                    .font(.atlasMono(7, .regular))
                    .tracking(0.6)
                    .foregroundColor(Palette.host.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.host.opacity(0.28), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .padding(.horizontal, 15)
            .padding(.top, 12)
        })
    }

    private func stats(_ cells: [(String, String, Bool)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 1) {
            ForEach(Array(cells.enumerated()), id: \.offset) { pair in
                let cell = pair.element
                VStack(alignment: .leading, spacing: 3) {
                    Text(cell.0.uppercased())
                        .font(.atlasMono(6.2, .regular))
                        .tracking(0.7)
                        .foregroundColor(Palette.hostFaint.color)
                    Text(cell.1)
                        .font(.atlasMono(11, .regular))
                        .foregroundColor(cell.2 ? Palette.hostGlow.color : Palette.hostOut.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Color.rgba("06141a", 0.8))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.hostText.opacity(0.07), lineWidth: 1))
        .padding(.horizontal, 15)
        .padding(.top, 13)
    }

    @ViewBuilder
    private func block<Content: View>(_ title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow(text: title, size: 6.8, color: Palette.host.color, trackingEm: 0.14)
                Spacer()
                Text(value)
                    .font(.atlasMono(6.4, .regular))
                    .foregroundColor(Palette.hostFaint.color)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.top, 5)
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
    }
}

// MARK: - Dock

struct HostDock: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    private var maxRate: Double {
        max(1, runtime.hostSnapshot.history.map { $0.rx + $0.tx }.max() ?? 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: metrics.tiny ? 9 : 16) {
                clock.layoutPriority(1)
                timeline.layoutPriority(2)
                transport.fixedSize(horizontal: true, vertical: false).layoutPriority(3)
            }
            .padding(.bottom, metrics.tiny ? 7 : 8)
            HStack(spacing: 12) {
                legend
                Spacer(minLength: 8)
                Rectangle().fill(Palette.hostText.opacity(0.08))
                    .frame(width: 1, height: 15).padding(.horizontal, 2)
                CameraHUD(runtime: runtime, compact: metrics.tiny)
            }
            .padding(.top, 5)
            .overlay(alignment: .top) { Hairline() }
        }
        .padding(.horizontal, metrics.tiny ? 10 : 13)
        .padding(.top, metrics.tiny ? 8 : 10)
        .padding(.bottom, metrics.tiny ? 8 : 9)
        .frame(width: metrics.dockWidth)
        .background(CoolGlass(radius: 11))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.46), radius: 30, x: 0, y: 20)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.host.opacity(0.06)).frame(height: 1)
                .padding(.top, 1).padding(.horizontal, 1)
        }
    }

    private var clock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Eyebrow(text: "Live", size: 6.5, color: Palette.hostMeta.color, trackingEm: 0.16)
                if !metrics.tiny {
                    Text("THIS MAC")
                        .font(.atlasMono(5.7, .regular))
                        .tracking(5.7 * 0.06)
                        .foregroundColor(Palette.host.color.opacity(0.8))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(metrics.tiny ? "↓\(Format.bytes(runtime.hostSnapshot.rxPerSecond))"
                     : "↓\(Format.dataRate(runtime.hostSnapshot.rxPerSecond))")
                    .font(.atlasMono(metrics.tiny ? 10 : 11, .regular))
                    .foregroundColor(Palette.hostGlow.color)
                    .lineLimit(1)
                Text(metrics.tiny ? "↑\(Format.bytes(runtime.hostSnapshot.txPerSecond))"
                     : "↑\(Format.dataRate(runtime.hostSnapshot.txPerSecond))")
                    .font(.atlasMono(metrics.tiny ? 10 : 11, .regular))
                    .foregroundColor(Palette.hostOut.color)
                    .lineLimit(1)
            }
            Text(runtime.hostPaused ? "PAUSED" : "STREAMING")
                .font(.atlasMono(6.3, .regular))
                .tracking(6.3 * 0.11)
                .foregroundColor(runtime.hostPaused ? Palette.coral.color : Palette.hostFaint.color)
        }
        .frame(minWidth: metrics.tiny ? 124 : 184, alignment: .leading)
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text("BANDWIDTH · LAST 90S")
                    .font(.atlasMono(6.2, .regular))
                    .tracking(6.2 * 0.07)
                    .foregroundColor(Palette.hostMeta.color)
                Spacer()
                Text(runtime.hostScopes.sorted { $0.rawValue < $1.rawValue }
                    .map(\.title).joined(separator: " + ").uppercased())
                    .font(.atlasMono(5.8, .regular))
                    .tracking(5.8 * 0.04)
                    .foregroundColor(Palette.hostFaint.color)
                    .lineLimit(1)
            }
            HostRateChart(history: runtime.hostSnapshot.history, maxRate: maxRate)
                .frame(height: 29)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Button {
                runtime.setHostPaused(!runtime.hostPaused)
            } label: {
                Group {
                    if runtime.hostPaused { PlayGlyph(size: 14, color: Palette.host.color) }
                    else { PauseGlyph(size: 14, color: Palette.hostMuted.color) }
                }
                .frame(width: 31, height: 31)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(runtime.hostPaused ? Palette.host.opacity(0.09) : Color.rgba("050d11", 0.72)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(runtime.hostPaused ? Palette.host.opacity(0.36) : Palette.hostText.opacity(0.11),
                                  lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .help(runtime.hostPaused ? "Resume host sampling" : "Pause host sampling")
            .accessibilityLabel(runtime.hostPaused ? "Resume host sampling" : "Pause host sampling")

            if metrics.tiny {
                Button {
                    runtime.settingsTab = .host
                    runtime.settingsOpen = true
                } label: {
                    Text("SCOPE")
                        .font(.atlasMono(6.8, .regular))
                        .tracking(0.5)
                        .foregroundColor(Palette.host.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Palette.host.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Palette.host.opacity(0.22), lineWidth: 1))
                }
                .buttonStyle(AtlasPlainButtonStyle())
                .help("Host scope")
                .accessibilityLabel("Host scope")
            } else {
                HStack(spacing: 1) {
                    ForEach(HostScope.allCases) { scope in
                        let active = runtime.hostScopes.contains(scope)
                        Button {
                            runtime.setHostScope(scope, enabled: !active)
                        } label: {
                            Text(scope == .loopback ? "LOOP" : scope.title.prefix(3).uppercased())
                                .font(.atlasMono(6.8, .regular))
                                .foregroundColor(active ? Palette.host.color : Palette.hostFaint.color)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 3)
                                    .fill(active ? Palette.host.opacity(0.09) : .clear))
                        }
                        .buttonStyle(AtlasPlainButtonStyle())
                        .help("\(scope.title) traffic")
                        .accessibilityLabel("\(scope.title) scope")
                        .accessibilityValue(active ? "On" : "Off")
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("050d11", 0.45)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.hostText.opacity(0.062), lineWidth: 1))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 11) {
            legendItem(Palette.hostGlow, "INBOUND")
            legendItem(Palette.hostOut, "OUTBOUND")
            legendItem(Palette.hostApp, "APP")
            legendItem(Palette.hostRemote, "DOMAIN")
            if !metrics.tiny {
                Text("LIVE ONLY · NO HISTORY")
                    .font(.atlasMono(5.8, .regular))
                    .tracking(5.8 * 0.06)
                    .foregroundColor(Palette.hostFaint.color)
            }
        }
    }

    private func legendItem(_ tone: SRGB, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tone.color).frame(width: 3.5, height: 3.5)
            Text(text)
                .font(.atlasMono(6.2, .regular))
                .tracking(6.2 * 0.08)
                .foregroundColor(Palette.hostMeta.color)
        }
    }
}

struct HostRateChart: View {
    let history: [HostRatePoint]
    let maxRate: Double

    var body: some View {
        GeometryReader { geo in
            let count = max(1, history.count)
            let width = max(1, geo.size.width / CGFloat(count))
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, point in
                    let total = point.rx + point.tx
                    let h = max(0.5, geo.size.height * CGFloat(total / maxRate))
                    let inPart = total > 0 ? h * CGFloat(point.rx / total) : 0
                    VStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(Palette.hostOut.opacity(0.9))
                            .frame(height: max(0.5, h - inPart))
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(Palette.hostGlow.opacity(0.9))
                            .frame(height: max(0.5, inPart))
                    }
                    .frame(width: max(1, width - 1))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
        }
        .accessibilityLabel("Host bandwidth, last 90 seconds")
    }
}

// MARK: - Top-bar helpers

struct HostGlobeSwitcher: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        HStack(spacing: 2) {
            segment(.dns, symbol: "circle.grid.cross", title: "DNS", tone: Palette.gold)
            segment(.host, symbol: "circle.hexagongrid", title: "HOST", tone: Palette.host)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.rgba("050d11", 0.72)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Palette.hostText.opacity(0.11), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Globe selector")
    }

    private func segment(_ kind: GlobeKind, symbol: String, title: String, tone: SRGB) -> some View {
        let active = runtime.displayedGlobe == kind
        return Button {
            runtime.focusGlobe(kind)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .regular))
                Text(title)
                    .font(.atlasMono(6.8, .regular))
                    .tracking(0.6)
            }
            .foregroundColor(active ? tone.color : Palette.hostMeta.color)
            .padding(.horizontal, metrics.narrowest ? 6 : 7)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(active ? tone.opacity(0.1) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(active ? tone.opacity(0.22) : .clear, lineWidth: 1))
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .help("Focus the \(kind == .dns ? "DNS" : "host") globe (G)")
        .accessibilityLabel("\(kind == .dns ? "DNS" : "Host") globe")
        .accessibilityValue(active ? "Focused" : "Background")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct HostScopeCountChip: View {
    @ObservedObject var runtime: AtlasRuntime
    var compact = false
    var body: some View {
        let scopes = runtime.hostScopes
        let label: String
        if scopes.contains(.loopback) {
            label = "ALL"
        } else if scopes == [.internet, .lan, .vpn] {
            label = compact ? "NET" : "INTERNET + LAN + VPN"
        } else {
            label = scopes.map(\.title).sorted().joined(separator: "+").uppercased()
        }
        return HStack(spacing: 4) {
            Circle().fill(Palette.host.color).frame(width: 3.5, height: 3.5)
            Text(label)
                .font(.atlasMono(6.8, .regular))
                .tracking(0.5)
                .foregroundColor(Palette.host.color)
                .lineLimit(1)
            if !compact {
                Text(Format.compact(runtime.hostSnapshot.domains.count))
                    .font(.atlasMono(6.4, .regular))
                    .foregroundColor(Palette.hostFaint.color)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("050d11", 0.72)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(Palette.host.opacity(0.2), lineWidth: 1))
        .help("Host traffic scope")
        .accessibilityLabel("Host traffic scope")
        .accessibilityValue(label)
    }
}


// MARK: - Help

struct HostHelpPanel: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow(text: "Host field guide", size: 8, color: Palette.hostMuted.color, trackingEm: 0.16)
                    Text("How to read this Mac")
                        .font(.atlasSans(20, .medium))
                        .tracking(-20 * 0.03)
                        .foregroundColor(Palette.hostText.color)
                }
                Spacer(minLength: 8)
                Button { runtime.helpOpen = false } label: {
                    CloseGlyph(size: 12, color: Palette.hostMuted.color)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("050d11", 0.4)))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Palette.hostText.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(AtlasPlainButtonStyle())
                .accessibilityLabel("Close host field guide")
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) { Hairline(color: Palette.hostText.opacity(0.1)) }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionKicker(title: "The two globes")
                    hostText("The warm globe is the DNS network. The cool globe is this Mac's live socket traffic. The inactive globe sits farther away, orbits behind the active one and never takes the camera. Click it, press G, or use ⌘1 / ⌘2 to focus a globe.")
                    SectionKicker(title: "Moving around").padding(.top, 12)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
                        gesture("Drag", "Orbit the active globe")
                        gesture("Right-drag", "Move the globe freely")
                        gesture("Scroll", "Zoom the field")
                        gesture("Click", "Select a body; background click focuses")
                        gesture("Double-click", "Fly to a body")
                    }
                    .padding(.top, 6)
                    SectionKicker(title: "Traffic").padding(.top, 12)
                    hostText("Apps and services are teal outer bodies. Remote domains are blue inner bodies; a domain is inferred from this Mac's Pi-hole dnsmasq log and local resolution. MATCH means an exact answer IP, LIKELY means several candidates shared an IP, PTR is reverse DNS, and IP ONLY means no name was resolved. IP:port is always the fallback and appears in the inspector.")
                    hostText("↓ inbound is ice; ↑ outbound is violet. Direction is also carried by the arrow and by the comet's travel. The scope chips in the dock choose Internet, LAN, VPN and Loopback; loopback is off by default because it double counts local IPC.")
                    hostText("HOST is live only. There is no replay, no history and no background collector. This app never captures packet payloads and never sends host traffic anywhere.")
                    SectionKicker(title: "Keys").padding(.top, 12)
                    keyRow("G", "toggle the focused globe")
                    keyRow("⌘1 / ⌘2", "focus DNS / HOST")
                    keyRow("Space", "pause or resume host sampling")
                    keyRow("F", "DNS outcome filter (DNS mode only)")
                    keyRow("Esc", "close panel or clear selection")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            HStack(spacing: 5) {
                Circle().fill(Palette.hostMint.color).frame(width: 3.5, height: 3.5)
                Text("LIVE ONLY · NO PACKET CAPTURE · NAMES INFERRED")
                    .font(.atlasMono(6.2, .regular))
                    .tracking(6.2 * 0.08)
                    .foregroundColor(Palette.hostFaint.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .overlay(alignment: .top) { Hairline(color: Palette.hostText.opacity(0.08)) }
        }
        .frame(width: metrics.helpWidth)
        .frame(height: min(metrics.helpHeight, max(280, metrics.height - metrics.railTop - 28)))
        .background(Palette.hostField.color.opacity(0.985))
        .background(CoolGlass(radius: 12, strong: true))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.hostText.opacity(0.11), lineWidth: 1))
        .shadow(color: .black.opacity(0.52), radius: 40, x: 0, y: 28)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How to read this Mac")
    }

    private func hostText(_ text: String) -> some View {
        Text(text)
            .font(.atlasSans(8.5, .regular))
            .lineSpacing(1.5)
            .foregroundColor(Palette.hostMuted.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 7)
    }

    private func gesture(_ key: String, _ copy: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key.uppercased())
                .font(.atlasMono(6.4, .regular))
                .tracking(6.4 * 0.08)
                .foregroundColor(Palette.host.color)
            Text(copy)
                .font(.atlasSans(9, .regular))
                .foregroundColor(Palette.hostMuted.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(Color.rgba("06141a", 0.7))
    }

    private func keyRow(_ key: String, _ copy: String) -> some View {
        HStack(spacing: 9) {
            Text(key)
                .font(.atlasMono(7, .regular))
                .foregroundColor(Palette.host.color)
                .frame(width: 58, alignment: .leading)
            Text(copy)
                .font(.atlasSans(9, .regular))
                .foregroundColor(Palette.hostMuted.color)
            Spacer()
        }
        .padding(.vertical, 3)
    }
}


struct BackgroundGlobeHint: View {
    let kind: GlobeKind
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(kind == .host ? Palette.host.color : Palette.gold.color)
                .frame(width: 3.5, height: 3.5)
            Text("\(kind == .host ? "HOST" : "DNS") · CLICK TO FOCUS")
                .font(.atlasMono(6.6, .regular))
                .tracking(6.6 * 0.09)
                .foregroundColor(kind == .host ? Palette.hostText.color : Palette.text2.color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(kind == .host ? Color.rgba("050d11", 0.88)
                                                 : Color.rgba("0c0704", 0.88)))
        .overlay(Capsule().strokeBorder((kind == .host ? Palette.host : Palette.gold)
            .opacity(0.32), lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityLabel("Focus the \(kind == .host ? "host" : "DNS") globe")
    }
}
