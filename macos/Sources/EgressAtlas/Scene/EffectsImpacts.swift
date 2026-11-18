import Foundation
import simd

/// Impact studies from app/src/lab/effects/impact/*.js. Formulas, counts,
/// palettes and timings are kept 1:1.

final class EclipseEffect: EffectStudy {
    let duration: Float = 1.38
    private let point: Vec3
    private let normal: Vec3
    private let R: Float
    private let main: ShockRing
    private let after: ShockRing
    private let razor: ShockRing
    private let flash: Flash
    private let burst: SparkBurst
    private let axialLine: (Vec3, Vec3, SIMD4<Float>)
    private let needleColor: SRGB
    private let tipColor: SRGB

    init(ctx: EffectContext) {
        point = ctx.point
        normal = ctx.normal.normalized
        R = ctx.radius
        let rng = ctx.rng
        let bone = EffectColors.bone
        let gold = EffectColors.gold
        let ice = EffectColors.ice
        let signal = EffectColors.signal
        main = ShockRing(point: point, normal: normal, radius: R,
                         start: 1.18, end: 4.2, duration: 1.22,
                         core: bone, tail: gold, thickness: 0.045, rays: 20,
                         seed: rng.next() * 10, halfFactor: 1.4, opacity: 1)
        after = ShockRing(point: point, normal: normal, radius: R,
                          start: 0.94, end: 3.0, duration: 0.95, delay: 0.07,
                          core: ice, tail: signal, thickness: 0.022,
                          halfFactor: 1.4, opacity: 0.7)
        razor = ShockRing(point: point, normal: normal, radius: R,
                          start: 1.0, end: 3.5, duration: 0.5,
                          core: bone, tail: gold, thickness: 0.012, rays: 46,
                          seed: 1.7, halfFactor: 1.4, opacity: 0.55)
        flash = Flash(point: point, size: R * 4.5, color: bone, haloColor: gold,
                      duration: 0.52, haloScale: 3.1)
        burst = SparkBurst(count: 72, origin: point, normal: normal, radius: R * 1.08,
                           rng: rng, speed: (1.2, 3.8), tangential: 1.9, normalSpeed: 0.8,
                           drag: 1.25, life: (0.5, 1.1), size: (0.012, 0.05),
                           palette: [bone, gold, ice, signal], startJitter: 0.06)
        axialLine = (point - normal * 0.1, point + normal * (R * 3.2), rgba(ice, 0.85))
        needleColor = ice
        tipColor = ice
        ctx.onShake(0.18)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        main.append(age: age, offset: ctx.offset, draw: draw)
        after.append(age: age, offset: ctx.offset, draw: draw)
        razor.append(age: age, offset: ctx.offset, draw: draw)
        flash.append(age: age, offset: ctx.offset, draw: draw)
        burst.update(dt: dt, offset: ctx.offset, draw: draw)

        let t = clamp01(age / duration)
        let trace = easeOutCubic(clamp01(age / 0.55))
        let travel = R * (0.4 + trace * 4.2)
        let needlePos = point + ctx.offset + normal * travel
        let fade = pow(1 - clamp01(age / 0.7), 1.6)
        let orientation = simd_quatf(from: .up, to: normal)
        draw.addMesh(.cone, MeshInstance(
            model: Mat4.compose(position: needlePos, quaternion: orientation,
                                scale: Vec3(R * 0.075, R * 0.7, R * 0.075)),
            color: rgba(needleColor, fade * 0.75)
        ))
        draw.sprites.append(.glow(needlePos, size: R * (0.8 + trace * 1.2),
                                  color: tipColor, opacity: fade * 0.8))

        let a = axialLine.0 + ctx.offset
        let b = axialLine.1 + ctx.offset
        draw.lines.append(LineVertex(a, SIMD4(axialLine.2.x, axialLine.2.y, axialLine.2.z,
                                             pow(1 - t, 2.4) * 0.8)))
        draw.lines.append(LineVertex(b, SIMD4(axialLine.2.x, axialLine.2.y, axialLine.2.z,
                                             pow(1 - t, 2.4) * 0.8)))
    }
}

