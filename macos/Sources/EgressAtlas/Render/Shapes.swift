import Foundation
import simd
import Metal

struct ShapeMesh {
    let buffer: MTLBuffer
    let count: Int
}

/// Geometry for the scene's mesh primitives. Shapes are unit-sized; the
/// caller supplies the model matrix.
final class ShapeLibrary {
    let device: MTLDevice
    private(set) var shapes: [ShapeID: ShapeMesh] = [:]
    private(set) var sphere: ShapeMesh
    private(set) var planetSphere: ShapeMesh
    private(set) var shieldSphere: ShapeMesh
    private(set) var jetCylinder: ShapeMesh
    private(set) var needleCone: ShapeMesh

    init(device: MTLDevice) {
        self.device = device
        sphere = Self.makeMesh(device, GeometryKit.sphere(width: 20, height: 14))
        planetSphere = Self.makeMesh(device, GeometryKit.sphere(width: 64, height: 40))
        shieldSphere = Self.makeMesh(device, GeometryKit.sphere(width: 48, height: 32))
        jetCylinder = Self.makeMesh(device, GeometryKit.cylinderOpen(top: 1, bottom: 0.16, height: 1, segments: 40))
        needleCone = Self.makeMesh(device, GeometryKit.coneOpen(radius: 1, height: 1, segments: 10))

        shapes[.sphere] = sphere
        shapes[.torus] = Self.makeMesh(device, GeometryKit.torus(major: 1, tube: 0.0045 / 0.345, tubular: 76, radial: 6))
        shapes[.ringSegmentInner] = Self.makeMesh(device, GeometryKit.ringSegment(inner: 1, outer: 1.34 / 1.12, theta: 0.9, segments: 24))
        shapes[.ringSegmentOuter] = Self.makeMesh(device, GeometryKit.ringSegment(inner: 1, outer: 2.14 / 1.86, theta: 0.9, segments: 32))
        shapes[.ringFull] = Self.makeMesh(device, GeometryKit.ringSegment(inner: 0.48 / 0.57, outer: 1, theta: .pi * 2, segments: 40))
        shapes[.tetra] = Self.makeMesh(device, GeometryKit.tetrahedron(radius: 1))
        shapes[.octa] = Self.makeMesh(device, GeometryKit.octahedron(radius: 1))
        shapes[.box] = Self.makeMesh(device, GeometryKit.box(size: 1))
        shapes[.cone] = Self.makeMesh(device, GeometryKit.coneOpen(radius: 1, height: 1, segments: 10))
    }

    static func makeMesh(_ device: MTLDevice, _ vertices: [ShapeVertex]) -> ShapeMesh {
        let length = max(1, vertices.count * MemoryLayout<ShapeVertex>.stride)
        let buffer = device.makeBuffer(bytes: vertices, length: length, options: .storageModeShared)!
        buffer.label = "shape mesh"
        return ShapeMesh(buffer: buffer, count: vertices.count)
    }
}

enum GeometryKit {
    static func triangles(_ a: Vec3, _ b: Vec3, _ c: Vec3,
                          _ n: Vec3 = Vec3(0, 0, 1),
                          _ uva: SIMD2<Float> = .zero,
                          _ uvb: SIMD2<Float> = .zero,
                          _ uvc: SIMD2<Float> = .zero) -> [ShapeVertex] {
        var out: [ShapeVertex] = []
        out.reserveCapacity(3)
        out.append(ShapeVertex(position: SIMD4(a, 1), normal: SIMD4(n, 0), uv: uva))
        out.append(ShapeVertex(position: SIMD4(b, 1), normal: SIMD4(n, 0), uv: uvb))
        out.append(ShapeVertex(position: SIMD4(c, 1), normal: SIMD4(n, 0), uv: uvc))
        return out
    }

    /// Counter-clockwise winding is front-facing; Metal defaults to clockwise.
    /// Build the sphere with clockwise outward faces so `.back` culling keeps
    /// the visible front hemisphere and the outward normals light correctly.
    static func appendOutward(_ out: inout [ShapeVertex], _ a: Vec3, _ b: Vec3, _ c: Vec3,
                              _ na: Vec3, _ nb: Vec3, _ nc: Vec3,
                              _ ua: SIMD2<Float>, _ ub: SIMD2<Float>, _ uc: SIMD2<Float>) {
        let face = (b - a).cross(c - a)
        let center = (a + b + c) / 3
        var bb = b, cc = c, nbb = nb, ncc = nc, ubb = ub, ucc = uc
        if face.dot(center) > 0 {
            bb = c; cc = b; nbb = nc; ncc = nb; ubb = uc; ucc = ub
        }
        out.append(ShapeVertex(position: SIMD4(a, 1), normal: SIMD4(na, 0), uv: ua))
        out.append(ShapeVertex(position: SIMD4(bb, 1), normal: SIMD4(nbb, 0), uv: ubb))
        out.append(ShapeVertex(position: SIMD4(cc, 1), normal: SIMD4(ncc, 0), uv: ucc))
    }

