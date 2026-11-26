import Foundation
import simd

// MARK: - Motion catalogue

/// The two body classes on the HOST globe. Each class owns its own reserved
/// motion pair for every event, so app arrivals/retirements never borrow a
/// destination's motion and vice versa.
enum HostMotionBody: String {
    case app
    case destination
}

enum HostMotionStyle: String, CaseIterable {
    case nova
    case hammer
    case ember
    case prism
    case weave
    case scan
    case condense
    case seed
    case fold
    case dissolve
    case implode
    case shear

    var isImpact: Bool {
        switch self {
        case .nova, .hammer, .ember, .prism: return true
        default: return false
        }
    }

    var isBirth: Bool {
        switch self {
        case .weave, .scan, .condense, .seed: return true
        default: return false
        }
    }

    var isDeath: Bool {
        switch self {
        case .fold, .dissolve, .implode, .shear: return true
        default: return false
        }
    }
}

enum HostMotionCatalog {
    /// Two reserved studies per body class and event.
    static let appImpacts: [HostMotionStyle] = [.nova, .hammer]
    static let destinationImpacts: [HostMotionStyle] = [.ember, .prism]
    static let appBirths: [HostMotionStyle] = [.weave, .scan]
    static let destinationBirths: [HostMotionStyle] = [.condense, .seed]
    static let appDeaths: [HostMotionStyle] = [.fold, .dissolve]
    static let destinationDeaths: [HostMotionStyle] = [.implode, .shear]

    static func impacts(for body: HostMotionBody) -> [HostMotionStyle] {
        body == .app ? appImpacts : destinationImpacts
    }

    static func births(for body: HostMotionBody) -> [HostMotionStyle] {
        body == .app ? appBirths : destinationBirths
    }

    static func deaths(for body: HostMotionBody) -> [HostMotionStyle] {
        body == .app ? appDeaths : destinationDeaths
    }

    /// Cheap catalogue guard: both body classes stay unique, every event keeps
    /// exactly two picks, and the twelve studies cover all four categories.
    static func selfCheck() -> [String] {
        var failed: [String] = []
        let groups: [(String, [HostMotionStyle], [HostMotionStyle])] = [
            ("impact", appImpacts, destinationImpacts),
            ("birth", appBirths, destinationBirths),
            ("death", appDeaths, destinationDeaths),
        ]
        var seen = Set<HostMotionStyle>()
        var impactCount = 0
        var birthCount = 0
        var deathCount = 0
        for (name, app, destination) in groups {
            if app.count != 2 { failed.append("\(name)-app-set") }
            if destination.count != 2 { failed.append("\(name)-destination-set") }
            if !Set(app).isDisjoint(with: Set(destination)) {
                failed.append("\(name)-overlap")
            }
            for style in app + destination {
                if seen.contains(style) { failed.append("duplicate-\(style.rawValue)") }
                seen.insert(style)
            }
            switch name {
            case "impact": impactCount = app.count + destination.count
            case "birth": birthCount = app.count + destination.count
            default: deathCount = app.count + destination.count
            }
        }
        if impactCount != 4 { failed.append("impact-count") }
        if birthCount != 4 { failed.append("birth-count") }
        if deathCount != 4 { failed.append("death-count") }
        if seen.count != HostMotionStyle.allCases.count {
            failed.append("style-coverage")
        }
        for style in HostMotionStyle.allCases {
            let grouped = (appImpacts + appBirths + appDeaths).contains(style)
                || (destinationImpacts + destinationBirths + destinationDeaths).contains(style)
            if !grouped { failed.append("ungrouped-\(style.rawValue)") }
        }
        return failed
    }
}

// MARK: - Shared building blocks

private let hostWhite = SRGB(hex: "f4feff")
private let hostViolet = Palette.hostOut
private let hostVioletHot = Palette.hostOutHot

private func hostNormal(_ value: Vec3) -> Vec3 {
    let length = value.lengthSq
    return length > 0.000001 ? value.normalized : Vec3(0, 0, -1)
}

private func hostBodyCore(_ body: HostMotionBody) -> SRGB {
    body == .app ? Palette.hostAppHot : Palette.hostRemoteHot
}

private func hostBodyTint(_ body: HostMotionBody) -> SRGB {
    body == .app ? Palette.hostApp : Palette.hostRemote
}

private func hostBodyDeep(_ body: HostMotionBody) -> SRGB {
    body == .app ? Palette.hostAppDeep : Palette.hostRemoteDeep
}

private func appendPolyline(_ draw: DrawList, _ points: [Vec3],
                            color: SRGB, alpha: Float) {
    guard points.count > 1, alpha > 0.002 else { return }
    let c = rgba(color, alpha)
    for i in 0..<(points.count - 1) {
        draw.lines.append(LineVertex(points[i], c))
        draw.lines.append(LineVertex(points[i + 1], c))
    }
}

private func appendHostGlow(_ draw: DrawList, at point: Vec3,
                            size: Float, color: SRGB, opacity: Float) {
    guard opacity > 0.002, size > 0.0001 else { return }
    draw.sprites.append(.glow(point, size: size, color: color, opacity: opacity))
}

private func hostRingPoint(_ center: Vec3, _ normal: Vec3,
                           radius: Float, angle: Float) -> Vec3 {
    let basis = orthoBasis(normal)
    return center
        + basis.t * (cos(angle) * radius)
        + basis.b * (sin(angle) * radius)
}

private func quadratic(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ t: Float) -> Vec3 {
    let it = 1 - t
    return a * (it * it) + b * (2 * it * t) + c * (t * t)
}

private struct HostMote {
    let angle: Float
    let radius: Float
    let spin: Float
    let normalOffset: Float
    let size: Float
    let delay: Float
    let color: SRGB
}

private func makeHostMotes(rng: RNG, count: Int, radius: Float,
                           inner: Float, outer: Float,
                           colors: [SRGB]) -> [HostMote] {
    (0..<count).map { _ in
        HostMote(angle: rng.next() * TAU,
                 radius: radius * (inner + rng.next() * (outer - inner)),
                 spin: (0.7 + rng.next() * 1.4) * (rng.next() > 0.15 ? 1 : -1),
                 normalOffset: (rng.next() * 2 - 1) * radius * 1.1,
                 size: radius * (0.018 + rng.next() * 0.055),
                 delay: rng.next() * 0.06,
                 color: colors[rng.int(colors.count)])
    }
}

private func appendConvergingMotes(_ motes: [HostMote], age: Float,
                                   center: Vec3, normal: Vec3, radius: Float,
                                   collapse: Float, spin: Float,
                                   draw: DrawList, opacity: Float) {
    guard age >= 0 else { return }
    let basis = orthoBasis(normal)
    let p = clamp01(age / max(0.001, collapse))
    let q = easeInCubic(p)
    for mote in motes {
        let a = age - mote.delay
        guard a >= 0 else { continue }
        let r = mote.radius * (1 - q * 0.985)
        let angle = mote.angle + mote.spin * p * 2.6 + spin
        let pos = center
            + basis.t * (cos(angle) * r)
            + basis.b * (sin(angle) * r)
            + normal * (mote.normalOffset * (1 - q * 0.9))
        let alpha = pow(1 - p, 0.5) * clamp01(a / 0.03) * opacity
        if alpha < 0.004 { continue }
        draw.points.append(PointVertex(pos, rgba(mote.color, alpha), size: mote.size))
        if mote.size > radius * 0.04 {
            appendHostGlow(draw, at: pos, size: mote.size * 6,
                           color: mote.color, opacity: alpha * 0.22)
        }
    }
}

