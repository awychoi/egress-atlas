import Foundation
import simd

// Emergence studies.

final class SpiralEffect: EffectStudy {
    let duration: Float = 2.4
    private let node: NodeView
    private let center: Vec3
    private let basisT: Vec3
    private let basisB: Vec3
    private let basisN: Vec3
    private let normal: Vec3
    private let R: Float
    private struct Mote {
        let angle: Float
        let radius: Float
        let speed: Float
        let dir: Float
        let normalOffset: Float
        let color: SRGB
        let size: Float
        let phase: Float
    }
    private struct Arm {
        let phase: Float
        let dir: Float
        let color: SRGB
    }
    private struct Orbiter {
        let angle: Float
        let radius: Float
        let speed: Float
        let tilt: Float
        let color: SRGB
        let size: Float
        let phase: Float
    }
    private let motes: [Mote]
    private let arms: [Arm]
    private let orbiters: [Orbiter]
    private let collapseFlash: Flash
    private let birthRing: ShockRing
    private let pop: SparkBurst

    init(ctx: EffectContext, node: NodeView) {
        self.node = node
        center = node.basePosition
        R = ctx.radius
        let rng = ctx.rng
        var n = (ctx.camera.position - center).normalized
        n = simd_quatf(angle: (rng.next() - 0.5) * 0.6, axis: .up).act(n)
        n.y += 0.08
        n = n.normalized
        normal = n
        let basis = orthoBasis(n)
        basisT = basis.t
        basisB = basis.b
        basisN = basis.n
        let palette: [SRGB] = [SRGB(hex: "fff4d9"), Palette.gold, Palette.signalIce,
                               Palette.signal, Palette.coral]
        var builtMotes: [Mote] = []
        for _ in 0..<150 {
            builtMotes.append(Mote(
                angle: rng.next() * TAU,
                radius: R * (1.8 + rng.next() * 2.8),
                speed: 2.6 + rng.next() * 4.4,
                dir: rng.next() > 0.2 ? 1 : -1,
                normalOffset: (rng.next() * 2 - 1) * R * 1.2,
                color: palette[Int(rng.next() * Float(palette.count)) % palette.count],
                size: R * (0.04 + pow(rng.next(), 2) * 0.16),
                phase: rng.next() * TAU
            ))
        }
        motes = builtMotes
        arms = (0..<3).map { i in
            Arm(phase: Float(i) / 3 * TAU, dir: i % 2 == 0 ? 1 : -1,
                color: i == 1 ? Palette.signalIce : Palette.gold)
        }
        collapseFlash = Flash(point: center, size: R * 3.6, color: SRGB(hex: "fff6e2"),
                              haloColor: Palette.gold, duration: 0.62, delay: 0.9,
                              haloScale: 2.8, opacity: 0.9)
        birthRing = ShockRing(point: center, normal: n, radius: R,
                              start: 0.85, end: 3.6, duration: 0.95, delay: 0.9,
                              core: SRGB(hex: "fff4d9"), tail: Palette.gold,
                              thickness: 0.045, rays: 18, seed: rng.next() * 8,
                              halfFactor: 1.45, opacity: 0.8)
        pop = SparkBurst(count: 60, origin: center, normal: n, radius: R * 0.8,
                         rng: rng, speed: (1.5, 5.5), tangential: 2.4, normalSpeed: 1.6,
                         drag: 1.2, life: (0.35, 0.95), size: (0.012, 0.055),
                         palette: [SRGB(hex: "fff4d9"), Palette.gold, Palette.signalIce, Palette.signal],
                         startJitter: 0.02, delay: (0.9, 1.0))
        var builtOrbiters: [Orbiter] = []
        for _ in 0..<22 {
            builtOrbiters.append(Orbiter(
                angle: rng.next() * TAU,
                radius: R * (1.5 + rng.next() * 1.6),
                speed: (0.25 + rng.next() * 0.85) * (rng.next() > 0.5 ? 1 : -1),
                tilt: (rng.next() * 2 - 1) * 0.7,
                color: palette[Int(rng.next() * Float(palette.count)) % palette.count],
                size: R * (0.025 + rng.next() * 0.07),
                phase: rng.next() * TAU
            ))
        }
        orbiters = builtOrbiters
        node.setPresence(0)
        ctx.onShake(0.05)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let collapse: Float = 0.9
        let p = easeInCubic(clamp01(age / collapse))
        let spin = age * 1.6
        let offset = ctx.offset

        for mote in motes {
            let r = mote.radius * (1 - pow(p, 1.15))
            let ang = mote.angle + mote.dir * (p * mote.speed + age * 0.25) + spin
            let visible: Float = age < collapse + 0.12 ? 1 : 0
            let alpha = visible * pow(1 - p, 0.55) * (0.55 + 0.45 * sin(age * 9 + mote.phase)) * 0.85
            let pos = center + offset
                + basisT * (cos(ang) * r)
                + basisB * (sin(ang) * r)
                + basisN * (mote.normalOffset * (1 - p))
            draw.points.append(PointVertex(pos, rgba(mote.color, max(0, alpha)),
                                           size: mote.size * (0.75 + (1 - p) * 0.7)))
        }

        // Three spiral arms wind inward.
        for arm in arms {
            let armP = clamp01(age / 0.96)
            var points: [Vec3] = []
            for i in 0...110 {
                let u = Float(i) / 110
                let spiralAngle = arm.phase + arm.dir * u * .pi * 2 * 1.75 + spin * arm.dir
                let baseR = R * (4.1 * pow(1 - u, 1.35) + 0.05)
                let rr = baseR * (1 - easeInCubic(armP) * 0.98)
                let pos = center + offset
                    + basisT * (cos(spiralAngle) * rr)
                    + basisB * (sin(spiralAngle) * rr)
                    + basisN * (sin(u * 12) * R * 0.06)
                points.append(pos)
            }
            let fade = clamp01(age / 0.12) * pow(1 - clamp01((age - 0.72) / 0.28), 1.4)
            addLinePoints(draw, points, color: arm.color, opacity: fade * 0.5)
        }

        collapseFlash.append(age: age, offset: offset, draw: draw)
        birthRing.append(age: age, offset: offset, draw: draw)
        pop.update(dt: dt, offset: offset, draw: draw)

        if age > 0.9 {
            let reveal = clamp01((age - 0.9) / 0.42)
            let flicker: Float = age < 1.12 ? 0.65 + 0.35 * sin(age * 80) : 1
            node.setPresence(max(0, easeOutBack(reveal, 1.35)) * flicker)
            if age > 1.35 { node.setPresence(1) }
        }

        let orbitStart: Float = 1.2
        if age > orbitStart {
            let op = clamp01((age - orbitStart) / 1.2)
            for o in orbiters {
                let a = o.angle + age * o.speed
                let rr = o.radius * (0.7 + op * 0.5)
                let x = cos(a) * rr
                let z = sin(a) * rr
                let y = sin(a * 1.7 + o.phase) * rr * o.tilt
                let pos = center + offset
                    + basisT * x + basisB * y + basisN * (z * 0.4)
                draw.points.append(PointVertex(pos, rgba(o.color, (1 - op) * 0.55), size: o.size))
            }
        }
        if age > 1.38 { node.setPresence(1) }
    }
}