    static func sphere(width: Int, height: Int) -> [ShapeVertex] {
        var out: [ShapeVertex] = []
        out.reserveCapacity(width * height * 6)
        func p(_ u: Float, _ v: Float) -> Vec3 {
            let phi = u * Float.pi
            let theta = v * TAU
            return Vec3(-cos(theta) * sin(phi), cos(phi), sin(theta) * sin(phi))
        }
        func n(_ u: Float, _ v: Float) -> Vec3 { p(u, v) }
        for iy in 0..<height {
            let v0 = Float(iy) / Float(height)
            let v1 = Float(iy + 1) / Float(height)
            for ix in 0..<width {
                let u0 = Float(ix) / Float(width)
                let u1 = Float(ix + 1) / Float(width)
                let a = p(u0, v0), b = p(u1, v0), c = p(u1, v1), d = p(u0, v1)
                let na = n(u0, v0), nb = n(u1, v0), nc = n(u1, v1), nd = n(u0, v1)
                let ua = SIMD2<Float>(u0, v0), ub = SIMD2<Float>(u1, v0)
                let uc = SIMD2<Float>(u1, v1), ud = SIMD2<Float>(u0, v1)
                appendOutward(&out, a, b, d, na, nb, nd, ua, ub, ud)
                appendOutward(&out, b, c, d, nb, nc, nd, ub, uc, ud)
            }
        }
        return out
    }

    static func torus(major: Float, tube: Float, tubular: Int, radial: Int) -> [ShapeVertex] {
        var out: [ShapeVertex] = []
        out.reserveCapacity(tubular * radial * 6)
        func point(_ u: Float, _ v: Float) -> (Vec3, Vec3) {
            let cu = cos(u), su = sin(u)
            let cv = cos(v), sv = sin(v)
            let n = Vec3(cu * cv, su * cv, sv)
            let p = Vec3(cu * major, su * major, 0) + n * tube
            return (p, n)
        }
        for i in 0..<tubular {
            let u0 = Float(i) / Float(tubular)
            let u1 = Float(i + 1) / Float(tubular)
            for j in 0..<radial {
                let v0 = Float(j) / Float(radial)
                let v1 = Float(j + 1) / Float(radial)
                let (a, na) = point(u0, v0)
                let (b, nb) = point(u1, v0)
                let (c, nc) = point(u1, v1)
                let (d, nd) = point(u0, v1)
                let ua = SIMD2<Float>(u0, v0), ub = SIMD2<Float>(u1, v0)
                let uc = SIMD2<Float>(u1, v1), ud = SIMD2<Float>(u0, v1)
                out.append(contentsOf: triangles(a, b, d, na, ua, ub, ud))
                out.append(contentsOf: triangles(b, c, d, nc, ub, uc, ud))
            }
        }
        return out
    }

