import Foundation
import simd

/// The wire curve leaves the shell along the device normal, splays, then
/// dives to the destination. The signal colour and pulse are evaluated on the
/// CPU per vertex so the whole wire field is a single additive line batch.
final class WireView {
    var edgeId: String = ""
    // Host graphs churn as apps and domains appear/disappear. The wire owns
    // its endpoints so a retiring node cannot leave a dangling reference in a
    // sort or draw pass. There is no cycle: views never point back at wires.
    var deviceView: DeviceView!
    var nodeView: NodeView!
    let offset: Float
    var tone: DNSStatus
    var curve: CatmullRom?
    var end = Vec3.zero
    var tangent = Vec3(0, 0, -1)

    var dim: Float = 1
    var facing: Float = 1
    var highlight: Float = 0
    var hidden = false
    var signalActive = false
    var hostTone = false
    /// Life-cycle fade for host wires. New wires grow in from zero and retired
    /// wires dissolve instead of vanishing in the same frame as their topology
    /// change.
    var visibility: Float = 1
    var retiring = false
    /// Endpoint presence, so a wire fades with the body it belongs to.
    var endpointFade: Float = 1
    /// Fraction of the curve currently drawn. Normal wires are 1; the
    /// reappearance pulse grows a wire from the device to its destination.
    var reveal: Float = 1

    private var points: [Vec3] = []
    private(set) var controlPoints: [Vec3] = []

    init(offset: Float, tone: DNSStatus) {
        self.offset = offset
        self.tone = tone
    }

    func setGlobePath(from: Vec3, to: Vec3, normal: Vec3, globeRadius: Float) {
        let fromV = from
        let toV = to
        let n = normal.normalized
        let dir = toV - fromV
        let dist = max(0.001, dir.length)
        let unit = dir.normalized

        var side = unit.cross(n)
        if side.lengthSq < 1e-4 { side = Vec3(1, 0, 0) }
        side = side.normalized
        let sway = (offset * 0.618).truncatingRemainder(dividingBy: 1)
        side = side * ((sway - 0.5) * 2 * (0.32 + min(1.4, dist * 0.08)))

        let p0 = fromV + n * 0.08
        var p1 = fromV + n * 0.95 + side + unit * min(0.9, dist * 0.08)
        var p2 = toV - unit * min(1.1, dist * 0.22)
        let p3 = toV
        let maxRadius = globeRadius * 0.92
        if p1.length > maxRadius { p1 = p1.withLength(maxRadius) }
        if p2.length > maxRadius { p2 = p2.withLength(maxRadius) }

        let control = [p0, p1, p2, p3]
        controlPoints = control
        let curve = CatmullRom(points: control, closed: false,
                               curveType: "centripetal", tension: 0.5)
        self.curve = curve
        end = p3
        var t = curve.tangentAt(1)
        if t.lengthSq < 0.1 { t = unit }
        tangent = t.normalized
        points = (0...96).map { curve.pointAt(Float($0) / 96) }
    }

    func snapshotCurve() -> [Vec3] { points }

    func setDim(_ dim: Float) { self.dim = max(0, dim) }
    func setFacing(_ facing: Float) { self.facing = max(0.06, min(1, facing)) }
    func setHighlight(_ highlight: Float) { self.highlight = max(0, min(1, highlight)) }
    func setVisible(_ visible: Bool) { hidden = !visible }
    func setSignalActive(_ active: Bool) { signalActive = active }

    func appendDraw(_ draw: DrawList, elapsed: Float, detail: Float = 1) {
        let lifeAlpha = visibility * endpointFade
        guard !hidden, lifeAlpha > 0.001, reveal > 0.001, points.count > 1, curve != nil else { return }
        let wireAlpha = smoothstep(0.40, 0.78, detail) * lifeAlpha
        guard wireAlpha > 0.01 else { return }
        let progress = (elapsed * 0.075 + offset).truncatingRemainder(dividingBy: 1)
        let pulse: Float = signalActive ? 0.015 : 0.32 * dim
        let opacity = (signalActive ? 0.78 : 1.0) * dim * facing * (1 + highlight * 1.8)
            * wireAlpha
        let a = (hostTone ? Palette.hostApp : Palette.signal).linear
        let b = hostTone ? Palette.hostRemote.linear
            : (tone == .blocked ? Palette.coral : Palette.gold).linear
        let white = hostTone ? Vec3(0.88, 0.99, 1.0) : Vec3(1.0, 0.95, 0.84)
        let segmentCount = max(1, min(points.count - 1,
                                      Int((Float(points.count - 1) * clamp01(reveal)).rounded(.up))))

        let stride = detail > 0.5 ? 1 : 4
        var i = 0
        while i < segmentCount {
            let t0 = Float(i) / 96
            let t1 = Float(i + 1) / 96
            draw.lines.append(LineVertex(points[i], wireColor(t0, a, b, white, progress, pulse, opacity, elapsed)))
            draw.lines.append(LineVertex(points[i + 1], wireColor(t1, a, b, white, progress, pulse, opacity, elapsed)))
            i += stride
        }
    }

    private func wireColor(_ vT: Float, _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                           _ white: Vec3, _ progress: Float, _ pulse: Float,
                           _ opacity: Float, _ elapsed: Float) -> SIMD4<Float> {
        var d = (vT - progress).truncatingRemainder(dividingBy: 1)
        if d < 0 { d += 1 }
        d = min(d, 1 - d)
        let head = exp(-d * d * 220) * pulse
        let trail = exp(-d * 8) * pulse * 0.18
        let base = (hostTone ? 0.30 : 0.17) + 0.045 * sin(vT * 34 - elapsed * 1.6)
        let alpha = min(1, (base + head + trail) * opacity)
        var col = a + (b - a) * smoothstep(0.58, 1.0, vT)
        col = col + (white - col) * min(head, 1) * 0.75
        return SIMD4(col * (0.85 + head * 2.6), alpha)
    }

}