final class ArcWeldEffect: EffectStudy {
    let duration: Float = 2.25
    private struct Tendril {
        let origin: Vec3
        let dir: Vec3
        let basisT: Vec3
        let basisB: Vec3
        let color: SRGB
        let coreColor: SRGB
        let start: Float
        let duration: Float
        let seed: Float
    }
    private let node: NodeView
    private let center: Vec3
    private let ringNormal: Vec3
    private let R: Float
    private let tendrils: [Tendril]
    private let flash: Flash
    private let ringA: ShockRing
    private let ringB: ShockRing
    private let burst: SparkBurst
    private let residual: SparkBurst
    private var flashDone = false
    private var arrived: [Bool]

    init(ctx: EffectContext, node: NodeView) {
        self.node = node
        center = node.basePosition
        R = ctx.radius
        ringNormal = (ctx.camera.position - center).normalized
        let rng = ctx.rng
        var built: [Tendril] = []
        for i in 0..<7 {
            var dir = Vec3(rng.next() * 2 - 1, rng.next() * 1.7 - 0.7, rng.next() * 2 - 1).normalized
            if dir.lengthSq < 0.01 { dir = Vec3(1, 0, 0) }
            let origin = center + dir * (R * (3.2 + rng.next() * 1.9))
            let base = orthoBasis(-dir)
            let color = i == 1 ? Palette.gold : (i % 3 == 0 ? Palette.signalIce : Palette.signal)
            let core = i == 1 ? SRGB(hex: "ffe4ad") : SRGB(hex: "e8fbff")
            built.append(Tendril(origin: origin, dir: dir, basisT: base.t, basisB: base.b,
                                 color: color, coreColor: core,
                                 start: Float(i) * 0.035 + rng.next() * 0.05,
                                 duration: 0.62 + rng.next() * 0.2,
                                 seed: rng.next() * 100))
        }
        tendrils = built
        arrived = Array(repeating: false, count: built.count)
        flash = Flash(point: center, size: R * 3.8, color: SRGB(hex: "fff6e4"),
                      haloColor: Palette.signal, duration: 0.6, delay: 0.94, haloScale: 3.2)
        ringA = ShockRing(point: center, normal: ringNormal, radius: R,
                          start: 1.0, end: 4.0, duration: 1.0, delay: 0.94,
                          core: SRGB(hex: "fff4d9"), tail: Palette.signal,
                          thickness: 0.04, rays: 20, seed: rng.next() * 10,
                          halfFactor: 1.45, opacity: 0.85)
        ringB = ShockRing(point: center, normal: .up, radius: R,
                          start: 0.8, end: 3.1, duration: 0.9, delay: 1.0,
                          core: Palette.signalIce, tail: Palette.signal2,
                          thickness: 0.022, halfFactor: 1.45, opacity: 0.42)
        burst = SparkBurst(count: 90, origin: center, normal: ringNormal, radius: R * 0.6,
                           rng: rng, speed: (1.8, 6.2), tangential: 3.2, normalSpeed: 2.4,
                           drag: 1.0, life: (0.4, 1.1), size: (0.012, 0.06),
                           palette: [SRGB(hex: "dff8ff"), Palette.signalIce, Palette.signal,
                                     SRGB(hex: "fff4d9"), Palette.gold],
                           startJitter: 0.01, delay: (0.94, 1.03))
        residual = SparkBurst(count: 46, origin: center, normal: ringNormal, radius: R * 1.6,
                              rng: rng, speed: (0.2, 1.8), tangential: 1.6, normalSpeed: 0.25,
                              drag: 0.4, life: (0.9, 1.6), size: (0.012, 0.04),
                              palette: [Palette.signalIce, Palette.signal, Palette.gold],
                              startJitter: 0.08, delay: (1.02, 1.15))
        node.setPresence(0)
        ctx.onShake(0.08)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let offset = ctx.offset
        for (idx, td) in tendrils.enumerated() {
            let raw = clamp01((age - td.start) / td.duration)
            let p = easeInOutCubic(raw)
            let tip = td.origin.lerp(center + offset, p)
            let amp = R * 0.48 * (1 - p)
            var points: [Vec3] = []
            var corePoints: [Vec3] = []
            for j in 0..<26 {
                let f = Float(j) / 25
                let jag = sin(f * 17 + td.seed + age * 21) * amp * (0.2 + f * 0.85)
                    + sin(f * 41 - age * 17 + td.seed * 0.7) * amp * 0.32
                let pos = td.origin.lerp(tip, f)
                    + td.basisT * jag
                    + td.basisB * (cos(f * 13 + td.seed) * amp * 0.55)
                points.append(pos)
                corePoints.append(pos + td.basisT * (R * 0.02) + td.basisB * (R * 0.014))
            }
            let lineOpacity = 0.8 * min(1, raw * 4) * (raw > 0.96 ? (1 - raw) / 0.04 : 1)
            addLinePoints(draw, points, color: td.color, opacity: lineOpacity)
            addLinePoints(draw, corePoints, color: td.coreColor, opacity: lineOpacity * 0.5)
            let tipAlpha: Float = raw > 0 && raw < 0.95 ? 0.9 : 0
            draw.points.append(PointVertex(tip, rgba(SRGB(hex: "dff8ff"), tipAlpha), size: R * 0.075))
            if raw >= 0.96 && !arrived[idx] {
                arrived[idx] = true
                ctx.onShake(0.035)
            }
        }

        let weld = clamp01(age / 1.0)
        draw.sprites.append(.glow(center + offset, size: R * (0.7 + weld * 2.2),
                                  color: Palette.signalIce,
                                  opacity: pow(weld, 2.2) * 0.55 * (1 - clamp01((age - 1.1) / 0.5))))
        flash.append(age: age, offset: offset, draw: draw)
        ringA.append(age: age, offset: offset, draw: draw)
        ringB.append(age: age, offset: offset, draw: draw)
        burst.update(dt: dt, offset: offset, draw: draw)
        residual.update(dt: dt, offset: offset, draw: draw)

        if age >= 0.94 && !flashDone {
            flashDone = true
            ctx.onShake(0.22)
        }
        if age > 0.94 {
            let reveal = clamp01((age - 0.94) / 0.4)
            let flicker: Float = age < 1.12 ? 0.55 + 0.45 * sin(age * 90) : 1
            node.setPresence(max(0, easeOutBack(reveal, 1.3)) * flicker)
            if age > 1.34 { node.setPresence(1) }
        }
    }
}

