import AppKit
import Foundation

/// The macOS icon grid. The supplied brand master is full-bleed; macOS 26+
/// expects app artwork to fill a rounded squircle with a transparent margin,
/// otherwise the Dock shrinks it into a gray tile ("squircle jail"). The
/// official artwork is clipped into the platform shape here, never redrawn.
enum BrandIconRenderer {
    static let canvas: CGFloat = 1024
    static let inset: CGFloat = 100
    static let cornerRadius: CGFloat = 185.4

    static func renderRep(_ source: NSImage, size: Int) -> NSBitmapImageRep? {
        guard size > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: size,
                                         pixelsHigh: size,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill(using: .copy)

        let scale = CGFloat(size) / canvas
        let edge = inset * scale
        let content = NSRect(x: edge, y: edge,
                             width: CGFloat(size) - edge * 2,
                             height: CGFloat(size) - edge * 2)
        let clip = NSBezierPath(roundedRect: content,
                                xRadius: cornerRadius * scale,
                                yRadius: cornerRadius * scale)
        clip.addClip()
        source.draw(in: content, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

/// Renders the official 1024 px app-icon master into the macOS iconset.
///
/// The source is the bundled `Resources/brand-app-icon.svg` master. There is
/// deliberately no redrawn fallback: if the master is missing, the build fails
/// rather than shipping an unofficial icon.
enum IconTool {
    static func run(path: String) {
        guard let sourcePath = ProcessInfo.processInfo.environment["ATLAS_ICON_SOURCE"],
              let brand = NSImage(contentsOfFile: sourcePath) else {
            let p = ProcessInfo.processInfo.environment["ATLAS_ICON_SOURCE"] ?? "(unset)"
            FileHandle.standardError.write(Data("icon error: cannot load official app icon at \(p)\n".utf8))
            exit(1)
        }

        let dir = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entries: [(String, Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        for (name, size) in entries {
            guard let rep = BrandIconRenderer.renderRep(brand, size: size),
                  let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("icon error: could not render \(name)\n".utf8))
                exit(1)
            }
            do {
                try png.write(to: dir.appendingPathComponent(name))
            } catch {
                FileHandle.standardError.write(Data("icon error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }
}
