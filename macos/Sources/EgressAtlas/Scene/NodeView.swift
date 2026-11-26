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

/// A destination is a real orb with the camera-facing instrument ring, two
/// orbiters, a world orbit line and a short-lived flash. The recoil offset
/// moves the whole assembly, not the anchor, so wires and hit planes stay
/// fixed.
final class NodeView {
    let spec: NodeSpec
    let id: String
    let index: Int
    let radius: Float
    unowned var destinationRef: Destination!
    var basePosition: Vec3

    var presence: Float = 1
    /// Host bodies shrink harder than DNS destinations on retirement. DNS keeps
    /// the default 1 so its existing studies are untouched.
    var presenceScale: Float = 1
    var hovered = false
    var selected = false
    var dimmed = false
    var labelWanted = true
    var phase: Float
    var destroyed = false
    var labelStatOverride: String?

    var status: DNSStatus = .allowed
    var flashAge: Float = 99
    var recoilActive = false
    var recoilDir = Vec3(0, 0, -1)
    /// Displacement and velocity of the visible assembly. The anchor stays
    /// fixed; only the orb, rings and orbiters move as one body.
    private var recoilPosition = Vec3.zero
    private var recoilVelocity = Vec3.zero
    private static let recoilStiffness: Float = 140
    /// Critical damping for the stiffness above (`2 * sqrt(k)`), so the hit
    /// returns to rest without a springy second bounce.
    private static let recoilDamping: Float = 23.7
    /// Impulse speed in radii per second. At the critical damping above this
    /// peaks just under half a radius of travel before settling.
    private static let recoilImpulse: Float = 24

    private var orbitTilt: Float
    private var orbitRoll: Float
    private var orbitYaw: Float = 0
    private var lastFlashScale: Float = 0
    private var hoverState = HoverEase()
    /// Host layout changes steer to a target instead of snapping. DNS calls
    /// `setBasePosition` without `animated`, so its layout remains deterministic
    /// and frame-identical.
    private var positionTarget: Vec3?
    var isMoving: Bool { positionTarget != nil }
    var debugTargetPosition: Vec3? { positionTarget }

    private var tint: NodeTint.Tint {
        if spec.tone == "hostLocal" { return NodeTint.hostLocal }
        if spec.tone == "hostDomain" { return NodeTint.hostDomain }
        if spec.tone == "host" { return NodeTint.host }
        return status == .blocked ? NodeTint.blocked : NodeTint.allowed
    }

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

