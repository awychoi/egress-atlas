import Foundation

/// Camera-relative front/back focus shared by both globes. The plane passes
/// through the globe centre and is perpendicular to the camera's forward
/// vector. Front geometry keeps a small brightness boost; the back half is
/// dimmed. Labels use the same plane with their own opacity floor so a
/// selected back card remains readable without competing with the front.
enum HemisphereFocus {
    static let feather: Float = 0.55
    static let objectFront: Float = 1.12
    static let objectBack: Float = 0.45
    static let shellFront: Float = 1.03
    static let shellBack: Float = 0.38

    /// 1 on the camera side of the plane, 0 behind it.
    @inline(__always)
    static func frontness(_ point: Vec3, camera: Camera) -> Float {
        frontness(point, camera: camera, centerDepth: camera.viewDepth(of: .zero))
    }

    @inline(__always)
    private static func frontness(_ point: Vec3, camera: Camera,
                                  centerDepth: Float) -> Float {
        let depth = camera.viewDepth(of: point) - centerDepth
        let t = clamp01((depth + feather) / (feather * 2))
        let smooth = t * t * (3 - 2 * t)
        return 1 - smooth
    }

    static func labelOpacity(_ point: Vec3, camera: Camera,
                             interactive: Bool) -> Double {
        let base = 0.30 + 0.70 * Double(frontness(point, camera: camera))
        return interactive ? max(0.58, base) : base
    }

    /// Applies the split to a complete draw list. Global atmosphere/glass and
    /// the fixed star dust are deliberately excluded; everything anchored to
    /// the globe — shell, wires, bodies, signals, effects and hit overlays —
    /// follows the plane.
    static func apply(to draw: DrawList, camera: Camera) {
        let centerDepth = camera.viewDepth(of: .zero)

        @inline(__always)
        func factor(_ point: Vec3, front: Float, back: Float) -> Float {
            let f = frontness(point, camera: camera, centerDepth: centerDepth)
            return back + (front - back) * f
        }

        @inline(__always)
        func scale(_ color: inout SIMD4<Float>, _ f: Float) {
            color.x *= f
            color.y *= f
            color.z *= f
            color.w = f < 1 ? color.w * f : min(1, color.w)
        }

        @inline(__always)
        func scaleRGB(_ color: inout SIMD4<Float>, _ f: Float) {
            color.x *= f
            color.y *= f
            color.z *= f
        }

        for i in draw.stageLines.indices {
            let p = draw.stageLines[i].position
            let f = factor(Vec3(p.x, p.y, p.z), front: shellFront, back: shellBack)
            scale(&draw.stageLines[i].color, f)
        }
        for i in draw.stagePoints.indices {
            let p = draw.stagePoints[i].position
            let f = factor(Vec3(p.x, p.y, p.z), front: shellFront, back: shellBack)
            scale(&draw.stagePoints[i].color, f)
        }
        for i in draw.lines.indices {
            let p = draw.lines[i].position
            let f = factor(Vec3(p.x, p.y, p.z), front: objectFront, back: objectBack)
            scale(&draw.lines[i].color, f)
        }
        for i in draw.points.indices {
            let p = draw.points[i].position
            let f = factor(Vec3(p.x, p.y, p.z), front: objectFront, back: objectBack)
            scale(&draw.points[i].color, f)
        }
        for i in draw.rawTriangles.indices {
            let p = draw.rawTriangles[i].position
            let f = factor(Vec3(p.x, p.y, p.z), front: objectFront, back: objectBack)
            scale(&draw.rawTriangles[i].color, f)
        }
        for i in draw.sprites.indices {
            let p = draw.sprites[i].center
            let f = factor(Vec3(p.x, p.y, p.z), front: objectFront, back: objectBack)
            scale(&draw.sprites[i].color, f)
            if f < 1 { draw.sprites[i].size.w *= f }
        }
        for batch in draw.meshBatches.indices {
            for i in draw.meshBatches[batch].indices {
                let t = draw.meshBatches[batch][i].model.columns.3
                let f = factor(Vec3(t.x, t.y, t.z), front: objectFront, back: objectBack)
                scale(&draw.meshBatches[batch][i].color, f)
            }
        }
        for i in draw.nodeRings.indices {
            let p = draw.nodeRings[i].centerHalf
            let f = factor(Vec3(p.x, p.y, p.z), front: objectFront, back: objectBack)
            scale(&draw.nodeRings[i].gold, f)
            scale(&draw.nodeRings[i].hot, f)
            scale(&draw.nodeRings[i].signal, f)
            if f < 1 { draw.nodeRings[i].params.z *= f }
        }
        for i in draw.shocks.indices {
            let p = draw.shocks[i].center
            let f = factor(Vec3(p.x, p.y, p.z), front: objectFront, back: objectBack)
            scale(&draw.shocks[i].core, f)
            scale(&draw.shocks[i].tail, f)
            if f < 1 { draw.shocks[i].meta1.w *= f }
        }
        for i in draw.scans.indices {
            let t = draw.scans[i].model.columns.3
            let f = factor(Vec3(t.x, t.y, t.z), front: objectFront, back: objectBack)
            scale(&draw.scans[i].color, f)
            if f < 1 { draw.scans[i].params.z *= f }
        }
        for i in draw.discs.indices {
            let t = draw.discs[i].model.columns.3
            let f = factor(Vec3(t.x, t.y, t.z), front: objectFront, back: objectBack)
            scale(&draw.discs[i].color, f)
            scale(&draw.discs[i].hot, f)
            if f < 1 { draw.discs[i].params.x *= f }
        }
        for i in draw.jets.indices {
            let t = draw.jets[i].model.columns.3
            let f = factor(Vec3(t.x, t.y, t.z), front: objectFront, back: objectBack)
            scale(&draw.jets[i].core, f)
            scale(&draw.jets[i].edge, f)
            if f < 1 { draw.jets[i].params.x *= f }
        }
        for i in draw.planets.indices {
            let t = draw.planets[i].model.columns.3
            let f = factor(Vec3(t.x, t.y, t.z), front: objectFront, back: objectBack)
            scale(&draw.planets[i].rockA, f)
            scaleRGB(&draw.planets[i].rockB, f)
            scale(&draw.planets[i].accent, f)
            scaleRGB(&draw.planets[i].hot, f)
        }
        for i in draw.planetAtmospheres.indices {
            let t = draw.planetAtmospheres[i].model.columns.3
            let f = factor(Vec3(t.x, t.y, t.z), front: objectFront, back: objectBack)
            scale(&draw.planetAtmospheres[i].color, f)
        }
        for i in draw.shockShells.indices {
            let t = draw.shockShells[i].model.columns.3
            let f = factor(Vec3(t.x, t.y, t.z), front: objectFront, back: objectBack)
            scale(&draw.shockShells[i].color, f)
            scale(&draw.shockShells[i].accent, f)
            if f < 1 { draw.shockShells[i].params.x *= f }
        }
        for i in draw.shields.indices {
            let t = draw.shields[i].model.columns.3
            let f = factor(Vec3(t.x, t.y, t.z), front: objectFront, back: objectBack)
            scale(&draw.shields[i].shell, f)
            scale(&draw.shields[i].rim, f)
            scale(&draw.shields[i].hot, f)
            if f < 1 { draw.shields[i].params.x *= f }
        }
    }
}
