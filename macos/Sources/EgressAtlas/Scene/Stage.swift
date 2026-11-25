import Foundation
import simd

/// The instrument's colour recipe. The DNS globe is the original warm
/// gold/copper instrument; the host globe is its cool ice/teal sibling.
struct GlobeTheme {
    let gridMajor: SRGB
    let gridMinor: SRGB
    let surfaceWarm: SRGB
    let surfaceEmber: SRGB
    let surfaceIce: SRGB
    let dustWarm: SRGB
    let dustIce: SRGB
    let orbit1: SRGB
    let orbit2: SRGB
    let orbit3: SRGB
    let tick: SRGB
    let horizon: SRGB
    let atmosphereWarm: SRGB
    let atmosphereCool: SRGB
    let limb: SRGB

    static let dns = GlobeTheme(
        gridMajor: Palette.gold,
        gridMinor: Palette.orbit,
        surfaceWarm: Palette.gold,
        surfaceEmber: Palette.orbit,
        surfaceIce: Palette.signal,
        dustWarm: Palette.gold,
        dustIce: Palette.signalIce,
        orbit1: Palette.gold,
        orbit2: Palette.orbit,
        orbit3: Palette.signal,
        tick: Palette.gold,
        horizon: Palette.gold,
        atmosphereWarm: Palette.orbit,
        atmosphereCool: Palette.gold,
        limb: Palette.gold
    )

    static let host = GlobeTheme(
        gridMajor: Palette.host,
        gridMinor: Palette.hostDim,
        surfaceWarm: Palette.hostGlow,
        surfaceEmber: Palette.host2,
        surfaceIce: Palette.hostIce,
        dustWarm: Palette.hostIce,
        dustIce: Palette.host,
        orbit1: Palette.host,
        orbit2: Palette.host2,
        orbit3: Palette.hostDeep,
        tick: Palette.host,
        horizon: Palette.hostGlow,
        atmosphereWarm: Palette.hostDeep,
        atmosphereCool: Palette.host,
        limb: Palette.hostGlow
    )
}

/// Port of app/src/lab/GlobeStage.js: the hollow instrument sphere. Every
/// element is the same primitive (lines, additive points, shader shells) with
/// the same constants and texture-free color recipes.
final class GlobeStage {
    let radius: Float = 6
    let theme: GlobeTheme
    private var rng = RNG(0x91a7e5)

    private var gridSegments: [(Vec3, Vec3, SIMD4<Float>)] = []
    private var gridMajorSegments: [(Vec3, Vec3, SIMD4<Float>)] = []
    private var surfacePoints: [(Vec3, SRGB, Float, Float)] = []
    private var surfaceDust: [(Vec3, SRGB, Float, Float)] = []
    private var orbitDust: [(theta: Float, y: Float, rr: Float, dist: Float, phase: Float,
                             speed: Float, color: SRGB, size: Float, alpha: Float)] = []
    private var orbitDefs: [(radius: Float, tilt: Float, yaw: Float, color: SRGB, opacity: Float, speed: Float)] = []
    private var orbitZ: [Float] = [0, 0, 0]
    private var tickRotation: Float = 0
    private var tickSegments: [(Vec3, Vec3)] = []

    var backdropYaw: Float { elapsed * 0.002 }
    private var elapsed: Float = 0

    init(theme: GlobeTheme = .dns) {
        self.theme = theme
        buildGrid()
        buildSurface()
        buildOrbits()
        buildDust()
    }

    private func buildGrid() {
        let r = radius * 1.0015
        // Latitude rings.
        for lat in stride(from: -75, through: 75, by: 15) {
            let phi = Float(90 - lat) * .pi / 180
            let y = r * cos(phi)
            let rr = r * sin(phi)
            let major = lat == 0 || lat % 45 == 0
            let opacity: Float = lat == 0 ? 0.09 : (lat % 45 == 0 ? 0.055 : 0.03)
            let color = rgba(major ? theme.gridMajor : theme.gridMinor, opacity)
            var previous: Vec3?
            for i in 0...96 {
                let a = Float(i) / 96 * TAU
                let p = Vec3(cos(a) * rr, y, sin(a) * rr)
                if let previous {
                    let segment = (previous, p, color)
                    gridSegments.append(segment)
                    if major { gridMajorSegments.append(segment) }
                }
                previous = p
            }
        }
        // Longitude arcs.
        for lon in stride(from: 0, through: 345, by: 15) {
            let fine = lon % 30 != 0
            let theta = Float(lon) * .pi / 180
            let isMajor = !fine && lon % 90 == 0
            let opacity: Float = isMajor ? 0.06 : (fine ? 0.018 : 0.028)
            let color = rgba(isMajor ? theme.gridMajor : theme.gridMinor, opacity)
            var previous: Vec3?
            for i in 0...64 {
                let phi = Float(i) / 64 * .pi
                let p = Vec3(r * sin(phi) * sin(theta), r * cos(phi), r * sin(phi) * cos(theta))
                if let previous {
                    let segment = (previous, p, color)
                    gridSegments.append(segment)
                    if isMajor { gridMajorSegments.append(segment) }
                }
                previous = p
            }
        }
    }

