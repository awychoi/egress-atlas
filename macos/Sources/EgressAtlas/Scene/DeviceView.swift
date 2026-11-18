import Foundation
import simd

struct DeviceSpecView {
    let id: String
    let name: String
    let kind: String
    let ip: String
    let thisMac: Bool
}

/// Port of app/src/lab/DeviceView.js. A blue gyro orb sits on a tangent pad on
/// the shell; its label and every mote share the same surface normal.
final class DeviceView {
    let spec: DeviceSpecView
    unowned var deviceRef: Device!
    var position: Vec3
    var normal: Vec3
    let radius: Float
    var phase: Float

    var hovered = false
    var selected = false
    var dimmed = false
    var labelWanted = true
    var shotAge: Float = 9
    var facing: Float = 0
    var displayVisibility: Float = 1
    var windowVisible = true
    var windowPresence: Float = 1

    enum AppearanceStyle: CaseIterable {
        case bloom
        case spin
        case shellWeld
    }
    var appearanceStyle: AppearanceStyle?
    var appearanceAge: Float = 1

    private var moteData: [(radius: Float, speed: Float, phase: Float, tilt: Float,
                            color: SRGB, size: Float)] = []
    private var padYaw: Float = 0
    private var gyroAngles: [(z: Float, y: Float)] = []
    private var gyroBase: [(x: Float, y: Float, z: Float)] = []

    var model: Mat4 {
        Mat4.translation(position) * Mat4(quaternionFromUp(to: normal))
    }

    var visualCenter: Vec3 {
        let p = model * SIMD4(0, 0.33, 0, 1)
        return Vec3(p.x, p.y, p.z)
    }

    var labelPosition: Vec3 {
        let p = model * SIMD4(0, 0.64, 0, 1)
        return Vec3(p.x, p.y, p.z)
    }

    init(spec: DeviceSpecView, position: Vec3, normal: Vec3, radius: Float = 0.085, rng: RNG) {
        self.spec = spec
        self.position = position
        self.normal = normal.normalized
        self.radius = radius
        self.phase = rng.next() * .pi * 2

        let signal = Palette.signal
        let ice = Palette.signalIce
        for _ in 0..<12 {
            let r = 0.42 + rng.next() * 0.32
            let speed = 0.4 + rng.next() * 1.1
            let phase = rng.next() * .pi * 2
            let tilt = rng.next() * 0.9 - 0.45
            let color = rng.next() > 0.65 ? signal : ice
            let size = 0.014 + rng.next() * 0.028
            moteData.append((r, speed, phase, tilt, color, size))
        }
        for i in 0..<3 {
            gyroBase.append((.pi / 2 + Float(i) * 0.72, Float(i) * 1.1, Float(i) * 0.6))
            gyroAngles.append((0, 0))
        }
    }

    func setSurfacePosition(_ position: Vec3, _ normal: Vec3) {
        self.position = position
        self.normal = normal.normalized
        deviceRef?.surface = position
        deviceRef?.normal = normal.normalized
    }

    func canPick() -> Bool {
        // Every device is a target, including the half of the shell that faces
        // away from the camera. Those bodies are dimmed by the shell falloff,
        // not removed; a deliberate click or double-click should still select
        // them and orbit the camera around to put them in front. Devices
        // outside the history window are not on the globe, so they drop out of
        // picking until they become active again.
        windowVisible && windowPresence > 0.2
    }

    func setHovered(_ hovered: Bool) { self.hovered = hovered }
    func setSelected(_ selected: Bool) { self.selected = selected }
    func setDimmed(_ dimmed: Bool) { self.dimmed = dimmed }
    func setLabelVisible(_ visible: Bool) { labelWanted = visible }
    func setWindowVisible(_ visible: Bool, animated: Bool = true, style: AppearanceStyle? = nil) {
        windowVisible = visible
        if !animated {
            windowPresence = visible ? 1 : 0
            appearanceStyle = nil
            appearanceAge = 1
        } else if visible {
            appearanceStyle = style
            appearanceAge = style == nil ? 1 : 0
        } else {
            appearanceStyle = nil
            appearanceAge = 1
        }
    }
    func onFire() { shotAge = 0 }

