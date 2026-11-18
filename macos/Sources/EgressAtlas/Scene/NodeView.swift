import Foundation
import simd

struct NodeSpec {
    let id: String
    let key: String
    let domain: String
    let meta: String
    let latency: String
    let status: DNSStatus
    let position: Vec3
    let tone: String
}

/// Port of app/src/lab/NodeView.js. A destination is a real orb with the
/// camera-facing instrument ring, two orbiters, a world orbit line and a
/// short-lived flash. The recoil offset moves the whole assembly, not the
/// anchor, so wires and hit planes stay fixed.
final class NodeView {
    let spec: NodeSpec
    let id: String
    let index: Int
    let radius: Float
    unowned var destinationRef: Destination!
    var basePosition: Vec3

    var presence: Float = 1
    var hovered = false
    var selected = false
    var dimmed = false
    var labelWanted = true
    var phase: Float
    var depthBlur: Float = 0
    var destroyed = false
    var labelStatOverride: String?

    var status: DNSStatus = .allowed
    var flashAge: Float = 99
    var recoilActive = false
    var recoilAge: Float = 0
    var recoilDir = Vec3(0, 0, -1)

    private var orbitTilt: Float
    private var orbitRoll: Float
    private var orbitYaw: Float = 0
    private var lastFlashScale: Float = 0
    private var hoverState = HoverEase()

    private var tint: NodeTint.Tint { status == .blocked ? NodeTint.blocked : NodeTint.allowed }

    init(spec: NodeSpec, radius: Float, index: Int, rng: RNG) {
        self.spec = spec
        self.id = spec.id
        self.index = index
        self.radius = radius
        self.basePosition = spec.position
        self.phase = rng.next() * .pi * 2
        self.orbitTilt = 1.06 + rng.next() * 0.3
        self.orbitRoll = rng.next() * .pi
        self.status = spec.status
    }

    func setBasePosition(_ position: Vec3) {
        basePosition = position
        destinationRef?.position = position
    }

    func setStatus(_ status: DNSStatus) {
        self.status = status == .blocked ? .blocked : .allowed
        setPresence(presence)
    }

    func setPresence(_ value: Float) {
        let next = clamp(value, 0, 1.16)
        if next < 0.004 && presence < 0.004 {
            presence = next
            return
        }
        presence = next
    }

    func setHovered(_ hovered: Bool) { self.hovered = hovered }
    func setSelected(_ selected: Bool) { self.selected = selected }
    func setDimmed(_ dimmed: Bool) { self.dimmed = dimmed }
    func setLabelVisible(_ visible: Bool) { labelWanted = visible }

    var visualScale: Float { 0.86 + 0.14 * min(1.2, presence) }
    var dimFactor: Float { dimmed ? 0.32 : 1 }

    var recoilOffset: Vec3 {
        guard recoilActive else { return .zero }
        let t = recoilAge / 0.66
        if t >= 1 { return .zero }
        let offset = sin(9.4 * t) * exp(-3.8 * t) * radius * 0.5
        return recoilDir * offset
    }

    var labelPosition: Vec3 {
        basePosition + recoilOffset + Vec3(0, radius + 0.18, 0)
    }

    func onHit(_ direction: Vec3, recoil: Bool) {
        flashAge = 0
        lastFlashScale = radius * (status == .blocked ? 2.25 : 2.7)
        let canRecoil = recoil && status != .blocked
        if canRecoil {
            recoilActive = true
            recoilAge = 0
            // `direction` is the inbound arrival tangent (source -> node).
            // Knockback must travel *against* the incoming packet, otherwise
            // the node appears to be pushed forward into the blast. Keep the
            // anchor (and therefore the wire and hit plane) fixed; only the
            // visible assembly moves.
            recoilDir = (-direction).normalized
        } else {
            stopRecoil()
        }
    }

    func stopRecoil() {
        recoilActive = false
        recoilAge = 0
    }

    func canPick() -> Bool { !destroyed && presence > 0.25 }

    func update(dt: Float, elapsed: Float) {
        let hoverTarget: Float = (hovered || selected) ? 1 : 0
        hoverState.value += (hoverTarget - hoverState.value) * min(1, dt * 10)
        if flashAge < 1 {
            flashAge += dt
        }
        if recoilActive {
            recoilAge += dt
            if recoilAge / 0.66 >= 1 { stopRecoil() }
        }
        orbitYaw += dt * 0.22
        _ = elapsed
    }

    private struct HoverEase { var value: Float = 0 }