final class SeedBloomEffect: EffectStudy {
    let duration: Float = 2.55
    private let node: NodeView
    private let center: Vec3
    private let R: Float
    private let basisT: Vec3
    private let basisB: Vec3
    private let basisN: Vec3
    private let seedStart: Vec3
    private let landTime: Float = 0.58
    private struct Trail {
        let lag: Float
        let jitter: Float
        let size: Float
        let color: SRGB
    }
    private struct Filament {
        let points: [Vec3]
        let color: SRGB
        let start: Float
        let duration: Float
    }
    private struct Spore {
        let a: Float
        let r: Float
        let y: Float
        let rise: Float
        let speed: Float
        let size: Float
        let color: SRGB
    }
    private let trail: [Trail]
    private let filaments: [Filament]
    private let tipDust: [SparkBurst]
    private let spores: [Spore]
    private let landFlash: Flash
    private let landingRing: ShockRing
    private let landSplash: SparkBurst
    private let halo: ShockRing
    private let halo2: ShockRing
    private let revealFlash: Flash
    private var revealFired = false

    init(ctx: EffectContext, node: NodeView) {
        self.node = node
        center = node.basePosition
        R = ctx.radius
        let toCam = (ctx.camera.position - center).normalized
        let basis = orthoBasis(toCam)
        basisT = basis.t
        basisB = basis.b
        basisN = basis.n
        seedStart = center + Vec3(0, R * 3.4, 0) + basisT * (R * 0.18)
        let rng = ctx.rng
        var trails: [Trail] = []
        for i in 0..<16 {
            trails.append(Trail(
                lag: Float(i) / 16 * 0.24,
                jitter: (rng.next() * 2 - 1) * R * 0.05,
                size: R * (0.02 + rng.next() * 0.05),
                color: i < 5 ? Palette.gold : (i < 10 ? Palette.coral : Palette.orbit)
            ))
        }
        trail = trails
        var builtFilaments: [Filament] = []
        for i in 0..<9 {
            let baseAngle = Float(i) / 9 * TAU + (rng.next() * 2 - 1) * 0.22
            let radial = basisT * cos(baseAngle) + basisB * sin(baseAngle)
            let tangent = basisT * (-sin(baseAngle)) + basisB * cos(baseAngle)
            let lift = basisN * (R * (0.05 + rng.next() * 0.12))
            let p0 = center
            let p1 = center + radial * (R * 0.22) + tangent * (R * 0.16)
            let p2 = center + radial * (R * (1.0 + rng.next() * 0.25))
                + tangent * (R * (0.6 + rng.next() * 0.4)) + lift
            let p3 = center + radial * (R * (1.35 + rng.next() * 0.35))
                + tangent * (R * (0.1 + rng.next() * 0.25)) + lift
            let curve = CatmullRom(points: [p0, p1, p2, p3], closed: false,
                                   curveType: "centripetal", tension: 0.5)
            let points = (0...50).map { curve.point(Float($0) / 50) }
            let color = i % 4 == 0 ? Palette.signalIce : (i % 3 == 0 ? SRGB(hex: "fff4d9") : Palette.gold)
            // Finish every tendril before the orb's reveal completes at
            // 1.4 s: the last tip is born and popped by ~1.20 s.
            builtFilaments.append(Filament(points: points, color: color,
                                           start: 0.56 + Float(i) * 0.030,
                                           duration: 0.40))
        }
        filaments = builtFilaments
        // Each tendril ends in a tiny dust pop instead of a permanent tip.
        let dustR = R
        let dustNormal = basisN
        let dustRng = rng
        let dustCenter = center
        tipDust = builtFilaments.map { filament in
            let tip = filament.points.last ?? dustCenter
            let at = filament.start + filament.duration
            return SparkBurst(count: 14, origin: tip, normal: dustNormal, radius: dustR * 0.06,
                              rng: dustRng, speed: (0.15, 0.75), tangential: 0.35,
                              normalSpeed: 0.20, drag: 1.5, life: (0.20, 0.45),
                              size: (dustR * 0.008, dustR * 0.024),
                              palette: [filament.color, SRGB(hex: "fff4d9"), Palette.gold],
                              startJitter: 0.03, delay: (at, at + 0.04))
        }
        var builtSpores: [Spore] = []
        for i in 0..<28 {
            builtSpores.append(Spore(
                a: rng.next() * TAU,
                r: R * (1.0 + rng.next() * 1.9),
                y: (rng.next() * 2 - 1) * R * 0.6,
                rise: R * (0.1 + rng.next() * 0.4),
                speed: 0.2 + rng.next() * 0.6,
                size: R * (0.018 + rng.next() * 0.04),
                color: i % 3 == 0 ? Palette.signalIce : (i % 3 == 1 ? Palette.gold : Palette.coral)
            ))
        }
        spores = builtSpores
        landFlash = Flash(point: center, size: R * 2.8, color: SRGB(hex: "fff2ce"),
                         haloColor: Palette.gold, duration: 0.55, delay: landTime,
                         haloScale: 3.0, opacity: 0.7)
        landingRing = ShockRing(point: center, normal: .up, radius: R,
                                start: 0.6, end: 3.6, duration: 0.9, delay: landTime,
                                core: SRGB(hex: "fff3d4"), tail: Palette.gold,
                                thickness: 0.028, halfFactor: 1.45, opacity: 0.55)
        landSplash = SparkBurst(count: 44, origin: center, normal: .up, radius: R * 0.4,
                                rng: rng, speed: (0.7, 3.2), tangential: 2.2, normalSpeed: 1.3,
                                drag: 1.0, life: (0.3, 0.9), size: (0.012, 0.05),
                                palette: [SRGB(hex: "fff4d9"), Palette.gold, Palette.coral],
                                startJitter: 0.2, delay: (landTime, landTime + 0.04))
        halo = ShockRing(point: center, normal: toCam, radius: R,
                         start: 0.9, end: 3.8, duration: 1.05, delay: 0.94,
                         core: SRGB(hex: "fff4d9"), tail: Palette.gold,
                         thickness: 0.038, rays: 14, seed: rng.next() * 10,
                         halfFactor: 1.45, opacity: 0.8)
        halo2 = ShockRing(point: center, normal: toCam, radius: R,
                          start: 0.7, end: 3.0, duration: 0.9, delay: 1.06,
                          core: Palette.signalIce, tail: Palette.signal2,
                          thickness: 0.016, halfFactor: 1.45, opacity: 0.5)
        revealFlash = Flash(point: center, size: R * 3.2, color: SRGB(hex: "fff6df"),
                            haloColor: Palette.gold, duration: 0.55, delay: 0.98,
                            haloScale: 3.2, opacity: 0.75)
        node.setPresence(0)
        ctx.onShake(0.025)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let offset = ctx.offset
        let center = self.center + offset
        let dropP = clamp01(age / landTime)
        let seedPos = seedStart.lerp(self.center, dropP * dropP) + offset
            + basisT * (sin(dropP * 9) * R * 0.12 * (1 - dropP))
        if age < landTime + 0.04 {
            let seedPulse = 0.8 + sin(age * 30) * 0.2
            draw.sprites.append(.glow(seedPos, size: R * 0.85 * seedPulse,
                                      color: SRGB(hex: "fff4d9"), opacity: 0.95))
            draw.sprites.append(.glow(seedPos, size: R * 2.1 * (0.85 + dropP * 0.3),
                                      color: Palette.gold, opacity: 0.25 * (1 - dropP * 0.4)))
            let spin = age * 4.2
            let crystal = Mat4.translation(seedPos) * Mat4.eulerXYZ(0, spin, sin(age * 8) * 0.18)
                * Mat4.scale(Vec3(repeating: R * 0.16))
            draw.addMesh(.octa, MeshInstance(model: crystal, color: rgba(SRGB(hex: "ffe6ae"), 0.9)))
        }

        // Comet trail.
        for (i, td) in trail.enumerated() {
            let lagP = clamp01((age - td.lag) / landTime)
            var p = seedStart.lerp(self.center, lagP * lagP)
            p += basisT * (sin(lagP * 9) * R * 0.12 * (1 - lagP) + td.jitter)
            let alpha = age < landTime ? (1 - Float(i) / 16) * 0.55 * clamp01(age / 0.08) : 0
            draw.points.append(PointVertex(p + offset, rgba(td.color, alpha), size: td.size))
        }
        _ = center
        let dropAlpha = 0.16 * (1 - clamp01(age / landTime))
        if age < landTime {
            draw.lines.append(LineVertex(seedStart + offset, rgba(Palette.gold, dropAlpha)))
            draw.lines.append(LineVertex(self.center + offset, rgba(Palette.gold, dropAlpha)))
        }

        landFlash.append(age: age, offset: offset, draw: draw)
        landingRing.append(age: age, offset: offset, draw: draw)
        landSplash.update(dt: dt, offset: offset, draw: draw)

        for f in filaments {
            let raw = clamp01((age - f.start) / f.duration)
            let progress = easeOutCubic(raw)
            // The trail erases from its base as the head travels outward, and
            // fades out completely before reveal reaches 1.4 s.
            let tail = max(0, progress - 0.65)
            let headIndex = min(50, max(0, Int(progress * 50)))
            let tailIndex = min(headIndex, max(0, Int(tail * 50)))
            let fadeIn = smoothstep(0, 0.10, raw)
            let fadeOut = 1 - smoothstep(0.80, 1.0, raw)
            let baseAlpha = 0.72 * fadeIn * fadeOut
            if headIndex > tailIndex {
                var previous: Vec3?
                var previousAlpha: Float = 0
                for i in tailIndex...headIndex {
                    let u = Float(i) / 50
                    let local = headIndex > tailIndex
                        ? clamp01((u - tail) / max(0.001, progress - tail)) : 1
                    let alpha = baseAlpha * pow(local, 0.8)
                    let point = f.points[i] + offset
                    if let previous {
                        draw.lines.append(LineVertex(previous, rgba(f.color, previousAlpha)))
                        draw.lines.append(LineVertex(point, rgba(f.color, alpha)))
                    }
                    previous = point
                    previousAlpha = alpha
                }
                if let tip = previous {
                    let tipAlpha = 0.85 * fadeIn * (1 - smoothstep(0.86, 0.99, raw))
                    draw.points.append(PointVertex(tip, rgba(f.color, tipAlpha), size: R * 0.055))
                }
            }
            // Tiny dust pop at the exact tip when this tendril completes.
        }

        for dust in tipDust {
            dust.update(dt: dt, offset: offset, draw: draw)
        }

        halo.append(age: age, offset: offset, draw: draw)
        halo2.append(age: age, offset: offset, draw: draw)
        revealFlash.append(age: age, offset: offset, draw: draw)

        if age > 0.98 {
            let reveal = clamp01((age - 0.98) / 0.45)
            let flicker: Float = age < 1.22 ? 0.6 + 0.4 * sin(age * 74) : 1
            node.setPresence(max(0, easeOutBack(reveal, 1.35)) * flicker)
            if !revealFired {
                revealFired = true
                ctx.onShake(0.12)
            }
        }
        if age > 1.4 { node.setPresence(1) }

        if age > 1.2 {
            let op = clamp01((age - 1.2) / 1.3)
            for s in spores {
                let a = s.a + age * s.speed * 0.35
                let y = s.y + op * s.rise
                let pos = center + basisT * (cos(a) * s.r) + basisB * (sin(a) * s.r) + Vec3(0, y, 0)
                draw.points.append(PointVertex(pos, rgba(s.color, (1 - op) * 0.4), size: s.size))
            }
        }
    }
}

