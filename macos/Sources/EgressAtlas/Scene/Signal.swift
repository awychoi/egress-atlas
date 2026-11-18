import Foundation
import simd

/// Port of app/src/lab/Signal.js: a white-hot comet with a 34-point tapered
/// trail that lives inside the moving signal group.
final class Signal {
    let curve: CatmullRom
    let duration: Float
    let length: Float
    var t: Float = 0
    var done = false
    var onArrive: (() -> Void)?
    private var rng: RNG
    private let trailCount = 34
    private var trailColors: [SIMD3<Float>] = []

    init(controlPoints: [Vec3], duration: Float? = nil, seed: UInt32 = 1, onArrive: (() -> Void)? = nil) {
        curve = CatmullRom(points: controlPoints, closed: false, curveType: "centripetal", tension: 0.5)
        length = curve.length()
        self.duration = duration ?? min(0.9, 0.42 + length * 0.028)
        self.onArrive = onArrive
        rng = RNG(seed)
        let ice = Palette.signalIce.linear
        let signal = Palette.signal.linear
        let white = Palette.white.linear
        for i in 0..<trailCount {
            let k = Float(i) / Float(trailCount - 1)
            let color = k < 0.52
                ? white + (ice - white) * (k / 0.52)
                : ice + (signal - ice) * ((k - 0.52) / 0.48)
            trailColors.append(color)
        }
    }

    var head: Vec3 { curve.pointAt(t) }

    func update(dt: Float) -> Bool {
        guard !done else { return false }
        t = clamp01(t + dt / duration)
        if t >= 0.999 {
            done = true
            onArrive?()
            return false
        }
        return true
    }

    func appendDraw(_ draw: DrawList, elapsed: Float) {
        guard !done else { return }
        let pos = curve.pointAt(t)
        let flicker = 0.85 + sin(t * 48) * 0.15
        draw.sprites.append(.glow(pos, size: 0.42 * flicker, color: Palette.white, opacity: 0.95))
        draw.sprites.append(.glow(pos, size: 1.55 * flicker, color: Palette.signal, opacity: 0.48))
        for i in 0..<trailCount {
            let lag = (Float(i) / Float(trailCount)) * 0.085
            let tt = max(0, t - lag)
            var prev = curve.pointAt(tt) - pos
            let jitter = (rng.next() - 0.5) * 0.028 * (Float(i) / Float(trailCount))
            let jitter2 = (rng.next() - 0.5) * 0.028 * (Float(i) / Float(trailCount))
            prev += Vec3(jitter, jitter2, jitter)
            let kk = Float(i) / Float(trailCount - 1)
            let size = 0.04 * (1 - kk * 0.7)
            let alpha = pow(1 - kk, 1.3) * 0.85 * (0.4 + t)
            draw.points.append(PointVertex(pos + prev, SIMD4(trailColors[i], alpha), size: size))
        }
        _ = elapsed
    }
}