    /// Append the destination's visual primitives. `camera` gives the billboard
    /// orientation and the camera-facing inner arc's plane.
    func appendDraw(_ draw: DrawList, elapsed: Float, camera: Camera) {
        guard presence > 0.004 else { return }
        let tint = self.tint
        let dim = dimFactor
        let op = presence * tint.dim * dim
        let visualCenter = basePosition + recoilOffset
        let visualScale = self.visualScale
        let scale = presence > 0 ? visualScale : 0.86

        // Instrument ring.
        var ring = NodeRingUniforms(
            centerHalf: SIMD4(visualCenter, radius * 2.55 * scale),
            params: SIMD4(radius, phase, op, hoverState.value),
            gold: rgba(tint.ring, 1),
            hot: rgba(tint.hot, 1),
            signal: rgba(tint.hover, 1)
        )
        draw.nodeRings.append(ring)

        // Camera plane basis, matching camera.quaternion.
        let forward = camera.forward
        let right = forward.cross(.up).normalized
        let up = right.cross(forward).normalized
        let back = -forward
        let camRot = Mat4(columns: (
            SIMD4(right, 0),
            SIMD4(up, 0),
            SIMD4(back, 0),
            SIMD4(0, 0, 0, 1)
        ))
        let satAngle = elapsed * 0.42 + 2 + phase
        let plane = Mat4.translation(visualCenter) * camRot

        // Inner arc and its bright head.
        let arcColor = status == .blocked ? SRGB(hex: "ffd2c4") : SRGB(hex: "fff4d9")
        let innerArcModel = plane
            * Mat4.eulerXYZ(0, 0, satAngle - 0.45)
            * Mat4.scale(Vec3(repeating: radius * 1.12 * scale))
        draw.addMesh(.ringSegmentInner, MeshInstance(
            model: innerArcModel,
            color: rgba(arcColor, 0.92 * min(1, presence) * dim)
        ))
        let headLocal = plane * SIMD4(cos(satAngle) * radius * 1.23 * scale,
                                      sin(satAngle) * radius * 1.23 * scale, 0.012, 1)
        draw.sprites.append(.glow(Vec3(headLocal.x, headLocal.y, headLocal.z),
                                  size: radius * (hovered || selected ? 2.7 : 2.15) * scale,
                                  color: status == .blocked ? SRGB(hex: "ff7d63") : SRGB(hex: "fff8e7"),
                                  opacity: 0.85 * min(1, presence) * dim))

        // Orb + soft core + hot glint.
        let orbSize = radius * 0.72 * scale
        draw.addSphere(center: visualCenter, radius: orbSize,
                       color: rgba(tint.orb, (0.9 + 0.08 * sin(phase)) * presence * dim))
        let pulse = 1 + sin(elapsed * 1.8 + phase) * 0.035
        draw.sprites.append(.glow(visualCenter,
                                  size: radius * 1.7 * pulse * scale,
                                  color: tint.core,
                                  opacity: 0.24 * presence * dim * (status == .blocked ? 0.78 : 1)))
        draw.sprites.append(.glow(visualCenter,
                                  size: radius * 0.52 * pulse * scale,
                                  color: tint.spark,
                                  opacity: 0.1 * presence * dim * (status == .blocked ? 0.68 : 1)))

        // World-space outer orbit + its light band and glow.
        let holder = Mat4.translation(visualCenter) * Mat4.eulerXYZ(orbitTilt, orbitYaw, orbitRoll)
        var previous: Vec3?
        for i in 0...96 {
            let a = Float(i) / 96 * TAU
            let p = holder * SIMD4(cos(a) * radius * 1.98, 0, sin(a) * radius * 1.98, 1)
            let point = Vec3(p.x, p.y, p.z)
            if let previous {
                draw.addLine(previous, point,
                             rgba(tint.orbit, 0.24 * min(1, presence) * tint.dim * dim))
            }
            previous = point
        }
        let arcTint = status == .blocked ? SRGB(hex: "ffb6a3") : SRGB(hex: "fff4d9")
        let arcModel = holder
            * Mat4.eulerXYZ(-.pi / 2, 0, 0)
            * Mat4.scale(Vec3(repeating: radius * 1.86))
        draw.addMesh(.ringSegmentOuter, MeshInstance(
            model: arcModel,
            color: rgba(arcTint, (hovered || selected ? 1 : 0.72) * min(1, presence) * (dimmed ? 0.3 : 1))
        ))
        let glowLocal = holder * SIMD4(cos(0.9) * radius * 1.98, 0,
                                       -sin(0.9) * radius * 1.98, 1)
        draw.sprites.append(.glow(Vec3(glowLocal.x, glowLocal.y, glowLocal.z),
                                  size: radius * 1.95,
                                  color: status == .blocked ? tint.hot : Palette.signalIce,
                                  opacity: (hovered || selected ? 0.95 : 0.58) * min(1, presence) * (dimmed ? 0.3 : 1)))

        // Hit flash.
        if flashAge < 1 {
            let t = min(1, flashAge / 0.34)
            draw.sprites.append(.glow(visualCenter,
                                      size: radius * (2.7 + t * 4.2),
                                      color: tint.flash,
                                      opacity: pow(1 - t, 2.2) * 0.85 * min(1, presence)))
        }
    }
}
