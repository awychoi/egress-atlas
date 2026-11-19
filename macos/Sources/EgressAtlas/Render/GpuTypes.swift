import Foundation
import simd
import Metal

// Swift mirrors of the MSL structs. Every field is 16-byte aligned so the
// byte layout is identical to the shader-side structs.

struct LineVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>

    init(_ p: Vec3, _ c: SIMD4<Float>) {
        position = SIMD4(p.x, p.y, p.z, 1)
        color = c
    }
}

struct PointVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
    var params: SIMD4<Float>

    init(_ p: Vec3, _ color: SIMD4<Float>, size: Float) {
        position = SIMD4(p.x, p.y, p.z, 1)
        self.color = color
        params = SIMD4(size, 0, 0, 0)
    }
}

struct ShapeVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var uv: SIMD2<Float>
    var pad: SIMD2<Float> = .zero
}

struct MeshInstance {
    var model: Mat4
    var color: SIMD4<Float>
}

struct SpriteInstance {
    var center: SIMD4<Float>   // xyz, mode
    var size: SIMD4<Float>     // width, height, rotation, opacity
    var color: SIMD4<Float>    // linear rgb
    var extra: SIMD4<Float> = .zero

    static func glow(_ p: Vec3, size: Float, color: SRGB, opacity: Float) -> SpriteInstance {
        SpriteInstance(
            center: SIMD4(p.x, p.y, p.z, 0),
            size: SIMD4(size, size, 0, opacity),
            color: SIMD4(color.linear, 1)
        )
    }

    static func spark(_ p: Vec3, size: Float, color: SRGB, opacity: Float) -> SpriteInstance {
        SpriteInstance(
            center: SIMD4(p.x, p.y, p.z, 1),
            size: SIMD4(size, size, 0, opacity),
            color: SIMD4(color.linear, 1)
        )
    }

    static func streak(_ p: Vec3, width: Float, height: Float, color: SRGB, opacity: Float) -> SpriteInstance {
        SpriteInstance(
            center: SIMD4(p.x, p.y, p.z, 2),
            size: SIMD4(width, height, 0, opacity),
            color: SIMD4(color.linear, 1)
        )
    }

    static func limb(_ center: Vec3, size: Float, tint: SRGB, opacity: Float) -> SpriteInstance {
        SpriteInstance(
            center: SIMD4(center.x, center.y, center.z, 3),
            size: SIMD4(size, size, 0, opacity),
            color: SIMD4(tint.linear, 1)
        )
    }
}

struct NodeRingUniforms {
    var centerHalf: SIMD4<Float>
    var params: SIMD4<Float> // radius, phase, opacity, hover
    var gold: SIMD4<Float>
    var hot: SIMD4<Float>
    var signal: SIMD4<Float>
}

struct ShockUniforms {
    var center: SIMD4<Float>
    var basisT: SIMD4<Float>
    var basisB: SIMD4<Float>
    var meta0: SIMD4<Float> // t, start, end, half
    var meta1: SIMD4<Float> // thickness, rays, seed, opacity
    var meta2: SIMD4<Float> // inner, hot, 0, 0
    var core: SIMD4<Float>
    var tail: SIMD4<Float>
}

struct AtmoUniforms {
    var model: Mat4
    var warm: SIMD4<Float> // rgb, strength
    var cool: SIMD4<Float> // rgb, time
    var params: SIMD4<Float>
}

struct PlanetUniforms {
    var model: Mat4
    var rockA: SIMD4<Float> // rgb, opacity
    var rockB: SIMD4<Float> // rgb, heat
    var accent: SIMD4<Float> // rgb, crack
    var hot: SIMD4<Float>   // rgb, time
}

struct PlanetAtmoUniforms {
    var model: Mat4
    var color: SIMD4<Float> // rgb, opacity
}

struct ShockShellUniforms {
    var model: Mat4
    var color: SIMD4<Float>
    var accent: SIMD4<Float>
    var params: SIMD4<Float> // opacity, time, 0, 0
}

struct ShieldUniforms {
    var model: Mat4
    var shell: SIMD4<Float>
    var rim: SIMD4<Float>
    var hot: SIMD4<Float>
    var hitDir: SIMD4<Float>
    var params: SIMD4<Float> // opacity, time, ripple, contact
}

struct ScanUniforms {
    var model: Mat4
    var color: SIMD4<Float>
    var params: SIMD4<Float> // radius, half, opacity, angle
}

struct DiscUniforms {
    var model: Mat4
    var color: SIMD4<Float>
    var hot: SIMD4<Float>
    var params: SIMD4<Float> // opacity, time, 0, 0
}

struct JetUniforms {
    var model: Mat4
    var core: SIMD4<Float>
    var edge: SIMD4<Float>
    var params: SIMD4<Float> // opacity, time, 0, 0
}

struct TriangleVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

struct FrameUniforms {
    var viewProj: Mat4
    var view: Mat4
    var cameraPos: SIMD4<Float>
    var viewport: SIMD4<Float>
    var cameraRight: SIMD4<Float>
    var cameraUp: SIMD4<Float>
    var cameraForward: SIMD4<Float>
    var misc: SIMD4<Float> // time, pointScale, aspect, tanHalfFov
    var stage: SIMD4<Float> // stageScale, backdropYaw, near, far
}