    private func buildSurface() {
        for _ in 0..<900 {
            let u = rng.next()
            let v = rng.next()
            let theta = u * TAU
            let phi = acos(2 * v - 1)
            let r = radius * 1.002
            let p = Vec3(r * sin(phi) * cos(theta), r * cos(phi), r * sin(phi) * sin(theta))
            let roll = rng.next()
            let color = roll > 0.94 ? theme.surfaceIce : (roll > 0.55 ? theme.surfaceWarm : theme.surfaceEmber)
            let alpha = 0.05 + pow(rng.next(), 2.2) * 0.26
            let size = 0.012 + pow(rng.next(), 3) * 0.036
            surfacePoints.append((p, color, size, alpha))
        }
        for _ in 0..<320 {
            let theta = rng.next() * TAU
            let y = rng.next() * 2 - 1
            let rr = sqrt(1 - y * y)
            let dist = radius * (1.005 + rng.next() * 0.045)
            let color = rng.next() > 0.8 ? theme.surfaceIce : theme.surfaceWarm
            surfaceDust.append((Vec3(cos(theta) * rr * dist, y * dist, sin(theta) * rr * dist),
                                color, 0.008 + rng.next() * 0.018, 0.03 + rng.next() * 0.1))
        }
    }

    private func buildOrbits() {
        orbitDefs = [
            (radius * 1.14, 0.22, 0.14, theme.orbit1, 0.05, 0.012),
            (radius * 1.30, -0.26, -0.2, theme.orbit2, 0.04, -0.007),
            (radius * 1.46, 0.1, 0.32, theme.orbit3, 0.025, 0.004),
        ]
        tickSegments = []
        for i in 0..<72 {
            let a = Float(i) / 72 * TAU
            let inner = radius * 1.02
            let outer = radius * (i % 6 == 0 ? 1.06 : 1.035)
            tickSegments.append((Vec3(cos(a) * inner, 0, sin(a) * inner),
                                 Vec3(cos(a) * outer, 0, sin(a) * outer)))
        }
    }

    private func buildDust() {
        for _ in 0..<130 {
            let theta = rng.next() * TAU
            let y = rng.next() * 2 - 1
            let rr = sqrt(1 - y * y)
            let dist = radius * (1.55 + rng.next() * 1.4)
            let phase = rng.next() * TAU
            let speed = 0.008 + rng.next() * 0.03
            let color = rng.next() > 0.82 ? theme.dustIce : theme.dustWarm
            let size = 0.018 + rng.next() * 0.055
            let alpha = 0.04 + rng.next() * 0.22
            orbitDust.append((theta, y, rr, dist, phase, speed, color, size, alpha))
        }
    }

