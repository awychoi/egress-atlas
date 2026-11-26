import Foundation
import simd

/// Everything a motion study needs from the live scene. Effects are authored
/// against this shared contract.
struct EffectContext {
    var camera: Camera
    var node: NodeView?
    var radius: Float
    var point: Vec3
    var normal: Vec3
    var offset: Vec3 = .zero
    var elapsed: Float
    var onShake: (Float) -> Void
    var rng: RNG

    var origin: Vec3 { point + offset }
    var center: Vec3 { (node?.basePosition ?? point) + offset }
}

protocol EffectStudy: AnyObject {
    var duration: Float { get }
    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList)
}

// ── Shock ring (effects/shared.js ShockRing) ─────────────────────────────

final class ShockRing {
    let center: Vec3
    let basisT: Vec3
    let basisB: Vec3
    let start: Float
    let end: Float
    let half: Float
    let duration: Float
    let delay: Float
    let thickness: Float
    let rays: Float
    let seed: Float
    let opacity: Float
    let inner: Bool
    let hot: Float
    let core: SRGB
    let tail: SRGB
    let localOffset: Vec3

    init(point: Vec3, normal: Vec3, radius: Float,
         start: Float = 1.15, end: Float = 4.8, duration: Float = 1.2, delay: Float = 0,
         core: SRGB = SRGB(hex: "fff4d8"), tail: SRGB = Palette.gold,
         thickness: Float = 0.06, rays: Float = 0, seed: Float = 0,
         halfFactor: Float = 1.35, opacity: Float = 1,
         inner: Bool = false, hot: Float = 0,
         offset: Vec3 = .zero) {
        center = point
        let basis = orthoBasis(normal)
        basisT = basis.t
        basisB = basis.b
        self.start = radius * start
        self.end = radius * end
        self.half = max(self.end * halfFactor, radius * 2.4)
        self.duration = duration
        self.delay = delay
        self.thickness = radius * thickness
        self.rays = rays
        self.seed = seed
        self.opacity = opacity
        self.inner = inner
        self.hot = hot
        self.core = core
        self.tail = tail
        localOffset = offset
    }

    func setT(_ t: Float) -> Bool {
        let visible = t > 0.0001 && t < 1
        return visible
    }

    func append(age: Float, offset: Vec3, draw: DrawList) {
        let t = (age - delay) / duration
        guard t >= 0, t < 1 else { return }
        let c = center + offset + localOffset
        draw.shocks.append(ShockUniforms(
            center: SIMD4(c, 1),
            basisT: SIMD4(basisT, 1),
            basisB: SIMD4(basisB, 1),
            meta0: SIMD4(clamp01(t), start, end, half),
            meta1: SIMD4(thickness, rays, seed, opacity),
            meta2: SIMD4(inner ? 1 : 0, hot, 0, 0),
            core: rgba(core, 1),
            tail: rgba(tail, 1)
        ))
    }
}

// ── Flash ────────────────────────────────────────────────────────────────

final class Flash {
    let point: Vec3
    let size: Float
    let color: SRGB
    let haloColor: SRGB
    let duration: Float
    let delay: Float
    let opacity: Float
    let haloScale: Float

    init(point: Vec3, size: Float = 2, color: SRGB = SRGB(hex: "fff2cf"),
         haloColor: SRGB? = nil, duration: Float = 0.45, delay: Float = 0,
         haloScale: Float = 2.6, opacity: Float = 1) {
        self.point = point
        self.size = size
        self.color = color
        self.haloColor = haloColor ?? color
        self.duration = duration
        self.delay = delay
        self.opacity = opacity
        self.haloScale = haloScale
    }

    func append(age: Float, offset: Vec3, draw: DrawList) {
        let t = clamp01((age - delay) / duration)
        guard age >= delay, t < 1 else { return }
        let appear = clamp01((age - delay) / 0.015)
        let expand = 0.46 + easeOutCubic(t) * 0.9
        let fade = pow(1 - t, 2.1)
        let p = point + offset
        draw.sprites.append(.glow(p, size: size * expand, color: color,
                                  opacity: fade * 0.8 * appear * opacity))
        draw.sprites.append(.glow(p, size: size * (1.2 + easeOutCubic(t) * 1.8), color: haloColor,
                                  opacity: fade * 0.2 * appear * opacity))
    }
}

// ── Spark burst ──────────────────────────────────────────────────────────

final class SparkBurst {
    struct Particle {
        var radial: Vec3
        var offset: Vec3
        var vel: Vec3
        var drag: Float
        var life: Float
        var delay: Float
        var size: Float
        var color: SRGB
    }

    let origin: Vec3
    let normal: Vec3
    var opacity: Float
    let gravity: Float
    private(set) var particles: [Particle] = []
    private(set) var liveLife: Float = 0
    var elapsed: Float = 0

