import SwiftUI

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
                    Eyebrow(text: "Transfers", size: 8, color: Palette.host.color, trackingEm: 0.12)
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
                    RailCloseButton(action: { runtime.rightRailOpen = false }, left: false, host: true)
                }
                Text("Recent transfers")
                    .font(.atlasSans(metrics.railHeadTitleSize, .medium))
                    .tracking(-metrics.railHeadTitleSize * 0.032)
                    .foregroundColor(Palette.hostText.color)
                    .padding(.top, 8)
                if metrics.showRailCopy {
                    Text("Byte flow from this Mac's sockets, newest first. Apps are processes; domains are inferred from Pi-hole queries.")
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

            Text(runtime.hostDemoActive
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
        runtime.hostAppDisplayName(appID: transfer.appID)
    }
    private var domainName: String {
        if let domain = runtime.hostSnapshot.domains.first(where: { $0.id == transfer.domainID }) {
            return runtime.hostDestinationDisplayName(domain)
        }
        return runtime.hostDestinationDisplayName(name: transfer.domain ?? "IP:port")
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
                        let local = domainStat?.scope == .loopback
                        let confidence = domainStat?.confidence ?? .none
                        let confidenceTone = local ? Palette.hostMint
                            : ((confidence == .none || confidence == .service)
                               ? Palette.hostMuted : Palette.hostRemote)
                        Text(local ? "LOCAL" : confidence.label.uppercased())
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

// MARK: - Rate chart

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
