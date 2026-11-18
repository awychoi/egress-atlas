import Foundation
import simd

// Disappearance studies from app/src/lab/effects/death/*.js, including the
// shared planet helper that gives all four their common body.

struct RockPalette {
    let rockA: SRGB
    let rockB: SRGB
    let accent: SRGB
    let hot: SRGB
    let ember: SRGB
    let dust: SRGB
    let ice: SRGB

    static let allowed = RockPalette(
        rockA: SRGB(hex: "5c3821"), rockB: SRGB(hex: "180b07"),
        accent: Palette.gold, hot: SRGB(hex: "ff8a3c"),
        ember: Palette.coral, dust: Palette.bone, ice: Palette.signalIce)
    static let blocked = RockPalette(
        rockA: SRGB(hex: "5c211d"), rockB: SRGB(hex: "190707"),
        accent: Palette.coral, hot: SRGB(hex: "ff8a70"),
        ember: SRGB(hex: "d94f43"), dust: SRGB(hex: "ffd6c9"),
        ice: SRGB(hex: "ffb0a0"))

    static func forNode(_ node: NodeView) -> RockPalette {
        node.status == .blocked ? .blocked : .allowed
    }
}

struct PlanetDrawState {
    let center: Vec3
    let baseR: Float
    let palette: RockPalette
}

func appendPlanet(_ draw: DrawList, center: Vec3, baseR: Float, palette: RockPalette,
                  opacity: Float, heat: Float, crack: Float, scale: Float,
                  squashY: Float = 1, rotationY: Float = 0, haloOpacity: Float) {
    let o = clamp01(opacity)
    guard o > 0.003 else { return }
    let rr = baseR * scale
    let model = Mat4.translation(center)
        * Mat4.rotation(quaternion: simd_quatf(angle: rotationY, axis: .up))
        * Mat4.scale(Vec3(rr, rr * squashY, rr))
    draw.planets.append(PlanetUniforms(
        model: model,
        rockA: rgba(palette.rockA, o),
        rockB: SIMD4(palette.rockB.linear, clamp01(heat)),
        accent: SIMD4(palette.accent.linear, clamp01(crack)),
        hot: SIMD4(palette.hot.linear, 0)
    ))
    let atmoModel = Mat4.translation(center)
        * Mat4.rotation(quaternion: simd_quatf(angle: rotationY, axis: .up))
        * Mat4.scale(Vec3(rr * 1.045, rr * 1.045 * squashY, rr * 1.045))
    draw.planetAtmospheres.append(PlanetAtmoUniforms(
        model: atmoModel,
        color: SIMD4(palette.accent.linear, o * (0.34 + heat * 0.5))
    ))
    draw.sprites.append(.glow(center, size: baseR * 3.4 * scale,
                              color: palette.accent, opacity: o * haloOpacity))
}

final class DebrisField {
    struct Piece {
        let dir: Vec3
        let tangent: Vec3
        let start: Float
        let speed: Float
        let tangential: Float
        let normal: Float
        let drag: Float
        let spin: Float
        let axis: Vec3
        let len: Float
        let wide: Float
        let thick: Float
        let color: SRGB
    }
    let center: Vec3
    let pieces: [Piece]

    init(center: Vec3, radius: Float, rng: RNG, palette: RockPalette, count: Int = 28,
         speed: (Float, Float) = (1.2, 3.6), tangential: Float = 1.2,
         normalSpeed: Float = 0.55, drag: Float = 0.55,
         size: (Float, Float) = (0.12, 0.3), startRadius: Float = 0.72) {
        self.center = center
        var built: [Piece] = []
        let colors: [SRGB] = [palette.rockA, palette.ember, palette.hot, palette.accent, palette.dust]
        for _ in 0..<count {
            let phi = rng.next() * TAU
            let cosTheta = rng.next() * 2 - 1
            let sinTheta = sqrt(max(0, 1 - cosTheta * cosTheta))
            let dir = Vec3(cos(phi) * sinTheta, cosTheta, sin(phi) * sinTheta)
            let tangent = Vec3(-sin(phi), 0, cos(phi))
            let length = size.0 + rng.next() * (size.1 - size.0)
            let width = length * (0.22 + rng.next() * 0.4)
            built.append(Piece(
                dir: dir, tangent: tangent,
                start: radius * startRadius * (0.7 + rng.next() * 0.5),
                speed: speed.0 + rng.next() * (speed.1 - speed.0),
                tangential: (rng.next() * 2 - 1) * tangential,
                normal: (rng.next() * 2 - 1) * normalSpeed,
                drag: drag * (0.65 + rng.next() * 0.7),
                spin: (rng.next() * 2 - 1) * 7.2,
                axis: Vec3(rng.next() * 2 - 1, rng.next() * 2 - 1, rng.next() * 2 - 1).normalized,
                len: length,
                wide: width,
                thick: width * (0.32 + rng.next() * 0.25),
                color: colors[Int(rng.next() * Float(colors.count)) % colors.count]
            ))
        }
        pieces = built
    }