private struct HostShard {
    let angle: Float
    let start: Float
    let speed: Float
    let tangential: Float
    let normalSpeed: Float
    let drag: Float
    let spin: Float
    let axis: Vec3
    let len: Float
    let wide: Float
    let thick: Float
    let color: SRGB
    let delay: Float
}

private func makeHostShards(rng: RNG, count: Int, radius: Float,
                            colors: [SRGB],
                            speed: (Float, Float) = (1.2, 3.6),
                            tangential: Float = 1.2,
                            normalSpeed: Float = 0.5,
                            size: (Float, Float) = (0.3, 0.7),
                            startRadius: Float = 0.62,
                            delay: (Float, Float) = (0, 0.06)) -> [HostShard] {
    (0..<count).map { _ in
        let length = radius * (size.0 + rng.next() * (size.1 - size.0))
        let width = length * (0.22 + rng.next() * 0.4)
        return HostShard(
            angle: rng.next() * TAU,
            start: radius * startRadius * (0.7 + rng.next() * 0.5),
            speed: radius * (speed.0 + rng.next() * (speed.1 - speed.0)),
            tangential: (rng.next() * 2 - 1) * tangential * radius,
            normalSpeed: (rng.next() * 2 - 1) * normalSpeed * radius,
            drag: 0.5 + rng.next() * 0.6,
            spin: (rng.next() * 2 - 1) * 8,
            axis: hostNormal(Vec3(rng.next() * 2 - 1, rng.next() * 2 - 1, rng.next() * 2 - 1)),
            len: length,
            wide: width,
            thick: width * (0.32 + rng.next() * 0.25),
            color: colors[rng.int(colors.count)],
            delay: delay.0 + rng.next() * (delay.1 - delay.0)
        )
    }
}

private func appendHostShards(_ shards: [HostShard], age: Float,
                              center: Vec3, normal: Vec3,
                              draw: DrawList, opacity: Float) {
    let basis = orthoBasis(normal)
    for shard in shards {
        let a = age - shard.delay
        guard a > 0, a < 1.45 else { continue }
        let travel = (1 - exp(-shard.drag * a)) / shard.drag
        let radial = basis.t * cos(shard.angle) + basis.b * sin(shard.angle)
        let tangent = basis.t * (-sin(shard.angle)) + basis.b * cos(shard.angle)
        let position = center
            + radial * (shard.start + shard.speed * travel)
            + tangent * (shard.tangential * travel)
            + normal * (shard.normalSpeed * travel)
        let fade = (1 - smoothstep(0.55, 1.35, a)) * clamp01(a / 0.035) * opacity
        if fade < 0.004 { continue }
        let q = simd_quatf(angle: shard.spin * a, axis: shard.axis)
        let shrink = 0.72 + min(1, a * 2.4) * 0.45
        let model = Mat4.compose(position: position, quaternion: q,
                                 scale: Vec3(shard.wide * shrink,
                                             shard.len * shrink,
                                             shard.thick * shrink))
        draw.addMesh(.box, MeshInstance(model: model,
                                        color: rgba(shard.color, fade * 0.86)))
    }
}

// MARK: - Impact studies

/// Shared host impact body. Nova and Hammer are reserved for apps; Ember and
/// Prism are reserved for destinations. All four are authored around the same
/// shock-ring/flash/spark contract so they read as one instrument family while
/// keeping distinct silhouettes.
final class HostMotionImpactEffect: EffectStudy {
    let duration: Float
    let style: HostMotionStyle
    let body: HostMotionBody
    private let point: Vec3
    private let normal: Vec3
    private let R: Float
    private let core: SRGB
    private let tail: SRGB
    private let hot: SRGB
    private let seed: Float
    private var rings: [ShockRing] = []
    private var flashes: [Flash] = []
    private var bursts: [SparkBurst] = []
    private var shards: [HostShard] = []
    private var preRing: ShockRing?
    private var crackAngles: [Float] = []
    private let crackBasis: (t: Vec3, b: Vec3)

    private static func normalized(_ style: HostMotionStyle) -> HostMotionStyle {
        style.isImpact ? style : .nova
    }

    private static func duration(for style: HostMotionStyle) -> Float {
        switch style {
        case .nova: return 1.12
        case .ember: return 1.88
        case .prism: return 1.30
        case .hammer: return 1.55
        default: return 1.12
        }
    }

    private static func palette(for style: HostMotionStyle,
                                body: HostMotionBody) -> (SRGB, SRGB, SRGB) {
        let roleCore = hostBodyCore(body)
        switch style {
        case .nova:
            return (hostWhite, body == .app ? roleCore : Palette.hostGlow, hostVioletHot)
        case .hammer:
            return (Palette.hostIce, hostViolet, hostWhite)
        case .ember:
            return (Palette.hostIce, Palette.hostGlow, hostVioletHot)
        case .prism:
            return (hostWhite, hostViolet, Palette.hostRemoteHot)
        default:
            return (hostWhite, Palette.hostGlow, hostVioletHot)
        }
    }

