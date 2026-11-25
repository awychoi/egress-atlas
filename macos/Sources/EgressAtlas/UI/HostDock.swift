import SwiftUI

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