    func append(age: Float, opacity: Float, offset: Vec3, draw: DrawList) {
        let o = clamp01(opacity)
        guard o > 0.002, age > 0 else { return }
        for d in pieces {
            let travel = d.drag > 0.0001 ? (1 - exp(-d.drag * age)) / d.drag : age
            let position = center + offset
                + d.dir * (d.start + d.speed * travel)
                + d.tangent * (d.tangential * travel)
                + Vec3.up * (d.normal * travel)
            let q = simd_quatf(angle: d.spin * age, axis: d.axis)
            let shrink = 0.7 + min(1, age * 2.4) * 0.45
            let model = Mat4.compose(position: position, quaternion: q,
                                     scale: Vec3(d.wide * shrink, d.len * shrink, d.thick * shrink))
            draw.addMesh(.tetra, MeshInstance(model: model, color: rgba(d.color, o)))
        }
    }
}

final class OrbitRingLines {
    let center: Vec3
    let radius: Float
    let color: SRGB
    let baseOpacity: Float
    let baseRotation: Mat4
    var spin: Float = 0

    init(center: Vec3, radius: Float, color: SRGB, opacity: Float,
         rotation: Mat4 = .identity()) {
        self.center = center
        self.radius = radius
        self.color = color
        self.baseOpacity = opacity
        self.baseRotation = rotation
    }

    func append(offset: Vec3, scale: Float, opacity: Float, draw: DrawList) {
        let m = Mat4.translation(center + offset)
            * Mat4.rotation(quaternion: simd_quatf(angle: spin, axis: .up))
            * baseRotation
            * Mat4.scale(Vec3(repeating: radius * scale))
        var prev: Vec3?
        for i in 0...128 {
            let a = Float(i) / 128 * TAU
            let p4 = m * SIMD4(cos(a), 0, sin(a), 1)
            let p = Vec3(p4.x, p4.y, p4.z)
            if let prev {
                draw.lines.append(LineVertex(prev, rgba(color, opacity)))
                draw.lines.append(LineVertex(p, rgba(color, opacity)))
            }
            prev = p
        }
    }
}

final class TectonicEffect: EffectStudy {
    let duration: Float = 2.95
    private let node: NodeView
    private let center: Vec3
    private let R: Float
    private let palette: RockPalette
    private let embers: SparkBurst
    private let dustBack: SparkBurst
    private let dustSide: SparkBurst
    private let shards: DebrisField
    private let flash: Flash
    private var broke = false
    private var fired = false