final class EmberEffect: EffectStudy {
    let duration: Float = 2.15
    private let point: Vec3
    private let flash: Flash
    private let front: ShockRing
    private let wake: ShockRing
    private let embers: SparkBurst
    private let haze: SparkBurst
    private let cinders: SparkBurst

    init(ctx: EffectContext) {
        point = ctx.point
        let R = ctx.radius
        let normal = ctx.normal.normalized
        let rng = ctx.rng
        let gold = EffectColors.gold
        let amber = EffectColors.amber
        let ember = EffectColors.ember
        let coral = EffectColors.coral
        let bone = SRGB(hex: "fff3d6")
        flash = Flash(point: point, size: R * 4.7, color: SRGB(hex: "ffe9b0"),
                      haloColor: ember, duration: 0.6, haloScale: 3.0, opacity: 0.8)
        front = ShockRing(point: point, normal: normal, radius: R,
                          start: 1.05, end: 4.0, duration: 1.55,
                          core: SRGB(hex: "ffdca2"), tail: SRGB(hex: "ff7a3a"),
                          thickness: 0.085, rays: 22, seed: rng.next() * 10,
                          halfFactor: 1.35, opacity: 0.58, inner: true)
        wake = ShockRing(point: point, normal: normal, radius: R,
                         start: 0.8, end: 3.0, duration: 1.15, delay: 0.12,
                         core: amber, tail: ember, thickness: 0.055,
                         halfFactor: 1.35, opacity: 0.4)
        embers = SparkBurst(count: 300, origin: point, normal: normal, radius: R * 1.02,
                            rng: rng, speed: (1.3, 4.6), tangential: 0.9, normalSpeed: 0.45,
                            drag: 0.8, life: (0.7, 1.6), size: (0.016, 0.09),
                            palette: [gold, amber, ember, coral, bone, ember],
                            startJitter: 0.07, delay: (0, 0.08))
        haze = SparkBurst(count: 60, origin: point, normal: normal, radius: R * 0.95,
                          rng: rng, speed: (0.4, 1.8), tangential: 0.5, normalSpeed: 0.2,
                          drag: 0.42, life: (0.9, 2.0), size: (0.09, 0.24),
                          palette: [SRGB(hex: "ffce80"), SRGB(hex: "ff9a4c"), SRGB(hex: "c85a2c")],
                          startJitter: 0.12, opacity: 0.26)
        cinders = SparkBurst(count: 24, origin: point, normal: normal, radius: R * 1.1,
                             rng: rng, speed: (2.4, 5.2), tangential: 0.7, normalSpeed: 0.65,
                             drag: 0.35, life: (1.2, 1.9), size: (0.03, 0.085),
                             palette: [bone, gold, ember], startJitter: 0.02)
        ctx.onShake(0.34)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        flash.append(age: age, offset: ctx.offset, draw: draw)
        front.append(age: age, offset: ctx.offset, draw: draw)
        wake.append(age: age, offset: ctx.offset, draw: draw)
        embers.update(dt: dt, offset: ctx.offset, draw: draw)
        let t = clamp01(age / duration)
        haze.opacity = 0.26 * pow(1 - t, 1.4)
        haze.update(dt: dt, offset: ctx.offset, draw: draw)
        cinders.update(dt: dt, offset: ctx.offset, draw: draw)
    }
}

final class PrismEffect: EffectStudy {
    let duration: Float = 1.25
    private struct Shard {
        let angle: Float
        let r0: Float
        let speed: Float
        let spin: Float
        let phase: Float
        let len: Float
        let wide: Float
        let thick: Float
        let drift: Float
        let color: SRGB
    }
    private let point: Vec3
    private let basisT: Vec3
    private let basisB: Vec3
    private let normal: Vec3
    private let flashA: Flash
    private let flashB: Flash
    private let razor: ShockRing
    private let echoCyan: ShockRing
    private let echoGold: ShockRing
    private let sparks: SparkBurst
    private let shards: [Shard]

