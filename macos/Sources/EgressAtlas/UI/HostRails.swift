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
                    RailCloseButton(action: { runtime.leftRailOpen = false }, left: true)
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
                    if let message = emptyStateMessage {
                        Text(message)
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

    /// Per-tab empty state. A domains-only snapshot must still list domains,
    /// and an empty selected tab gets a tab-specific message.
    private var emptyStateMessage: String? {
        if apps.isEmpty && domains.isEmpty {
            return runtime.hostAvailable ? "WAITING FOR HOST TRAFFIC…" : "MONITOR UNAVAILABLE"
        }
        if tab == 0 {
            return apps.isEmpty ? "NO APPS IN THIS SCOPE…" : nil
        }
        return domains.isEmpty ? "NO DOMAINS IN THIS SCOPE…" : nil
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
                HostRailRateStats(rx: app.rxPerSecond, tx: app.txPerSecond,
                                  total: app.totalPerSecond, maxRate: maxRate,
                                  tone: Palette.hostApp)
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
                HostRailRateStats(rx: domain.rxPerSecond, tx: domain.txPerSecond,
                                  total: domain.totalPerSecond, maxRate: maxRate,
                                  tone: Palette.hostRemote)
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
            if let icon = HostAppIcon.image(for: app) {
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

/// Main-thread icon cache for host app rows. AppKit icon lookup never runs on
/// the sampler queue; misses are remembered so a process without a usable
/// bundle is only probed once.
@MainActor
enum HostAppIcon {
    private static var cache: [String: NSImage] = [:]
    private static var misses: Set<String> = []

    static func image(for app: HostAppStat) -> NSImage? {
        if let cached = cache[app.id] { return cached }
        if misses.contains(app.id) { return nil }
        var image: NSImage?
        if app.path.contains(".app/") {
            image = NSWorkspace.shared.icon(forFile: app.path)
        }
        if image == nil, app.detail.contains("."),
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.detail).first {
            image = running.icon
        }
        if let image {
            cache[app.id] = image
        } else {
            misses.insert(app.id)
        }
        return image
    }
}

/// Rate readout and bar shared by the app and domain rows.
private struct HostRailRateStats: View {
    let rx: Double
    let tx: Double
    let total: Double
    let maxRate: Double
    let tone: SRGB

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 5) {
                Text("↓\(Format.rateCompact(rx))")
                    .font(.atlasMono(6.8, .regular))
                    .foregroundColor(rx > 0 ? Palette.hostGlow.color : Palette.hostFaint.color)
                Text("↑\(Format.rateCompact(tx))")
                    .font(.atlasMono(6.8, .regular))
                    .foregroundColor(tx > 0 ? Palette.hostOut.color : Palette.hostFaint.color)
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hostText.opacity(0.07))
                Capsule().fill(tone.opacity(0.7))
                    .frame(width: 52 * max(0.02, min(1, CGFloat(total / maxRate))))
            }
            .frame(width: 52, height: 2)
        }
    }
}
