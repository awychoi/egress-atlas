import Foundation
import simd

// Direct port of app/src/lab/math.js plus the small vector helpers the
// Three.js scene relied on. Keep the names close to the source so the port is
// auditable line by line.

typealias Vec3 = SIMD3<Float>
typealias Vec2 = SIMD2<Float>
typealias Mat4 = simd_float4x4
typealias Quat = simd_quatf

let TAU: Float = .pi * 2
let DEG: Float = 180 / .pi

@inline(__always) func clamp(_ v: Float, _ a: Float = 0, _ b: Float = 1) -> Float {
    min(b, max(a, v))
}

@inline(__always) func clamp01(_ v: Float) -> Float { clamp(v, 0, 1) }

@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

@inline(__always) func invLerp(_ a: Float, _ b: Float, _ v: Float) -> Float { (v - a) / (b - a) }

@inline(__always) func smoothstep(_ a: Float, _ b: Float, _ v: Float) -> Float {
    let t = clamp01((v - a) / (b - a))
    return t * t * (3 - 2 * t)
}

@inline(__always) func easeInQuad(_ t: Float) -> Float { t * t }
@inline(__always) func easeOutQuad(_ t: Float) -> Float { 1 - (1 - t) * (1 - t) }
@inline(__always) func easeInCubic(_ t: Float) -> Float { t * t * t }
@inline(__always) func easeOutCubic(_ t: Float) -> Float { 1 - pow(1 - t, 3) }
@inline(__always) func easeInOutCubic(_ t: Float) -> Float {
    t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
}
@inline(__always) func easeOutQuint(_ t: Float) -> Float { 1 - pow(1 - t, 5) }
@inline(__always) func easeOutExpo(_ t: Float) -> Float { t >= 1 ? 1 : 1 - pow(2, -10 * t) }
@inline(__always) func easeInExpo(_ t: Float) -> Float { t <= 0 ? 0 : pow(2, 10 * t - 10) }
@inline(__always) func easeOutBack(_ t: Float, _ overshoot: Float = 1.4) -> Float {
    let c3 = overshoot + 1
    let p = t - 1
    return 1 + c3 * p * p * p + overshoot * p * p
}

/// The deterministic RNG that seeds every demo layout and motion study:
/// mulberry32 from app/src/lab/math.js. Exact 32-bit JS semantics.
final class RNG {
    private var a: UInt32

    init(_ seed: UInt32) {
        a = seed
    }

    init(_ seed: Int) {
        a = UInt32(truncatingIfNeeded: seed)
    }

    func next() -> Float {
        a = a &+ 0x6D2B_79F5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Float(t ^ (t >> 14)) / 4_294_967_296.0
    }

    func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }
    func spread(_ amount: Float) -> Float { (next() * 2 - 1) * amount }
    func int(_ n: Int) -> Int { Int(next() * Float(n)) % max(1, n) }

    func pick<T>(_ arr: [T]) -> T { arr[Int(next() * Float(arr.count)) % arr.count] }

    func shuffle<T>(_ list: [T]) -> [T] {
        var out = list
        guard out.count > 1 else { return out }
        for i in stride(from: out.count - 1, through: 1, by: -1) {
            let j = Int(next() * Float(i + 1))
            out.swapAt(i, j)
        }
        return out
    }
}

extension Vec3 {
    @inline(__always) var length: Float { simd_length(self) }
    @inline(__always) var lengthSq: Float { simd_length_squared(self) }
    @inline(__always) var normalized: Vec3 { simd_normalize(self) }
    @inline(__always) func dot(_ other: Vec3) -> Float { simd_dot(self, other) }
    @inline(__always) func cross(_ other: Vec3) -> Vec3 { simd_cross(self, other) }
    @inline(__always) func distance(to other: Vec3) -> Float { simd_distance(self, other) }
    @inline(__always) func distanceSquared(to other: Vec3) -> Float { simd_distance_squared(self, other) }
    @inline(__always) func lerp(_ other: Vec3, _ t: Float) -> Vec3 { self + (other - self) * t }
    @inline(__always) func withLength(_ length: Float) -> Vec3 {
        let l = simd_length(self)
        guard l > 1e-8 else { return .zero }
        return self * (length / l)
    }
    @inline(__always) func adding(_ scalar: Float) -> Vec3 { self + Vec3(repeating: scalar) }
}

