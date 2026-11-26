import SwiftUI

struct ToastView: View {
    let toast: ToastMessage
    var host: Bool = false

    private var color: Color {
        switch toast.tone {
        case .gold: return Palette.gold.color
        case .signal: return Palette.signalIce.color
        case .coral: return Palette.coralHot.color
        }
    }

    private var border: Color {
        switch toast.tone {
        case .gold: return Palette.gold.opacity(0.2)
        case .signal: return Palette.signal.opacity(0.3)
        case .coral: return Palette.coral.opacity(0.32)
        }
    }

    var body: some View {
        Text(toast.text.uppercased())
            .font(.atlasMono(7.4, .regular))
            .tracking(7.4 * 0.08)
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(host ? Color.rgba("050d11", 0.88) : Color.rgba("120a06", 0.82))
            )
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(border, lineWidth: 1))
            .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 8)
            .fixedSize()
    }
}

struct BootOverlay: View {
    @ObservedObject var runtime: AtlasRuntime
    @State private var scan: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            ZStack {
                let host = runtime.displayedGlobe == .host
                Color.rgba(host ? "040a0d" : "060301", 1)
                RadialGradient(colors: [Color.rgba(host ? "0c1b22" : "2a140c", host ? 0.72 : 0.52), .clear],
                               center: UnitPoint(x: 0.5, y: 0.48),
                               startRadius: 0, endRadius: min(geo.size.width, geo.size.height) * 0.7)
                VStack(spacing: 14) {
                    BrandLockup(height: 52, host: host)
                    VStack(spacing: 5) {
                        Text(host ? "Reading this Mac's sockets" : "Calibrating egress field")
                            .font(.atlasSans(15, .medium))
                            .tracking(-0.14)
                            .foregroundColor(host ? Palette.hostText2.color : Palette.text2.color)
                    }
                    ZStack(alignment: .leading) {
                        Rectangle().fill(host ? Palette.hostText.opacity(0.07) : Palette.text.opacity(0.07))
                            .frame(width: 280, height: 1)
                        LinearGradient(colors: [.clear, host ? Palette.host.color : Palette.gold.color, .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 118, height: 1)
                            .offset(x: scan * 280)
                    }
                    .frame(width: 280, height: 1)
                    .clipped()
                    Text(host ? "THIS MAC · LIVE SOCKETS · NO HISTORY"
                              : "MAPPING \(runtime.network.devices.count) DEVICES TO THE SHELL · \(runtime.network.destinations.count) DESTINATIONS INSIDE")
                        .font(.atlasMono(6.5, .regular))
                        .tracking(6.5 * 0.1)
                        .foregroundColor(host ? Palette.hostFaint.color : Palette.faint.color)
                }
                .frame(width: 280)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 1.4).repeatForever(autoreverses: false)) {
                scan = 1.2
            }
        }
        .transition(.opacity)
    }
}

struct AtlasCommandScrim: View {
    var body: some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
    }
}

struct AtlasChrome: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if metrics.showFieldCaption {
                    FieldCaption(runtime: runtime)
                        .position(x: geo.size.width / 2, y: 104)
                        .zIndex(4)
                }

                if let hint = runtime.inactiveGlobeHint(viewSize: geo.size) {
                    BackgroundGlobeHint(kind: hint.kind)
                        .position(x: min(max(hint.point.x, 90), geo.size.width - 90),
                                  y: min(max(hint.point.y + hint.radius + 16, 120),
                                         geo.size.height - 150))
                        .zIndex(7)
                        .transition(.opacity)
                }

                AtlasRails(runtime: runtime, metrics: metrics)
                    .zIndex(6)

                AtlasTopBar(runtime: runtime, metrics: metrics)
                    .frame(width: geo.size.width, height: 100, alignment: .top)
                    .zIndex(10)

                VStack {
                    Spacer()
                    AtlasDock(runtime: runtime, metrics: metrics)
                        .padding(.bottom, 18)
                        .popover(isPresented: $runtime.replayJumpOpen, arrowEdge: .bottom) {
                            ReplayJumpCard(runtime: runtime, metrics: metrics)
                        }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                .zIndex(8)

                if let toast = runtime.toast {
                    VStack {
                        Spacer()
                        ToastView(toast: toast, host: runtime.displayedGlobe == .host)
                            .padding(.bottom, 178)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .zIndex(15)
                    .animation(.easeOut(duration: 0.25), value: toast.id)
                }

                if runtime.settingsOpen {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { runtime.settingsOpen = false }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .zIndex(13)
                    SettingsPanel(runtime: runtime, metrics: metrics)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, metrics.railTop)
                        .padding(.trailing, metrics.edge)
                        .zIndex(14)
                        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.36), value: runtime.settingsOpen)
                }

                if runtime.helpOpen {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { runtime.helpOpen = false }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .zIndex(13)
                    Group {
                        if runtime.displayedGlobe == .host {
                            HostHelpPanel(runtime: runtime, metrics: metrics)
                        } else {
                            HelpPanel(runtime: runtime, metrics: metrics)
                        }
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, metrics.railTop)
                        .padding(.trailing, metrics.edge)
                        .zIndex(14)
                        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.36), value: runtime.helpOpen)
                }

                if runtime.commandOpen {
                    CommandPalette(runtime: runtime)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .zIndex(25)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { enforceRailExclusivity(width: geo.size.width) }
            .onChange(of: geo.size.width) { width in enforceRailExclusivity(width: width) }
        }
    }

    private func enforceRailExclusivity(width: CGFloat) {
        guard width <= 1020, runtime.leftRailOpen, runtime.rightRailOpen else { return }
        runtime.rightRailOpen = false
    }
}