final class ScanEffect: EffectStudy {
    let duration: Float = 2.2
    private struct Fragment {
        let y: Float
        let a: Float
        let len: Float
        let offset: Float
        let color: SRGB
    }
    private struct Mote {
        let angle: Float
        let radius: Float
        let speed: Float
        let phase: Float
        let size: Float
        let color: SRGB
    }
    private let node: NodeView
    private let center: Vec3
    private let R: Float
    private let RL: Float
    private let halfSpan: Float
    private let toCam: Vec3
    private let fragments: [Fragment]
    private let motes: [Mote]
    private let flash: Flash
    private let topRing: ShockRing
    private let faceRing: ShockRing
    private let burst: SparkBurst
    private var fired = false

    init(ctx: EffectContext, node: NodeView) {
        self.node = node
        center = node.basePosition
        R = ctx.radius
        RL = R * 2.65
        halfSpan = R * 2.3
        toCam = (ctx.camera.position - center).normalized
        let rng = ctx.rng
        var frags: [Fragment] = []
        for i in 0..<22 {
            let y = -halfSpan * 0.82 + rng.next() * halfSpan * 1.64
            let a = rng.next() * TAU
            let len = R * (0.22 + rng.next() * 1.05)
            let offset = R * (0.1 + rng.next() * 0.9)
            let color = i % 4 == 0 ? Palette.signalIce
                : (i % 3 == 0 ? Palette.gold : Palette.text2)
            frags.append(Fragment(y: y, a: a, len: len, offset: offset, color: color))
        }
        fragments = frags
        var builtMotes: [Mote] = []
        for i in 0..<34 {
            builtMotes.append(Mote(
                angle: rng.next() * TAU,
                radius: RL * (0.2 + rng.next() * 0.7),
                speed: 0.25 + rng.next() * 0.8,
                phase: rng.next(),
                size: R * (0.015 + rng.next() * 0.04),
                color: i % 3 == 0 ? Palette.gold : Palette.signalIce
            ))
        }
        motes = builtMotes
        flash = Flash(point: center, size: R * 3.8, color: SRGB(hex: "f2fbff"),
                      haloColor: Palette.signal, duration: 0.62, delay: 1.34, haloScale: 3.1)
        topRing = ShockRing(point: center, normal: .up, radius: R,
                            start: 0.9, end: 3.4, duration: 1.0, delay: 1.34,
                            core: SRGB(hex: "f2fbff"), tail: Palette.signal,
                            thickness: 0.026, halfFactor: 1.45, opacity: 0.7)
        faceRing = ShockRing(point: center, normal: toCam, radius: R,
                             start: 0.8, end: 3.4, duration: 1.05, delay: 1.4,
                             core: SRGB(hex: "fff4d9"), tail: Palette.gold,
                             thickness: 0.035, rays: 18, seed: rng.next() * 10,
                             halfFactor: 1.45)
        burst = SparkBurst(count: 64, origin: center, normal: .up, radius: R * 0.5,
                           rng: rng, speed: (1.0, 4.4), tangential: 2.4, normalSpeed: 2.2,
                           drag: 1.0, life: (0.4, 1.05), size: (0.01, 0.05),
                           palette: [SRGB(hex: "f2fbff"), Palette.signalIce, Palette.signal, Palette.gold],
                           startJitter: 0.05, delay: (1.34, 1.42))
        node.setPresence(0)
        ctx.onShake(0.04)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let offset = ctx.offset
        let scanStart: Float = 0.25
        let scanDur: Float = 1.08
        let sp = clamp01((age - scanStart) / scanDur)
        let eased = easeInOutCubic(sp)
        let scanY = -halfSpan + eased * halfSpan * 2
        let scanVisible = age >= scanStart && age < scanStart + scanDur + 0.04
        let appear = clamp01(age / 0.3)
        let fadeOut = 1 - clamp01((age - 1.45) / 0.55)
        let center = self.center + offset

        // Lattice.
        if fadeOut > 0.01 {
            for i in 0..<8 {
                let a = Float(i) / 8 * TAU + .pi / 8
                let color = i % 3 == 0 ? Palette.gold : Palette.signal
                let alpha = appear * fadeOut * 0.12
                let x = cos(a) * RL
                let z = sin(a) * RL
                draw.lines.append(LineVertex(center + Vec3(x, -halfSpan, z), rgba(color, alpha)))
                draw.lines.append(LineVertex(center + Vec3(x, halfSpan, z), rgba(color, alpha)))
            }
            for h in 0..<3 {
                let y = -R * 1.45 + Float(h) * R * 1.45
                let rr = RL * (0.92 + Float(h) * 0.015)
                var prev: Vec3?
                for i in 0...72 {
                    let a = Float(i) / 72 * TAU
                    let p = center + Vec3(cos(a) * rr, y, sin(a) * rr)
                    if let prev { draw.lines.append(LineVertex(prev, rgba(Palette.orbit, appear * fadeOut * 0.07))) ; draw.lines.append(LineVertex(p, rgba(Palette.orbit, appear * fadeOut * 0.07))) }
                    prev = p
                }
            }
        }

        if scanVisible {
            let scanAlpha = appear
            draw.scans.append(ScanUniforms(
                model: Mat4.translation(center + Vec3(0, scanY, 0)) * Mat4.scale(Vec3(repeating: RL * 1.4)),
                color: rgba(Palette.signalIce, 1),
                params: SIMD4(RL, RL * 1.4, scanAlpha * 0.72, age * 1.6)
            ))
            draw.scans.append(ScanUniforms(
                model: Mat4.translation(center + Vec3(0, scanY - R * 0.12, 0)) * Mat4.scale(Vec3(repeating: RL * 1.4)),
                color: rgba(Palette.gold, 1),
                params: SIMD4(RL * 0.98, RL * 1.4, scanAlpha * 0.28, -age * 1.1)
            ))
        }

        for f in fragments {
            let passed = scanY > f.y
            let glow = passed ? clamp01(1 - (scanY - f.y) / (halfSpan * 1.4)) : 0
            let alpha = glow * 0.5 * fadeOut
            guard alpha > 0.005 else { continue }
            let dir = Vec3(cos(f.a + .pi / 2), 0, sin(f.a + .pi / 2))
            let base = center + Vec3(cos(f.a) * f.offset, f.y, sin(f.a) * f.offset)
            draw.lines.append(LineVertex(base - dir * (f.len * 0.5), rgba(f.color, alpha)))
            draw.lines.append(LineVertex(base + dir * (f.len * 0.5), rgba(f.color, alpha)))
        }

        for m in motes {
            let cycle = (age * m.speed + m.phase).truncatingRemainder(dividingBy: 1)
            let y = center.y - halfSpan + cycle * halfSpan * 2
            let a = m.angle + age * 0.3
            let x = center.x + cos(a) * m.radius
            let z = center.z + sin(a) * m.radius
            let nearScan = 1 - clamp01(abs(y - (center.y + scanY)) / (R * 1.8))
            let alpha = appear * (0.1 + nearScan * 0.5) * fadeOut
            draw.points.append(PointVertex(Vec3(x, y, z), rgba(m.color, alpha), size: m.size))
        }

        flash.append(age: age, offset: offset, draw: draw)
        topRing.append(age: age, offset: offset, draw: draw)
        faceRing.append(age: age, offset: offset, draw: draw)
        burst.update(dt: dt, offset: offset, draw: draw)

        if age >= 1.34 && !fired {
            fired = true
            ctx.onShake(0.2)
        }
        if age > 1.28 {
            let reveal = clamp01((age - 1.3) / 0.36)
            let flicker: Float = age < 1.52 ? 0.5 + 0.5 * sin(age * 96) : 1
            node.setPresence(max(0, easeOutBack(reveal, 1.3)) * flicker)
            if age > 1.7 { node.setPresence(1) }
        }
    }
}

