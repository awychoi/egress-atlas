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
    var body: some View {
        Group {
            if let image = BrandAssets.image("brand-workbench") {
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
        .accessibilityLabel("Egress Atlas. DNS traffic, mapped.")
    }
}

struct BrandMark: View {
    var side: CGFloat = 37
    var body: some View {
        Group {
            if let image = BrandAssets.image("brand-mark") {
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