    init(ctx: EffectContext, node: NodeView) {
        self.node = node
        center = node.basePosition
        R = ctx.radius
        palette = RockPalette.forNode(node)
        let rng = ctx.rng
        embers = SparkBurst(count: 130, origin: center, normal: .up, radius: R * 0.72,
                            rng: rng, speed: (1.3, 4.4), tangential: 1.9, normalSpeed: 1.4,
                            drag: 0.65, life: (0.8, 1.9), size: (0.016, 0.075),
                            palette: [palette.dust, palette.accent, palette.hot, palette.ember],
                            startJitter: 0.1, delay: (0.88, 0.98))
        dustBack = SparkBurst(count: 65, origin: center, normal: Vec3(1, 0, 0), radius: R * 0.72,
                              rng: rng, speed: (0.6, 2.2), tangential: 1.8, normalSpeed: 1.5,
                              drag: 0.42, life: (1.0, 2.2), size: (0.03, 0.12),
                              palette: [palette.ember, palette.accent, palette.dust],
                              startJitter: 0.15, delay: (0.9, 1.0), opacity: 0.32)
        dustSide = SparkBurst(count: 55, origin: center, normal: Vec3(0, 0, 1), radius: R * 0.7,
                              rng: rng, speed: (0.4, 1.7), tangential: 1.2, normalSpeed: 1.1,
                              drag: 0.35, life: (0.9, 2.0), size: (0.04, 0.15),
                              palette: [palette.accent, palette.ember, Palette.orbit],
                              startJitter: 0.2, delay: (0.92, 1.02), opacity: 0.24)
        shards = DebrisField(center: center, radius: R, rng: rng, palette: palette,
                             count: 26, speed: (1.3, 3.6), tangential: 0.85,
                             normalSpeed: 0.9, drag: 0.55, size: (0.17, 0.38),
                             startRadius: 0.62)
        flash = Flash(point: center, size: R * 7.2, color: palette.dust,
                      haloColor: palette.hot, duration: 0.72, delay: 0.9,
                      haloScale: 3.4, opacity: 0.95)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let offset = ctx.offset
        let center = self.center + offset
        let reveal = easeOutCubic(clamp01(age / 0.42))
        let heat = smoothstep(0.08, 0.86, age)
        let before = age < 0.9
        if before {
            appendPlanet(draw, center: center, baseR: R * 0.94, palette: palette,
                         opacity: clamp01(age / 0.3), heat: heat * 0.82,
                         crack: smoothstep(0.12, 0.85, age) * 1.1,
                         scale: 0.45 + reveal * 0.55,
                         rotationY: age * 0.22,
                         haloOpacity: 0.1 + heat * 0.14)
        }
        // Shock shell.
        draw.shockShells.append(ShockShellUniforms(
            model: Mat4.translation(center) * Mat4.scale(Vec3(repeating: R * (0.38 + easeOutCubic(clamp01((age - 0.9) / 1.4)) * 4.8))),
            color: rgba(palette.ember, 1),
            accent: rgba(palette.accent, 1),
            params: SIMD4(age > 0.9 ? max(0, 1 - (age - 0.9) / 1.35) * 0.28 : 0, age, 0, 0)
        ))
        draw.sprites.append(.glow(center, size: R * 2.0,
                                  color: palette.accent,
                                  opacity: before ? heat * 0.18 : 0))
        draw.sprites.append(.glow(center, size: R * 5.2,
                                  color: palette.hot,
                                  opacity: before ? heat * 0.06 : max(0, 0.5 * (1 - (age - 0.9) / 1.5))))
        if before {
            node.setPresence(age < 0.78 ? 1 : 1 - smoothstep(0.78, 0.9, age))
        } else if !broke {
            broke = true
            node.setPresence(0)
            if !fired {
                fired = true
                ctx.onShake(0.42)
            }
        }
        flash.append(age: age, offset: offset, draw: draw)
        embers.update(dt: dt, offset: offset, draw: draw)
        dustBack.update(dt: dt, offset: offset, draw: draw)
        dustSide.update(dt: dt, offset: offset, draw: draw)
        shards.append(age: max(0, age - 0.9),
                      opacity: max(0, 1 - max(0, age - 2.15) / 0.65),
                      offset: offset, draw: draw)
    }
}

final class CoreCollapseEffect: EffectStudy {
    let duration: Float = 2.7
    private let node: NodeView
    private let center: Vec3
    private let R: Float
    private let palette: RockPalette
    private let orbits: [OrbitRingLines]
    private let inward: SparkBurst
    private let inwardB: SparkBurst
    private let flash: Flash
    private let dust: SparkBurst
    private let dustWide: SparkBurst
    private var collapsed = false
    private var fired = false