    var labelVisible: Bool {
        // A background device has no visible label until the pointer or
        // selection reaches it. Once it does, the tag stays crisp: the depth
        // falloff belongs to the orb and the shell, not the UI chrome. A
        // device outside the history window has no tag at all.
        windowVisible && windowPresence > 0.05
            && labelWanted && (hovered || (!dimmed && (facing > 0.1 || selected)))
    }

    func update(dt: Float, elapsed: Float, camera: Camera) {
        let cameraDir = camera.position.normalized
        facing = normal.dot(cameraDir)
        let dim = smoothstep(-0.32, 0.36, facing)
        let target: Float = selected ? max(0.82, 0.08 + dim * 0.92) : 0.08 + dim * 0.92
        displayVisibility += (target - displayVisibility) * (1 - exp(-dt * 7))
        let presenceTarget: Float = windowVisible ? 1 : 0
        windowPresence += (presenceTarget - windowPresence) * (1 - exp(-dt * 6))
        if windowPresence < 0.002 && !windowVisible { windowPresence = 0 }
        if appearanceAge < 1 {
            appearanceAge = min(1, appearanceAge + dt / 0.72)
        }
        if shotAge < 1 { shotAge += dt }
        padYaw += dt * 0.18
        for i in 0..<3 {
            gyroAngles[i].z += dt * (0.22 + Float(i) * 0.13)
            gyroAngles[i].y += dt * (0.22 + Float(i) * 0.13) * 0.55
        }
        _ = elapsed
    }

