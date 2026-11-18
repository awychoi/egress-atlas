import Foundation
import SwiftUI
import AppKit

/// sRGB color with the same hex values as the web's CSS tokens and config.js.
/// `linear` is what the MSL shaders see, mirroring Three's ColorManagement
/// (hex is authored in sRGB and converted to linear working space).
struct SRGB: Hashable, Sendable {
    let r: Float
    let g: Float
    let b: Float

    init(_ r: Float, _ g: Float, _ b: Float) {
        self.r = r; self.g = g; self.b = b
    }

    init(hex: String, alpha: Float = 1) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 {
            h = h.map { "\($0)\($0)" }.joined()
        }
        var value: UInt64 = 0
        Scanner(string: h).scanHexInt64(&value)
        let rr = Float((value >> 16) & 0xFF) / 255
        let gg = Float((value >> 8) & 0xFF) / 255
        let bb = Float(value & 0xFF) / 255
        self.init(rr, gg, bb)
    }

    var simd: SIMD3<Float> { SIMD3(r, g, b) }

    var linear: SIMD3<Float> {
        func f(_ c: Float) -> Float {
            c < 0.04045 ? c * 0.0773993808 : pow(c * 0.9478672986 + 0.0521327014, 2.4)
        }
        return SIMD3(f(r), f(g), f(b))
    }

    var linear4: SIMD4<Float> { SIMD4(linear, 1) }

    var color: Color {
        Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: 1)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
    }

    func opacity(_ a: Double) -> Color {
        Color(.sRGB, red: Double(r), green: Double(g), blue: Double(b), opacity: a)
    }

    static func mix(_ a: SRGB, _ b: SRGB, _ t: Float) -> SRGB {
        SRGB(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }
}

/// app/src/lab/config.js COLORS.
enum Palette {
    static let deep = SRGB(hex: "080402")
    static let bgDeep = SRGB(hex: "050201")
    static let field = SRGB(hex: "140b07")
    static let fieldWarm = SRGB(hex: "2a140c")
    static let gold = SRGB(hex: "f8c65b")
    static let gold2 = SRGB(hex: "dba94d")
    static let goldHot = SRGB(hex: "ffd27a")
    static let goldDeep = SRGB(hex: "d78335")
    static let bone = SRGB(hex: "f8eedb")
    static let signal = SRGB(hex: "45b8e8")
    static let signal2 = SRGB(hex: "1f87ad")
    static let signalIce = SRGB(hex: "a9e8ff")
    static let coral = SRGB(hex: "e08068")
    static let coralHot = SRGB(hex: "ff8a70")
    static let red = SRGB(hex: "e0564a")
    static let ember = SRGB(hex: "ff8a3c")
    static let white = SRGB(hex: "fff8e7")
    static let sage = SRGB(hex: "8fbea0")
    static let orbit = SRGB(hex: "a85a40")
    static let cacao = SRGB(hex: "2d150c")

    // CSS text tokens
    static let text = SRGB(hex: "f8eedb")
    static let text2 = SRGB(hex: "d5c1a9")
    static let muted = SRGB(hex: "a98d77")
    static let dim = SRGB(hex: "7d6757")
    static let faint = SRGB(hex: "514033")
    static let line = SRGB(hex: "f8eedb")
}

/// NodeView TINTS.
enum NodeTint {
    struct Tint {
        let ring: SRGB
        let hot: SRGB
        let hover: SRGB
        let core: SRGB
        let spark: SRGB
        let orbit: SRGB
        let flash: SRGB
        let orb: SRGB
        let dim: Float
    }

    static let allowed = Tint(
        ring: SRGB(hex: "f8c65b"),
        hot: SRGB(hex: "ffedc2"),
        hover: SRGB(hex: "45b8e8"),
        core: SRGB(hex: "ffd27a"),
        spark: SRGB(hex: "fff8e7"),
        orbit: SRGB(hex: "f8c65b"),
        flash: SRGB(hex: "ffd27a"),
        orb: SRGB(hex: "ffd27a"),
        dim: 1
    )

    static let blocked = Tint(
        ring: SRGB(hex: "e0564a"),
        hot: SRGB(hex: "ffd2c4"),
        hover: SRGB(hex: "ff7a5c"),
        core: SRGB(hex: "ff7d63"),
        spark: SRGB(hex: "ffe4d9"),
        orbit: SRGB(hex: "d94a3f"),
        flash: SRGB(hex: "ff8a70"),
        orb: SRGB(hex: "ff7d63"),
        dim: 0.85
    )
}

extension Color {
    static let atlasGold = Palette.gold.color
    static let atlasSignal = Palette.signal.color
    static let atlasCoral = Palette.coral.color
    static let atlasText = Palette.text.color
    static let atlasText2 = Palette.text2.color
    static let atlasMuted = Palette.muted.color
    static let atlasDim = Palette.dim.color
    static let atlasFaint = Palette.faint.color
    static let atlasSage = Palette.sage.color
    static let atlasIce = Palette.signalIce.color
}

// CSS rgba(…) over the warm panel substrate.
extension Color {
    static func rgba(_ hex: String, _ alpha: Double) -> Color {
        SRGB(hex: hex).opacity(alpha)
    }
}