    init(ctx: EffectContext, node: NodeView) {
        self.node = node
        center = node.basePosition
        R = ctx.radius
        palette = RockPalette.forNode(node)
        let rng = ctx.rng
        let origin = center
        let radius = R
        let pal = palette
        var builtOrbits: [OrbitRingLines] = []
        for i in 0..<4 {
            let rr = radius * (1.8 + Float(i) * 0.24)
            let color = i % 2 == 0 ? pal.ice : pal.accent
            let op = 0.25 - Float(i) * 0.035
            let rot = Mat4.eulerXYZ(0.55 + Float(i) * 0.34, Float(i) * 0.7, Float(i) * 0.22)
            builtOrbits.append(OrbitRingLines(center: origin, radius: rr, color: color,
                                              opacity: op, rotation: rot))
        }
        orbits = builtOrbits
        inward = SparkBurst(count: 240, origin: center, normal: .up, radius: R * 1.55,
                            rng: rng, speed: (-3.6, -1.1), tangential: 1.2, normalSpeed: 0.9,
                            drag: 0.15, life: (1.0, 2.0), size: (0.012, 0.05),
                            palette: [palette.dust, palette.accent, palette.ice],
                            startJitter: 0.16, delay: (0, 0.16))
        inwardB = SparkBurst(count: 170, origin: center, normal: Vec3(1, 0, 0), radius: R * 1.25,
                             rng: rng, speed: (-2.4, -0.8), tangential: 1.6, normalSpeed: 0.8,
                             drag: 0.2, life: (0.8, 1.6), size: (0.015, 0.055),
                             palette: [palette.accent, palette.ice, palette.dust],
                             startJitter: 0.2, delay: (0.04, 0.2))
        flash = Flash(point: center, size: R * 5.8, color: palette.dust,
                      haloColor: palette.accent, duration: 0.65, delay: 1.0,
                      haloScale: 3.0, opacity: 0.85)
        dust = SparkBurst(count: 190, origin: center, normal: .up, radius: R * 0.55,
                          rng: rng, speed: (1.0, 3.6), tangential: 1.3, normalSpeed: 1.8,
                          drag: 0.5, life: (1.2, 2.2), size: (0.015, 0.06),
                          palette: [palette.accent, palette.ember, palette.dust],
                          startJitter: 0.18, delay: (1.0, 1.08))
        dustWide = SparkBurst(count: 120, origin: center, normal: Vec3(0, 0, 1), radius: R * 0.9,
                              rng: rng, speed: (0.35, 1.8), tangential: 2.2, normalSpeed: 1.1,
                              drag: 0.18, life: (1.5, 2.5), size: (0.012, 0.05),
                              palette: [palette.accent, palette.ember, palette.ice, palette.dust],
                              startJitter: 0.2, delay: (1.0, 1.12), opacity: 0.45)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let offset = ctx.offset
        let center = self.center + offset
        let collapse = easeInCubic(clamp01(age / 1.02))
        let heat = smoothstep(0.1, 1.0, age)
        let before = age < 1.0
        if before {
            appendPlanet(draw, center: center, baseR: R * 0.94, palette: palette,
                         opacity: clamp01(age / 0.32), heat: heat * 0.9,
                         crack: smoothstep(0.15, 0.94, age) * 1.2,
                         scale: 0.52 + easeOutCubic(clamp01(age / 0.38)) * 0.48 - collapse * 0.62,
                         rotationY: age * 0.4,
                         haloOpacity: 0.08 + heat * 0.2)
            node.setPresence(1 - smoothstep(0.78, 1.0, age))
        } else if !collapsed {
            collapsed = true
            node.setPresence(0)
            if !fired {
                fired = true
                ctx.onShake(0.14)
            }
        }

        for (i, ring) in orbits.enumerated() {
            if before {
                let contract = easeOutCubic(clamp01(age / 1.0))
                let scale = 1.0 + (1.0 - contract) * 1.5
                let opacity = (0.24 - Float(i) * 0.035) * (0.4 + heat * 0.8)
                ring.append(offset: offset, scale: scale, opacity: opacity, draw: draw)
            } else {
                let out = easeOutCubic(clamp01((age - 1.0) / 1.35))
                let scale = 1.0 + out * (2.8 + Float(i) * 0.5)
                let opacity = max(0, 0.18 - Float(i) * 0.018) * (1 - out)
                ring.append(offset: offset, scale: scale, opacity: opacity, draw: draw)
            }
        }

        flash.append(age: age, offset: offset, draw: draw)
        inward.update(dt: dt, offset: offset, draw: draw)
        inwardB.update(dt: dt, offset: offset, draw: draw)
        dust.update(dt: dt, offset: offset, draw: draw)
        dustWide.update(dt: dt, offset: offset, draw: draw)
        draw.sprites.append(.glow(center, size: R * (0.8 + easeOutCubic(clamp01((age - 1.0) / 0.6)) * 2.4),
                                  color: palette.dust,
                                  opacity: before ? 0 : max(0, 0.45 * (1 - (age - 1.0) / 1.1))))
        draw.sprites.append(.glow(center, size: R * (2.8 + easeOutCubic(clamp01((age - 1.0) / 1.0)) * 4.0),
                                  color: palette.accent,
                                  opacity: before ? 0 : max(0, 0.18 * (1 - (age - 1.0) / 1.3))))
        draw.shockShells.append(ShockShellUniforms(
            model: Mat4.translation(center) * Mat4.scale(Vec3(repeating: R * (0.3 + easeOutCubic(clamp01((age - 1.0) / 1.2)) * 3.8))),
            color: rgba(palette.accent, 1),
            accent: rgba(palette.dust, 1),
            params: SIMD4(age > 1.0 ? max(0, 1 - (age - 1.0) / 1.2) * 0.10 : 0, age, 0, 0)
        ))
    }
}