extension Vec3 {
    static let up = Vec3(0, 1, 0)
    static let right = Vec3(1, 0, 0)
    static let forward = Vec3(0, 0, 1)
}

@inline(__always) func vec3(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }

/// Orthonormal basis whose +Z is `normal`, matching math.js orthoBasis.
func orthoBasis(_ normal: Vec3) -> (n: Vec3, t: Vec3, b: Vec3) {
    let n = normal.normalized
    let helper: Vec3 = abs(n.y) > 0.92 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
    let t = helper.cross(n).normalized
    let b = n.cross(t).normalized
    return (n, t, b)
}

/// Degrees between a plane normal and the camera forward, folded to 0...90.
func angleToView(_ normal: Vec3, _ camera: Camera) -> Float {
    let forward = camera.forward
    let d = abs(normal.dot(forward))
    return acos(min(1, d)) * DEG
}

func nowSeconds() -> Double { Date.timeIntervalSinceReferenceDate }

// ── Matrices ──────────────────────────────────────────────────────────────

extension Mat4 {
    static func identity() -> Mat4 { matrix_identity_float4x4 }

    static func translation(_ t: Vec3) -> Mat4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: Vec3) -> Mat4 {
        var m = matrix_identity_float4x4
        m.columns.0.x = s.x
        m.columns.1.y = s.y
        m.columns.2.z = s.z
        return m
    }

    static func rotation(quaternion q: Quat) -> Mat4 {
        Mat4(q)
    }

    /// Three.js Euler default order (XYZ), R = Rx * Ry * Rz.
    static func eulerXYZ(_ x: Float, _ y: Float, _ z: Float) -> Mat4 {
        let cx = cos(x), sx = sin(x)
        let cy = cos(y), sy = sin(y)
        let cz = cos(z), sz = sin(z)
        let rx = Mat4(columns: (
            SIMD4(1, 0, 0, 0),
            SIMD4(0, cx, sx, 0),
            SIMD4(0, -sx, cx, 0),
            SIMD4(0, 0, 0, 1)
        ))
        let ry = Mat4(columns: (
            SIMD4(cy, 0, -sy, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(sy, 0, cy, 0),
            SIMD4(0, 0, 0, 1)
        ))
        let rz = Mat4(columns: (
            SIMD4(cz, sz, 0, 0),
            SIMD4(-sz, cz, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        ))
        return rx * ry * rz
    }

    static func compose(position: Vec3, quaternion: Quat, scale: Vec3) -> Mat4 {
        var m = Mat4(quaternion)
        m.columns.0 *= scale.x
        m.columns.1 *= scale.y
        m.columns.2 *= scale.z
        m.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return m
    }

    var upper3x3: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3(columns.0.x, columns.0.y, columns.0.z),
            SIMD3(columns.1.x, columns.1.y, columns.1.z),
            SIMD3(columns.2.x, columns.2.y, columns.2.z)
        ))
    }
}

func quaternionFromUp(to normal: Vec3) -> Quat {
    simd_quatf(from: Vec3.up, to: normal.normalized)
}

// ── Camera (Three.js PerspectiveCamera + OrbitControls target) ────────────

struct Camera {
    var position: Vec3
    var target: Vec3
    var fov: Float
    var near: Float
    var far: Float
    var aspect: Float

    init(
        position: Vec3 = Vec3(16.5, 12.4, 32.5),
        target: Vec3 = Vec3(0, 0.15, 0),
        fov: Float = 35,
        near: Float = 0.1,
        far: Float = 220,
        aspect: Float = 1.6
    ) {
        self.position = position
        self.target = target
        self.fov = fov
        self.near = near
        self.far = far
        self.aspect = aspect
    }