    static func ringSegment(inner: Float, outer: Float, theta: Float, segments: Int) -> [ShapeVertex] {
        var out: [ShapeVertex] = []
        out.reserveCapacity(segments * 6)
        let n = Vec3(0, 0, 1)
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * theta
            let a1 = Float(i + 1) / Float(segments) * theta
            let p0i = Vec3(cos(a0) * inner, sin(a0) * inner, 0)
            let p1i = Vec3(cos(a1) * inner, sin(a1) * inner, 0)
            let p0o = Vec3(cos(a0) * outer, sin(a0) * outer, 0)
            let p1o = Vec3(cos(a1) * outer, sin(a1) * outer, 0)
            let u0 = SIMD2<Float>(0, Float(i) / Float(segments))
            let u1 = SIMD2<Float>(0, Float(i + 1) / Float(segments))
            let u2 = SIMD2<Float>(1, Float(i + 1) / Float(segments))
            let u3 = SIMD2<Float>(1, Float(i) / Float(segments))
            out.append(contentsOf: triangles(p0i, p0o, p1o, n, u0, u3, u2))
            out.append(contentsOf: triangles(p0i, p1o, p1i, n, u0, u2, u1))
        }
        return out
    }

    static func tetrahedron(radius: Float) -> [ShapeVertex] {
        let a = Vec3(1, 1, 1).normalized * radius
        let b = Vec3(-1, -1, 1).normalized * radius
        let c = Vec3(-1, 1, -1).normalized * radius
        let d = Vec3(1, -1, -1).normalized * radius
        var out: [ShapeVertex] = []
        for (p, q, r) in [(a, b, c), (a, c, d), (a, d, b), (b, d, c)] {
            let n = (q - p).cross(r - p).normalized
            out.append(contentsOf: triangles(p, q, r, n))
        }
        return out
    }

    static func octahedron(radius: Float) -> [ShapeVertex] {
        let p = [Vec3(radius, 0, 0), Vec3(-radius, 0, 0), Vec3(0, radius, 0),
                 Vec3(0, -radius, 0), Vec3(0, 0, radius), Vec3(0, 0, -radius)]
        let faces = [(0, 2, 4), (2, 1, 4), (1, 3, 4), (3, 0, 4),
                     (2, 0, 5), (1, 2, 5), (3, 1, 5), (0, 3, 5)]
        var out: [ShapeVertex] = []
        for (i, j, k) in faces {
            let n = (p[j] - p[i]).cross(p[k] - p[i]).normalized
            out.append(contentsOf: triangles(p[i], p[j], p[k], n))
        }
        return out
    }

    static func box(size: Float) -> [ShapeVertex] {
        let h = size * 0.5
        let v = [Vec3(-h, -h, -h), Vec3(h, -h, -h), Vec3(h, h, -h), Vec3(-h, h, -h),
                 Vec3(-h, -h, h), Vec3(h, -h, h), Vec3(h, h, h), Vec3(-h, h, h)]
        let faces = [(0, 1, 2, 3), (5, 4, 7, 6), (4, 0, 3, 7),
                     (1, 5, 6, 2), (3, 2, 6, 7), (4, 5, 1, 0)]
        var out: [ShapeVertex] = []
        for (a, b, c, d) in faces {
            let n = (v[b] - v[a]).cross(v[c] - v[a]).normalized
            out.append(contentsOf: triangles(v[a], v[b], v[c], n))
            out.append(contentsOf: triangles(v[a], v[c], v[d], n))
        }
        return out
    }

    static func coneOpen(radius: Float, height: Float, segments: Int) -> [ShapeVertex] {
        var out: [ShapeVertex] = []
        let apex = Vec3(0, height * 0.5, 0)
        let baseY = -height * 0.5
        for i in 0..<segments {
            let a0 = Float(i) / Float(segments) * TAU
            let a1 = Float(i + 1) / Float(segments) * TAU
            let p0 = Vec3(cos(a0) * radius, baseY, sin(a0) * radius)
            let p1 = Vec3(cos(a1) * radius, baseY, sin(a1) * radius)
            let n0 = (p0 - apex).cross(p1 - p0).normalized
            out.append(contentsOf: triangles(p0, p1, apex, n0,
                                             SIMD2<Float>(0, 0), SIMD2<Float>(1, 0), SIMD2<Float>(1, 1)))
        }
        return out
    }

    /// CylinderGeometry(radiusTop, radiusBottom, 1, 40, 1, true), shifted so
    /// its base sits at y=0 like the vapor jet in vaporBloom.js.
    static func cylinderOpen(top: Float, bottom: Float, height: Float, segments: Int) -> [ShapeVertex] {
        var out: [ShapeVertex] = []
        for i in 0..<segments {
            let u0 = Float(i) / Float(segments)
            let u1 = Float(i + 1) / Float(segments)
            let a0 = u0 * TAU
            let a1 = u1 * TAU
            let p00 = Vec3(cos(a0) * bottom, 0, sin(a0) * bottom)
            let p10 = Vec3(cos(a1) * bottom, 0, sin(a1) * bottom)
            let p01 = Vec3(cos(a0) * top, height, sin(a0) * top)
            let p11 = Vec3(cos(a1) * top, height, sin(a1) * top)
            let n = Vec3(cos((a0 + a1) * 0.5), 0.3, sin((a0 + a1) * 0.5)).normalized
            out.append(contentsOf: triangles(p00, p01, p10, n,
                                             SIMD2<Float>(u0, 0), SIMD2<Float>(u0, 1), SIMD2<Float>(u1, 0)))
            out.append(contentsOf: triangles(p10, p01, p11, n,
                                             SIMD2<Float>(u1, 0), SIMD2<Float>(u0, 1), SIMD2<Float>(u1, 1)))
        }
        return out
    }

    /// A tube along a point set, used for local flows and the selected path
    /// halo (tube around a curve).
    static func tube(points: [Vec3], radius: Float, tubularSegments: Int = 72, radialSegments: Int = 5) -> [Vec3] {
        guard points.count >= 2 else { return [] }
        let curve = CatmullRom(points: points, closed: false, curveType: "catmullrom", tension: 0.5)
        var positions: [Vec3] = []
        positions.reserveCapacity(tubularSegments * radialSegments * 6 * 3)
        var frames: [(Vec3, Vec3, Vec3)] = []
        for i in 0...tubularSegments {
            let u = Float(i) / Float(tubularSegments)
            let p = curve.pointAt(u)
            let tangent = curve.tangentAt(u)
            let n0 = abs(tangent.dot(.up)) > 0.92 ? Vec3.right : Vec3.up
            let normal = tangent.cross(n0).normalized
            let binormal = tangent.cross(normal).normalized
            frames.append((p, normal, binormal))
        }
        for i in 0..<tubularSegments {
            let f0 = frames[i]
            let f1 = frames[i + 1]
            func ring(_ f: (Vec3, Vec3, Vec3), _ v: Int) -> Vec3 {
                let a = Float(v) / Float(radialSegments) * TAU
                return f.0 + f.1 * (cos(a) * radius) + f.2 * (sin(a) * radius)
            }
            for j in 0..<radialSegments {
                let a = ring(f0, j), b = ring(f1, j)
                let c = ring(f1, j + 1), d = ring(f0, j + 1)
                positions.append(contentsOf: [a, b, d, b, c, d])
            }
        }
        return positions
    }
}