    /// `detail` is 1 for the focused globe and 0 for the background impostor.
    /// The background keeps the shell, atmosphere and major grid, and drops
    /// the expensive dust/orbit/tick layers that the eye cannot read at that
    /// distance.
    func update(dt: Float, elapsed: Float, stageScale: Float, detail: Float = 1,
                into draw: DrawList) {
        self.elapsed = elapsed
        let full = detail > 0.5
        let grid = full ? gridSegments : gridMajorSegments

        // Grid.
        for (a, b, color) in grid {
            draw.addLine(a, b, color, stage: true)
        }

        if full {
            // Surface sparkle and dust.
            for (p, color, size, alpha) in surfacePoints {
                draw.stagePoints.append(PointVertex(p, rgba(color, alpha), size: size))
            }
            for (p, color, size, alpha) in surfaceDust {
                draw.stagePoints.append(PointVertex(p, rgba(color, alpha), size: size))
            }
        }

        // Orbit rings, with the same accumulated roll and breath.
        for (i, orbit) in orbitDefs.enumerated() {
            orbitZ[i] += dt * orbit.speed
            guard full || i == 0 else { continue }
            let tilt = orbit.tilt + sin(elapsed * 0.052 + Float(i)) * 0.018
            let matrix = Mat4.eulerXYZ(tilt, orbit.yaw, orbitZ[i])
            var previous: Vec3?
            let step = full ? 1 : 4
            var j = 0
            while j <= 260 {
                let a = Float(j) / 260 * TAU
                let p = matrix * SIMD4(cos(a) * orbit.radius, 0, sin(a) * orbit.radius, 1)
                let point = Vec3(p.x, p.y, p.z)
                if let previous {
                    draw.addLine(previous, point, rgba(orbit.color, orbit.opacity), stage: true)
                }
                previous = point
                j += step
            }
        }

        if full {
            // Horizon tick ring.
            tickRotation -= dt * 0.006
            let tickMatrix = Mat4.eulerXYZ(0.24, tickRotation, -0.12)
            for (a, b) in tickSegments {
                let pa = tickMatrix * SIMD4(a, 1)
                let pb = tickMatrix * SIMD4(b, 1)
                draw.addLine(Vec3(pa.x, pa.y, pa.z), Vec3(pb.x, pb.y, pb.z),
                             rgba(theme.tick, 0.16), stage: true)
            }

            // Single bright horizon ring, just off the ecliptic.
            let horizonMatrix = Mat4.eulerXYZ(0.24, 0, -0.12)
            var horizonPrev: Vec3?
            for i in 0...320 {
                let a = Float(i) / 320 * TAU
                let r = radius * 1.006
                let p = horizonMatrix * SIMD4(cos(a) * r, 0, sin(a) * r, 1)
                let point = Vec3(p.x, p.y, p.z)
                if let horizonPrev {
                    draw.addLine(horizonPrev, point, rgba(theme.horizon, 0.1), stage: true)
                }
                horizonPrev = point
            }

            // Drifting dust. This is the far space layer, not part of the
            // globe: the renderer projects it against the fixed sky view so it
            // stays put while the user drags the globe around.
            for p in orbitDust {
                let theta = p.theta + elapsed * p.speed
                let wobble = sin(elapsed * 0.06 + p.phase) * 0.08
                let dist = p.dist * (1 + wobble)
                let x = cos(theta) * p.rr * dist
                let z = sin(theta) * p.rr * dist
                let y = p.y * dist + sin(elapsed * 0.09 + p.phase) * 0.2
                draw.ambientPoints.append(PointVertex(Vec3(x, y, z), rgba(p.color, p.alpha), size: p.size))
            }
        }

        // Atmosphere shells and glass. The web scales its stage root by R/6;
        // our geometry is generated at radius 6, so the globes use R directly.
        let scale = stageScale * radius
        let shells: [AtmoUniforms]
        if full {
            shells = [
                AtmoUniforms(model: Mat4.scale(Vec3(repeating: scale * 1.095)),
                             warm: SIMD4(theme.atmosphereWarm.linear, 0.19),
                             cool: SIMD4(theme.atmosphereCool.linear, elapsed),
                             params: .zero),
                AtmoUniforms(model: Mat4.scale(Vec3(repeating: scale * 1.002)),
                             warm: SIMD4(theme.atmosphereWarm.linear, 0.06),
                             cool: SIMD4(theme.atmosphereCool.linear, elapsed),
                             params: .zero),
            ]
        } else {
            shells = [
                AtmoUniforms(model: Mat4.scale(Vec3(repeating: scale * 1.06)),
                             warm: SIMD4(theme.atmosphereWarm.linear, 0.12),
                             cool: SIMD4(theme.atmosphereCool.linear, elapsed),
                             params: .zero),
            ]
        }
        draw.atmospheres = shells
        draw.glass = AtmoUniforms(model: Mat4.scale(Vec3(repeating: scale)),
                                  warm: SIMD4(theme.atmosphereWarm.linear, 0.19),
                                  cool: SIMD4(theme.atmosphereCool.linear, elapsed),
                                  params: SIMD4(1, 0, 0, 0))
        draw.limbSprite = .limb(.zero, size: scale * 2.04,
                                tint: theme.limb, opacity: full ? 0.23 : 0.16)
    }
}
