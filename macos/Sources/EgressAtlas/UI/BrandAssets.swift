import SwiftUI
import AppKit

/// Supplied brand assets. The in-app lockup is the workbench SVG from
/// `docs/assets/`; the older mark, wordmark and tagline PNGs remain only as a
/// fallback. The app icon is rendered from the official 1024 px SVG into the
/// macOS squircle (see `BrandIconRenderer`).
enum BrandAssets {
    static func image(_ name: String) -> NSImage? {
        for ext in ["png", "svg"] {
            let candidates: [URL?] = [
                Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources"),
                Bundle.module.url(forResource: name, withExtension: ext),
            ]
            for case let url? in candidates {
                if let image = NSImage(contentsOf: url) { return image }
            }
        }
        return nil
    }

    /// The icon used by the Dock, the app switcher and the About panel.
    ///
    /// A bundled launch already gets `AppIcon.icns` from Launch Services, but a
    /// direct `swift run` / bare executable has no bundle icon and falls back to
    /// the generic `exec` tile. Setting `NSApplication.applicationIconImage`
    /// explicitly makes every launch path use the official artwork.
    /// A template copy keeps the supplied wordmark's vector detail while
    /// letting the HOST lockup tint it with the cold text token.
    static func templateImage(_ name: String) -> NSImage? {
        guard let source = image(name) else { return nil }
        let copy = source.copy() as? NSImage ?? source
        copy.isTemplate = true
        return copy
    }

    static func appIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            return icon
        }
        guard let source = image("brand-app-icon") else { return nil }
        let icon = NSImage(size: NSSize(width: 1024, height: 1024))
        for side in [16, 32, 64, 128, 256, 512, 1024] {
            if let rep = BrandIconRenderer.renderRep(source, size: side) {
                icon.addRepresentation(rep)
            }
        }
        return icon.representations.isEmpty ? nil : icon
    }
}

/// The supplied workbench lockup: app tile, wordmark and tagline in one SVG.
/// Kept as vector artwork so it stays crisp at every window size.
struct BrandLockup: View {
    var height: CGFloat = 50
    var host: Bool = false

    var body: some View {
        Group {
            if host {
                HostBrandLockup(height: height)
            } else if let image = BrandAssets.image("brand-workbench") {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                HStack(spacing: height * 0.2) {
                    BrandMark(side: height * 0.76)
                    VStack(alignment: .leading, spacing: height * 0.04) {
                        BrandWordmark(height: height * 0.4)
                        BrandTagline(height: height * 0.22)
                    }
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel(host ? "Egress Atlas. Live sockets, mapped."
                                 : "Egress Atlas. DNS traffic, mapped.")
    }
}

/// HOST mode needs the same lockup geometry in the cool climate: a cold app
/// tile, the supplied wordmark, and a HOST-specific tagline. The warm artwork
/// is never recoloured in place, so DNS focus is untouched.
private struct HostBrandLockup: View {
    var height: CGFloat

    var body: some View {
        HStack(spacing: height * 0.19) {
            HostBrandTile(side: height)
            VStack(alignment: .leading, spacing: height * 0.035) {
                if let image = BrandAssets.templateImage("brand-wordmark") {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundColor(Palette.hostText.color)
                        .frame(height: height * 0.325)
                } else {
                    Text("EGRESS ATLAS")
                        .font(.system(size: height * 0.40, weight: .bold))
                        .foregroundColor(Palette.hostText.color)
                }
                let taglineSize = max(6.0, height * 0.13)
                Text("LIVE SOCKETS, MAPPED")
                    .font(.system(size: taglineSize, weight: .regular, design: .monospaced))
                    .tracking(taglineSize * 0.15)
                    .foregroundColor(Palette.host.color)
                    .padding(.leading, height * 0.10)
                    .lineLimit(1)
            }
            .overlay(alignment: .topLeading) {
                // Same short rule that sits above the DNS wordmark.
                Rectangle()
                    .fill(Palette.host.color)
                    .frame(width: height * 0.62, height: max(1, height * 0.03))
                    .offset(y: -height * 0.09)
            }
            .offset(y: height * 0.06)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct HostBrandTile: View {
    var side: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                .fill(LinearGradient(
                    stops: [
                        .init(color: Palette.hostPanelTop.opacity(0.98), location: 0),
                        .init(color: Palette.hostBg.color, location: 0.72),
                        .init(color: SRGB(hex: "040a0d").color, location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            RadialGradient(colors: [Palette.host.opacity(0.20), .clear],
                           center: UnitPoint(x: 0.5, y: 0.46),
                           startRadius: 0, endRadius: side * 0.55)
            if let image = BrandAssets.image("brand-mark-host") {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(side * 0.02)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
            .strokeBorder(Palette.hostText.opacity(0.18), lineWidth: 1))
        .shadow(color: Palette.host.opacity(0.16), radius: side * 0.18)
    }
}

struct BrandMark: View {
    var side: CGFloat = 37
    var host: Bool = false
    var body: some View {
        Group {
            if let image = BrandAssets.image(host ? "brand-mark-host" : "brand-mark") {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Circle()
                    .fill(Palette.gold.color)
                    .frame(width: side * 0.6, height: side * 0.6)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

struct BrandWordmark: View {
    var height: CGFloat = 22
    var body: some View {
        Group {
            if let image = BrandAssets.image("brand-wordmark") {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Text("EGRESS ATLAS")
                    .font(.system(size: height, weight: .bold))
                    .foregroundColor(Palette.bone.color)
            }
        }
        .frame(height: height)
        .accessibilityLabel("Egress Atlas")
    }
}

struct BrandTagline: View {
    var height: CGFloat = 15
    var body: some View {
        Group {
            if let image = BrandAssets.image("brand-tagline") {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Text("DNS TRAFFIC, MAPPED")
                    .font(.system(size: max(9, height * 0.7), weight: .medium, design: .monospaced))
                    .foregroundColor(Palette.gold.color)
            }
        }
        .frame(height: height)
        .accessibilityLabel("DNS traffic, mapped")
    }
}

/// The personal abacus mark used by the understated byline in Settings → About.
struct WychoiAvatar: View {
    var side: CGFloat = 17
    var body: some View {
        Group {
            if let image = BrandAssets.image("brand-wychoi") {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                    .fill(Palette.dim.color)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .strokeBorder(Palette.text.opacity(0.12), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

/// Understated personal credit for Settings → About. The whole lockup is the
/// link target so the mark is not a dead end beside a live label.
struct WychoiCredit: View {
    @State private var hovering = false
    private let url = URL(string: "https://wychoi.com")!

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 7) {
                WychoiAvatar(side: 17)
                Text("by wychoi")
                    .font(.atlasSans(9.4, .regular))
                    .underline(hovering)
                    .foregroundColor(hovering ? Palette.text2.color : Palette.dim.color)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("wychoi.com")
        .accessibilityLabel("by wychoi")
        .accessibilityHint("Opens wychoi.com in your browser")
    }
}