    init(ctx: EffectContext) {
        point = ctx.point
        normal = ctx.normal.normalized
        let basis = orthoBasis(normal)
        basisT = basis.t
        basisB = basis.b
        let R = ctx.radius
        let rng = ctx.rng
        let bone = EffectColors.bone
        let gold = EffectColors.gold
        let ice = EffectColors.ice
        let signal = EffectColors.signal
        flashA = Flash(point: point, size: R * 4.6, color: bone, haloColor: gold,
                       duration: 0.38, haloScale: 2.4)
        flashB = Flash(point: point + basis.t * (R * 0.06), size: R * 4.2,
                       color: ice, haloColor: signal, duration: 0.52, delay: 0.03,
                       haloScale: 3.0, opacity: 0.55)
        razor = ShockRing(point: point, normal: normal, radius: R,
                          start: 1.08, end: 3.7, duration: 0.72,
                          core: bone, tail: gold, thickness: 0.018, rays: 42,
                          seed: rng.next() * 10, halfFactor: 1.4, opacity: 0.85)
        echoCyan = ShockRing(point: point, normal: normal, radius: R,
                             start: 0.96, end: 3.7, duration: 0.9, delay: 0.05,
                             core: ice, tail: signal, thickness: 0.014, rays: 24,
                             seed: 3.1, halfFactor: 1.4, opacity: 0.55,
                             offset: basis.t * (R * 0.05))
        echoGold = ShockRing(point: point, normal: normal, radius: R,
                             start: 0.9, end: 3.2, duration: 0.82, delay: 0.09,
                             core: gold, tail: Palette.goldDeep, thickness: 0.016,
                             halfFactor: 1.4, opacity: 0.45,
                             offset: basis.t * (-R * 0.05))
        let palette = [bone, gold, ice, signal, SRGB(hex: "d78335")]
        var built: [Shard] = []
        for _ in 0..<72 {
            let angle = rng.next() * TAU
            built.append(Shard(
                angle: angle,
                r0: R * (0.96 + rng.next() * 0.16),
                speed: 1.1 + rng.next() * 2.6,
                spin: (rng.next() * 2 - 1) * 10,
                phase: rng.next() * TAU,
                len: R * (0.18 + rng.next() * 0.55),
                wide: R * (0.012 + rng.next() * 0.05),
                thick: R * (0.006 + rng.next() * 0.012),
                drift: (rng.next() * 2 - 1) * R * 0.26,
                color: palette[Int(rng.next() * Float(palette.count)) % palette.count]
            ))
        }
        shards = built
        sparks = SparkBurst(count: 54, origin: point, normal: normal, radius: R,
                            rng: rng, speed: (2.6, 6.2), tangential: 1.1, normalSpeed: 1.1,
                            drag: 0.65, life: (0.35, 0.85), size: (0.012, 0.045),
                            palette: [bone, ice, gold, signal], startJitter: 0.04)
        ctx.onShake(0.4)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        flashA.append(age: age, offset: ctx.offset, draw: draw)
        flashB.append(age: age, offset: ctx.offset, draw: draw)
        razor.append(age: age, offset: ctx.offset, draw: draw)
        echoCyan.append(age: age, offset: ctx.offset, draw: draw)
        echoGold.append(age: age, offset: ctx.offset, draw: draw)
        sparks.update(dt: dt, offset: ctx.offset, draw: draw)

        let tt = clamp01(age / duration)
        let fade = 1 - smoothstep(0.45, 0.92, tt)
        for d in shards {
            let radial = basisT * cos(d.angle) + basisB * sin(d.angle)
            let r = d.r0 + d.speed * age * (0.7 + 0.3 * min(1, age / 0.4))
            let p = point + ctx.offset + radial * r + normal * (d.drift * min(1, age * 2.4))
            let grow = smoothstep(0, 0.1, tt)
            let orientation = simd_quatf(from: .up, to: radial)
            let localSpin = Mat4.rotation(quaternion: simd_quatf(angle: d.phase + d.spin * age, axis: .up))
            let scale = Vec3(d.wide * grow,
                             d.len * (0.4 + grow * 0.75) * (0.4 + fade * 0.6),
                             d.thick * grow)
            let model = Mat4.translation(p) * Mat4(orientation) * localSpin * Mat4.scale(scale)
            draw.addMesh(.box, MeshInstance(
                model: model,
                color: rgba(d.color, 0.95 * max(0, fade) + 0.05)
            ))
        }
    }
}