    init(style: HostMotionStyle, point: Vec3, normal: Vec3, radius: Float,
         body: HostMotionBody, rng: RNG) {
        let resolved = Self.normalized(style)
        self.style = resolved
        self.body = body
        self.point = point
        self.normal = hostNormal(normal)
        self.R = max(0.24, radius)
        self.duration = Self.duration(for: resolved)
        let palette = Self.palette(for: resolved, body: body)
        self.core = palette.0
        self.tail = palette.1
        self.hot = palette.2
        self.seed = rng.next() * 9
        let basis = orthoBasis(self.normal)
        self.crackBasis = (basis.t, basis.b)
        let roleCore = hostBodyCore(body)
        let roleTint = hostBodyTint(body)
        let ice = Palette.hostIce
        let glow = Palette.hostGlow
        let deep = Palette.hostDeep

        switch resolved {
        case .nova:
            let seedA = seed
            let seedB = rng.next() * 9
            let seedC = rng.next() * 9
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 1.12, end: 4.25, duration: 0.92,
                          core: hostWhite, tail: body == .app ? roleTint : hostViolet,
                          thickness: 0.045, rays: 28, seed: seedA,
                          halfFactor: 1.50, opacity: 0.94),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.92, end: 2.95, duration: 0.95, delay: 0.055,
                          core: ice, tail: deep,
                          thickness: 0.021, rays: 0, seed: seedB,
                          halfFactor: 1.55, opacity: 0.55),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 1.0, end: 3.5, duration: 0.48,
                          core: hostWhite, tail: roleCore,
                          thickness: 0.011, rays: 44, seed: seedC,
                          halfFactor: 1.45, opacity: 0.62),
            ]
            flashes = [
                Flash(point: point, size: R * 4.5, color: hostWhite,
                      haloColor: hot, duration: 0.48, haloScale: 3.0, opacity: 0.92),
            ]
            bursts = [
                SparkBurst(count: 36, origin: point, normal: self.normal,
                           radius: R * 0.78, rng: rng, mode: "disc",
                           speed: (1.8, 5.4), tangential: 1.8, normalSpeed: 1.2,
                           drag: 1.28, life: (0.30, 0.85), size: (0.012, 0.042),
                           palette: [hostWhite, ice, roleCore, hostViolet],
                           startJitter: 0.20, delay: (0, 0.04), opacity: 0.9),
            ]
        case .ember:
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.9, end: 4.2, duration: 1.55,
                          core: hostWhite, tail: glow,
                          thickness: 0.095, rays: 24, seed: rng.next() * 9,
                          halfFactor: 1.65, opacity: 0.82),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.7, end: 3.2, duration: 1.22, delay: 0.08,
                          core: ice, tail: deep,
                          thickness: 0.065, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.70, opacity: 0.66),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 1.0, end: 2.6, duration: 0.8, delay: 0.28,
                          core: hostVioletHot, tail: hostViolet,
                          thickness: 0.028, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.60, opacity: 0.50),
            ]
            flashes = [
                Flash(point: point, size: R * 4.6, color: hostWhite,
                      haloColor: glow, duration: 0.74, haloScale: 3.2, opacity: 0.82),
                Flash(point: point, size: R * 2.8, color: ice,
                      haloColor: hostViolet, duration: 0.50, delay: 0.12,
                      haloScale: 3.0, opacity: 0.42),
            ]
            bursts = [
                SparkBurst(count: 96, origin: point, normal: self.normal,
                           radius: R * 0.9, rng: rng, mode: "disc",
                           speed: (1.2, 4.5), tangential: 1.3, normalSpeed: 0.8,
                           drag: 0.62, life: (0.8, 1.75),
                           size: (0.012, 0.044),
                           palette: [ice, Palette.host, hostViolet, hostWhite],
                           startJitter: 0.16, delay: (0, 0.08), opacity: 0.95),
                SparkBurst(count: 26, origin: point, normal: self.normal,
                           radius: R * 0.9, rng: rng, mode: "disc",
                           speed: (2.2, 4.8), tangential: 0.8, normalSpeed: 0.9,
                           drag: 0.32, life: (1.0, 1.75),
                           size: (0.04, 0.09),
                           palette: [hostWhite, ice, hostViolet],
                           startJitter: 0.08, delay: (0, 0.05), opacity: 0.9),
                SparkBurst(count: 26, origin: point, normal: self.normal,
                           radius: R * 0.7, rng: rng, mode: "disc",
                           speed: (0.2, 1.3), tangential: 0.5, normalSpeed: 0.2,
                           drag: 0.42, life: (0.9, 2.0),
                           size: (0.09, 0.2),
                           palette: [glow, ice, hostViolet],
                           startJitter: 0.2, delay: (0.02, 0.1), opacity: 0.22),
            ]
        case .prism:
            crackAngles = (0..<3).map { _ in rng.next() * TAU }
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 1.08, end: 3.8, duration: 0.72,
                          core: hostWhite, tail: hostViolet,
                          thickness: 0.02, rays: 40, seed: rng.next() * 9,
                          halfFactor: 1.5, opacity: 0.82),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.94, end: 3.4, duration: 0.9, delay: 0.05,
                          core: Palette.host, tail: deep,
                          thickness: 0.014, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.6, opacity: 0.48,
                          offset: basis.t * (R * 0.055)),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.9, end: 3.0, duration: 0.84, delay: 0.09,
                          core: hostVioletHot, tail: hostViolet,
                          thickness: 0.014, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.6, opacity: 0.38,
                          offset: basis.t * (-R * 0.05)),
            ]
            flashes = [
                Flash(point: point, size: R * 4.2, color: hostWhite,
                      haloColor: hostViolet, duration: 0.35, haloScale: 2.8, opacity: 0.9),
                Flash(point: point, size: R * 3.4, color: ice,
                      haloColor: Palette.host, duration: 0.50, delay: 0.03,
                      haloScale: 3.0, opacity: 0.5),
            ]
            shards = makeHostShards(rng: rng, count: 24, radius: R,
                                    colors: [ice, Palette.hostRemoteHot,
                                             hostViolet, roleCore, hostWhite],
                                    speed: (1.4, 3.8), tangential: 0.8,
                                    normalSpeed: 0.6, size: (0.28, 0.72),
                                    startRadius: 0.72, delay: (0, 0.06))
            bursts = [
                SparkBurst(count: 42, origin: point, normal: self.normal,
                           radius: R * 0.8, rng: rng, mode: "disc",
                           speed: (2.4, 6.0), tangential: 1.4, normalSpeed: 1.3,
                           drag: 0.8, life: (0.28, 0.80), size: (0.01, 0.04),
                           palette: [hostWhite, ice, hostViolet, Palette.host],
                           startJitter: 0.12, delay: (0, 0.05), opacity: 0.9),
            ]
        case .hammer:
            let pre = ShockRing(point: point, normal: self.normal, radius: R,
                                start: 2.8, end: 0.10, duration: 0.22,
                                core: ice, tail: hostViolet,
                                thickness: 0.030, rays: 0, seed: rng.next() * 9,
                                halfFactor: 1.35, opacity: 0.9)
            preRing = pre
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.35, end: 5.5, duration: 1.08, delay: 0.18,
                          core: hostWhite, tail: hostViolet,
                          thickness: 0.062, rays: 18, seed: rng.next() * 9,
                          halfFactor: 1.65, opacity: 0.95),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.55, end: 3.8, duration: 0.92, delay: 0.22,
                          core: ice, tail: Palette.host,
                          thickness: 0.022, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.6, opacity: 0.5),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.8, end: 2.4, duration: 0.55, delay: 0.18,
                          core: Palette.host, tail: deep,
                          thickness: 0.030, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.6, opacity: 0.55, inner: true),
            ]
            flashes = [
                Flash(point: point, size: R * 5.2, color: hostWhite,
                      haloColor: hostViolet, duration: 0.52, delay: 0.18,
                      haloScale: 3.3, opacity: 0.95),
            ]
            shards = makeHostShards(rng: rng, count: 10, radius: R,
                                    colors: [ice, hostWhite, hostViolet],
                                    speed: (0.8, 2.4), tangential: 0.6,
                                    normalSpeed: 0.6, size: (0.25, 0.6),
                                    startRadius: 0.7, delay: (0.18, 0.23))
            bursts = [
                SparkBurst(count: 66, origin: point, normal: self.normal,
                           radius: R * 0.8, rng: rng, mode: "disc",
                           speed: (1.6, 6.2), tangential: 2.2, normalSpeed: 1.5,
                           drag: 0.9, life: (0.35, 1.15), size: (0.012, 0.05),
                           palette: [hostWhite, ice, Palette.host, hostViolet],
                           startJitter: 0.1, delay: (0.18, 0.24), opacity: 0.95),
                SparkBurst(count: 30, origin: point, normal: self.normal,
                           radius: R * 1.0, rng: rng, mode: "disc",
                           speed: (0.7, 2.2), tangential: 1.1, normalSpeed: 0.6,
                           drag: 0.25, life: (1.0, 1.6), size: (0.024, 0.07),
                           palette: [ice, hostViolet, Palette.hostDim],
                           startJitter: 0.2, delay: (0.18, 0.28), opacity: 0.5),
            ]
        default:
            break
        }
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        let offset = ctx.offset
        for ring in rings {
            ring.append(age: age, offset: offset, draw: draw)
        }
        preRing?.append(age: age, offset: offset, draw: draw)
        for flash in flashes {
            flash.append(age: age, offset: offset, draw: draw)
        }
        for burst in bursts {
            burst.update(dt: dt, offset: offset, draw: draw)
        }

        switch style {
        case .nova:
            let trace = easeOutCubic(clamp01(age / 0.38))
            let travel = R * (0.2 + trace * 3.2)
            let tip = point + offset + normal * travel
            let base = point + offset - normal * (R * 0.16)
            let fade = pow(1 - clamp01(age / 0.70), 1.6)
            draw.addLine(base, tip, rgba(iceColor(), fade * 0.62))
            draw.addLine(base + crackBasis.t * (R * 0.004),
                         tip + crackBasis.t * (R * 0.004),
                         rgba(hostWhite, fade * 0.32))
            appendHostGlow(draw, at: tip, size: R * (0.8 + trace * 1.2),
                           color: hot, opacity: fade * 0.72)
            appendHostGlow(draw, at: tip, size: R * 0.46,
                           color: hostWhite, opacity: fade * 0.9)
            if age < 0.55 {
                let head = easeOutCubic(clamp01(age / 0.40))
                let a = point + offset - normal * (R * 4.6 * (1 - head))
                let b = a - normal * (R * 0.3)
                draw.addLine(a, b, rgba(hostVioletHot, pow(1 - head, 1.6) * 0.42))
            }
        case .ember:
            let t = clamp01(age / duration)
            appendHostGlow(draw, at: point + offset,
                           size: R * (2.6 + easeOutCubic(t) * 5.4),
                           color: Palette.hostGlow,
                           opacity: pow(1 - t, 1.1) * 0.18)
            appendHostGlow(draw, at: point + offset, size: R * 1.35,
                           color: Palette.hostIce,
                           opacity: pow(1 - t, 2.1) * 0.28)
        case .prism:
            appendHostShards(shards, age: age, center: point + offset,
                             normal: normal, draw: draw, opacity: 0.94)
            if age < 0.20 {
                let fade = (1 - age / 0.20) * 0.55
                for angle in crackAngles {
                    let dir = crackBasis.t * cos(angle) + crackBasis.b * sin(angle)
                    let a = point + offset - dir * (R * 1.25)
                    let b = point + offset + dir * (R * 1.25)
                    draw.addLine(a, b, rgba(hostWhite, fade))
                }
            }
        case .hammer:
            if age < 0.20 {
                let t = clamp01(age / 0.20)
                appendHostGlow(draw, at: point + offset,
                               size: R * (0.6 + t * 3.0),
                               color: Palette.hostIce,
                               opacity: t * 0.36)
            }
        default:
            break
        }
    }

    private func iceColor() -> SRGB { Palette.hostIce }
}

