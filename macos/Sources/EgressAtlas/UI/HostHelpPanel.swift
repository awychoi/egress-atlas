import SwiftUI

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
                    SectionKicker(title: "The two globes", color: Palette.hostMuted.color, valueColor: Palette.hostFaint.color)
                    hostText("The warm globe is the DNS network. The cool globe is this Mac's live socket traffic. The inactive globe sits farther away, orbits behind the active one and never takes the camera. Click it, press G, or use ⌘1 / ⌘2 to focus a globe.")
                    SectionKicker(title: "Moving around", color: Palette.hostMuted.color, valueColor: Palette.hostFaint.color).padding(.top, 12)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)], spacing: 1) {
                        gesture("Drag", "Orbit the active globe")
                        gesture("Right-drag", "Move the globe freely")
                        gesture("Scroll", "Zoom the field")
                        gesture("Click", "Select a body; background click focuses")
                        gesture("Double-click", "Fly to a body")
                    }
                    .padding(.top, 6)
                    SectionKicker(title: "Traffic", color: Palette.hostMuted.color, valueColor: Palette.hostFaint.color).padding(.top, 12)
                    hostText("Apps and services are teal outer bodies. Remote domains are blue inner bodies; a domain is inferred from this Mac's Pi-hole dnsmasq log and local resolution. MATCH means an exact answer IP, LIKELY means several candidates shared an IP, PTR is reverse DNS, and IP ONLY means no name was resolved. IP:port is always the fallback and appears in the inspector.")
                    hostText("The camera-facing half of the field stays in focus; the far half dims with its effects and labels. Select a body to set a local display alias for an app or an IP/domain remote.")
                    hostText("↓ inbound is ice; ↑ outbound is violet. Direction is also carried by the arrow and by the comet's travel. Outbound traffic to an external site lands as a cold blast; a loopback address on this Mac answers with a mint pulse. The scope chips in the dock choose Internet, LAN, VPN and Loopback; loopback is off by default because it double counts local IPC.")
                    hostText("HOST is live only. There is no replay, no history and no background collector. This app never captures packet payloads and never sends host traffic anywhere.")
                    SectionKicker(title: "Keys", color: Palette.hostMuted.color, valueColor: Palette.hostFaint.color).padding(.top, 12)
                    keyRow("G", "toggle the focused globe")
                    keyRow("⌘1 / ⌘2", "focus DNS / HOST")
                    keyRow("Space", "pause or resume host sampling")
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
        .frame(height: min(660, max(280, metrics.height - metrics.railTop - 28)))
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