    init(count: Int, origin: Vec3, normal: Vec3, radius: Float, rng: RNG,
         mode: String = "ring", speed: (Float, Float) = (1.5, 5), tangential: Float = 0.6,
         normalSpeed: Float = 0.25, drag: Float = 0.8, life: (Float, Float) = (0.5, 1.2),
         size: (Float, Float) = (0.012, 0.06),
         palette: [SRGB] = [SRGB(hex: "fff4d8"), Palette.gold],
         startJitter: Float = 0.08, delay: (Float, Float) = (0, 0),
         opacity: Float = 1, gravity: Float = 0) {
        self.origin = origin
        self.normal = normal.normalized
        self.opacity = opacity
        self.gravity = gravity
        let basis = orthoBasis(normal)
        let t = basis.t
        let b = basis.b
        for _ in 0..<count {
            let angle = rng.next() * TAU
            let ringR: Float = mode == "disc"
                ? sqrt(rng.next()) * radius * 1.1
                : radius * (1 + (rng.next() - 0.5) * startJitter * 2)
            let radial = t * cos(angle) + b * sin(angle)
            let tangent = t * (-sin(angle)) + b * cos(angle)
            let rSpeed = speed.0 + (speed.1 - speed.0) * rng.next()
            let tSpeed = (rng.next() * 2 - 1) * tangential
            let nSpeed = (rng.next() * 2 - 1) * normalSpeed
            let vel = radial * rSpeed + tangent * tSpeed + self.normal * nSpeed
            let lf = life.0 + (life.1 - life.0) * rng.next()
            let offset = radial * ringR + self.normal * ((rng.next() * 2 - 1) * radius * 0.12)
            let d = drag * (0.7 + rng.next() * 0.6)
            let delayValue = delay.0 + (delay.1 - delay.0) * rng.next()
            let sizeValue = size.0 + (size.1 - size.0) * rng.next()
            let color = palette[Int(rng.next() * Float(palette.count)) % palette.count]
            particles.append(Particle(radial: radial, offset: offset, vel: vel, drag: d,
                                      life: lf, delay: delayValue, size: sizeValue, color: color))
            liveLife = max(liveLife, lf + delayValue)
        }
    }

    func update(dt: Float, offset: Vec3, draw: DrawList) {
        elapsed += dt
        // Integrate in place so every particle keeps its own velocity and drag.
        for i in particles.indices {
            let age = elapsed - particles[i].delay
            guard age >= 0, age <= particles[i].life else { continue }
            particles[i].offset += particles[i].vel * dt
            particles[i].vel *= exp(-particles[i].drag * dt)
            particles[i].vel += normal * (-gravity * dt)
        }
        for p in particles {
            let age = elapsed - p.delay
            guard age >= 0, age <= p.life else { continue }
            let lifeT = age / p.life
            let alpha = pow(1 - lifeT, 1.4) * clamp01(age / 0.012) * opacity
            let shrink = 0.55 + (1 - lifeT) * 0.75
            draw.points.append(PointVertex(origin + offset + p.offset,
                                           rgba(p.color, alpha), size: p.size * shrink))
        }
    }
}

// ── effect host ──────────────────────────────────────────────────────────

final class EffectEntry {
    let effect: EffectStudy
    var age: Float = 0
    let node: NodeView?
    let origin: Vec3
    let key: String?
    let kind: String

    init(effect: EffectStudy, node: NodeView?, origin: Vec3, key: String?, kind: String) {
        self.effect = effect
        self.node = node
        self.origin = origin
        self.key = key
        self.kind = kind
    }
}

final class EffectHost {
    private(set) var entries: [EffectEntry] = []

    func add(_ effect: EffectStudy, node: NodeView? = nil, origin: Vec3,
             key: String? = nil, kind: String = "effect") {
        if let key { cancel(key) }
        entries.append(EffectEntry(effect: effect, node: node, origin: origin, key: key, kind: kind))
    }

    func cancel(_ key: String) {
        entries.removeAll { $0.key == key }
    }

    func isActive(_ key: String) -> Bool { entries.contains { $0.key == key } }

    func update(dt: Float, ctx: EffectContext, draw: DrawList) {
        for i in entries.indices.reversed() {
            let entry = entries[i]
            entry.age += dt
            var frame = ctx
            if let node = entry.node {
                frame.offset = node.basePosition - entry.origin
            }
            entry.effect.update(dt: dt, age: entry.age, ctx: frame, draw: draw)
            if entry.age >= entry.effect.duration + 0.001 {
                entries.remove(at: i)
            }
        }
    }

    func countByKind(_ kind: String) -> Int { entries.filter { $0.kind == kind }.count }
    func clear() { entries.removeAll() }
}

// ── small builders ───────────────────────────────────────────────────────

enum EffectColors {
    static let gold = Palette.gold
    static let bone = SRGB(hex: "fff4d9")
    static let ice = Palette.signalIce
    static let signal = Palette.signal
    static let amber = SRGB(hex: "ffb25e")
    static let ember = SRGB(hex: "ff7a3a")
    static let coral = Palette.coral
    static let white = Palette.white
}

func glowSprite(_ p: Vec3, size: Float, color: SRGB, opacity: Float) -> SpriteInstance {
    .glow(p, size: size, color: color, opacity: opacity)
}

func lineObject(_ a: Vec3, _ b: Vec3, color: SRGB, opacity: Float) -> (Vec3, Vec3, SIMD4<Float>) {
    (a, b, rgba(color, opacity))
}

func tubeTriangles(points: [Vec3], radius: Float, color: SRGB, opacity: Float,
                   tubular: Int = 72, radial: Int = 5) -> [TriangleVertex] {
    let positions = GeometryKit.tube(points: points, radius: radius,
                                     tubularSegments: tubular, radialSegments: radial)
    let c = rgba(color, opacity)
    return positions.map { TriangleVertex(position: SIMD4($0, 1), color: c) }
}

func addLinePoints(_ draw: DrawList, _ points: [Vec3], color: SRGB, opacity: Float) {
    let c = rgba(color, opacity)
    guard points.count > 1 else { return }
    for i in 0..<(points.count - 1) {
        draw.lines.append(LineVertex(points[i], c))
        draw.lines.append(LineVertex(points[i + 1], c))
    }
}

func ringPoints(center: Vec3, axisX: Vec3, axisY: Vec3, radius: Float, segments: Int = 96) -> [Vec3] {
    (0...segments).map { i in
        let a = Float(i) / Float(segments) * TAU
        return center + axisX * (cos(a) * radius) + axisY * (sin(a) * radius)
    }
}