final class ResonanceEffect: EffectStudy {
    let duration: Float = 1.8
    private let point: Vec3
    private let basisT: Vec3
    private let basisB: Vec3
    private let flash: Flash
    private let rings: [ShockRing]
    private let sparks: SparkBurst
    private let sweepDefs: [(index: Int, color: SRGB, opacity: Float)]
    private let tickPoints: [(Vec3, Vec3)]
    private let crossScale: Float

    init(ctx: EffectContext) {
        point = ctx.point
        let normal = ctx.normal.normalized
        let basis = orthoBasis(normal)
        basisT = basis.t
        basisB = basis.b
        let R = ctx.radius
        let rng = ctx.rng
        let bone = EffectColors.bone
        let gold = EffectColors.gold
        let ice = EffectColors.ice
        let signal = EffectColors.signal
        let origin = point
        let axisN = normal
        let aT = basis.t
        let aB = basis.b
        flash = Flash(point: point, size: R * 3.6, color: bone, haloColor: signal,
                      duration: 0.46, haloScale: 2.6, opacity: 0.7)
        let defs: [(delay: Float, end: Float, color: SRGB, tail: SRGB, opacity: Float, duration: Float)] = [
            (0, 4.4, ice, signal, 0.55, 1.35),
            (0.1, 3.4, gold, SRGB(hex: "d78335"), 0.65, 1.28),
            (0.22, 3.4, ice, signal, 0.42, 1.2),
            (0.34, 2.9, gold, SRGB(hex: "d78335"), 0.34, 1.14),
        ]
        rings = defs.map { d in
            ShockRing(point: origin, normal: axisN, radius: R, start: 0.9, end: d.end,
                      duration: d.duration, delay: d.delay, core: d.color, tail: d.tail,
                      thickness: 0.016, halfFactor: 1.35, opacity: d.opacity)
        }
        sweepDefs = (0..<4).map { i in
            (i, i < 2 ? ice : signal, 0.32 - Float(i) * 0.07)
        }
        // Both endpoints are local plane directions; the radius is applied in
        // the update so the ring can breathe with the study clock.
        tickPoints = (0..<48).map { i in
            let a = Float(i) / 48 * TAU
            let dir = aT * cos(a) + aB * sin(a)
            return (dir, dir)
        }
        sparks = SparkBurst(count: 52, origin: origin, normal: axisN, radius: R * 1.05,
                            rng: rng, speed: (1.1, 3.4), tangential: 0.55, normalSpeed: 0.25,
                            drag: 0.55, life: (0.8, 1.6), size: (0.012, 0.045),
                            palette: [ice, signal, gold, bone], startJitter: 0.03)
        crossScale = R * 0.55
        ctx.onShake(0.12)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        flash.append(age: age, offset: ctx.offset, draw: draw)
        rings.forEach { $0.append(age: age, offset: ctx.offset, draw: draw) }
        sparks.update(dt: dt, offset: ctx.offset, draw: draw)
        let t = clamp01(age / duration)
        let appear = smoothstep(0, 0.18, t)
        let fade = 1 - smoothstep(0.66, 1.0, t)
        let sweepAngle = age * 2.1
        for def in sweepDefs {
            let angle = sweepAngle - Float(def.index) * 0.055
            let dir = basisT * cos(angle) + basisB * sin(angle)
            let a = point + ctx.offset
            let b = a + dir * (ctx.radius * 4.8)
            let alpha = def.opacity * appear * fade
            draw.lines.append(LineVertex(a, rgba(def.color, alpha)))
            draw.lines.append(LineVertex(b, rgba(def.color, alpha)))
        }
        let tickOpacity = 0.28 * appear * fade
        let tickScale = 0.96 + t * 0.1
        for i in 0..<48 {
            let a = Float(i) / 48 * TAU
            let dir = basisT * cos(a) + basisB * sin(a)
            let r0 = ctx.radius * 4.15 * tickScale
            let r1 = r0 + (i % 4 == 0 ? ctx.radius * 0.18 : ctx.radius * 0.08) * tickScale
            let p0 = point + ctx.offset + dir * r0
            let p1 = point + ctx.offset + dir * r1
            draw.lines.append(LineVertex(p0, rgba(Palette.gold, tickOpacity)))
            draw.lines.append(LineVertex(p1, rgba(Palette.gold, tickOpacity)))
        }
        let crossAlpha = 0.38 * pow(1 - t, 1.8)
        let crossR = crossScale * (1 + t * 2.4)
        let c = point + ctx.offset
        for dir in [basisT, basisB] {
            draw.lines.append(LineVertex(c - dir * crossR, rgba(EffectColors.ice, crossAlpha)))
            draw.lines.append(LineVertex(c + dir * crossR, rgba(EffectColors.ice, crossAlpha)))
        }
    }
}