    var forward: Vec3 { (target - position).normalized }
    var viewMatrix: Mat4 { Mat4.lookAt(eye: position, target: target, up: .up) }
    var projectionMatrix: Mat4 {
        Mat4.perspectiveRightHand(fovY: fov * .pi / 180, aspect: aspect, near: near, far: far)
    }
    var viewProjection: Mat4 { projectionMatrix * viewMatrix }

    /// The camera-space depth used by the bokeh shader (positive distance in
    /// front of the camera). This is the equivalent of Three's `viewZ`.
    func viewDepth(of point: Vec3) -> Float {
        (point - position).dot(forward)
    }

    func project(_ point: Vec3, viewport: SIMD2<Float>) -> SIMD3<Float> {
        let clip = viewProjection * SIMD4(point.x, point.y, point.z, 1)
        guard clip.w > 0.0001 else { return SIMD3(-1000, -1000, clip.w) }
        let ndc = SIMD3(clip.x / clip.w, clip.y / clip.w, clip.z / clip.w)
        return SIMD3(
            (ndc.x * 0.5 + 0.5) * viewport.x,
            (0.5 - ndc.y * 0.5) * viewport.y,
            ndc.z
        )
    }

    func rayDirection(ndc: SIMD2<Float>) -> Vec3 {
        let tanFov = tan(fov * .pi / 360)
        let x = ndc.x * aspect * tanFov
        let y = ndc.y * tanFov
        let forward = forward
        let right = forward.cross(.up).normalized
        let up = right.cross(forward).normalized
        return (forward + right * x + up * y).normalized
    }
}

extension Mat4 {
    static func lookAt(eye: Vec3, target: Vec3, up: Vec3) -> Mat4 {
        let z = (eye - target).normalized
        let x = up.cross(z).normalized
        let y = z.cross(x).normalized
        return Mat4(columns: (
            SIMD4(x.x, y.x, z.x, 0),
            SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-x.dot(eye), -y.dot(eye), -z.dot(eye), 1)
        ))
    }

    /// Right-handed perspective for Metal's [0,1] depth range.
    static func perspectiveRightHand(fovY: Float, aspect: Float, near: Float, far: Float) -> Mat4 {
        let ys = 1 / tan(fovY * 0.5)
        let xs = ys / max(0.0001, aspect)
        let zs = far / (near - far)
        return Mat4(columns: (
            SIMD4(xs, 0, 0, 0),
            SIMD4(0, ys, 0, 0),
            SIMD4(0, 0, zs, -1),
            SIMD4(0, 0, zs * near, 0)
        ))
    }
}

// ── CatmullRom (port of Three.CatmullRomCurve3, centripetal, arc length) ──

final class CatmullRom {
    let points: [Vec3]
    let closed: Bool
    let curveType: String
    let tension: Float
    private var cachedLengths: [Float]?
    private var cachedDivisions = -1

    init(points: [Vec3], closed: Bool = false, curveType: String = "centripetal", tension: Float = 0.5) {
        self.points = points
        self.closed = closed
        self.curveType = curveType
        self.tension = tension
    }