// MARK: - Presence contract

protocol HostPresenceDrivenStudy: AnyObject {
    var onPresence: ((Float) -> Void)? { get set }
    var onFinish: (() -> Void)? { get set }
}

// MARK: - Birth studies

private struct HostTendril {
    let origin: Vec3
    let seed: Float
    let start: Float
    let duration: Float
    let basisT: Vec3
    let basisB: Vec3
    let color: SRGB
}

private struct HostFilament {
    let points: [Vec3]
    let start: Float
    let duration: Float
    let color: SRGB
}

final class HostMotionBirthEffect: EffectStudy, HostPresenceDrivenStudy {
    let duration: Float
    let style: HostMotionStyle
    let body: HostMotionBody
    var onPresence: ((Float) -> Void)?
    var onFinish: (() -> Void)?

    private let point: Vec3
    private let normal: Vec3
    private let R: Float
    private let core: SRGB
    private let tail: SRGB
    private let hot: SRGB
    private let camera: Camera
    private let normalBasisT: Vec3
    private let normalBasisB: Vec3
    private var rings: [ShockRing] = []
    private var flashes: [Flash] = []
    private var bursts: [SparkBurst] = []
    private var motes: [HostMote] = []
    private var tendrils: [HostTendril] = []
    private var filaments: [HostFilament] = []
    private var scanMotes: [(angle: Float, radius: Float, speed: Float, phase: Float, size: Float, color: SRGB)] = []
    private let seedStart: Vec3
    private var finished = false

    private static func normalized(_ style: HostMotionStyle) -> HostMotionStyle {
        style.isBirth ? style : .condense
    }

    private static func duration(for style: HostMotionStyle) -> Float {
        switch style {
        case .weave: return 1.35
        case .scan: return 1.05
        case .condense: return 1.15
        case .seed: return 1.35
        default: return 1.15
        }
    }

    private static func palette(for body: HostMotionBody) -> (SRGB, SRGB, SRGB) {
        if body == .app {
            return (Palette.hostAppHot, Palette.hostApp, Palette.hostIce)
        }
        return (Palette.hostRemoteHot, Palette.hostRemote, Palette.hostGlow)
    }