final class RedactionEffect: EffectStudy {
    let duration: Float = 1.95
    private let node: NodeView
    private let center: Vec3
    private let R: Float
    private let basisT: Vec3
    private let basisB: Vec3
    private let normal: Vec3
    private let perimeterRadius: Float
    private let perimeter: [Vec3]
    private let tickPoints: [(Vec3, Vec3)]
    private struct Mote {
        let angle: Float
        let radius: Float
        let speed: Float
        let dir: Float
        let phase: Float
        let size: Float
        let color: SRGB
    }
    private let motes: [Mote]
    private let flash: Flash
    private var fired = false

    init(ctx: EffectContext, node: NodeView) {
        self.node = node
        center = node.basePosition
        R = ctx.radius
        let normal = (ctx.camera.position - center).normalized
        self.normal = normal
        let basis = orthoBasis(normal)
        basisT = basis.t
        basisB = basis.b
        perimeterRadius = R * 2.15
        let aT = basis.t
        let aB = basis.b
        let pr = perimeterRadius
        perimeter = (0...144).map { i in
            let a = Float(i) / 144 * TAU - .pi / 2
            return aT * (cos(a) * pr) + aB * (sin(a) * pr)
        }
        var ticks: [(Vec3, Vec3)] = []
        for i in 0..<6 {
            let a = Float(i) / 6 * TAU
            ticks.append((aT * (cos(a) * pr * 0.96) + aB * (sin(a) * pr * 0.96),
                          aT * (cos(a) * pr * 1.1) + aB * (sin(a) * pr * 1.1)))
        }
        tickPoints = ticks
        let rng = ctx.rng
        var built: [Mote] = []
        for i in 0..<24 {
            built.append(Mote(
                angle: rng.next() * TAU,
                radius: R * (2.0 + rng.next() * 1.2),
                speed: 0.2 + rng.next() * 0.5,
                dir: rng.next() > 0.5 ? 1 : -1,
                phase: rng.next() * TAU,
                size: R * (0.035 + rng.next() * 0.06),
                color: i % 3 == 0 ? SRGB(hex: "ffd6c9") : (i % 3 == 1 ? SRGB(hex: "d94f43") : Palette.coral)
            ))
        }
        motes = built
        flash = Flash(point: center, size: R * 2.7, color: SRGB(hex: "fff0e8"),
                      haloColor: SRGB(hex: "d94f43"), duration: 0.52, delay: 0.9,
                      haloScale: 2.7, opacity: 0.58)
        node.setPresence(0)
        ctx.onShake(0.018)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let offset = ctx.offset
        let center = self.center + offset
        let drawT = clamp01((age - 0.04) / 0.78)
        let count = min(144, Int(drawT * 144))
        let perimeterAlpha = 0.62 * smoothstep(0, 0.08, age) * (1 - smoothstep(0.8, 1.22, age))
        if count > 0, age < 1.3 {
            for i in 0..<count {
                draw.lines.append(LineVertex(center + perimeter[i], rgba(SRGB(hex: "d94f43"), perimeterAlpha)))
                draw.lines.append(LineVertex(center + perimeter[i + 1], rgba(SRGB(hex: "d94f43"), perimeterAlpha)))
            }
            if count < 144 {
                let p = center + perimeter[count]
                draw.sprites.append(.glow(p, size: R * (0.14 + 0.06 * sin(age * 20)),
                                          color: SRGB(hex: "ffd6c9"), opacity: 0.8))
            }
        }
        let tickIn = smoothstep(0.45, 0.72, age)
        let tickAlpha = 0.4 * tickIn * (1 - smoothstep(0.95, 1.3, age))
        let tickRot = Mat4.rotation(quaternion: simd_quatf(angle: 0.12 * age, axis: normal))
        for (a, b) in tickPoints {
            let pa = tickRot * SIMD4(a, 1)
            let pb = tickRot * SIMD4(b, 1)
            draw.lines.append(LineVertex(center + Vec3(pa.x, pa.y, pa.z), rgba(Palette.coral, tickAlpha)))
            draw.lines.append(LineVertex(center + Vec3(pb.x, pb.y, pb.z), rgba(Palette.coral, tickAlpha)))
        }
        let coreIn = smoothstep(0.45, 0.95, age)
        draw.sprites.append(.glow(center, size: R * (0.8 + coreIn * 1.7),
                                  color: SRGB(hex: "d94f43"),
                                  opacity: 0.32 * coreIn * (1 - smoothstep(1.0, 1.4, age))))
        let contract = smoothstep(0.86, 1.35, age)
        let planeScale: Float = 1 - contract * 0.18
        let sealT = clamp01((age - 0.82) / 0.62)
        let sealR = R * (1.85 - 0.82 * easeOutCubic(sealT)) * planeScale
        let sealAlpha = 0.55 * smoothstep(0, 0.1, sealT) * (1 - smoothstep(0.62, 1, sealT))
        for i in 0...96 {
            let a = Float(i) / 96 * TAU
            let p0 = center + (basisT * cos(a) + basisB * sin(a)) * sealR
            let a1 = Float(i + 1) / 96 * TAU
            let p1 = center + (basisT * cos(a1) + basisB * sin(a1)) * sealR
            draw.lines.append(LineVertex(p0, rgba(SRGB(hex: "ffd6c9"), sealAlpha)))
            draw.lines.append(LineVertex(p1, rgba(SRGB(hex: "ffd6c9"), sealAlpha)))
        }

        flash.append(age: age, offset: offset, draw: draw)
        let moteP = easeInCubic(clamp01(age / 0.95))
        for m in motes {
            let r = m.radius * (1 - moteP * 0.78)
            let a = m.angle + m.dir * age * m.speed
            let pos = center + (basisT * cos(a) + basisB * sin(a)) * r
            let alpha = 0.4 * sin(.pi * clamp01(age / 1.1)) * (1 - clamp01((age - 0.95) / 0.5))
            draw.points.append(PointVertex(pos, rgba(m.color, max(0, alpha)), size: m.size))
        }

        if age > 0.9 {
            let reveal = clamp01((age - 0.9) / 0.38)
            let flicker: Float = age < 1.08 ? 0.68 + 0.32 * sin(age * 84) : 1
            node.setPresence(max(0, easeOutBack(reveal, 1.25)) * flicker)
            if !fired {
                fired = true
                ctx.onShake(0.03)
            }
        }
        if age > 1.3 { node.setPresence(1) }
    }
}