    /// Uniform-parameter sample, `t` in 0...1.
    func point(_ t: Float) -> Vec3 {
        guard !points.isEmpty else { return .zero }
        if points.count == 1 { return points[0] }
        let p = clamp(t, 0, 1) * Float(points.count - 1)
        var i = Int(floor(p))
        if i >= points.count - 1 { i = points.count - 2 }
        // `t = 1` lands exactly on the last control point. Clamping the
        // segment index without also clamping the interpolation weight made
        // `point(1)` evaluate the start of the previous segment, so every
        // `getTangentAt(1)` pointed backwards and shield/recoil directions
        // were inverted.
        let weight = p - Float(i)
        let p1 = points[i]
        let p2 = points[i + 1]
        let p0: Vec3
        let p3: Vec3
        if closed || i > 0 {
            p0 = points[(i - 1 + points.count) % points.count]
        } else {
            p0 = p1 + (p1 - p2)
        }
        if closed || i + 2 < points.count {
            p3 = points[(i + 2) % points.count]
        } else {
            p3 = p2 + (p2 - p1)
        }
        if curveType == "centripetal" || curveType == "chordal" {
            var dt0: Float = 0, dt1: Float = 0, dt2: Float = 0
            let powValue: Float = curveType == "chordal" ? 0.5 : 0.25
            dt0 = pow((p0 - p1).lengthSq, powValue)
            dt1 = pow((p1 - p2).lengthSq, powValue)
            dt2 = pow((p2 - p3).lengthSq, powValue)
            if dt1 < 1e-4 { dt1 = 1 }
            if dt0 < 1e-4 { dt0 = dt1 }
            if dt2 < 1e-4 { dt2 = dt1 }
            func spline(_ x0: Float, _ x1: Float, _ x2: Float, _ x3: Float) -> Float {
                var t1 = (x1 - x0) / dt0 - (x2 - x0) / (dt0 + dt1) + (x2 - x1) / dt1
                var t2 = (x2 - x1) / dt1 - (x3 - x1) / (dt1 + dt2) + (x3 - x2) / dt2
                t1 *= dt1
                t2 *= dt1
                let c2 = -3 * x1 + 3 * x2 - 2 * t1 - t2
                let c3 = 2 * x1 - 2 * x2 + t1 + t2
                return x1 + t1 * weight + c2 * weight * weight + c3 * weight * weight * weight
            }
            return Vec3(spline(p0.x, p1.x, p2.x, p3.x),
                        spline(p0.y, p1.y, p2.y, p3.y),
                        spline(p0.z, p1.z, p2.z, p3.z))
        }
        // Uniform Catmull-Rom with tension.
        let t1 = (p2 - p0) * tension
        let t2 = (p3 - p1) * tension
        let w2 = weight * weight
        let w3 = w2 * weight
        return p1 * (2 * w3 - 3 * w2 + 1)
            + t1 * (w3 - 2 * w2 + weight)
            + p2 * (-2 * w3 + 3 * w2)
            + t2 * (w3 - w2)
    }

    /// Arc-length parameterisation, `u` in 0...1 (Three's getPointAt).
    func pointAt(_ u: Float, divisions: Int = 200) -> Vec3 {
        guard points.count > 1 else { return points.first ?? .zero }
        let lengths = arcLengths(divisions: divisions)
        let total = lengths.last ?? 0
        guard total > 0 else { return point(clamp(u, 0, 1)) }
        let target = clamp(u, 0, 1) * total
        var low = 0
        var high = lengths.count - 1
        while low < high {
            let mid = (low + high) / 2
            if lengths[mid] < target { low = mid + 1 } else { high = mid }
        }
        let prev = lengths[max(0, low - 1)]
        let next = lengths[low]
        let weight = next > prev ? (target - prev) / (next - prev) : 0
        return point((Float(low - 1) + weight) / Float(lengths.count - 1))
    }

    func arcLengths(divisions: Int = 200) -> [Float] {
        if cachedDivisions == divisions, let cachedLengths { return cachedLengths }
        var lengths: [Float] = [0]
        lengths.reserveCapacity(divisions + 1)
        var last = point(0)
        var sum: Float = 0
        for i in 1...divisions {
            let p = point(Float(i) / Float(divisions))
            sum += p.distance(to: last)
            lengths.append(sum)
            last = p
        }
        cachedLengths = lengths
        cachedDivisions = divisions
        return lengths
    }

    func length(divisions: Int = 200) -> Float {
        arcLengths(divisions: divisions).last ?? 0
    }

    func tangentAt(_ u: Float, divisions: Int = 200) -> Vec3 {
        let delta: Float = 0.0001
        let a = pointAt(max(0, u - delta), divisions: divisions)
        let b = pointAt(min(1, u + delta), divisions: divisions)
        let t = b - a
        return t.lengthSq > 1e-10 ? t.normalized : .zero
    }
}

func spherical(lat: Float, lon: Float, radius: Float = 6) -> Vec3 {
    let phi = (90 - lat) * .pi / 180
    let theta = lon * .pi / 180
    return Vec3(
        radius * sin(phi) * sin(theta),
        radius * cos(phi),
        radius * sin(phi) * cos(theta)
    )
}

extension Float {
    var radians: Float { self * .pi / 180 }
}