    init(style: HostMotionStyle, point: Vec3, normal: Vec3, radius: Float,
         body: HostMotionBody, camera: Camera, rng: RNG) {
        let resolved = Self.normalized(style)
        self.style = resolved
        self.body = body
        self.point = point
        self.normal = hostNormal(normal)
        self.R = max(0.24, radius)
        self.camera = camera
        self.duration = Self.duration(for: resolved)
        let palette = Self.palette(for: body)
        self.core = palette.0
        self.tail = palette.1
        self.hot = palette.2
        let basis = orthoBasis(self.normal)
        self.normalBasisT = basis.t
        self.normalBasisB = basis.b
        let toCam = hostNormal(camera.position - point)
        let camBasis = orthoBasis(toCam)
        self.seedStart = point + Vec3(0, R * 2.6, 0) + camBasis.t * (R * 0.2)
        let roleCore = hostBodyCore(body)
        let ice = Palette.hostIce
        let glow = Palette.hostGlow

        switch resolved {
        case .weave:
            var built: [HostTendril] = []
            for i in 0..<6 {
                let angle = (Float(i) / 6) * TAU + (rng.next() - 0.5) * 0.22
                let radial = camBasis.t * cos(angle) + camBasis.b * sin(angle)
                let origin = point
                    + radial * (R * (2.25 + rng.next() * 0.65))
                    + toCam * ((rng.next() - 0.5) * R * 0.24)
                let dir = hostNormal(origin - point)
                let wobbleBasis = orthoBasis(dir)
                let color = i == 2 ? Palette.host : (i % 2 == 0 ? roleCore : ice)
                built.append(HostTendril(
                    origin: origin,
                    seed: rng.next() * 100,
                    start: Float(i) * 0.032 + rng.next() * 0.03,
                    duration: 0.4 + rng.next() * 0.08,
                    basisT: wobbleBasis.t,
                    basisB: wobbleBasis.b,
                    color: color))
            }
            self.tendrils = built
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.85, end: 2.7, duration: 0.85, delay: 0.57,
                          core: roleCore, tail: glow,
                          thickness: 0.03, rays: 10, seed: rng.next() * 9,
                          halfFactor: 1.6, opacity: 0.55),
            ]
            flashes = [
                Flash(point: point, size: R * 2.7, color: hostWhite,
                      haloColor: roleCore, duration: 0.46, delay: 0.57,
                      haloScale: 2.8, opacity: 0.7),
            ]
            bursts = [
                SparkBurst(count: 34, origin: point, normal: self.normal,
                           radius: R * 0.75, rng: rng, mode: "disc",
                           speed: (1.2, 4.6), tangential: 2.2, normalSpeed: 1.4,
                           drag: 1.1, life: (0.32, 0.90), size: (0.01, 0.04),
                           palette: [roleCore, ice, Palette.host, hostWhite, hostViolet],
                           startJitter: 0.18, delay: (0.57, 0.64), opacity: 0.75),
            ]
        case .scan:
            var built: [(angle: Float, radius: Float, speed: Float, phase: Float, size: Float, color: SRGB)] = []
            for i in 0..<10 {
                built.append((
                    angle: rng.next() * TAU,
                    radius: R * (1.2 + rng.next() * 1.2),
                    speed: 0.7 + rng.next() * 1.2,
                    phase: rng.next() * TAU,
                    size: R * (0.018 + rng.next() * 0.03),
                    color: i % 3 == 0 ? roleCore : ice))
            }
            self.scanMotes = built
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.9, end: 3.0, duration: 0.82, delay: 0.78,
                          core: ice, tail: Palette.host,
                          thickness: 0.028, rays: 16, seed: rng.next() * 9,
                          halfFactor: 1.55, opacity: 0.55),
            ]
            flashes = [
                Flash(point: point, size: R * 2.4, color: hostWhite,
                      haloColor: roleCore, duration: 0.40, delay: 0.78,
                      haloScale: 2.7, opacity: 0.62),
            ]
            bursts = [
                SparkBurst(count: 26, origin: point, normal: self.normal,
                           radius: R * 0.5, rng: rng, mode: "disc",
                           speed: (1.0, 3.4), tangential: 1.4, normalSpeed: 1.2,
                           drag: 0.95, life: (0.30, 0.82), size: (0.01, 0.038),
                           palette: [hostWhite, roleCore, Palette.host, hostViolet],
                           startJitter: 0.1, delay: (0.78, 0.84), opacity: 0.75),
            ]
        case .condense:
            motes = makeHostMotes(rng: rng, count: 44, radius: R,
                                  inner: 2.3, outer: 3.5,
                                  colors: [roleCore, Palette.host, ice, hostWhite])
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.8, end: 2.65, duration: 0.8, delay: 0.48,
                          core: roleCore, tail: Palette.host,
                          thickness: 0.033, rays: 14, seed: rng.next() * 9,
                          halfFactor: 1.55, opacity: 0.55),
            ]
            flashes = [
                Flash(point: point, size: R * 2.9, color: hostWhite,
                      haloColor: roleCore, duration: 0.42, delay: 0.48,
                      haloScale: 2.8, opacity: 0.78),
            ]
            bursts = [
                SparkBurst(count: 20, origin: point, normal: self.normal,
                           radius: R * 0.6, rng: rng, mode: "disc",
                           speed: (0.8, 2.8), tangential: 1.8, normalSpeed: 1.0,
                           drag: 1.1, life: (0.30, 0.80), size: (0.008, 0.032),
                           palette: [roleCore, Palette.host, hostWhite, hostViolet],
                           startJitter: 0.12, delay: (0.48, 0.55), opacity: 0.72),
            ]
        case .seed:
            var built: [HostFilament] = []
            for i in 0..<8 {
                let angle = (Float(i) / 8) * TAU + (rng.next() - 0.5) * 0.18
                let radial = normalBasisT * cos(angle) + normalBasisB * sin(angle)
                let tangent = normalBasisT * (-sin(angle)) + normalBasisB * cos(angle)
                let p0 = point
                let p1 = point + radial * (R * 0.25) + tangent * (R * 0.2)
                let p2 = point + radial * (R * (1.0 + rng.next() * 0.35))
                    + tangent * (R * (0.4 + rng.next() * 0.4))
                    + self.normal * (R * 0.14)
                let p3 = point + radial * (R * (1.3 + rng.next() * 0.4))
                    + tangent * (R * (0.1 + rng.next() * 0.3))
                    + self.normal * (R * 0.12)
                let curve = CatmullRom(points: [p0, p1, p2, p3],
                                       closed: false, curveType: "centripetal",
                                       tension: 0.5)
                let pts = (0...24).map { curve.pointAt(Float($0) / 24) }
                let color = i % 4 == 0 ? Palette.host
                    : (i % 3 == 0 ? roleCore : ice)
                built.append(HostFilament(points: pts,
                                          start: 0.45 + Float(i) * 0.026,
                                          duration: 0.34,
                                          color: color))
            }
            self.filaments = built
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.5, end: 2.5, duration: 0.72, delay: 0.37,
                          core: roleCore, tail: Palette.host,
                          thickness: 0.022, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.6, opacity: 0.48),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.7, end: 2.9, duration: 0.8, delay: 0.80,
                          core: ice, tail: roleCore,
                          thickness: 0.026, rays: 12, seed: rng.next() * 9,
                          halfFactor: 1.55, opacity: 0.45),
            ]
            flashes = [
                Flash(point: point, size: R * 2.7, color: hostWhite,
                      haloColor: roleCore, duration: 0.44, delay: 0.37,
                      haloScale: 2.8, opacity: 0.68),
                Flash(point: point, size: R * 2.4, color: ice,
                      haloColor: roleCore, duration: 0.42, delay: 0.80,
                      haloScale: 2.7, opacity: 0.55),
            ]
            bursts = [
                SparkBurst(count: 30, origin: point, normal: self.normal,
                           radius: R * 0.5, rng: rng, mode: "disc",
                           speed: (0.6, 2.7), tangential: 2.0, normalSpeed: 1.2,
                           drag: 0.9, life: (0.28, 0.80), size: (0.01, 0.036),
                           palette: [hostWhite, roleCore, Palette.host, hostViolet],
                           startJitter: 0.12, delay: (0.37, 0.41), opacity: 0.8),
                SparkBurst(count: 22, origin: point, normal: self.normal,
                           radius: R * 0.85, rng: rng, mode: "disc",
                           speed: (0.1, 0.6), tangential: 0.3, normalSpeed: 0.2,
                           drag: 1.4, life: (0.5, 1.1), size: (0.012, 0.035),
                           palette: [ice, hostViolet, roleCore],
                           startJitter: 0.2, delay: (0.90, 1.10), opacity: 0.45),
            ]
        default:
            break
        }
    }

    private func presence(at age: Float) -> Float {
        switch style {
        case .condense:
            guard age > 0.50 else { return 0 }
            return clamp(easeOutBack(clamp01((age - 0.50) / 0.28), 1.28), 0, 1.05)
        case .weave:
            guard age > 0.58 else { return 0 }
            return clamp(easeOutBack(clamp01((age - 0.58) / 0.26), 1.30), 0, 1.05)
        case .scan:
            guard age > 0.10 else { return 0 }
            return easeInOutCubic(clamp01((age - 0.10) / 0.64))
        case .seed:
            guard age > 0.80 else { return 0 }
            return clamp(easeOutBack(clamp01((age - 0.80) / 0.28), 1.35), 0, 1.06)
        default:
            return 1
        }
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        onPresence?(presence(at: age))
        let offset = ctx.offset
        let center = point + offset
        for ring in rings {
            ring.append(age: age, offset: offset, draw: draw)
        }
        for flash in flashes {
            flash.append(age: age, offset: offset, draw: draw)
        }
        for burst in bursts {
            burst.update(dt: dt, offset: offset, draw: draw)
        }

        switch style {
        case .weave:
            for tendril in tendrils {
                let raw = clamp01((age - tendril.start) / tendril.duration)
                guard raw > 0 else { continue }
                let reach = easeInOutCubic(raw)
                var points: [Vec3] = []
                points.reserveCapacity(27)
                for j in 0...26 {
                    let f = Float(j) / 26
                    let base = tendril.origin.lerp(center, reach * f)
                    let amp = R * 0.72 * (1 - reach * 0.55) * (0.35 + f * 0.9)
                    let wobble = sin(f * 16 + tendril.seed + age * 18) * amp
                        + cos(f * 29 - age * 12 + tendril.seed * 0.7) * amp * 0.3
                    let p = base
                        + tendril.basisT * wobble
                        + tendril.basisB * (cos(f * 11 + tendril.seed) * amp * 0.55)
                    points.append(p)
                }
                let fade = clamp01(raw / 0.12) * (raw > 0.94 ? (1 - raw) / 0.06 : 1)
                appendPolyline(draw, points, color: tendril.color, alpha: fade * 0.62)
                if let tip = points.last, raw < 0.98 {
                    appendHostGlow(draw, at: tip, size: R * 0.45,
                                   color: tendril.color, opacity: fade * 0.55)
                    appendHostGlow(draw, at: tip, size: R * 0.14,
                                   color: hostWhite, opacity: fade * 0.7)
                }
            }
            if age < 0.62 {
                appendHostGlow(draw, at: center, size: R * 1.7,
                               color: core, opacity: 0.18 * clamp01(age / 0.58))
            }
        case .scan:
            let scanStart: Float = 0.12
            let scanDur: Float = 0.62
            let halfSpan = R * 1.75
            let scanT = clamp01((age - scanStart) / scanDur)
            let eased = easeInOutCubic(scanT)
            let scanY = -halfSpan + eased * halfSpan * 2
            let visible = age >= scanStart && age < scanStart + scanDur + 0.04
            let fadeOut = 1 - smoothstep(0.80, 1.02, age)
            if age < 1.0 {
                for i in 0..<8 {
                    let angle = (Float(i) / 8) * TAU + .pi / 8
                    let x = cos(angle) * R * 2.5
                    let z = sin(angle) * R * 2.5
                    let a = center + Vec3(x, -halfSpan, z)
                    let b = center + Vec3(x, halfSpan, z)
                    draw.addLine(a, b, rgba(tail, 0.09 * fadeOut))
                }
                for i in 0..<3 {
                    let y = -R * 1.35 + Float(i) * R * 1.35
                    let rr = R * 2.3
                    var previous: Vec3?
                    for j in 0...56 {
                        let angle = Float(j) / 56 * TAU
                        let p = center + Vec3(cos(angle) * rr, y, sin(angle) * rr)
                        if let previous {
                            draw.addLine(previous, p, rgba(tail, 0.06 * fadeOut))
                        }
                        previous = p
                    }
                }
            }
            if visible {
                let opacity = smoothstep(0.07, 0.2, age) * (1 - smoothstep(0.80, 0.95, age))
                let radius = R * 2.5
                let extent = radius * 1.4
                draw.scans.append(ScanUniforms(
                    model: Mat4.translation(center + Vec3(0, scanY, 0))
                        * Mat4.scale(Vec3(repeating: extent)),
                    color: rgba(Palette.hostIce, 1),
                    params: SIMD4(radius, extent, opacity * 0.7, age * 1.6)))
                draw.scans.append(ScanUniforms(
                    model: Mat4.translation(center + Vec3(0, scanY - R * 0.10, 0))
                        * Mat4.scale(Vec3(repeating: extent)),
                    color: rgba(core, 1),
                    params: SIMD4(radius * 0.98, extent, opacity * 0.28, -age * 1.1)))
                let right = hostNormal(camera.forward.cross(camera.up))
                let a = center + Vec3(0, scanY, 0) - right * (R * 2.1)
                let b = center + Vec3(0, scanY, 0) + right * (R * 2.1)
                draw.addLine(a, b, rgba(hostWhite, opacity * 0.52))
                draw.addLine(a, b, rgba(core, opacity * 0.18))
                appendHostGlow(draw, at: center + Vec3(0, scanY, 0),
                               size: R * 0.85, color: core, opacity: opacity * 0.32)
                for mote in scanMotes {
                    let mx = cos(simTimeAngle(age, mote.speed) + mote.angle) * mote.radius
                    let mz = sin(simTimeAngle(age, mote.speed) + mote.angle) * mote.radius
                    let p = center + Vec3(mx, scanY, mz)
                    draw.points.append(PointVertex(p, rgba(mote.color, opacity * 0.6),
                                                   size: mote.size))
                }
            }
            if age < 0.16 {
                appendHostGlow(draw, at: center + Vec3(0, -halfSpan, 0),
                               size: R * 0.4, color: hostWhite,
                               opacity: (1 - age / 0.16) * 0.35)
            }
        case .condense:
            let collapse = clamp01(age / 0.55)
            let shrink = 1 - easeInCubic(collapse)
            if age < 0.64 {
                for arm in 0..<3 {
                    let base = (Float(arm) / 3) * TAU + age * 1.35
                    var points: [Vec3] = []
                    for j in 0...36 {
                        let u = Float(j) / 36
                        let angle = base + u * 4.2
                        let rr = R * (0.06 + 2.9 * (1 - u)) * shrink
                        points.append(center
                            + normalBasisT * (cos(angle) * rr)
                            + normalBasisB * (sin(angle) * rr)
                            + normal * (sin(u * 9 + Float(arm) * 2) * R * 0.07 * shrink))
                    }
                    let fade = (1 - smoothstep(0.36, 0.62, age)) * (0.26 - Float(arm) * 0.04)
                    appendPolyline(draw, points,
                                   color: arm == 1 ? Palette.host : core,
                                   alpha: max(0, fade))
                }
            }
            appendConvergingMotes(motes, age: age, center: center,
                                  normal: normal, radius: R,
                                  collapse: 0.56, spin: age * 1.2,
                                  draw: draw, opacity: 0.7)
            if age < 0.55 {
                appendHostGlow(draw, at: center, size: R * (0.5 + collapse * 1.9),
                               color: Palette.host, opacity: 0.12 * collapse)
            }
        case .seed:
            let land: Float = 0.39
            let fall = clamp01(age / land)
            if age < land + 0.03 {
                let seedPos = seedStart.lerp(center, fall * fall)
                    + normalBasisT * (sin(fall * 9) * R * 0.11 * (1 - fall))
                for i in 0..<12 {
                    let u = clamp01(fall - Float(i) * 0.03)
                    let p = seedStart.lerp(center, u * u)
                        + normalBasisT * (sin(u * 9) * R * 0.1 * (1 - u))
                    draw.points.append(PointVertex(p,
                                                   rgba(core, (1 - Float(i) / 12) * 0.5 * fall),
                                                   size: R * 0.055 * (1 - Float(i) / 12)))
                }
                appendHostGlow(draw, at: seedPos, size: R * 3.2,
                               color: core, opacity: 0.55)
                appendHostGlow(draw, at: seedPos, size: R * 1.0,
                               color: hostWhite, opacity: 0.9)
                let diamond = R * 0.36
                for i in 0..<4 {
                    let angle = Float(i) * .pi / 2
                    let dir = normalBasisT * cos(angle) + normalBasisB * sin(angle)
                    let a = seedPos - dir * diamond
                    let b = seedPos + dir * diamond
                    draw.addLine(a, b, rgba(hostWhite, 0.55))
                }
            }
            for filament in filaments {
                let raw = clamp01((age - filament.start) / filament.duration)
                guard raw > 0 else { continue }
                let head = max(2, Int(raw * 24))
                let fade = clamp01(raw / 0.1) * (1 - smoothstep(0.82, 1.0, raw))
                var points: [Vec3] = []
                for i in 0...head {
                    points.append(filament.points[min(i, filament.points.count - 1)])
                }
                appendPolyline(draw, points, color: filament.color,
                               alpha: fade * 0.66)
                if let tip = points.last {
                    appendHostGlow(draw, at: tip, size: R * 0.35,
                                   color: filament.color, opacity: fade * 0.4)
                    appendHostGlow(draw, at: tip, size: R * 0.1,
                                   color: hostWhite, opacity: fade * 0.6)
                }
            }
        default:
            break
        }

        if age >= duration && !finished {
            finished = true
            onPresence?(1)
            onFinish?()
        }
    }

    private func simTimeAngle(_ age: Float, _ speed: Float) -> Float {
        age * speed + sin(age * 1.7) * 0.2
    }
}