final class OrbitalShearEffect: EffectStudy {
    let duration: Float = 2.75
    private struct ArcStreak {
        let baseAngle: Float
        let baseRadius: Float
        let angularSpeed: Float
        let radialSpeed: Float
        let length: Float
        let tilt: Float
        let color: SRGB
    }
    private let node: NodeView
    private let center: Vec3
    private let R: Float
    private let palette: RockPalette
    private let rings: [OrbitRingLines]
    private let streaks: [ArcStreak]
    private let flatDust: SparkBurst
    private let flash: Flash
    private var broke = false
    private var fired = false

    init(ctx: EffectContext, node: NodeView) {
        self.node = node
        center = node.basePosition
        R = ctx.radius
        palette = RockPalette.forNode(node)
        let rng = ctx.rng
        let origin = center
        let radius = R
        let pal = palette
        var builtRings: [OrbitRingLines] = []
        for i in 0..<6 {
            let rr = radius * (1.1 + Float(i) * 0.22)
            let color = i == 2 ? pal.ice : (i % 2 == 0 ? pal.accent : pal.ember)
            let op = 0.36 - Float(i) * 0.025
            let rot = Mat4.eulerXYZ(0.34 + Float(i) * 0.025, Float(i) * 0.3, Float(i) * 0.06)
            builtRings.append(OrbitRingLines(center: origin, radius: rr, color: color,
                                             opacity: op, rotation: rot))
        }
        rings = builtRings
        var built: [ArcStreak] = []
        let colors: [SRGB] = [palette.ice, palette.accent, palette.dust, palette.hot, palette.ember]
        for _ in 0..<120 {
            built.append(ArcStreak(
                baseAngle: rng.next() * TAU,
                baseRadius: R * (0.8 + rng.next() * 2.2),
                angularSpeed: 0.9 + rng.next() * 3.0,
                radialSpeed: 0.16 + rng.next() * 1.1,
                length: R * (0.22 + rng.next() * 0.65),
                tilt: (rng.next() * 2 - 1) * 0.12,
                color: colors[Int(rng.next() * Float(colors.count)) % colors.count]
            ))
        }
        streaks = built
        flatDust = SparkBurst(count: 170, origin: center, normal: .up, radius: R * 0.7,
                              rng: rng, speed: (1.0, 4.0), tangential: 5.2, normalSpeed: 0.16,
                              drag: 0.3, life: (0.9, 2.0), size: (0.009, 0.04),
                              palette: [palette.ice, palette.accent, palette.dust, palette.hot],
                              startJitter: 0.1, delay: (0.52, 0.7))
        flash = Flash(point: center, size: R * 4.4, color: palette.dust,
                      haloColor: palette.ice, duration: 0.5, delay: 0.54,
                      haloScale: 2.8, opacity: 0.6)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let offset = ctx.offset
        let center = self.center + offset
        let reveal = easeOutCubic(clamp01(age / 0.32))
        let heat = smoothstep(0.06, 0.56, age)
        let flatten = 1 - easeInCubic(clamp01(age / 0.58)) * 0.87
        let before = age < 0.55
        if before {
            appendPlanet(draw, center: center, baseR: R * 0.94, palette: palette,
                         opacity: clamp01(age / 0.22), heat: heat * 0.75,
                         crack: smoothstep(0.16, 0.55, age) * 0.95,
                         scale: 0.4 + reveal * 0.6, squashY: flatten,
                         rotationY: age * 0.8,
                         haloOpacity: 0.1 + heat * 0.12)
            node.setPresence(age < 0.28 ? 1 : 1 - smoothstep(0.28, 0.55, age))
        } else if !broke {
            broke = true
            node.setPresence(0)
            if !fired { fired = true; ctx.onShake(0.22) }
        }

        let out = easeOutCubic(clamp01((age - 0.55) / 1.55))
        if age > 0.5 {
            draw.discs.append(DiscUniforms(
                model: Mat4.translation(center) * Mat4.eulerXYZ(0.38, 0.2 + age * 0.3, 0.12)
                    * Mat4.scale(Vec3(repeating: R * (0.35 + out * 3.5))),
                color: rgba(palette.ember, 1),
                hot: rgba(palette.ice, 1),
                params: SIMD4(max(0, 1 - out) * 0.9, age, 0, 0)
            ))
            let streakMatrix = Mat4.translation(center) * Mat4.eulerXYZ(0.38, 0.2, 0.12)
            let streakOpacity = clamp01(1 - out) * 0.78
            for d in streaks {
                let r = d.baseRadius + d.radialSpeed * R * max(0, age - 0.55)
                let a = d.baseAngle + max(0, age - 0.55) * d.angularSpeed
                let a2 = a + d.length / max(0.2, r)
                let p0 = Vec3(cos(a) * r, sin(a) * r * d.tilt, sin(a) * r)
                let p1 = Vec3(cos(a2) * r, sin(a2) * r * d.tilt, sin(a2) * r)
                let q0 = streakMatrix * SIMD4(p0, 1)
                let q1 = streakMatrix * SIMD4(p1, 1)
                draw.lines.append(LineVertex(Vec3(q0.x, q0.y, q0.z), rgba(d.color, streakOpacity)))
                draw.lines.append(LineVertex(Vec3(q1.x, q1.y, q1.z), rgba(d.color, streakOpacity)))
            }
        }

        for (i, ring) in rings.enumerated() {
            if before {
                let scale = 1.0 + (1 - age / 0.55) * 0.25
                let opacity = (0.34 - Float(i) * 0.025) * (0.5 + heat * 0.7)
                ring.append(offset: offset, scale: scale, opacity: opacity, draw: draw)
            } else {
                let scale = 1 + out * (4.0 + Float(i) * 0.4)
                let opacity = max(0, 0.26 - Float(i) * 0.015) * (1 - out)
                ring.append(offset: offset, scale: scale, opacity: opacity, draw: draw)
            }
        }

        flash.append(age: age, offset: offset, draw: draw)
        flatDust.update(dt: dt, offset: offset, draw: draw)
        draw.sprites.append(.glow(center, size: R * (1.8 + out * 5.2), color: palette.accent,
                                  opacity: before ? 0 : max(0, 0.3 * (1 - out))))
    }
}