    func setBasePosition(_ position: Vec3, animated: Bool = false) {
        if animated {
            positionTarget = position
        } else {
            positionTarget = nil
            basePosition = position
            destinationRef?.position = position
        }
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
        recoilActive ? recoilPosition : .zero
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
            // `direction` is the inbound arrival tangent (source -> node).
            // The blast impulse carries the orb away from the packet's origin,
            // along the packet's travel direction. Add the impulse to the
            // current velocity so rapid hits stack instead of snapping the
            // assembly back to its anchor between impacts.
            recoilDir = direction.normalized
            if !recoilDir.x.isFinite || !recoilDir.y.isFinite || !recoilDir.z.isFinite {
                recoilDir = Vec3(0, 0, -1)
            }
            recoilVelocity += recoilDir * (radius * Self.recoilImpulse)
            let maxSpeed = radius * 34
            if recoilVelocity.length > maxSpeed {
                recoilVelocity = recoilVelocity.withLength(maxSpeed)
            }
        } else {
            stopRecoil()
        }
    }

    func stopRecoil() {
        recoilActive = false
        recoilPosition = .zero
        recoilVelocity = .zero
    }

    func canPick() -> Bool { !destroyed && presence > 0.25 }

    func update(dt: Float, elapsed: Float) {
        updatePosition(dt)
        let hoverTarget: Float = (hovered || selected) ? 1 : 0
        hoverState.value += (hoverTarget - hoverState.value) * min(1, dt * 10)
        if flashAge < 1 {
            flashAge += dt
        }
        if recoilActive {
            let step = min(dt, 1.0 / 20.0)
            let accel = recoilPosition * -Self.recoilStiffness
                - recoilVelocity * Self.recoilDamping
            recoilVelocity += accel * step
            recoilPosition += recoilVelocity * step
            if recoilPosition.length < radius * 0.002,
               recoilVelocity.length < radius * 0.02 {
                stopRecoil()
            }
        }
        orbitYaw += dt * 0.22
        _ = elapsed
    }

    /// Critically damped-looking exponential approach. Host layout changes
    /// retarget the orb; it travels there over roughly a second instead of
    /// blinking to its new slot. Wires read `basePosition` per frame while
    /// this runs, so they travel with it.
    private func updatePosition(_ dt: Float) {
        guard let target = positionTarget else { return }
        let k = 1 - exp(-min(dt, 0.1) * 6.5)
        basePosition += (target - basePosition) * k
        if basePosition.distanceSquared(to: target) < 0.000001 {
            basePosition = target
            positionTarget = nil
        }
        destinationRef?.position = basePosition
    }

    private struct HoverEase { var value: Float = 0 }

    /// Append the destination's visual primitives. `camera` gives the billboard
    /// orientation and the camera-facing inner arc's plane.
    func appendDraw(_ draw: DrawList, elapsed: Float, camera: Camera,
                    detail: Float = 1, depthFocus: Bool = true) {
        guard presence > 0.004 else { return }
        let tint = self.tint
        let dim = dimFactor
        let op = presence * tint.dim * dim
        let visualCenter = basePosition + recoilOffset
        let visualScale = self.visualScale * presenceScale
        let scale = presence > 0 ? visualScale : 0.86
        // Continuous LOD tiers: bokeh fades out as the body, ring, arc and
        // world orbit fade in. No binary low/high model swap.
        // Per-node clarity. A small stagger makes neighbouring bodies resolve
        // at slightly different times; depth defocus keeps interior orbs soft
        // until they are near the focal plane.
        let stagger = Float(index % 7) / 7 * 0.10
        let localDetail = clamp01((detail - stagger) / max(0.001, 1 - stagger))
        // HOST still uses the local soft-depth tier; DNS passes depthFocus:
        // false and relies entirely on the shared hemisphere dim pass.
        let focusDepth = camera.viewDepth(of: .zero)
        let depthDelta = camera.viewDepth(of: visualCenter) - focusDepth
        let depthDefocus = depthFocus && depthDelta > 0
            ? clamp01(depthDelta * 0.16) : 0
        let blurAlpha = max(1 - smoothstep(0.45, 0.92, localDetail), depthDefocus * 0.85)
        // Keep a dim but legible structure in the defocused half: the orbit
        // lights and ring never disappear, they just lose most of their
        // intensity and spread.
        let sharpness = detail >= 0.5 ? max(0.12, 1 - depthDefocus * 0.96) : 1
        let focusLight = detail >= 0.5 ? max(0.18, 1 - depthDefocus * 1.08) : 1
        // The broad atmospheric glow is the hazy part; let it fall almost
        // entirely away while the thin ring stays dim but present.
        let glowLight = detail >= 0.5 ? max(0.025, 1 - depthDefocus * 1.15) : 1
        let glowScale = 0.25 + 0.75 * glowLight
        let orbAlpha = smoothstep(0.30, 0.75, localDetail) * sharpness
        let ringAlpha = smoothstep(0.40, 0.72, localDetail) * focusLight
        let arcAlpha = smoothstep(0.56, 0.84, localDetail) * focusLight
        let orbitAlpha = smoothstep(0.64, 0.90, localDetail) * focusLight

        // Defocused tier. Instead of one generic cloud, each real node keeps
        // its own position and colour as a small cluster of bokeh samples.
        // The cluster tightens continuously as the node comes into focus.
        if blurAlpha > 0.01 {
            let backgroundDim: Float = detail < 0.5 ? 0.18 : 1
            let exposure: Float = (spec.tone.hasPrefix("host") ? 0.85 : 0.5) * backgroundDim
            // A single soft disc, not a ring of petals. The disc stays close
            // to the real body radius so a background node can never look
            // larger than its foreground version.
            // A real point only. Any additive glow disc at this depth becomes
            // a huge bloom ring that reads larger than the foreground orb.
            draw.points.append(PointVertex(visualCenter,
                                           rgba(tint.orb, 0.18 * blurAlpha * presence * dim),
                                           size: 1.2))
        }

        // Instrument ring (active globe only; the background keeps the orb).
        if ringAlpha > 0.01 {
            var ring = NodeRingUniforms(
                centerHalf: SIMD4(visualCenter, radius * 2.55 * scale),
                params: SIMD4(radius, phase, op * ringAlpha, hoverState.value),
                gold: rgba(tint.ring, 1),
                hot: rgba(tint.hot, 1),
                signal: rgba(tint.hover, 1)
            )
            draw.nodeRings.append(ring)
        }

        // Camera plane basis, matching camera.quaternion.
        let forward = camera.forward
        let right = forward.cross(camera.up).normalized
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
        if arcAlpha > 0.01 {
            let arcColor = status == .blocked ? SRGB(hex: "ffd2c4") : SRGB(hex: "fff4d9")
            let innerArcModel = plane
                * Mat4.eulerXYZ(0, 0, satAngle - 0.45)
                * Mat4.scale(Vec3(repeating: radius * 1.12 * scale))
            draw.addMesh(.ringSegmentInner, MeshInstance(
                model: innerArcModel,
                color: rgba(arcColor, 0.92 * arcAlpha * min(1, presence) * dim)
            ))
            let headLocal = plane * SIMD4(cos(satAngle) * radius * 1.23 * scale,
                                          sin(satAngle) * radius * 1.23 * scale, 0.012, 1)
            draw.sprites.append(.glow(Vec3(headLocal.x, headLocal.y, headLocal.z),
                                      size: radius * (hovered || selected ? 2.7 : 2.15) * scale,
                                      color: status == .blocked ? SRGB(hex: "ff7d63") : SRGB(hex: "fff8e7"),
                                      opacity: 0.85 * arcAlpha * min(1, presence) * dim))
        }

        // Orb + soft core + hot glint. The host instrument is deliberately
        // quieter: its many small bodies share one cool light, and additive
        // bloom at full DNS intensity turns the constellation white.
        let hostTone = spec.tone.hasPrefix("host")
        if orbAlpha > 0.01 {
            let orbSize = radius * 0.72 * scale
            draw.addSphere(center: visualCenter, radius: orbSize,
                           color: rgba(tint.orb, (0.9 + 0.08 * sin(phase)) * presence * dim
                                       * (hostTone ? 0.72 : 1) * orbAlpha))
            let pulse = 1 + sin(elapsed * 1.8 + phase) * 0.035
            draw.sprites.append(.glow(visualCenter,
                                      size: radius * 1.7 * pulse * scale * glowScale,
                                      color: tint.core,
                                      opacity: 0.24 * orbAlpha * glowLight * presence * dim
                                        * (hostTone ? 0.55 : 1)
                                        * (status == .blocked ? 0.78 : 1)))
            draw.sprites.append(.glow(visualCenter,
                                      size: radius * 0.52 * pulse * scale * glowScale,
                                      color: tint.spark,
                                      opacity: 0.1 * orbAlpha * glowLight * presence * dim
                                        * (status == .blocked ? 0.68 : 1)))
        }

        // World-space outer orbit + its light band and glow.
        if orbitAlpha > 0.01 {
        let holder = Mat4.translation(visualCenter) * Mat4.eulerXYZ(orbitTilt, orbitYaw, orbitRoll)
        var previous: Vec3?
        for i in 0...96 {
            let a = Float(i) / 96 * TAU
            let p = holder * SIMD4(cos(a) * radius * 1.98, 0, sin(a) * radius * 1.98, 1)
            let point = Vec3(p.x, p.y, p.z)
            if let previous {
                draw.addLine(previous, point,
                             rgba(tint.orbit, 0.24 * orbitAlpha * min(1, presence) * tint.dim * dim))
            }
            previous = point
        }
        let arcTint = status == .blocked ? SRGB(hex: "ffb6a3") : SRGB(hex: "fff4d9")
        let arcModel = holder
            * Mat4.eulerXYZ(-.pi / 2, 0, 0)
            * Mat4.scale(Vec3(repeating: radius * 1.86))
        draw.addMesh(.ringSegmentOuter, MeshInstance(
            model: arcModel,
            color: rgba(arcTint, orbitAlpha * (hovered || selected ? 1 : 0.72) * min(1, presence) * (dimmed ? 0.3 : 1))
        ))
        let glowLocal = holder * SIMD4(cos(0.9) * radius * 1.98, 0,
                                       -sin(0.9) * radius * 1.98, 1)
        draw.sprites.append(.glow(Vec3(glowLocal.x, glowLocal.y, glowLocal.z),
                                  size: radius * 1.95,
                                  color: status == .blocked ? tint.hot : Palette.signalIce,
                                  opacity: orbitAlpha * (hovered || selected ? 0.95 : 0.58) * min(1, presence) * (dimmed ? 0.3 : 1)))
        }

        // Local destinations carry a quieter, continuous heartbeat so a
        // loopback body reads as "this Mac" even between transfers.
        if spec.tone == "hostLocal", orbAlpha > 0.01 {
            let beat = 0.5 + 0.5 * sin(elapsed * 2.1 + phase)
            draw.sprites.append(.glow(visualCenter,
                                      size: radius * (2.4 + beat * 0.65) * scale * glowScale,
                                      color: Palette.hostMint,
                                      opacity: 0.12 * orbAlpha * presence * dim * (0.55 + beat * 0.45)))
        }

        // Hit flash.
        if orbAlpha > 0.05, flashAge < 1 {
            let t = min(1, flashAge / 0.34)
            draw.sprites.append(.glow(visualCenter,
                                      size: radius * (2.7 + t * 4.2),
                                      color: tint.flash,
                                      opacity: pow(1 - t, 2.2) * 0.85 * orbAlpha * min(1, presence)))
        }
    }
}