    func appendDraw(_ draw: DrawList, elapsed: Float) {
        guard windowPresence > 0.001 else { return }
        let visibility = displayVisibility * windowPresence
        let selectedBoost: Float = selected ? 1.1 : 1
        // Devices outside the history window shrink toward the shell as they
        // fade, so a range change reads as an arrival or retirement rather
        // than a pop. An arrival triggered by a live query also plays one of a
        // few short device-specific studies once the pulse reaches the shell.
        let grow = 0.58 + 0.42 * windowPresence
        var model = self.model * Mat4.scale(Vec3(repeating: grow))
        var appearFlash: Float = 0
        if let style = appearanceStyle, windowVisible, appearanceAge < 1 {
            let t = clamp01(appearanceAge)
            switch style {
            case .bloom:
                let punch = sin(t * .pi) * (1 - t * 0.3)
                model = self.model * Mat4.scale(Vec3(repeating: grow * (1 + 0.22 * punch)))
                appearFlash = pow(1 - t, 2) * 0.22
            case .spin:
                let spin = (1 - t) * (1 - t) * TAU * 1.4
                model = self.model
                    * Mat4.rotation(quaternion: Quat(angle: spin, axis: .up))
                    * Mat4.scale(Vec3(repeating: grow))
                appearFlash = pow(1 - t, 2) * 0.14
            case .shellWeld:
                let height = 0.22 + 0.78 * easeOutCubic(t)
                model = self.model * Mat4.scale(Vec3(grow, grow * height, grow))
                appearFlash = pow(1 - t, 2) * 0.16
            }
        }
        let center4 = model * SIMD4(0, 0.33, 0, 1)
        let center = Vec3(center4.x, center4.y, center4.z)

        // Orb.
        let orbScale = (0.9 + sin(elapsed * 3.1 + phase) * 0.08) * 1.1
        draw.addSphere(center: center, radius: radius * orbScale * grow,
                       color: rgba(Palette.signalIce, 0.96 * visibility * selectedBoost))

        // Glow and broad halo.
        let pulse = 1 + sin(elapsed * 2.2 + phase) * 0.1
        draw.sprites.append(.glow(center, size: 1.15 * pulse * grow, color: Palette.signal,
                                  opacity: (0.42 + sin(elapsed * 2.2 + phase) * 0.08) * visibility))
        if shotAge < 1 {
            let t = min(1, shotAge / 0.5)
            draw.sprites.append(.glow(center, size: (2.7 + t * 2.6) * grow, color: Palette.signal,
                                      opacity: pow(1 - t, 1.8) * 0.28 * visibility))
        } else {
            draw.sprites.append(.glow(center, size: 2.7 * grow, color: Palette.signal,
                                      opacity: 0.12 * visibility))
        }
        if selected {
            draw.sprites.append(.glow(center, size: 2.1 * grow, color: Palette.signalIce,
                                      opacity: 0.34 * visibility))
        }
        if appearFlash > 0.001 {
            draw.sprites.append(.glow(center, size: 2.6 * grow, color: Palette.signalIce,
                                      opacity: appearFlash))
        }

        // Three gyros. The torus supplies the soft bloom body; the 1 px line
        // keeps the instrument ring legible at native resolution, where the
        // web's 0.0045 world tube is sub-pixel.
        let gyroScale = Vec3(repeating: 0.345)
        for i in 0..<3 {
            let base = gyroBase[i]
            let angle = gyroAngles[i]
            let local = Mat4.eulerXYZ(base.x, base.y + angle.y, base.z + angle.z)
            let m = model * Mat4.translation(Vec3(0, 0.33, 0)) * local * Mat4.scale(gyroScale)
            let color = i == 1 ? Palette.signalIce : Palette.signal
            let alpha = (0.28 + sin(elapsed * 1.6 + Float(i) * 2.1) * 0.1) * visibility
            draw.addMesh(.torus, MeshInstance(model: m, color: rgba(color, alpha)))
            var prev: Vec3?
            for s in 0...72 {
                let a = Float(s) / 72 * TAU
                let p4 = m * SIMD4(cos(a), sin(a), 0, 1)
                let p = Vec3(p4.x, p4.y, p4.z)
                if let prev {
                    draw.lines.append(LineVertex(prev, rgba(color, min(1, alpha * 3.0))))
                    draw.lines.append(LineVertex(p, rgba(color, min(1, alpha * 3.0))))
                }
                prev = p
            }
        }

        // Orbiting motes.
        for m in moteData {
            let a = elapsed * m.speed + m.phase
            let local = Vec3(cos(a) * m.radius, sin(a * 1.7 + m.tilt) * 0.24, sin(a) * m.radius)
            let p4 = model * SIMD4(local.x, local.y + 0.33, local.z, 1)
            let p = Vec3(p4.x, p4.y, p4.z)
            let alpha = (0.22 + sin(elapsed * 2 + m.phase) * 0.16) * visibility
            draw.points.append(PointVertex(p, rgba(m.color, alpha), size: m.size * grow))
        }

        // Pad: ring, ticks, pool and stem.
        let padRotation = Mat4.eulerXYZ(0, padYaw, 0)
        let padModel = model * Mat4.translation(Vec3(0, 0.015, 0)) * padRotation
        var previous: Vec3?
        for i in 0...96 {
            let a = Float(i) / 96 * TAU
            let p4 = padModel * SIMD4(cos(a) * 0.82, 0, sin(a) * 0.82, 1)
            let p = Vec3(p4.x, p4.y, p4.z)
            if let previous {
                draw.addLine(previous, p, rgba(Palette.signal, min(1, 0.34 * visibility * selectedBoost * 1.45)))
            }
            previous = p
        }
        let padModelNoYaw = model * Mat4.translation(Vec3(0, 0.015, 0))
        for i in 0..<12 {
            let a = Float(i) / 12 * TAU
            let inner: Float = 0.86
            let outer: Float = i % 3 == 0 ? 1.04 : 0.94
            let a4 = padModelNoYaw * SIMD4(cos(a) * inner, 0, sin(a) * inner, 1)
            let b4 = padModelNoYaw * SIMD4(cos(a) * outer, 0, sin(a) * outer, 1)
            draw.addLine(Vec3(a4.x, a4.y, a4.z), Vec3(b4.x, b4.y, b4.z),
                         rgba(Palette.signalIce, 0.22 * visibility * selectedBoost))
        }
        let pool = padModel * SIMD4(0, -0.002, 0, 1)
        draw.sprites.append(.glow(Vec3(pool.x, pool.y, pool.z), size: 1.9 * grow,
                                  color: Palette.signal, opacity: min(1, 0.15 * visibility * selectedBoost * 1.3)))
        let stemA = model * SIMD4(0, 0.02, 0, 1)
        let stemB = model * SIMD4(0, 0.31, 0, 1)
        draw.addLine(Vec3(stemA.x, stemA.y, stemA.z), Vec3(stemB.x, stemB.y, stemB.z),
                     rgba(Palette.signal, 0.18 * visibility * selectedBoost))
    }
}
