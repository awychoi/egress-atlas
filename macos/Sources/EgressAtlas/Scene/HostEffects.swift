import Foundation
import simd

/// HOST-field impact studies. They deliberately reuse the shared shock-ring,
/// flash and spark builders so the cold globe answers a transfer with the same
/// kind of authored motion the warm DNS globe uses, without borrowing its gold
/// palette.
enum HostFieldEffectStyle {
    /// Outbound traffic reaching an external site: a directional blast.
    case blast
    /// Traffic to an address on this Mac: concentric, spark-free pulses.
    case pulse
    /// A new app or destination condensing onto the stage.
    case birth
    /// A retiring app or destination folding away.
    case collapse
}

final class HostFieldEffect: EffectStudy {
    let duration: Float

    private let style: HostFieldEffectStyle
    private let node: NodeView?
    private let point: Vec3
    private let normal: Vec3
    private let radius: Float
    private let core: SRGB
    private let hot: SRGB
    private let rings: [ShockRing]
    private let flash: Flash?
    private let burst: SparkBurst?
    private let converge: SparkBurst?

    static let ice = SRGB(hex: "f2ffff")
    static let pulseMint = Palette.hostMint

    init(style: HostFieldEffectStyle, point: Vec3, normal: Vec3, radius: Float,
         node: NodeView?, local: Bool, rng: RNG) {
        self.style = style
        self.node = node
        self.point = point
        self.normal = normal.lengthSq > 0.001 ? normal.normalized : .up
        self.radius = max(0.24, radius)

        let cold = local || style == .collapse
        self.core = cold ? Palette.hostIce : HostFieldEffect.ice
        self.hot = cold ? Palette.hostMint : Palette.hostOutHot

        let n = self.normal
        let r = self.radius
        var rings: [ShockRing] = []
        var flash: Flash?
        var burst: SparkBurst?
        var converge: SparkBurst?

        switch style {
        case .blast:
            duration = 1.28
            rings = [
                ShockRing(point: point, normal: n, radius: r,
                          start: 0.65, end: 4.6, duration: 0.98,
                          core: core, tail: Palette.hostOut,
                          thickness: 0.052, rays: 26, seed: rng.next() * 9,
                          halfFactor: 1.48, opacity: 0.92),
                ShockRing(point: point, normal: n, radius: r,
                          start: 0.38, end: 2.9, duration: 1.18, delay: 0.05,
                          core: Palette.hostGlow, tail: Palette.hostDeep,
                          thickness: 0.03, rays: 12, seed: rng.next() * 9,
                          halfFactor: 1.7, opacity: 0.55, inner: true),
                ShockRing(point: point, normal: n, radius: r,
                          start: 1.15, end: 3.4, duration: 1.12, delay: 0.17,
                          core: Palette.hostIce, tail: Palette.host,
                          thickness: 0.022, rays: 18, seed: rng.next() * 9,
                          halfFactor: 1.85, opacity: 0.36),
            ]
            flash = Flash(point: point, size: r * 3.4, color: core,
                          haloColor: Palette.hostGlow, duration: 0.5,
                          haloScale: 2.9, opacity: 0.95)
            burst = SparkBurst(count: 42, origin: point, normal: n, radius: r * 0.78,
                               rng: rng, mode: "disc", speed: (1.6, 5.8),
                               tangential: 2.4, normalSpeed: 1.5, drag: 1.25,
                               life: (0.34, 1.0), size: (0.012, 0.06),
                               palette: [core, Palette.hostGlow, Palette.hostIce,
                                         Palette.hostOut, Palette.hostOutHot],
                               startJitter: 0.12, delay: (0, 0.06), opacity: 0.95)
        case .pulse:
            duration = 1.6
            rings = [
                ShockRing(point: point, normal: n, radius: r,
                          start: 0.82, end: 3.1, duration: 1.14,
                          core: Palette.hostIce, tail: Palette.hostMint,
                          thickness: 0.038, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.9, opacity: 0.98),
                ShockRing(point: point, normal: n, radius: r,
                          start: 0.7, end: 4.1, duration: 1.4, delay: 0.13,
                          core: Palette.hostMint, tail: Palette.hostApp,
                          thickness: 0.027, rays: 0, seed: rng.next() * 9,
                          halfFactor: 2.0, opacity: 0.64),
                ShockRing(point: point, normal: n, radius: r,
                          start: 1.0, end: 2.35, duration: 0.96, delay: 0.28,
                          core: Palette.hostGlow, tail: Palette.hostDeep,
                          thickness: 0.02, rays: 0, seed: rng.next() * 9,
                          halfFactor: 2.1, opacity: 0.44, inner: true),
            ]
            flash = Flash(point: point, size: r * 2.4, color: Palette.hostIce,
                          haloColor: Palette.hostMint, duration: 0.7,
                          haloScale: 2.5, opacity: 0.88)
        case .birth:
            duration = 1.15
            rings = [
                ShockRing(point: point, normal: n, radius: r,
                          start: 0.8, end: 2.55, duration: 0.82,
                          core: core, tail: hot,
                          thickness: 0.034, rays: local ? 0 : 14,
                          seed: rng.next() * 9, halfFactor: 1.7, opacity: 0.58),
            ]
            flash = Flash(point: point, size: r * 2.2, color: core,
                          haloColor: hot, duration: 0.48, delay: 0.04,
                          haloScale: 2.3, opacity: 0.72)
            converge = SparkBurst(count: local ? 16 : 24, origin: point, normal: n,
                                  radius: r * 3.0, rng: rng, mode: "disc",
                                  speed: (-8.2, -3.6), tangential: -0.9,
                                  normalSpeed: 0.3, drag: 1.8,
                                  life: (0.2, 0.44), size: (0.008, 0.035),
                                  palette: [core, Palette.hostGlow, Palette.hostIce,
                                            local ? Palette.hostMint : Palette.hostOut,
                                            hot],
                                  startJitter: 0.3, delay: (0, 0.10), opacity: 0.72)
            if !local {
                burst = SparkBurst(count: 12, origin: point, normal: n, radius: r * 0.5,
                                   rng: rng, mode: "ring", speed: (1.2, 3.2),
                                   tangential: 1.2, normalSpeed: 0.7, drag: 1.4,
                                   life: (0.22, 0.55), size: (0.008, 0.032),
                                   palette: [core, Palette.hostGlow, Palette.hostOutHot],
                                   startJitter: 0.1, delay: (0.12, 0.26), opacity: 0.55)
            }
        case .collapse:
            duration = 1.2
            rings = [
                ShockRing(point: point, normal: n, radius: r,
                          start: 2.5, end: 0.22, duration: 0.98,
                          core: Palette.hostGlow, tail: Palette.hostDeep,
                          thickness: 0.036, rays: 16, seed: rng.next() * 9,
                          halfFactor: 1.5, opacity: 0.72, inner: true),
                ShockRing(point: point, normal: n, radius: r,
                          start: 1.6, end: 0.35, duration: 1.16, delay: 0.06,
                          core: Palette.hostIce, tail: Palette.host2,
                          thickness: 0.024, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.9, opacity: 0.46),
            ]
            flash = Flash(point: point, size: r * 1.7, color: Palette.hostIce,
                          haloColor: Palette.hostDeep, duration: 0.42,
                          delay: 0.46, haloScale: 2.2, opacity: 0.62)
            converge = SparkBurst(count: 30, origin: point, normal: n,
                                  radius: r * 2.7, rng: rng, mode: "disc",
                                  speed: (-7.2, -2.8), tangential: -1.3,
                                  normalSpeed: 0.4, drag: 1.5,
                                  life: (0.26, 0.8), size: (0.012, 0.05),
                                  palette: [Palette.hostIce, Palette.hostGlow,
                                            Palette.hostOutHot, Palette.hostDeep],
                                  startJitter: 0.22, delay: (0, 0.14), opacity: 0.8)
        }

        self.rings = rings
        self.flash = flash
        self.burst = burst
        self.converge = converge
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let center = node?.basePosition ?? point
        let offset = center - point
        let t = clamp01(age / duration)

        for ring in rings {
            ring.append(age: age, offset: offset, draw: draw)
        }
        flash?.append(age: age, offset: offset, draw: draw)
        burst?.update(dt: dt, offset: offset, draw: draw)
        converge?.update(dt: dt, offset: offset, draw: draw)

        // A cool core bloom that ties the ring and sparks together. The warm
        // effect families use the same device; the HOST version keeps it
        // short so a busy stream does not wash the constellation white.
        let bloomIn = clamp01(age / 0.16)
        let bloomOut = pow(1 - t, 1.8)
        let bloomSize: Float
        switch style {
        case .blast, .birth: bloomSize = radius * (1.4 + easeOutCubic(bloomIn) * 4.4)
        case .pulse: bloomSize = radius * (1.6 + easeOutCubic(bloomIn) * 2.2)
        case .collapse: bloomSize = radius * (2.2 - easeOutCubic(bloomIn) * 1.5)
        }
        draw.sprites.append(.glow(center, size: bloomSize, color: core,
                                  opacity: bloomOut * (style == .pulse ? 0.16 : 0.12)))

        // A thin directional foil on an external blast makes the outgoing
        // path legible even when the destination is small.
        if style == .blast, age < 0.7 {
            let head = easeOutCubic(clamp01(age / 0.45))
            let tailDir = -normal
            let a = center + tailDir * radius * 4.2 * (1 - head)
            let b = center + tailDir * radius * 4.2 * (1 - head) + normal * radius * 0.32
            draw.addLine(a, b, rgba(Palette.hostOutHot, pow(1 - head, 1.6) * 0.55))
        }
        _ = ctx
    }
}