final class ContainmentEffect: EffectStudy {
    let duration: Float = 1.55
    private let center: Vec3
    private let normal: Vec3
    private let R: Float
    private let hitDir: Vec3
    private let shieldR: Float
    private let cageEdges: [(Vec3, Vec3)]
    private var cageRotationY: Float = 0
    private var cageRotationZ: Float = 0

    init(ctx: EffectContext) {
        center = ctx.node?.basePosition ?? ctx.point
        normal = ctx.normal.normalized
        R = ctx.radius
        // `normal` is the corrected packet tangent (source -> node). The
        // shield is struck on the side facing the source, so the scan's theta
        // starts there and expands toward the back hemisphere.
        hitDir = (normal * -1).normalized
        shieldR = R * 1.72
        cageEdges = icosphereEdges(subdivisions: 2)
        ctx.onShake(0.006)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let open = clamp01(age / 0.16)
        let settle = 0.8 + 0.2 * easeOutBack(open, 1.1)
        let fade = 1 - smoothstep(0.92, 1.5, age)
        let shieldScale = shieldR * settle * (1 - smoothstep(1.15, 1.5, age) * 0.035)
        cageRotationY += dt * 0.12
        cageRotationZ += dt * 0.06
        let ripple = clamp01((age - 0.02) / 0.72)
        let appear = smoothstep(0, 0.05, age)
        let opacity = appear * fade
        let contactAmount = pow(1 - clamp01(age / 0.62), 1.4)
        let c = center + ctx.offset

        draw.shields.append(ShieldUniforms(
            model: Mat4.compose(position: c, quaternion: simd_quatf(angle: 0, axis: .up),
                                scale: Vec3(repeating: shieldScale)),
            shell: rgba(SRGB(hex: "8f2f28"), 1),
            rim: rgba(SRGB(hex: "d94f43"), 1),
            hot: rgba(SRGB(hex: "ffd6c9"), 1),
            hitDir: SIMD4(hitDir, 1),
            params: SIMD4(opacity * 0.85, age, ripple, contactAmount)
        ))

        let cageAlpha = 0.038 * appear * fade * (1 - smoothstep(0.85, 1.45, age))
            + 0.018 * opacity * (0.6 + 0.4 * sin(age * 6))
        let rotation = Mat4.eulerXYZ(0, cageRotationY, cageRotationZ)
        for (a, b) in cageEdges {
            let pa = rotation * SIMD4(a * shieldScale, 1)
            let pb = rotation * SIMD4(b * shieldScale, 1)
            let p1 = c + Vec3(pa.x, pa.y, pa.z)
            let p2 = c + Vec3(pb.x, pb.y, pb.z)
            draw.lines.append(LineVertex(p1, rgba(EffectColors.coral, cageAlpha)))
            draw.lines.append(LineVertex(p2, rgba(EffectColors.coral, cageAlpha)))
        }

        let front = c + hitDir * shieldScale
        let contactScale = R * (0.95 + 0.3 * sin(min(1, age / 0.6) * .pi))
        draw.sprites.append(.glow(front, size: contactScale, color: SRGB(hex: "fff0e8"),
                                  opacity: opacity * pow(1 - clamp01(age / 0.65), 1.3) * 0.55))
        draw.sprites.append(.glow(front, size: R * (2.5 + ripple * 0.6), color: SRGB(hex: "d94f43"),
                                  opacity: opacity * 0.07 * (1 - ripple)))
    }
}