// MARK: - Death studies

private struct HostAsh {
    let angle: Float
    let radius: Float
    let normalOffset: Float
    let drift: Float
    let rise: Float
    let delay: Float
    let life: Float
    let size: Float
    let color: SRGB
}

final class HostMotionDeathEffect: EffectStudy, HostPresenceDrivenStudy {
    let duration: Float
    let style: HostMotionStyle
    let body: HostMotionBody
    var onPresence: ((Float) -> Void)?
    var onFinish: (() -> Void)?

    private let point: Vec3
    private let normal: Vec3
    private let R: Float
    private let initialPresence: Float
    private let core: SRGB
    private let tail: SRGB
    private let hot: SRGB
    private let camera: Camera
    private let basisT: Vec3
    private let basisB: Vec3
    private var rings: [ShockRing] = []
    private var flashes: [Flash] = []
    private var bursts: [SparkBurst] = []
    private var motes: [HostMote] = []
    private var shards: [HostShard] = []
    private var ash: [HostAsh] = []
    private var finished = false

    private static func normalized(_ style: HostMotionStyle) -> HostMotionStyle {
        style.isDeath ? style : .implode
    }

    private static func duration(for style: HostMotionStyle) -> Float {
        switch style {
        case .fold: return 1.00
        case .dissolve: return 1.35
        case .implode: return 1.15
        case .shear: return 1.30
        default: return 1.15
        }
    }