struct LineUniforms {
    var transform: Mat4
}

struct DofUniforms {
    var params: SIMD4<Float> // focus, aperture, maxblur, aspect
    var cameraPos: SIMD4<Float>
    var cameraRight: SIMD4<Float>
    var cameraUp: SIMD4<Float>
    var cameraForward: SIMD4<Float>
    var depthParams: SIMD4<Float> // tanHalfFov, globeRadius, near, far
    var pan: SIMD4<Float> // lens-shift x, y, unused, unused
}

struct BrightUniforms {
    var params: SIMD4<Float> // threshold, smoothWidth, exposure, 0
}

struct BlurUniforms {
    var offsets: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var weights: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var directionSize: SIMD4<Float>
    var params: SIMD4<Float> // pairCount, centerWeight, 0, 0
}

struct BloomUniforms {
    var params: SIMD4<Float> // strength, radius, 0, 0
}

struct FinalUniforms {
    var params: SIMD4<Float> // elapsed, bloomEnabled, logicalW, logicalH
    var renderSize: SIMD4<Float>
}

// ── Draw list ─────────────────────────────────────────────────────────────

enum ShapeID: Int, CaseIterable {
    case sphere
    case torus
    case ringSegmentInner
    case ringSegmentOuter
    case ringFull
    case tetra
    case octa
    case box
    case cone
}

/// CPU-side collection of everything the scene wants drawn in a frame. The
/// effects append their geometry here; the renderer owns the Metal buffers.
final class DrawList {
    var lines: [LineVertex] = []
    var stageLines: [LineVertex] = []
    var points: [PointVertex] = []
    var stagePoints: [PointVertex] = []
    /// Free-floating space dust. It is drawn against the fixed sky view rather
    /// than the live globe camera, so orbiting, panning or zooming the globe
    /// leaves the surrounding space still.
    var ambientPoints: [PointVertex] = []
    var sprites: [SpriteInstance] = []
    var limbSprite: SpriteInstance?
    var meshBatches: [[MeshInstance]] = Array(repeating: [], count: ShapeID.allCases.count)
    var rawTriangles: [TriangleVertex] = []
    var nodeRings: [NodeRingUniforms] = []
    var shocks: [ShockUniforms] = []
    var planets: [PlanetUniforms] = []
    var planetAtmospheres: [PlanetAtmoUniforms] = []
    var shockShells: [ShockShellUniforms] = []
    var shields: [ShieldUniforms] = []
    var scans: [ScanUniforms] = []
    var discs: [DiscUniforms] = []
    var jets: [JetUniforms] = []
    var atmospheres: [AtmoUniforms] = []
    var glass: AtmoUniforms?

    func reset() {
        lines.removeAll(keepingCapacity: true)
        stageLines.removeAll(keepingCapacity: true)
        points.removeAll(keepingCapacity: true)
        stagePoints.removeAll(keepingCapacity: true)
        ambientPoints.removeAll(keepingCapacity: true)
        sprites.removeAll(keepingCapacity: true)
        limbSprite = nil
        for i in meshBatches.indices { meshBatches[i].removeAll(keepingCapacity: true) }
        rawTriangles.removeAll(keepingCapacity: true)
        nodeRings.removeAll(keepingCapacity: true)
        shocks.removeAll(keepingCapacity: true)
        planets.removeAll(keepingCapacity: true)
        planetAtmospheres.removeAll(keepingCapacity: true)
        shockShells.removeAll(keepingCapacity: true)
        shields.removeAll(keepingCapacity: true)
        scans.removeAll(keepingCapacity: true)
        discs.removeAll(keepingCapacity: true)
        jets.removeAll(keepingCapacity: true)
        atmospheres.removeAll(keepingCapacity: true)
        glass = nil
    }

    func addLine(_ a: Vec3, _ b: Vec3, _ color: SIMD4<Float>, stage: Bool = false) {
        if stage {
            stageLines.append(LineVertex(a, color))
            stageLines.append(LineVertex(b, color))
        } else {
            lines.append(LineVertex(a, color))
            lines.append(LineVertex(b, color))
        }
    }

    func addPolyline(_ points: [Vec3], color: SIMD4<Float>, stage: Bool = false) {
        guard points.count > 1 else { return }
        for i in 0..<(points.count - 1) {
            addLine(points[i], points[i + 1], color, stage: stage)
        }
    }

    func addMesh(_ shape: ShapeID, _ instance: MeshInstance) {
        meshBatches[shape.rawValue].append(instance)
    }

    func addSphere(center: Vec3, radius: Float, color: SIMD4<Float>) {
        let m = Mat4.compose(position: center, quaternion: simd_quatf(angle: 0, axis: .up), scale: Vec3(repeating: radius))
        addMesh(.sphere, MeshInstance(model: m, color: color))
    }
}

@inline(__always) func rgba(_ color: SRGB, _ alpha: Float) -> SIMD4<Float> {
    SIMD4(color.linear, alpha)
}

@inline(__always) func rgba(_ rgb: SIMD3<Float>, _ alpha: Float) -> SIMD4<Float> {
    SIMD4(rgb, alpha)
}