final class VaporBloomEffect: EffectStudy {
    let duration: Float = 2.5
    private let node: NodeView
    private let center: Vec3
    private let R: Float
    private let palette: RockPalette
    private let vent: SparkBurst
    private let ash: SparkBurst
    private let flash: Flash
    private var gone = false
    private var fired = false

    init(ctx: EffectContext, node: NodeView) {
        self.node = node
        center = node.basePosition
        R = ctx.radius
        palette = RockPalette.forNode(node)
        let rng = ctx.rng
        flash = Flash(point: center, size: R * 5.6, color: SRGB(hex: "ffffff"),
                      haloColor: palette.accent, duration: 0.68, delay: 0.82,
                      haloScale: 3.2, opacity: 0.9)
        vent = SparkBurst(count: 190, origin: center, normal: .up, radius: R * 0.42,
                          rng: rng, speed: (0.5, 2.0), tangential: 0.65, normalSpeed: 7.2,
                          drag: 0.5, life: (0.7, 1.7), size: (0.012, 0.06),
                          palette: [palette.dust, SRGB(hex: "ffffff"), palette.accent, palette.ice],
                          startJitter: 0.1, delay: (0.8, 0.9))
        ash = SparkBurst(count: 90, origin: center, normal: .up, radius: R * 1.0,
                         rng: rng, speed: (0.4, 2.0), tangential: 1.8, normalSpeed: -1.8,
                         drag: 0.22, life: (1.3, 2.4), size: (0.012, 0.05),
                         palette: [palette.ember, palette.accent, palette.dust],
                         startJitter: 0.2, delay: (0.95, 1.08), opacity: 0.42)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let offset = ctx.offset
        let center = self.center + offset
        let heat = smoothstep(0.08, 0.82, age)
        let before = age < 0.82
        let p = clamp01((age - 0.82) / 1.5)
        let expand = easeOutCubic(p)
        if before {
            appendPlanet(draw, center: center, baseR: R * 0.94, palette: palette,
                         opacity: clamp01(age / 0.22), heat: heat,
                         crack: smoothstep(0.14, 0.8, age) * 1.3,
                         scale: 0.45 + easeOutCubic(clamp01(age / 0.34)) * 0.55,
                         rotationY: age * 0.2,
                         haloOpacity: 0.1 + heat * 0.26)
            node.setPresence(age < 0.56 ? 1 : 1 - smoothstep(0.56, 0.82, age))
        } else if !gone {
            gone = true
            node.setPresence(0)
            if !fired { fired = true; ctx.onShake(0.12) }
        }

        flash.append(age: age, offset: offset, draw: draw)
        vent.update(dt: dt, offset: offset, draw: draw)
        ash.update(dt: dt, offset: offset, draw: draw)

        let jetOn = age > 0.82
        if jetOn {
            let width = R * (0.45 + expand * 1.0)
            let height = R * (0.7 + expand * 4.2)
            let jetModel = Mat4.translation(center) * Mat4.rotation(
                quaternion: simd_quatf(angle: age * 0.16, axis: .up))
                * Mat4.scale(Vec3(width, height, width))
            draw.jets.append(JetUniforms(
                model: jetModel,
                core: rgba(SRGB(hex: "fff8e7"), 1),
                edge: rgba(palette.accent, 1),
                params: SIMD4(max(0, 1 - p) * 0.58, age, 0, 0)
            ))
            let jetDown = Mat4.translation(center)
                * Mat4.rotation(quaternion: simd_quatf(angle: .pi, axis: Vec3(0, 0, 1)))
                * Mat4.scale(Vec3(width, height, width))
            draw.jets.append(JetUniforms(
                model: jetDown,
                core: rgba(SRGB(hex: "fff8e7"), 1),
                edge: rgba(palette.accent, 1),
                params: SIMD4(max(0, 1 - p) * 0.58, age, 0, 0)
            ))
        }
        draw.sprites.append(.glow(center, size: R * (0.8 + expand * 2.4), color: SRGB(hex: "ffffff"),
                                  opacity: before ? heat * 0.14 : max(0, 0.4 * (1 - p))))
        draw.sprites.append(.glow(center, size: R * (1.1 + expand * 1.6), color: palette.accent,
                                  opacity: before ? 0 : max(0, 0.2 * (1 - p))))

        // Equatorial shock rings.
        let shockPairs: [(SRGB, Float)] = [(palette.ice, 0.34), (palette.accent, 0.18)]
        for (idx, pair) in shockPairs.enumerated() {
            let radius = R * (idx == 0 ? 1.0 : 1.2) * (0.4 + expand * (idx == 0 ? 5.0 : 6.5))
            let opacity = jetOn ? max(0, pair.1 * (1 - p)) : 0
            let m = Mat4.scale(Vec3(repeating: radius))
            var prev: Vec3?
            for i in 0...128 {
                let a = Float(i) / 128 * TAU
                let local = Vec3(cos(a), 0, sin(a))
                let p4 = m * SIMD4(local, 1)
                let point = center + Vec3(p4.x, p4.y, p4.z)
                if let prev { draw.lines.append(LineVertex(prev, rgba(pair.0, opacity))); draw.lines.append(LineVertex(point, rgba(pair.0, opacity))) }
                prev = point
            }
        }
    }
}