    private static func palette(for body: HostMotionBody) -> (SRGB, SRGB, SRGB) {
        if body == .app {
            return (Palette.hostAppHot, Palette.hostApp, Palette.hostIce)
        }
        return (Palette.hostRemoteHot, Palette.hostRemote, Palette.hostGlow)
    }

    init(style: HostMotionStyle, point: Vec3, normal: Vec3, radius: Float,
         body: HostMotionBody, camera: Camera, initialPresence: Float,
         rng: RNG) {
        let resolved = Self.normalized(style)
        self.style = resolved
        self.body = body
        self.point = point
        self.normal = hostNormal(normal)
        self.R = max(0.24, radius)
        self.camera = camera
        self.initialPresence = clamp(initialPresence, 0.05, 1)
        self.duration = Self.duration(for: resolved)
        let palette = Self.palette(for: body)
        self.core = palette.0
        self.tail = palette.1
        self.hot = palette.2
        let basis = orthoBasis(self.normal)
        self.basisT = basis.t
        self.basisB = basis.b
        let roleCore = hostBodyCore(body)
        let ice = Palette.hostIce

        switch resolved {
        case .fold:
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 0.7, end: 2.3, duration: 0.70, delay: 0.36,
                          core: roleCore, tail: hostViolet,
                          thickness: 0.010, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.5, opacity: 0.30),
            ]
            flashes = [
                Flash(point: point, size: R * 2.4, color: hostWhite,
                      haloColor: roleCore, duration: 0.40, delay: 0.34,
                      haloScale: 2.7, opacity: 0.7),
            ]
            bursts = [
                SparkBurst(count: 14, origin: point, normal: self.normal,
                           radius: R * 0.3, rng: rng, mode: "disc",
                           speed: (0.3, 1.6), tangential: 1.2, normalSpeed: 0.6,
                           drag: 1.2, life: (0.25, 0.65), size: (0.008, 0.028),
                           palette: [ice, roleCore, hostViolet],
                           startJitter: 0.2, delay: (0.30, 0.38), opacity: 0.55),
            ]
        case .dissolve:
            var built: [HostAsh] = []
            for _ in 0..<84 {
                let angle = rng.next() * TAU
                let radius = sqrt(rng.next()) * R * 0.82
                built.append(HostAsh(
                    angle: angle,
                    radius: radius,
                    normalOffset: (rng.next() * 2 - 1) * R * 0.35,
                    drift: R * (0.2 + rng.next() * 0.9),
                    rise: R * (0.15 + rng.next() * 0.55),
                    delay: rng.next() * 0.42,
                    life: 0.55 + rng.next() * 0.7,
                    size: R * (0.012 + rng.next() * 0.028),
                    color: rng.next() > 0.72 ? hostViolet
                        : (rng.next() > 0.45 ? ice : roleCore)))
            }
            self.ash = built
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 1.1, end: 3.0, duration: 1.05, delay: 0.20,
                          core: roleCore, tail: hostViolet,
                          thickness: 0.010, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.6, opacity: 0.24),
            ]
            flashes = [
                Flash(point: point, size: R * 1.8, color: ice,
                      haloColor: roleCore, duration: 0.50, delay: 0.82,
                      haloScale: 2.4, opacity: 0.35),
            ]
        case .implode:
            motes = makeHostMotes(rng: rng, count: 44, radius: R,
                                  inner: 1.8, outer: 3.1,
                                  colors: [ice, roleCore, hostViolet, Palette.host])
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 2.8, end: 0.10, duration: 0.70,
                          core: ice, tail: hostViolet,
                          thickness: 0.045, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.5, opacity: 0.92),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 2.0, end: 0.06, duration: 0.78, delay: 0.08,
                          core: roleCore, tail: Palette.hostRemoteDeep,
                          thickness: 0.030, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.6, opacity: 0.7),
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 1.3, end: 0.04, duration: 0.62, delay: 0.18,
                          core: hostWhite, tail: hostViolet,
                          thickness: 0.020, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.6, opacity: 0.55),
            ]
            flashes = [
                Flash(point: point, size: R * 2.5, color: hostWhite,
                      haloColor: hostViolet, duration: 0.46, delay: 0.58,
                      haloScale: 2.8, opacity: 0.85),
            ]
            bursts = [
                SparkBurst(count: 20, origin: point, normal: self.normal,
                           radius: R * 0.35, rng: rng, mode: "disc",
                           speed: (0.4, 2.0), tangential: 1.0, normalSpeed: 0.8,
                           drag: 1.2, life: (0.25, 0.62), size: (0.01, 0.036),
                           palette: [ice, roleCore, hostViolet],
                           startJitter: 0.2, delay: (0.52, 0.58), opacity: 0.7),
            ]
        case .shear:
            shards = makeHostShards(rng: rng, count: 24, radius: R,
                                    colors: [ice, roleCore, hostViolet,
                                             Palette.hostRemote, hostWhite],
                                    speed: (1.5, 4.2), tangential: 0.9,
                                    normalSpeed: 0.7, size: (0.30, 0.75),
                                    startRadius: 0.72, delay: (0.21, 0.27))
            rings = [
                ShockRing(point: point, normal: self.normal, radius: R,
                          start: 1.0, end: 3.4, duration: 0.86, delay: 0.22,
                          core: roleCore, tail: hostViolet,
                          thickness: 0.018, rays: 0, seed: rng.next() * 9,
                          halfFactor: 1.55, opacity: 0.34),
            ]
            flashes = [
                Flash(point: point, size: R * 2.4, color: hostWhite,
                      haloColor: hostViolet, duration: 0.38, delay: 0.21,
                      haloScale: 2.6, opacity: 0.66),
            ]
            bursts = [
                SparkBurst(count: 40, origin: point, normal: self.normal,
                           radius: R * 0.7, rng: rng, mode: "disc",
                           speed: (1.8, 4.8), tangential: 1.6, normalSpeed: 1.2,
                           drag: 0.9, life: (0.30, 0.85), size: (0.01, 0.04),
                           palette: [hostWhite, ice, hostViolet, Palette.host],
                           startJitter: 0.12, delay: (0.22, 0.27), opacity: 0.86),
            ]
        default:
            break
        }
    }

    private func presence(at age: Float) -> Float {
        let value: Float
        switch style {
        case .fold:
            value = 1 - smoothstep(0.18, 0.55, age)
        case .dissolve:
            value = 1 - smoothstep(0.12, 0.90, age)
        case .implode:
            value = 1 - smoothstep(0.04, 0.60, age)
        case .shear:
            value = 1 - smoothstep(0.18, 0.34, age)
        default:
            value = 1 - smoothstep(0.05, 0.55, age)
        }
        return initialPresence * clamp01(value)
    }

    func update(dt: Float, age: Float, ctx: EffectContext, draw: DrawList) {
        onPresence?(presence(at: age))
        let offset = ctx.offset
        let center = point + offset
        for ring in rings {
            ring.append(age: age, offset: offset, draw: draw)
        }
        for flash in flashes {
            flash.append(age: age, offset: offset, draw: draw)
        }
        for burst in bursts {
            burst.update(dt: dt, offset: offset, draw: draw)
        }

        switch style {
        case .fold:
            if age < 0.72 {
                let p = smoothstep(0.12, 0.56, age)
                let seam = max(0, 1 - abs(p - 0.62) / 0.62)
                let right = hostNormal(camera.forward.cross(camera.up))
                let length = R * (1 + p * 1.4)
                let a = center - right * length
                let b = center + right * length
                draw.addLine(a, b, rgba(hostWhite, 1.0 * seam))
                draw.addLine(a, b, rgba(core, 0.26 * seam))
                for i in 0...6 {
                    let p = a.lerp(b, Float(i) / 6)
                    appendHostGlow(draw, at: p, size: R * 0.42,
                                   color: Palette.hostIce,
                                   opacity: 0.16 * seam)
                }
                appendHostGlow(draw, at: center, size: length * 1.2,
                               color: core, opacity: 0.36 * seam)
            }
        case .dissolve:
            for particle in ash {
                let local = age - particle.delay
                guard local >= 0, local <= particle.life else { continue }
                let t = clamp01(local / particle.life)
                let dir = basisT * cos(particle.angle) + basisB * sin(particle.angle)
                let base = center + dir * particle.radius
                    + normal * particle.normalOffset
                let position = base
                    + dir * (particle.drift * easeOutCubic(t))
                    + Vec3(0, particle.rise * easeOutCubic(t), 0)
                let alpha = pow(1 - t, 1.2) * clamp01(local / 0.08) * 0.86
                guard alpha > 0.004 else { continue }
                draw.points.append(PointVertex(position,
                                               rgba(particle.color, alpha),
                                               size: particle.size * 1.15))
                if particle.size > R * 0.022 {
                    appendHostGlow(draw, at: position,
                                   size: particle.size * 6,
                                   color: particle.color,
                                   opacity: alpha * 0.4)
                }
            }
            let p = clamp01(age / 1.10)
            let radius = R * (1.2 + easeOutCubic(p) * 2.2)
            let arcAlpha = (1 - p) * 0.44
            if arcAlpha > 0.004 {
                appendArc(draw, center: center, radius: radius,
                          start: 0.1 + age * 0.2, sweep: 1.55,
                          color: roleColor(), alpha: arcAlpha)
                appendArc(draw, center: center, radius: radius * 0.93,
                          start: 2.1 + age * 0.15, sweep: 1.2,
                          color: hostViolet, alpha: arcAlpha * 0.7)
                appendArc(draw, center: center, radius: radius * 1.08,
                          start: 4.0 + age * 0.1, sweep: 0.8,
                          color: Palette.hostIce, alpha: arcAlpha * 0.5)
            }
            appendHostGlow(draw, at: center,
                           size: R * (2.0 + easeOutCubic(p) * 3.5),
                           color: hostViolet,
                           opacity: 0.18 * (1 - smoothstep(0.3, 1.2, age)))
            appendHostGlow(draw, at: center, size: R * 1.2,
                           color: Palette.hostIce,
                           opacity: 0.14 * (1 - smoothstep(0.1, 0.8, age)))
        case .implode:
            appendConvergingMotes(motes, age: age, center: center,
                                  normal: normal, radius: R,
                                  collapse: 0.62, spin: age * 2.6,
                                  draw: draw, opacity: 0.85)
            if age < 0.75 {
                appendHostGlow(draw, at: center,
                               size: R * (1.3 + max(0, 0.62 - age) * 2.6),
                               color: roleColor(),
                               opacity: 0.26 * smoothstep(0.2, 0.56, age)
                                   * (1 - smoothstep(0.56, 0.9, age)))
            }
            if age > 0.52 {
                appendHostGlow(draw, at: center, size: R * 0.4,
                               color: hostWhite,
                               opacity: max(0, 1 - abs(age - 0.62) * 4) * 0.8)
            }
        case .shear:
            if age > 0.07 && age < 0.42 {
                let cut = smoothstep(0.07, 0.16, age)
                    * (1 - smoothstep(0.28, 0.42, age))
                let right = hostNormal(camera.forward.cross(camera.up))
                let tilted = (right * cos(-0.58) + camera.up * sin(-0.58))
                let length = R * 2.2
                let a = center - tilted * length
                let b = center + tilted * length
                draw.addLine(a, b, rgba(hostWhite, cut * 0.82))
                draw.addLine(a, b, rgba(hostViolet, cut * 0.18))
                appendHostGlow(draw, at: center, size: R * 1.7,
                               color: hostViolet, opacity: cut * 0.22)
            }
            appendHostShards(shards, age: age, center: center,
                             normal: normal, draw: draw, opacity: 0.92)
            let p = clamp01((age - 0.20) / 0.90)
            let radius = R * (0.9 + easeOutCubic(p) * 3.0)
            let alpha = (1 - p) * 0.5
            if alpha > 0.004 {
                appendArc(draw, center: center, radius: radius,
                          start: 0.35, sweep: 1.35,
                          color: hostViolet, alpha: alpha)
                appendArc(draw, center: center, radius: radius,
                          start: 2.8, sweep: 1.15,
                          color: Palette.hostIce, alpha: alpha * 0.6)
            }
        default:
            break
        }

        if age >= duration && !finished {
            finished = true
            onPresence?(0)
            onFinish?()
        }
    }

    private func roleColor() -> SRGB {
        body == .app ? Palette.hostApp : Palette.hostRemote
    }

    private func appendArc(_ draw: DrawList, center: Vec3, radius: Float,
                           start: Float, sweep: Float, color: SRGB, alpha: Float) {
        guard alpha > 0.004 else { return }
        var points: [Vec3] = []
        let steps = 26
        for i in 0...steps {
            let angle = start + sweep * Float(i) / Float(steps)
            points.append(center
                + basisT * (cos(angle) * radius)
                + basisB * (sin(angle) * radius))
        }
        appendPolyline(draw, points, color: color, alpha: alpha)
    }
}