func icosphereEdges(subdivisions: Int) -> [(Vec3, Vec3)] {
    let t: Float = (1 + sqrt(5.0)) / 2
    var verts: [Vec3] = [
        Vec3(-1, t, 0), Vec3(1, t, 0), Vec3(-1, -t, 0), Vec3(1, -t, 0),
        Vec3(0, -1, t), Vec3(0, 1, t), Vec3(0, -1, -t), Vec3(0, 1, -t),
        Vec3(t, 0, -1), Vec3(t, 0, 1), Vec3(-t, 0, -1), Vec3(-t, 0, 1),
    ].map { $0.normalized }
    var faces: [SIMD3<Int>] = [
        SIMD3(0, 11, 5), SIMD3(0, 5, 1), SIMD3(0, 1, 7), SIMD3(0, 7, 10), SIMD3(0, 10, 11),
        SIMD3(1, 5, 9), SIMD3(5, 11, 4), SIMD3(11, 10, 2), SIMD3(10, 7, 6), SIMD3(7, 1, 8),
        SIMD3(3, 9, 4), SIMD3(3, 4, 2), SIMD3(3, 2, 6), SIMD3(3, 6, 8), SIMD3(3, 8, 9),
        SIMD3(4, 9, 5), SIMD3(2, 4, 11), SIMD3(6, 2, 10), SIMD3(8, 6, 7), SIMD3(9, 8, 1),
    ]
    var cache: [String: Int] = [:]
    func midpoint(_ a: Int, _ b: Int) -> Int {
        let key = a < b ? "\(a)-\(b)" : "\(b)-\(a)"
        if let idx = cache[key] { return idx }
        let p = ((verts[a] + verts[b]) * 0.5).normalized
        verts.append(p)
        cache[key] = verts.count - 1
        return verts.count - 1
    }
    for _ in 0..<subdivisions {
        var next: [SIMD3<Int>] = []
        for f in faces {
            let a = midpoint(f.x, f.y)
            let b = midpoint(f.y, f.z)
            let c = midpoint(f.z, f.x)
            next.append(SIMD3(f.x, a, c))
            next.append(SIMD3(f.y, b, a))
            next.append(SIMD3(f.z, c, b))
            next.append(SIMD3(a, b, c))
        }
        faces = next
    }
    var seen = Set<String>()
    var edges: [(Vec3, Vec3)] = []
    for f in faces {
        for (i, j) in [(f.x, f.y), (f.y, f.z), (f.z, f.x)] {
            let key = i < j ? "\(i)-\(j)" : "\(j)-\(i)"
            if seen.insert(key).inserted {
                edges.append((verts[i], verts[j]))
            }
        }
    }
    return edges
}
