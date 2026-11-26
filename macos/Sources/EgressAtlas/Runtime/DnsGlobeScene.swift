import Foundation
import AppKit
import simd

/// The DNS globe's scene graph and per-frame geometry.
///
/// `AtlasRuntime` owns one instance and keeps the shared state around it:
/// camera, source, replay, selection/filter/aliases, host/deck composition and
/// chrome. The scene owns the DNS graph, events, effects, presence windows,
/// labels, picking and the per-frame draw list, and borrows the runtime for
/// those shared inputs.
///
/// The runtime → scene reference is strong and the scene → runtime reference is
/// unowned, so ownership stays acyclic.
final class DnsGlobeScene {
    unowned let runtime: AtlasRuntime

    // ── scene graph ──────────────────────────────────────────────────────

    let stage = GlobeStage()
    var nodes: [NodeView] = []
    var devices: [DeviceView] = []
    var wires: [WireView] = []
    var nodeByDest: [String: NodeView] = [:]
    var deviceById: [String: DeviceView] = [:]
    var wireByKey: [String: WireView] = [:]
    var wireByEdge: [String: WireView] = [:]
    var edgeByKey: [String: Edge] = [:]
    let effects = EffectHost()
    var signals: [Signal] = []
    var deviceAppearanceLinks: [DeviceAppearanceLink] = []
    var signalCounts: [String: Int] = [:]
    /// Cumulative local traffic by device, both directions. This sparse index
    /// avoids rebuilding a sorted "id::id" key for every visible device pair
    /// on every frame and scanning the whole pair grid just to find the few
    /// pairs with activity. The per-frame layout loop is proportional to
    /// active pairs, not population².
    var localWeights: [String: [String: Float]] = [:]
    /// Stable network order for the sparse pull index. Summing the few active
    /// peers in `network.devices` order keeps the floating-point layout
    /// reproducible across launches (dictionary iteration order is not).
    var deviceRank: [String: Int] = [:]
    var localTraces: [LocalTrace] = []
    var ringTraces: [RingTrace] = []
    var pathHalo: PathHalo?
    var haloKey: String?
    var trauma: Float = 0

    // ── per-frame state ──────────────────────────────────────────────────

    var globeRadius: Float = 6
    var layoutTick = 0
    var dot = DrawList()
    var rng = RNG(20261116)
    var stageScale: Float = 1
    var wireClock: Float = 0
    var haloClock: Float = 0
    var hitCounts = (impact: 0, birth: 0, death: 0)
    var previewIndex = (impact: 0, birth: 0, death: 0)
    var lastImpact: ImpactRecord?
    var hitGeometryReplayAt: Float?
    var eventLabels: [String: Double] = [:]

    // ── label caches / timing ─────────────────────────────────────────────

    var labelSizeCache: [String: CGSize] = [:]
    var labelTimingSum: Double = 0
    var labelTimingMax: Double = 0
    var labelTimingCount = 0

    init(runtime: AtlasRuntime) {
        self.runtime = runtime
    }

    /// Clear the graph and the per-source scene state. Camera, RNG, globe
    /// radius and post state persist across a source switch.
    func reset() {
        nodes.removeAll()
        devices.removeAll()
        wires.removeAll()
        nodeByDest.removeAll()
        deviceById.removeAll()
        wireByKey.removeAll()
        wireByEdge.removeAll()
        edgeByKey.removeAll()
        effects.clear()
        signals.removeAll()
        deviceAppearanceLinks.removeAll()
        signalCounts.removeAll()
        localWeights.removeAll()
        deviceRank.removeAll()
        localTraces.removeAll()
        ringTraces.removeAll()
        pathHalo = nil
        haloKey = nil
        eventLabels.removeAll()
        hitCounts = (impact: 0, birth: 0, death: 0)
        previewIndex = (impact: 0, birth: 0, death: 0)
        lastImpact = nil
    }

    // ── construction ─────────────────────────────────────────────────────

    func buildScene() {
        for (index, destination) in runtime.network.destinations.enumerated() {
            let spec = NodeSpec(
                id: destination.id,
                key: destination.key,
                domain: destination.domain,
                meta: destination.status.rawValue,
                latency: Format.count(destination.liveQueries),
                status: destination.status,
                position: destination.position,
                tone: destination.tone
            )
            let node = NodeView(spec: spec, radius: destination.visualRadius, index: index, rng: rng)
            node.destinationRef = destination
            node.setPresence(0)
            nodes.append(node)
            nodeByDest[destination.id] = node
        }
        for device in runtime.network.devices {
            let position = device.surface + device.normal * 0.015
            let view = DeviceView(spec: DeviceSpecView(id: device.id, name: device.name,
                                                       kind: device.kind, ip: device.ip,
                                                       thisMac: device.thisMac),
                                  position: position, normal: device.normal, rng: rng)
            view.deviceRef = device
            devices.append(view)
            deviceById[device.id] = view
        }
        for (index, edge) in runtime.network.edges.enumerated() {
            guard let device = deviceById[edge.deviceId], let node = nodeByDest[edge.destinationId] else { continue }
            let wire = WireView(offset: 0.11 + Float(index) * 0.173,
                                tone: edge.destination.status)
            wire.deviceView = device
            wire.nodeView = node
            wire.edgeId = edge.id
            wire.setGlobePath(from: device.position, to: node.basePosition,
                              normal: device.normal, globeRadius: globeRadius)
            wires.append(wire)
            wireByKey["\(edge.deviceId)::\(edge.destinationId)"] = wire
            wireByEdge[edge.id] = wire
            edgeByKey[edge.id] = edge
        }
        rebuildLocalWeights()
        for view in devices {
            view.update(dt: 0, elapsed: 0, camera: runtime.camera)
        }
        for node in nodes {
            node.update(dt: 0, elapsed: 0)
        }
        stageScale = globeRadius / 6
    }

    /// Seed the sparse pull index from the graph's cumulative activity (a live
    /// snapshot can arrive with local traffic already recorded). Keys use the
    /// same sorted "a::b" form the source writes, so both directions share one
    /// weight.
    func rebuildLocalWeights() {
        localWeights.removeAll(keepingCapacity: true)
        deviceRank = Dictionary(uniqueKeysWithValues: runtime.network.devices.enumerated().map {
            ($0.element.id, $0.offset)
        })
        for (key, count) in runtime.network.localActivity {
            let parts = key.components(separatedBy: "::")
            guard parts.count == 2 else { continue }
            let weight = Float(count)
            localWeights[parts[0], default: [:]][parts[1], default: 0] += weight
            localWeights[parts[1], default: [:]][parts[0], default: 0] += weight
        }
    }

    // ── per-frame updates ────────────────────────────────────────────────

    func updateDevices(_ dt: Float) {
        for view in devices {
            view.update(dt: dt, elapsed: runtime.elapsed, camera: runtime.camera)
        }
    }

    func updateNodes(_ dt: Float) {
        for node in nodes {
            node.update(dt: dt, elapsed: runtime.elapsed)
        }
    }

    func updateWires(_ dt: Float) {
        let cameraDir = runtime.camera.position.normalized
        for wire in wires {
            let facing = clamp(wire.deviceView.normal.dot(cameraDir) * 1.4 + 0.15, 0.06, 1)
            wire.setFacing(facing)
        }
        wireClock += dt
        if wireClock >= 0.06 {
            wireClock = 0
            updateWireGeometry()
        }
    }

    func updateWireGeometry() {
        for wire in wires {
            wire.setGlobePath(from: wire.deviceView.position,
                              to: wire.nodeView.basePosition,
                              normal: wire.deviceView.normal,
                              globeRadius: globeRadius)
        }
    }

    // ── layout (AtlasGlobe._updateLayout) ────────────────────────────────

    private enum OrbSpacing {
        /// Nominal centre-to-centre clearances. These are only achievable while
        /// the population is small; inside the capped globe they shrink.
        static let device: Float = 1.25
        static let destinationBase: Float = 1.0
        static let shellInner: Float = 0.24
        static let shellOuter: Float = 0.9
        static let volumePacking: Float = 0.72
        static let surfacePacking: Float = 0.8
        static let minimumRadius: Float = 6
        /// The live cap is 7; the extra 35% is the largest globe we draw.
        /// Beyond it, orbs overlap instead of growing the field.
        static let maximumRadius: Float = 7 * 1.35
    }

    func visibleDevicesCount() -> Int {
        runtime.network.devices.reduce(0) { $0 + ($1.windowVisible ? 1 : 0) }
    }

    func visibleDestinationsCount() -> Int {
        runtime.network.destinations.reduce(0) { $0 + ($1.windowVisible ? 1 : 0) }
    }

    /// The globe grows gently from 6 to the 35%-larger maximum as the visible
    /// population rises, then stops. It no longer expands to honour a fixed
    /// clearance; the layout spacing shrinks inside the capped globe instead.
    func targetGlobeRadius() -> Float {
        let count = visibleDevicesCount() + visibleDestinationsCount()
        let t = smoothstep(8, 320, Float(count))
        return OrbSpacing.minimumRadius
            + (OrbSpacing.maximumRadius - OrbSpacing.minimumRadius) * t
    }

    /// Centre-to-centre spacing that the current globe can actually support.
    /// At low counts this is the authored clearance; as the population grows
    /// the value falls so the capped globe does not jitter against an
    /// impossible constraint.
    func effectiveDeviceSpacing(radius: Float, count: Int) -> Float {
        guard count > 0 else { return OrbSpacing.device }
        let supported = 4 * radius * (OrbSpacing.surfacePacking / Float(count)).squareRoot()
        return max(0.02, min(OrbSpacing.device, supported))
    }

    func effectiveDestinationSpacing(radius: Float, count: Int,
                                     averageVisualRadius: Float) -> Float {
        let nominal = OrbSpacing.destinationBase + averageVisualRadius * 2
        guard count > 0 else { return nominal }
        let shellFraction = OrbSpacing.shellOuter * OrbSpacing.shellOuter * OrbSpacing.shellOuter
            - OrbSpacing.shellInner * OrbSpacing.shellInner * OrbSpacing.shellInner
        let available = shellFraction * (4.0 / 3.0) * Float.pi * radius * radius * radius
            * OrbSpacing.volumePacking
        let perOrb = available / Float(count)
        let supported = 2 * Float(cbrt(Double(3 * perOrb / (4 * Float.pi))))
        return max(0.02, min(nominal, supported))
    }

    func updateLayout(realDt: Float) {
        let dt = min(0.1, max(0, realDt))
        let target = targetGlobeRadius()
        if abs(target - runtime.lastFramingTarget) > 0.35 {
            runtime.lastFramingTarget = target
            AtlasDiagnostics.log("globe target=\(String(format: "%.2f", target)) devices=\(visibleDevicesCount()) destinations=\(visibleDestinationsCount())")
            if !runtime.userZoomed, runtime.selection == nil, runtime.cameraFlight == nil {
                runtime.applyFraming()
            }
        }
        globeRadius += (target - globeRadius) * (1 - exp(-dt * 1.35))
        stageScale = globeRadius / 6
        let R = globeRadius

        let devices = runtime.network.devices
        let visibleDevices = devices.filter(\.windowVisible)
        let destinations = runtime.network.destinations
        let visible = destinations.filter(\.windowVisible)

        let averageDestinationRadius = visible.isEmpty ? 0
            : visible.reduce(0) { $0 + $1.visualRadius } / Float(visible.count)
        let deviceSpacing = effectiveDeviceSpacing(radius: R, count: visibleDevices.count)
        let destinationSpacing = effectiveDestinationSpacing(
            radius: R, count: visible.count, averageVisualRadius: averageDestinationRadius)

        layoutTick &+= 1
        let pairBudget = visibleDevices.count * visibleDevices.count
            + visible.count * visible.count
        let relaxationInterval = pairBudget > 1_000_000 ? 8 : (pairBudget > 250_000 ? 4 : 1)
        let relaxPairs = layoutTick % relaxationInterval == 0

        let move = 1 - exp(-dt * 0.22)
        for device in visibleDevices {
            var targetDir = device.homeNormal * 2.0
            // Only pairs that have exchanged local traffic pull on each other;
            // the weight is symmetric because handleLocal indexes both
            // directions. Summing the sparse index avoids building a key per
            // pair per frame.
            if let peers = localWeights[device.id] {
                let ordered = peers.sorted {
                    (deviceRank[$0.key] ?? Int.max) < (deviceRank[$1.key] ?? Int.max)
                }
                for (peerId, count) in ordered where peerId != device.id {
                    guard let peer = deviceById[peerId]?.deviceRef,
                          peer.windowVisible else { continue }
                    let strength = min(5, sqrt(count)) * 0.42
                    targetDir += peer.normal * strength
                }
            }
            if targetDir.lengthSq > 0.0001 {
                device.normal = (device.normal + (targetDir.normalized - device.normal) * move).normalized
            }
        }
        if relaxPairs {
            for _ in 0..<2 {
                for i in 0..<visibleDevices.count {
                    for j in (i + 1)..<visibleDevices.count {
                        let a = visibleDevices[i], b = visibleDevices[j]
                        let distance = a.normal.distance(to: b.normal) * R
                        if distance >= deviceSpacing { continue }
                        var delta = a.normal - b.normal
                        if delta.lengthSq < 1e-6 { delta = Vec3(1, 0, 0) }
                        delta = delta.normalized * (((deviceSpacing - distance) / R) * 0.5)
                        a.normal = (a.normal + delta).normalized
                        b.normal = (b.normal - delta).normalized
                    }
                }
            }
        }

        let destMove = 1 - exp(-dt * 0.2)
        let radialMove = 1 - exp(-dt * 0.3)
        for destination in visible {
            var pull = Vec3.zero
            var total: Float = 0
            var maxWeight: Float = 0
            for edge in destination.edges where edge.device.windowVisible {
                let weight = 0.2 + Float(edge.baseQueries) * 0.003 + edge.activity * 2.2
                pull += edge.device.normal * weight
                total += weight
                maxWeight = max(maxWeight, weight)
            }
            if total > 0.0001 {
                var targetDirection = pull.normalized
                targetDirection = (targetDirection + (destination.homeDirection - targetDirection) * 0.3).normalized
                destination.direction = (destination.direction
                    + (targetDirection - destination.direction) * destMove).normalized
                let dominance = max(0.2, maxWeight / total)
                let clearance = destination.visualRadius + 0.55
                let maxFraction = max(0.36, min(OrbSpacing.shellOuter, 1 - clearance / R))
                let targetFraction = max(0.34, min(maxFraction, 0.42 + dominance * 0.4))
                destination.radialFraction += (targetFraction - destination.radialFraction) * radialMove
            }
            destination.radialFraction = max(OrbSpacing.shellInner, min(OrbSpacing.shellOuter, destination.radialFraction))
        }

        if relaxPairs {
            for _ in 0..<3 {
                for i in 0..<visible.count {
                    let a = visible[i]
                    for j in (i + 1)..<visible.count {
                        let b = visible[j]
                        var pa = a.direction * (a.radialFraction * R)
                        var pb = b.direction * (b.radialFraction * R)
                        let minDist = min(a.visualRadius + b.visualRadius + OrbSpacing.destinationBase,
                                          destinationSpacing)
                        var delta = pa - pb
                        let distance = max(0.0001, delta.length)
                        if distance >= minDist { continue }
                        delta = delta.normalized * ((minDist - distance) * 0.5)
                        pa += delta
                        pb -= delta
                        let maxA = max(0.34, min(OrbSpacing.shellOuter, 1 - (a.visualRadius + 0.55) / R))
                        let maxB = max(0.34, min(OrbSpacing.shellOuter, 1 - (b.visualRadius + 0.55) / R))
                        a.radialFraction = max(0.34, min(maxA, pa.length / R))
                        b.radialFraction = max(0.34, min(maxB, pb.length / R))
                        a.direction = pa.normalized
                        b.direction = pb.normalized
                    }
                }
            }
        }

        for device in devices {
            device.surface = device.normal * R
            deviceById[device.id]?.setSurfacePosition(device.surface, device.normal)
        }
        for destination in destinations {
            let maxFraction = max(0.34, min(OrbSpacing.shellOuter, 1 - (destination.visualRadius + 0.55) / R))
            destination.radialFraction = min(destination.radialFraction, maxFraction)
            destination.radius = destination.radialFraction * R
            destination.position = destination.direction * destination.radius
            nodeByDest[destination.id]?.setBasePosition(destination.position)
        }

        runtime.updateCameraLimits()

        haloClock += realDt
        if haloClock >= 0.55 {
            haloClock = 0
            if runtime.selection?.destinationId != nil || runtime.hoveredPath != nil {
                pathHalo = nil
                haloKey = nil
                syncPathHalo()
            }
        }
    }

    // ── draw list ────────────────────────────────────────────────────────

    func buildDrawList(simDt: Float) {
        dot.reset()
        if !runtime.dnsHasVisualData {
            // An empty globe never joins the crossfade, so it stays at the
            // background floor even while a deck is in flight.
            let detail: Float = runtime.activeGlobe == .dns && !runtime.deckActive
                ? 1 : GlobeDeckPresentation.backgroundDetail
            let startLine = dot.stageLines.count
            let startPoint = dot.stagePoints.count
            stage.update(dt: simDt, elapsed: runtime.elapsed, stageScale: stageScale,
                         detail: max(0.51, detail), into: dot)
            let alpha = 0.03 + 0.97 * smoothstep(0.28, 0.82, detail)
            for i in startLine..<dot.stageLines.count { dot.stageLines[i].color.w *= alpha }
            for i in startPoint..<dot.stagePoints.count { dot.stagePoints[i].color.w *= alpha }
            runtime.labels.labels = []
            return
        }
        let dnsDetail = runtime.deckPresentation.dnsGeometryDetail
        // Keep the stage geometry stable and fade it, so the shell does not
        // pop in at a detail threshold while the globe is coming into focus.
        let stageLineStart = dot.stageLines.count
        let stagePointStart = dot.stagePoints.count
        stage.update(dt: simDt, elapsed: runtime.elapsed, stageScale: stageScale,
                     detail: max(0.51, dnsDetail), into: dot)
        let stageAlpha = 0.03 + 0.97 * smoothstep(0.28, 0.82, dnsDetail)
        for i in stageLineStart..<dot.stageLines.count { dot.stageLines[i].color.w *= stageAlpha }
        for i in stagePointStart..<dot.stagePoints.count { dot.stagePoints[i].color.w *= stageAlpha }

        for node in nodes {
            node.appendDraw(dot, elapsed: runtime.elapsed, camera: runtime.camera,
                            detail: dnsDetail, depthFocus: false)
        }
        for (index, device) in devices.enumerated() {
            device.stagger = Float(index % 7) / 7 * 0.10
            device.appendDraw(dot, elapsed: runtime.elapsed, detail: dnsDetail)
        }
        for wire in wires where !wire.hidden {
            wire.appendDraw(dot, elapsed: runtime.elapsed, detail: dnsDetail)
        }
        let dnsLive = runtime.activeGlobe == .dns && !runtime.deckActive
        if dnsLive {
            for signal in signals {
                signal.appendDraw(dot, elapsed: runtime.elapsed)
            }

            let ctx = EffectContext(camera: runtime.camera, node: nil, radius: 0.3, point: .zero,
                                    normal: .up, elapsed: runtime.elapsed, onShake: { [weak self] amount in
                                        self?.trauma = min(1, (self?.trauma ?? 0) + amount * 0.55)
                                    }, rng: rng)
            effects.update(dt: simDt, ctx: ctx, draw: dot)
            appendHitGeometry(dot)
            _ = ctx
        }

        for trace in localTraces {
            let t = min(1, trace.age / trace.duration)
            let alpha = 1 - t
            for vertex in trace.baseTriangles {
                var v = vertex
                v.color.w *= alpha
                dot.rawTriangles.append(v)
            }
        }
        for trace in ringTraces {
            let t = min(1, trace.age / trace.duration)
            let scale = 0.9 + t * 1.3
            let orientation = simd_quatf(from: Vec3(0, 0, 1), to: trace.normal)
            let model = Mat4.compose(position: trace.center, quaternion: orientation,
                                     scale: Vec3(repeating: scale))
            dot.addMesh(.ringFull, MeshInstance(model: model,
                                                color: rgba(Palette.signalIce, trace.baseAlpha * (1 - t))))
        }
        if let halo = pathHalo {
            dot.rawTriangles.append(contentsOf: halo.wide)
            dot.rawTriangles.append(contentsOf: halo.tight)
            let t = (runtime.elapsed * 0.16).truncatingRemainder(dividingBy: 1)
            let p = halo.curve.pointAt(t)
            dot.sprites.append(.glow(p, size: 0.75,
                                     color: halo.blocked ? Palette.coral : Palette.gold,
                                     opacity: 0.55 + sin(runtime.elapsed * 3.2) * 0.18))
        }
        if dnsLive {
            HemisphereFocus.apply(to: dot, camera: runtime.camera)
        }
    }

    /// Port of the lab's optional Hit geometry overlay: the blast plane, its
    /// normal and the impact centre. It is drawn from the same record the
    /// effects use, so the plane can never disagree with the blast. Shield
    /// hits are 360° and deliberately have no planar overlay.
    private func appendHitGeometry(_ draw: DrawList) {
        guard runtime.showHitGeometry,
              let record = lastImpact,
              !record.blocked,
              record.impactId != "containment",
              let node = nodeByDest[record.destinationId],
              !node.destroyed else { return }
        let age = runtime.elapsed - (hitGeometryReplayAt ?? record.at)
        guard age >= 0, age < 1.9 else { return }

        let baseR = max(0.26, node.radius * 1.55)
        let size = baseR * 3.2
        let centre = node.basePosition + node.recoilOffset
        let basis = orthoBasis(record.normal)
        let fade = 1 - max(0, (age - 1.05) / (1.9 - 1.05))
        let pulse = 1 + sin(age * 5.5) * 0.012

        let cross = rgba(Palette.signal, 0.045 * fade)
        draw.addLine(centre - basis.t * (size * pulse), centre + basis.t * (size * pulse), cross)
        draw.addLine(centre - basis.b * (size * pulse), centre + basis.b * (size * pulse), cross)

        draw.addPolyline(ringPoints(center: centre, axisX: basis.t, axisY: basis.b,
                                    radius: size * 0.55 * pulse, segments: 96),
                         color: rgba(Palette.signal, 0.06 * fade))
        draw.addPolyline(ringPoints(center: centre, axisX: basis.t, axisY: basis.b,
                                    radius: size * pulse, segments: 128),
                         color: rgba(Palette.signal, 0.17 * fade))
        draw.addPolyline(ringPoints(center: centre, axisX: basis.t, axisY: basis.b,
                                    radius: node.radius * 1.02, segments: 96),
                         color: rgba(Palette.gold, 0.28 * fade))

        draw.addLine(centre - record.normal * (size * 0.18),
                     centre + record.normal * (size * pulse),
                     rgba(Palette.signalIce, 0.34 * fade))
        draw.sprites.append(.glow(centre + record.normal * (size * 0.98),
                                  size: node.radius * 0.7,
                                  color: Palette.signal,
                                  opacity: 0.55 * fade))
        draw.sprites.append(.glow(centre - record.normal * (node.radius * 0.92),
                                  size: node.radius * 1.15,
                                  color: Palette.gold,
                                  opacity: 0.55 * fade))
    }
    // ── queries / signals / impacts ──────────────────────────────────────

    func selectionAllows(deviceId: String, destinationId: String) -> Bool {
        guard let selection = runtime.selection else { return true }
        switch selection {
        case .device(let id): return deviceId == id
        case .destination(let id): return destinationId == id
        case .path(let d, let dest): return deviceId == d && destinationId == dest
        }
    }

    func handleQuery(_ event: QueryEvent) {
        guard runtime.ready else { return }
        guard runtime.activeGlobe == .dns, !runtime.deckActive else { return }
        if let status = runtime.filter.status, event.status != status { return }
        guard selectionAllows(deviceId: event.deviceId, destinationId: event.destinationId) else { return }
        guard let node = nodeByDest[event.destinationId],
              let wire = wireByKey["\(event.deviceId)::\(event.destinationId)"] else { return }
        let destination = node.destinationRef!
        let wasHidden = !destination.windowVisible
        if node.destroyed && !wasHidden { return }
        if signals.count > 44 { return }

        // An aged-out device is not shown yet. First recompute where it belongs
        // on the shell and let the query draw a wire from that empty position
        // to the destination. The arrival callback then reveals the device with
        // one of its appearance studies.
        let deviceWasHidden = !event.device.windowVisible && !event.device.pendingAppearance
        if deviceWasHidden {
            event.device.pendingAppearance = true
            revealDeviceLocation(event.device, wire: wire, node: node)
        }
        if wasHidden {
            wire.setVisible(true)
            wire.setDim(0.55)
        }
        let key = "\(event.deviceId)::\(event.destinationId)"
        signalCounts[key, default: 0] += 1
        wire.setSignalActive(true)
        let control = wire.controlPoints
        let length = CatmullRom(points: control).length()
        let duration = max(0.38, min(1.25, 0.42 + length * 0.05))
        if deviceWasHidden {
            let link = DeviceAppearanceLink(device: event.device, wire: wire, duration: duration) { [weak self] in
                self?.finishDeviceArrival(event.device, wire: wire)
            }
            deviceAppearanceLinks.append(link)
        }
        let arrival = CatmullRom(points: control, closed: false,
                                 curveType: "centripetal", tension: 0.5)
        let signal = Signal(controlPoints: control, duration: duration,
                            seed: UInt32(truncatingIfNeeded: Int(runtime.elapsed * 1000) ^ control.count)) { [weak self, weak node, weak wire] in
            guard let self, let node, let wire else { return }
            let next = max(0, (self.signalCounts[key] ?? 1) - 1)
            if next == 0 { self.signalCounts.removeValue(forKey: key) }
            else { self.signalCounts[key] = next }
            wire.setSignalActive(next > 0)
            if wasHidden {
                if !destination.windowVisible {
                    destination.windowVisible = true
                    self.birthDestination(destination, style: destination.birthId)
                    self.runtime.refreshUI()
                }
                return
            }
            if node.destroyed { return }
            // Use the curve snapshot the packet actually travelled, exactly as
            // the lab's `snapshot.getTangentAt(1)`. The live wire tangent can
            // drift if the destination moved while the packet was in flight.
            self.registerImpact(node: node, normal: arrival.tangentAt(1), event: event)
        }
        signals.append(signal)
        deviceById[event.deviceId]?.onFire()
    }

    /// Blocked destinations own the red containment/redaction pair; allowed
    /// destinations never receive either study. This mirrors the lab's field
    /// mapping (the red orb answers with the 360° shield and is sealed with a
    /// redaction) and keeps the two tones mutually exclusive even if a source
    /// document ever carries a mismatched style id.
    func impactStyle(for destination: Destination) -> String {
        if destination.status == .blocked { return "containment" }
        if runtime.motionMode == .calm { return "eclipse" }
        let candidate = destination.impactId
        if candidate == "containment" || !Effects.impacts.contains(where: { $0.id == candidate }) {
            return "eclipse"
        }
        return candidate
    }

    func birthStyle(for destination: Destination, override: String? = nil) -> String {
        if destination.status == .blocked { return "redaction" }
        if let override, override != "redaction",
           Effects.births.contains(where: { $0.id == override }) {
            return override
        }
        return destination.birthId == "redaction" ? "spiral" : destination.birthId
    }

    func registerImpact(node: NodeView, normal: Vec3, event: QueryEvent?) {
        let destination = node.destinationRef!
        let blocked = destination.status == .blocked
        let n = normal.normalized
        node.onHit(n, recoil: runtime.recoilEnabled && !blocked)
        hitCounts.impact += 1

        let style = impactStyle(for: destination)
        let meta = Effects.meta(impact: style)
        if runtime.motionMode != .off {
            if effects.countByKind("impact") < 24 {
                let R = max(0.26, node.radius * 1.55)
                var ctx = EffectContext(camera: runtime.camera, node: node, radius: R,
                                        point: node.basePosition, normal: n,
                                        elapsed: runtime.elapsed, onShake: { [weak self] amount in
                                            self?.trauma = min(1, (self?.trauma ?? 0) + amount * 0.55)
                                        }, rng: rng)
                ctx.offset = .zero
                let effect = Effects.impact(style, ctx: ctx)
                effects.add(effect, node: node, origin: node.basePosition,
                            kind: "impact")
            }
            if !blocked && runtime.motionMode == .cinematic {
                trauma = max(trauma, 0.42)
            }
        }
        lastImpact = ImpactRecord(destinationId: destination.id, blocked: blocked,
                                  at: runtime.elapsed, normal: n, point: node.basePosition,
                                  impactId: meta.id, impactName: "\(meta.key) · \(meta.name)")
        hitGeometryReplayAt = nil
        flashDestinationLabel(destination.id, duration: 1.7)
        runtime.inspectorRevision += 1
    }

    func handleLocal(_ event: LocalTrafficEvent) {
        // The layout's pull index mirrors network.localActivity; index it even
        // when the visual flow is skipped (paused/hidden).
        localWeights[event.source.id, default: [:]][event.target.id, default: 0] += 1
        localWeights[event.target.id, default: [:]][event.source.id, default: 0] += 1
        guard let sourceView = deviceById[event.source.id],
              let targetView = deviceById[event.target.id] else { return }
        // A local flow is still a visual claim that both orbs are on stage.
        guard sourceView.deviceRef.windowVisible,
              targetView.deviceRef.windowVisible else { return }
        if runtime.paused { return }
        if signals.count > 52 { return }
        let from = sourceView.position
        let to = targetView.position
        var points: [Vec3] = []
        for i in 0...20 {
            let t = Float(i) / 20
            let radial = from.lerp(to, t).normalized
            let lift = 0.34 + sin(Float.pi * t) * 0.62
            points.append(radial * (globeRadius + lift))
        }
        let curve = CatmullRom(points: points, closed: false, curveType: "centripetal", tension: 0.5)
        let sampled = (0...72).map { curve.pointAt(Float($0) / 72) }
        let tightPositions = GeometryKit.tube(points: sampled, radius: 0.018, tubularSegments: 72, radialSegments: 5)
        let widePositions = GeometryKit.tube(points: sampled, radius: 0.06, tubularSegments: 72, radialSegments: 5)
        let ice = Palette.signalIce
        let tight = tightPositions.map { TriangleVertex(position: SIMD4($0, 1), color: rgba(ice, 0.42)) }
        let wide = widePositions.map { TriangleVertex(position: SIMD4($0, 1), color: rgba(ice, 0.065)) }
        localTraces.append(LocalTrace(baseTriangles: tight + wide, duration: 1.8))
        for view in [sourceView, targetView] {
            ringTraces.append(RingTrace(center: view.position + view.normal * 0.035,
                                        normal: view.normal, duration: 0.9,
                                        baseAlpha: 0.46))
        }
        sourceView.onFire()
        let localCurve = CatmullRom(points: points, closed: false, curveType: "centripetal", tension: 0.5)
        let duration = max(0.62, min(1.25, 0.36 + localCurve.length() * 0.045))
        let signal = Signal(controlPoints: points, duration: duration) { [weak targetView] in
            targetView?.onFire()
        }
        signals.append(signal)
    }

    // ── births / deaths / windows ────────────────────────────────────────

    func setWireVisibility(destinationId: String, visible: Bool) {
        for wire in wires where wire.nodeView.destinationRef?.id == destinationId {
            let deviceVisible = wire.deviceView.deviceRef?.windowVisible ?? true
            let next = visible && deviceVisible
            wire.setVisible(next)
            if next { wire.setDim(1) }
        }
    }

    func setWireVisibility(deviceId: String, visible: Bool) {
        for wire in wires where wire.deviceView.deviceRef?.id == deviceId {
            let destinationVisible = wire.nodeView.destinationRef?.windowVisible ?? true
            let next = visible && destinationVisible
            wire.setVisible(next)
            if next { wire.setDim(1) }
        }
    }

    func pulseDeviceRing(_ view: DeviceView) {
        guard runtime.motionMode != .off, !runtime.reducedMotion else { return }
        ringTraces.append(RingTrace(center: view.position + view.normal * 0.035,
                                    normal: view.normal, duration: 0.9, baseAlpha: 0.46))
    }

    /// Place an aged-out device back on the current shell radius and rebuild
    /// the query edge from that relative location. The wire starts empty and
    /// grows as the pulse travels; the orb itself stays hidden until arrival.
    func revealDeviceLocation(_ device: Device, wire: WireView, node: NodeView) {
        device.surface = device.normal * globeRadius
        guard let view = deviceById[device.id] else { return }
        view.setSurfacePosition(device.surface, device.normal)
        wire.setGlobePath(from: view.position, to: node.basePosition,
                          normal: view.normal, globeRadius: globeRadius)
        wire.reveal = 0
        wire.setVisible(true)
        wire.setDim(0.55)
    }

    func updateDeviceAppearances(_ dt: Float) {
        guard !deviceAppearanceLinks.isEmpty, dt > 0 else { return }
        for index in deviceAppearanceLinks.indices.reversed() {
            var link = deviceAppearanceLinks[index]
            link.t = min(1, link.t + dt / max(0.001, link.duration))
            link.wire.reveal = link.t
            if link.t >= 1 {
                deviceAppearanceLinks.remove(at: index)
                link.wire.reveal = 1
                link.onArrive()
            } else {
                deviceAppearanceLinks[index] = link
            }
        }
    }

    func finishDeviceArrival(_ device: Device, wire: WireView) {
        guard let view = deviceById[device.id] else { return }
        device.pendingAppearance = false
        device.windowVisible = true
        view.setSurfacePosition(device.surface, device.normal)
        let styles = DeviceView.AppearanceStyle.allCases
        let style = styles[Int(rng.next() * Float(styles.count)) % styles.count]
        view.setWindowVisible(true, style: style)
        wire.reveal = 1
        setWireVisibility(deviceId: device.id, visible: true)
        pulseDeviceRing(view)
        runtime.windowStats = runtime.network.windowStats()
        updateLabels(force: true)
        applyVisualState()
    }

    func birthDestination(_ destination: Destination, fromBoot: Bool = false, style: String? = nil,
                          forceStyle: Bool = false) {
        guard let node = nodeByDest[destination.id] else { return }
        let id = forceStyle ? (style ?? destination.birthId) : birthStyle(for: destination, override: style)
        let meta = Effects.meta(birth: id)
        effects.cancel("death:\(destination.id)")
        effects.cancel("birth:\(destination.id)")
        node.destroyed = false
        node.setPresence(0)
        setWireVisibility(destinationId: destination.id, visible: true)
        let R = max(0.26, node.radius * 1.6)
        let ctx = EffectContext(camera: runtime.camera, node: node, radius: R,
                                point: node.basePosition, normal: .up,
                                elapsed: runtime.elapsed, onShake: { [weak self] amount in
                                    self?.trauma = min(1, (self?.trauma ?? 0) + amount * 0.55)
                                }, rng: rng)
        let effect = Effects.birth(meta.id, ctx: ctx, node: node)
        effects.add(effect, node: node, origin: node.basePosition,
                    key: "birth:\(destination.id)", kind: "birth")
        hitCounts.birth += 1
        flashDestinationLabel(destination.id, duration: 2.6)
        applyVisualState()
        _ = fromBoot
    }

    func retireDestination(_ destination: Destination, style: String? = nil, restoreAfter: Float = 0) {
        guard let node = nodeByDest[destination.id], !node.destroyed else { return }
        let meta: EffectMeta
        if let style, Effects.deaths.contains(where: { $0.id == style }) {
            meta = Effects.meta(death: style)
        } else {
            // Natural window expiry is not indexed by destination any more:
            // every orb that leaves the stage rolls one of the remaining
            // disappearance studies (D1–D2), so a busy lifetime change does
            // not replay the same death in the same order.
            meta = Effects.meta(death: randomDeathStyle())
        }
        effects.cancel("birth:\(destination.id)")
        effects.cancel("impact:\(destination.id)")
        node.destroyed = true
        node.stopRecoil()
        node.setPresence(0)
        setWireVisibility(destinationId: destination.id, visible: false)
        let R = max(0.26, node.radius * 1.6)
        let ctx = EffectContext(camera: runtime.camera, node: node, radius: R,
                                point: node.basePosition, normal: .up,
                                elapsed: runtime.elapsed, onShake: { [weak self] amount in
                                    self?.trauma = min(1, (self?.trauma ?? 0) + amount * 0.55)
                                }, rng: rng)
        let effect = Effects.death(meta.id, ctx: ctx, node: node)
        effects.add(effect, node: node, origin: node.basePosition,
                    key: "death:\(destination.id)", kind: "death")
        hitCounts.death += 1
        flashDestinationLabel(destination.id, duration: 2.0)
        if restoreAfter > 0 {
            runtime.after(restoreAfter) { [weak self] in
                self?.restoreDestination(destination, birth: true)
            }
        }
        applyVisualState()
    }

    /// World-clock disappearance roll. The four studies are deliberately
    /// equiprobable and the roll goes through the scene RNG, so a deterministic
    /// snapshot seed still reproduces the same sequence of erasures.
    func randomDeathStyle() -> String {
        let index = Int(rng.next() * Float(Effects.deaths.count)) % Effects.deaths.count
        return Effects.deaths[index].id
    }

    func restoreDestination(_ destination: Destination, birth: Bool = false) {
        guard let node = nodeByDest[destination.id] else { return }
        effects.cancel("death:\(destination.id)")
        effects.cancel("birth:\(destination.id)")
        node.destroyed = false
        node.stopRecoil()
        node.setPresence(1)
        setWireVisibility(destinationId: destination.id, visible: true)
        if birth { birthDestination(destination, style: destination.birthId) }
        applyVisualState()
    }

    @discardableResult
    func applyWindow(animate: Bool, initial: Bool) -> Bool {
        // Replay owns presence while it runs: a body that was outside the live
        // history window is born by its first replayed query and should stay
        // on stage for the rest of the range. Returning to live re-applies the
        // live window immediately.
        if runtime.isReplay { return false }
        let now = Date().timeIntervalSince1970 * 1000
        let windowMS = Double(runtime.windowHours) * 3_600_000
        var changed = false
        var becameVisible: [Destination] = []
        var becameHidden: [Destination] = []
        var becameVisibleDevices: [Device] = []
        var becameHiddenDevices: [Device] = []
        let canAnimate = animate && !runtime.paused

        // Update both endpoint flags before any wire decision: a wire is only
        // present while its device and its destination are inside the window.
        for device in runtime.network.devices {
            if device.pendingAppearance { continue }
            let visible = now - device.lastSeen <= windowMS
            let was = device.windowVisible
            if was != visible { changed = true }
            device.windowVisible = visible
            if !visible {
                if canAnimate {
                    if was { becameHiddenDevices.append(device) }
                } else {
                    deviceById[device.id]?.setWindowVisible(false, animated: false)
                    setWireVisibility(deviceId: device.id, visible: false)
                }
            } else if !initial && !was {
                if canAnimate {
                    becameVisibleDevices.append(device)
                } else {
                    deviceById[device.id]?.setWindowVisible(true, animated: false)
                    setWireVisibility(deviceId: device.id, visible: true)
                }
            }
        }

        for destination in runtime.network.destinations {
            let visible = now - destination.lastSeen <= windowMS
            let was = destination.windowVisible
            if was != visible { changed = true }
            destination.windowVisible = visible
            guard let node = nodeByDest[destination.id] else { continue }
            if !visible {
                if canAnimate {
                    if was { becameHidden.append(destination) }
                } else {
                    node.destroyed = true
                    node.setPresence(0)
                    setWireVisibility(destinationId: destination.id, visible: false)
                }
            } else if !initial && !was {
                if canAnimate {
                    becameVisible.append(destination)
                } else {
                    node.destroyed = false
                    node.setPresence(1)
                    setWireVisibility(destinationId: destination.id, visible: true)
                }
            }
        }
        if let selection = runtime.selection {
            let hiddenDevice = selection.deviceId
                .flatMap { runtime.network.deviceById[$0] }?.windowVisible == false
            let hiddenDestination = selection.destinationId
                .flatMap { runtime.network.destinationById[$0] }?.windowVisible == false
            if hiddenDevice || hiddenDestination { runtime.select(nil) }
        }
        if let hover = runtime.hover {
            let hiddenDevice = hover.deviceId
                .flatMap { runtime.network.deviceById[$0] }?.windowVisible == false
            let hiddenDestination = hover.destinationId
                .flatMap { runtime.network.destinationById[$0] }?.windowVisible == false
            if hiddenDevice || hiddenDestination { runtime.setHovered(nil) }
        }
        if canAnimate {
            for (index, destination) in becameHidden.enumerated() {
                runtime.after(Float(index) * 0.06) { [weak self] in
                    guard let self, !destination.windowVisible else { return }
                    self.retireDestination(destination)
                }
            }
            for (index, destination) in becameVisible.enumerated() {
                runtime.after(Float(index) * 0.09) { [weak self] in
                    guard let self, destination.windowVisible else { return }
                    self.birthDestination(destination, style: destination.birthId)
                }
            }
        }
        for device in becameHiddenDevices {
            deviceById[device.id]?.setWindowVisible(false)
            setWireVisibility(deviceId: device.id, visible: false)
            if let view = deviceById[device.id] { pulseDeviceRing(view) }
        }
        for device in becameVisibleDevices {
            deviceById[device.id]?.setWindowVisible(true)
            setWireVisibility(deviceId: device.id, visible: true)
            if let view = deviceById[device.id] { pulseDeviceRing(view) }
        }
        runtime.network.windowHours = runtime.windowHours
        updateLabels(force: true)
        applyVisualState()
        runtime.refreshUI()
        return changed
    }

    // ── visual state / halo / traces ─────────────────────────────────────

    func relatedForSelection() -> (devices: Set<String>, destinations: Set<String>, edges: Set<String>) {
        var relatedDevices = Set<String>()
        var relatedDestinations = Set<String>()
        var relatedEdges = Set<String>()
        guard let selection = runtime.selection else { return (relatedDevices, relatedDestinations, relatedEdges) }
        switch selection {
        case .device(let id):
            guard let device = runtime.network.deviceById[id] else { break }
            relatedDevices.insert(device.id)
            for edge in device.edges {
                relatedEdges.insert(edge.id)
                relatedDestinations.insert(edge.destinationId)
            }
        case .destination(let id):
            guard let destination = runtime.network.destinationById[id] else { break }
            relatedDestinations.insert(destination.id)
            for edge in destination.edges {
                relatedEdges.insert(edge.id)
                relatedDevices.insert(edge.deviceId)
            }
        case .path(let deviceId, let destinationId):
            relatedEdges.insert("\(deviceId)::\(destinationId)")
            relatedDevices.insert(deviceId)
            relatedDestinations.insert(destinationId)
        }
        return (relatedDevices, relatedDestinations, relatedEdges)
    }

    func applyVisualState() {
        let related = relatedForSelection()
        let hasSelection = runtime.selection != nil
        for node in nodes {
            let destination = node.destinationRef!
            let matchesFilter = runtime.filter == .all || destination.status == runtime.filter.status
            let isRelated = !hasSelection || related.destinations.contains(destination.id)
            node.setDimmed(!matchesFilter || !isRelated)
            switch runtime.selection {
            case .destination(let id): node.setSelected(id == destination.id)
            case .path(_, let id): node.setSelected(id == destination.id)
            default: node.setSelected(false)
            }
        }
        for view in devices {
            let isRelated = !hasSelection || related.devices.contains(view.deviceRef.id)
            view.setDimmed(!isRelated)
            switch runtime.selection {
            case .device(let id): view.setSelected(id == view.deviceRef.id)
            case .path(let id, _): view.setSelected(id == view.deviceRef.id)
            default: view.setSelected(false)
            }
        }
        for wire in wires {
            let edge = wire.nodeView.destinationRef!
            let matchesFilter = runtime.filter == .all || edge.status == runtime.filter.status
            let isRelated = !hasSelection || related.edges.contains(wire.edgeId)
            let isSelected = hasSelection && related.edges.contains(wire.edgeId)
            var dim: Float = 1
            if !matchesFilter { dim = 0.06 }
            else if !isRelated { dim = 0.12 }
            wire.setDim(dim)
            var highlight: Float = isSelected ? 0.75 : 0
            if !isSelected, let hover = runtime.hover, let id = hover.deviceId,
               id == wire.deviceView.deviceRef.id {
                highlight = 0.35
            }
            if let hoveredPath = runtime.hoveredPath,
               hoveredPath.deviceId == wire.deviceView.deviceRef.id,
               hoveredPath.destinationId == wire.nodeView.destinationRef.id {
                highlight = 0.9
            }
            wire.setHighlight(highlight)
        }
        syncPathHalo()
    }

    func syncPathHalo() {
        var edge: Edge?
        if let selection = runtime.selection, case .path(let deviceId, let destinationId) = selection {
            edge = runtime.network.edges.first { $0.deviceId == deviceId && $0.destinationId == destinationId }
        } else if runtime.selection == nil, let hoveredPath = runtime.hoveredPath {
            edge = runtime.network.edges.first {
                $0.deviceId == hoveredPath.deviceId && $0.destinationId == hoveredPath.destinationId
            }
        }
        guard let edge, let wire = wireByEdge[edge.id], let curve = wire.curve,
              let node = nodeByDest[edge.destinationId], !node.destroyed else {
            pathHalo = nil
            haloKey = nil
            return
        }
        if runtime.filter != .all && edge.destination.status != runtime.filter.status {
            pathHalo = nil
            haloKey = nil
            return
        }
        if haloKey == edge.id { return }
        haloKey = edge.id
        let blocked = edge.destination.status == .blocked
        let color = blocked ? Palette.coral : Palette.gold
        let tightColor = blocked ? SRGB(hex: "ffb6a3") : SRGB(hex: "fff1c9")
        let sampled = (0...96).map { curve.pointAt(Float($0) / 96) }
        let wideVerts = GeometryKit.tube(points: sampled, radius: 0.055, tubularSegments: 96, radialSegments: 6)
            .map { TriangleVertex(position: SIMD4($0, 1), color: rgba(color, 0.09)) }
        let tightVerts = GeometryKit.tube(points: sampled, radius: 0.016, tubularSegments: 96, radialSegments: 6)
            .map { TriangleVertex(position: SIMD4($0, 1), color: rgba(tightColor, 0.72)) }
        pathHalo = PathHalo(curve: curve, wide: wideVerts, tight: tightVerts, blocked: blocked)
    }

    func updateHalo(_ dt: Float) {
        _ = dt
    }

    func updateLocalTraces(_ dt: Float) {
        for i in localTraces.indices.reversed() {
            localTraces[i].age += dt
            if localTraces[i].age >= localTraces[i].duration { localTraces.remove(at: i) }
        }
        for i in ringTraces.indices.reversed() {
            ringTraces[i].age += dt
            if ringTraces[i].age >= ringTraces[i].duration { ringTraces.remove(at: i) }
        }
    }

    // ── labels ───────────────────────────────────────────────────────────

    private struct LabelEntry {
        let el: AtlasLabel
        let priority: Int
        let order: Float
    }

    /// Upper bounds for the dense label modes. The demo never reaches them;
    /// the live All field would otherwise measure text for every destination
    /// and try to lay out hundreds of tags in one SwiftUI pass.
    private static let maxLabelCandidates = 64
    private static let maxFieldLabels = 24

    func updateLabels(force: Bool) {
        _ = force
        guard runtime.dnsHasVisualData else {
            runtime.labels.labels = []
            return
        }
        var destSet = Set<String>()
        var deviceSet = Set<String>()
        if runtime.labelMode != .off {
            if let selection = runtime.selection {
                switch selection {
                case .destination(let id): destSet.insert(id)
                case .device(let id): deviceSet.insert(id)
                case .path(let d, let dest): destSet.insert(dest); deviceSet.insert(d)
                }
            }
            if let hover = runtime.hover {
                switch hover {
                case .destination(let id): destSet.insert(id)
                case .device(let id): deviceSet.insert(id)
                case .path(let d, let dest): destSet.insert(dest); deviceSet.insert(d)
                }
            }
            if runtime.labelMode == .events {
                let now = Date().timeIntervalSince1970
                for (id, until) in eventLabels where until > now { destSet.insert(id) }
            }
            if runtime.labelMode == .all {
                // Do not construct a label (or measure its text) for every orb
                // in a live All graph. Resolve the busiest visible candidates
                // only; the overlay then keeps the highest-priority visible
                // set (24 normally, 4 above 200 destinations). On the demo
                // this changes nothing (14 destinations).
                let candidates = nodes.compactMap { node -> (NodeView, Destination)? in
                    guard let destination = node.destinationRef, destination.windowVisible else { return nil }
                    guard runtime.filter == .all || destination.status == runtime.filter.status else { return nil }
                    return (node, destination)
                }.sorted { $0.1.liveQueries > $1.1.liveQueries }
                for (_, destination) in candidates.prefix(Self.maxLabelCandidates) {
                    destSet.insert(destination.id)
                }
                for view in devices.prefix(Self.maxLabelCandidates) {
                    deviceSet.insert(view.deviceRef.id)
                }
            }
        }
        for node in nodes {
            node.setLabelVisible(destSet.contains(node.destinationRef.id))
        }
        for view in devices {
            view.setLabelVisible(deviceSet.contains(view.deviceRef.id))
        }
        resolveLabels()
    }

    func resolveLabels() {
        let timingStart = AtlasDiagnostics.enabled ? CACurrentMediaTime() : 0
        var entries: [LabelEntry] = []
        for node in nodes {
            let destination = node.destinationRef!
            let visible = node.labelWanted && node.presence > 0.12 && !node.dimmed
            if visible {
                let screen = runtime.camera.project(node.labelPosition, viewport: SIMD2(Float(runtime.frameViewSize.width), Float(runtime.frameViewSize.height)))
                let text = node.labelStatOverride ?? (destination.status == .blocked
                    ? "\(Format.count(destination.liveBlocked)) blocked"
                    : "\(Format.count(destination.liveQueries)) q")
                let entry = destinationLabel(node: node, destination: destination,
                                             screen: screen, latency: text)
                var priority = 10
                if node.labelWanted { priority = 40 + (destination.status == .blocked ? 6 : 0) }
                if let selection = runtime.selection, selection.destinationId == destination.id { priority = 120 }
                if let hover = runtime.hover, hover.destinationId == destination.id { priority = 130 }
                entries.append(LabelEntry(el: entry, priority: priority, order: Float(destination.liveQueries)))
            }
        }
        for view in devices {
            let device = view.deviceRef!
            if view.labelVisible {
                let screen = runtime.camera.project(view.labelPosition, viewport: SIMD2(Float(runtime.frameViewSize.width), Float(runtime.frameViewSize.height)))
                let entry = deviceLabel(view: view, device: device, screen: screen)
                var priority = 5
                if view.labelWanted { priority = 35 }
                if device.thisMac { priority = 94 }
                if let selection = runtime.selection, selection.deviceId == device.id { priority = 118 }
                if let hover = runtime.hover, hover.deviceId == device.id { priority = 128 }
                entries.append(LabelEntry(el: entry, priority: priority, order: runtime.source.getQps(device.id)))
            }
        }
        entries.sort { $0.priority == $1.priority ? $0.order > $1.order : $0.priority > $1.priority }
        var placed: [CGRect] = []
        var labels: [AtlasLabel] = []
        let fieldLimit = nodes.count > 200 ? 4 : Self.maxFieldLabels
        for entry in entries {
            let label = entry.el
            guard label.anchor.x > -200, label.anchor.x < runtime.frameViewSize.width + 200,
                  label.anchor.y > -200, label.anchor.y < runtime.frameViewSize.height + 200 else { continue }
            let rect = labelRect(label)
            var collides = false
            for other in placed where rect.intersects(other) { collides = true; break }
            if collides && entry.priority < 100 { continue }
            if !collides { placed.append(rect.insetBy(dx: -4, dy: -3)) }
            labels.append(label)
            // `.all` on a live All graph can admit hundreds of tags. Rendering
            // them all stalls SwiftUI, and they are unreadable anyway; keep the
            // highest-priority visible set (selected/hover are sorted first).
            if labels.count >= fieldLimit { break }
        }
        labelsStoreUpdate(labels)
        if timingStart > 0 {
            recordLabelTiming(CACurrentMediaTime() - timingStart)
        }
    }

    func recordLabelTiming(_ seconds: Double) {
        labelTimingSum += seconds
        labelTimingMax = max(labelTimingMax, seconds)
        labelTimingCount += 1
        guard labelTimingCount >= 120 else { return }
        let avg = labelTimingSum / Double(labelTimingCount) * 1000
        AtlasDiagnostics.log(String(format: "labels resolve count=%d avg=%.2fms max=%.2fms",
                                    runtime.labels.labels.count, avg, labelTimingMax * 1000))
        labelTimingSum = 0
        labelTimingMax = 0
        labelTimingCount = 0
    }

    func labelsStoreUpdate(_ labels: [AtlasLabel]) {
        // The resolver runs every frame now; only wake SwiftUI when the label
        // set or an anchor actually moved (e.g. paused camera).
        if runtime.labels.labels != labels {
            runtime.labels.labels = labels
        }
    }

    func labelRect(_ label: AtlasLabel) -> CGRect {
        CGRect(x: label.anchor.x - label.size.width / 2,
               y: label.anchor.y - label.size.height - 8,
               width: label.size.width, height: label.size.height)
    }

    func destinationLabel(node: NodeView, destination: Destination,
                          screen: SIMD3<Float>, latency: String) -> AtlasLabel {
        let host = runtime.destinationDisplayName(destination)
        let original = runtime.destinationOriginalText(destination)
        let detail = original.map { "\($0) · \(latency)" } ?? latency
        let cacheKey = "d:\(destination.id):\(host):\(detail):\(destination.status.rawValue)"
        let size: CGSize
        if let cached = labelSizeCache[cacheKey] {
            size = cached
        } else {
            let hostFont = NSFont.monospacedSystemFont(ofSize: 8.2, weight: .regular)
            let keyFont = NSFont.monospacedSystemFont(ofSize: 5.6, weight: .regular)
            let subFont = NSFont.monospacedSystemFont(ofSize: 6.2, weight: .regular)
            let hostWidth = ceil((host as NSString).size(withAttributes: [.font: hostFont]).width)
            let keyWidth = max(16, ceil((destination.key as NSString).size(withAttributes: [.font: keyFont]).width) + 6)
            let chipWidth: CGFloat = destination.status == .blocked ? 38 : 0
            let tagWidth = 5 + keyWidth + 6 + hostWidth + (chipWidth > 0 ? 6 + chipWidth : 0) + 7
            let metaWidth = ceil((destination.status.rawValue as NSString).size(withAttributes: [.font: subFont]).width)
            let detailWidth = ceil((detail as NSString).size(withAttributes: [.font: subFont]).width)
            let width = max(tagWidth, metaWidth + 6 + 2 + 6 + detailWidth)
            size = CGSize(width: max(52, width), height: 40)
            if labelSizeCache.count > 2048 { labelSizeCache.removeAll(keepingCapacity: true) }
            labelSizeCache[cacheKey] = size
        }
        return AtlasLabel(
            id: "dest-\(destination.id)", kind: .destination,
            anchor: CGPoint(x: CGFloat(screen.x), y: CGFloat(screen.y)),
            key: destination.key, host: host,
            badge: destination.status == .blocked ? "blocked" : nil,
            meta: destination.status.rawValue, detail: detail,
            blocked: destination.status == .blocked,
            hovered: node.hovered, selected: node.selected, size: size,
            accessibilityLabel: "\(host), \(destination.domain), \(destination.status.rawValue), \(detail)",
            opacity: HemisphereFocus.labelOpacity(node.basePosition, camera: runtime.camera,
                                                  interactive: node.selected || node.hovered)
        )
    }

    func deviceLabel(view: DeviceView, device: Device, screen: SIMD3<Float>) -> AtlasLabel {
        let rate = Format.rate(runtime.source.getQps(device.id))
        let host = runtime.deviceDisplayName(device)
        let address = runtime.deviceAddressText(device)
        let detail = "\(address) · \(rate)/s"
        let cacheKey = "v:\(device.id):\(host):\(detail)"
        let size: CGSize
        if let cached = labelSizeCache[cacheKey] {
            size = cached
        } else {
            let hostFont = NSFont.monospacedSystemFont(ofSize: 8.2, weight: .regular)
            let subFont = NSFont.monospacedSystemFont(ofSize: 6.2, weight: .regular)
            let hostWidth = ceil((host as NSString).size(withAttributes: [.font: hostFont]).width)
            let tagWidth = 5 + 12 + 6 + hostWidth + (device.thisMac ? 6 + 35 : 0) + 7
            let metaWidth = ceil(("source" as NSString).size(withAttributes: [.font: subFont]).width)
            let detailWidth = ceil((detail as NSString).size(withAttributes: [.font: subFont]).width)
            let width = max(tagWidth, metaWidth + 6 + 2 + 6 + detailWidth)
            size = CGSize(width: max(56, width), height: 40)
            if labelSizeCache.count > 2048 { labelSizeCache.removeAll(keepingCapacity: true) }
            labelSizeCache[cacheKey] = size
        }
        return AtlasLabel(
            id: "dev-\(device.id)", kind: .device,
            anchor: CGPoint(x: CGFloat(screen.x), y: CGFloat(screen.y)),
            key: "", host: host,
            badge: device.thisMac ? "this mac" : nil,
            meta: "source", detail: detail,
            blocked: false, hovered: view.hovered, selected: view.selected, size: size,
            accessibilityLabel: "\(host), \(device.kind), \(device.name), \(detail)",
            opacity: HemisphereFocus.labelOpacity(view.position, camera: runtime.camera,
                                                  interactive: view.selected || view.hovered)
        )
    }

    func invalidateLabelSizes() {
        labelSizeCache.removeAll(keepingCapacity: true)
    }

    // ── event labels ─────────────────────────────────────────────────────

    func flashDestinationLabel(_ id: String, duration: Double) {
        eventLabels[id] = Date().timeIntervalSince1970 + duration
        if runtime.labelMode == .events { updateLabels(force: true) }
    }

    func expireEventLabels() {
        guard !eventLabels.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var changed = false
        for (id, until) in eventLabels where until <= now {
            eventLabels.removeValue(forKey: id)
            changed = true
        }
        if changed { updateLabels(force: true) }
    }

    // ── picking ──────────────────────────────────────────────────────────

    func pick(at point: CGPoint, viewSize: CGSize) -> Selection? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let ndc = SIMD2<Float>(Float(point.x / viewSize.width) * 2 - 1,
                               -(Float(point.y / viewSize.height) * 2 - 1))
        let ray = runtime.camera.rayDirection(ndc: ndc)
        var candidates: [(selection: Selection, center: Vec3, distance: Float)] = []
        for node in nodes where node.canPick() {
            let center = node.basePosition
            let radius = node.radius * 2.1
            if let t = raySphere(origin: runtime.camera.position, direction: ray, center: center, radius: radius) {
                candidates.append((.destination(node.destinationRef.id), center, t))
            }
        }
        for view in devices where view.canPick() {
            let center = view.visualCenter
            if let t = raySphere(origin: runtime.camera.position, direction: ray, center: center, radius: 0.9) {
                candidates.append((.device(view.deviceRef.id), center, t))
            }
        }
        guard !candidates.isEmpty else { return nil }

        // Hit volumes deliberately overreach the drawn bodies so small orbs
        // stay easy to catch, which makes ray order a poor tie-breaker: a
        // foreground body can swallow a click aimed at a background one. Rank
        // by screen distance to each projected centre instead, and use ray
        // distance only for near-exact ties. This is what makes an out-of-
        // focus device on the far shell directly addressable.
        let viewport = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
        var best: (selection: Selection, screenDistance: Float, distance: Float)?
        for candidate in candidates {
            let projected = runtime.camera.project(candidate.center, viewport: viewport)
            let dx = projected.x - Float(point.x)
            let dy = projected.y - Float(point.y)
            let screenDistance = (dx * dx + dy * dy).squareRoot()
            if best == nil
                || screenDistance < best!.screenDistance - 1.5
                || (abs(screenDistance - best!.screenDistance) <= 1.5
                    && candidate.distance < best!.distance) {
                best = (candidate.selection, screenDistance, candidate.distance)
            }
        }
        return best?.selection
    }

    func raySphere(origin: Vec3, direction: Vec3, center: Vec3, radius: Float) -> Float? {
        let oc = origin - center
        let b = oc.dot(direction)
        let c = oc.dot(oc) - radius * radius
        let disc = b * b - c
        guard disc > 0 else { return nil }
        let sqrtD = sqrt(disc)
        let t1 = -b - sqrtD
        let t2 = -b + sqrtD
        if t1 > 0.001 { return t1 }
        if t2 > 0.001 { return t2 }
        return nil
    }

    // ── replay / debug scene support ─────────────────────────────────────

    func clearReplayEffects() {
        effects.clear()
        signals.removeAll()
        deviceAppearanceLinks.removeAll()
        signalCounts.removeAll()
        localTraces.removeAll()
        ringTraces.removeAll()
        eventLabels.removeAll()
        lastImpact = nil
        hitGeometryReplayAt = nil
        for wire in wires {
            wire.setSignalActive(false)
            wire.reveal = 1
        }
        for node in nodes { node.stopRecoil() }
        for device in runtime.network.devices { device.pendingAppearance = false }
        updateLabels(force: true)
        applyVisualState()
    }

    func clearEffectsForSnapshot() {
        effects.clear()
        runtime.clearTimers()
        signals.removeAll()
        deviceAppearanceLinks.removeAll()
        signalCounts.removeAll()
        eventLabels.removeAll()
        lastImpact = nil
        hitGeometryReplayAt = nil
        for node in nodes {
            if node.destinationRef?.windowVisible == true {
                node.destroyed = false
                node.stopRecoil()
                node.setPresence(1)
                setWireVisibility(destinationId: node.destinationRef.id, visible: true)
            }
        }
        runtime.labelMode = .off
        updateLabels(force: true)
        rebuildDrawListForSnapshot()
    }

    func rebuildDrawListForSnapshot() {
        buildDrawList(simDt: 0)
    }

    func debugPreviewEffect(kind: String, style: String, destinationId: String?,
                            age: Float, viewSize: CGSize) {
        runtime.paused = false
        let destination = destinationId.flatMap { runtime.network.destinationById[$0] }
            ?? runtime.network.destinations.sorted { $0.liveQueries > $1.liveQueries }.first
        guard let destination, let node = nodeByDest[destination.id] else { return }
        runtime.selection = .destination(destination.id)
        effects.clear()
        node.destroyed = false
        node.stopRecoil()
        node.setPresence(1)
        setWireVisibility(destinationId: destination.id, visible: true)
        switch kind {
        case "birth":
            birthDestination(destination, style: style, forceStyle: true)
        case "death":
            retireDestination(destination, style: style)
        default:
            let meta = Effects.meta(impact: style)
            registerImpactPreview(node: node, meta: meta)
        }
        // Step only the scene; the demo source is driven by its own timer and
        // must stay out of deterministic study captures.
        var remaining = max(0, age)
        while remaining > 0.00001 {
            let dt = min(1.0 / 60.0, remaining)
            runtime.updateFrame(dt: dt, viewSize: viewSize)
            remaining -= dt
        }
        runtime.paused = true
        runtime.settlePostForSnapshot()
        rebuildDrawListForSnapshot()
        updateLabels(force: true)
    }

    func previewMotion(_ kind: String) {
        if runtime.autoTour { runtime.setAutoTour(false) }
        if runtime.paused { runtime.setPaused(false) }
        guard let destination = previewDestination(), let node = nodeByDest[destination.id] else {
            runtime.showToast("Select a destination first.", tone: .gold)
            return
        }
        switch kind {
        case "impact":
            let allowed = destination.status == .blocked
                ? [Effects.meta(impact: "containment")]
                : Effects.impacts.filter { $0.id != "containment" }
            let meta = allowed[previewIndex.impact % allowed.count]
            previewIndex.impact += 1
            registerImpactPreview(node: node, meta: meta)
            runtime.showToast("Impact preview · \(meta.key) \(meta.name)", tone: .gold)
        case "birth":
            let pool = destination.status == .blocked
                ? [Effects.meta(birth: "redaction")]
                : Effects.births.filter { $0.id != "redaction" }
            let meta = pool[previewIndex.birth % pool.count]
            previewIndex.birth += 1
            birthDestination(destination, style: meta.id)
            runtime.showToast("Emergence preview · \(meta.key) \(meta.name)", tone: .gold)
        case "death":
            let meta = Effects.deaths[previewIndex.death % Effects.deaths.count]
            previewIndex.death += 1
            retireDestination(destination, style: meta.id, restoreAfter: meta.duration + 1.25)
            runtime.showToast("Erasure preview · \(meta.key) \(meta.name)", tone: .coral)
        default: break
        }
    }

    func registerImpactPreview(node: NodeView, meta: EffectMeta) {
        let destination = node.destinationRef!
        // Preview the same geometry an arriving packet uses: the plane normal
        // is the wire's arrival tangent, not the destination's radial normal.
        // Falling back to the radial only keeps random/debug previews safe when
        // no wire exists; it never replaces the real inbound vector.
        let busiestEdge = destination.edges.max { $0.liveQueries < $1.liveQueries }
        let previewWire = busiestEdge.flatMap {
            wireByKey["\($0.deviceId)::\($0.destinationId)"]
        }
        let normal = (previewWire?.tangent ?? node.basePosition).normalized
        node.onHit(normal, recoil: runtime.recoilEnabled && destination.status != .blocked)
        let R = max(0.26, node.radius * 1.9)
        var ctx = EffectContext(camera: runtime.camera, node: node, radius: R,
                                point: node.basePosition, normal: normal,
                                elapsed: runtime.elapsed, onShake: { [weak self] amount in
                                    self?.trauma = min(1, (self?.trauma ?? 0) + amount * 0.55)
                                }, rng: rng)
        ctx.offset = .zero
        let effect = Effects.impact(meta.id, ctx: ctx)
        effects.add(effect, node: node, origin: node.basePosition, kind: "impact")
        lastImpact = ImpactRecord(destinationId: destination.id, blocked: destination.status == .blocked,
                                  at: runtime.elapsed, normal: normal, point: node.basePosition,
                                  impactId: meta.id, impactName: "\(meta.key) · \(meta.name)")
        hitGeometryReplayAt = nil
        flashDestinationLabel(destination.id, duration: 1.7)
    }

    func previewDestination() -> Destination? {
        if let selection = runtime.selection, let id = selection.destinationId {
            return runtime.network.destinationById[id]
        }
        if let hover = runtime.hover, let id = hover.destinationId {
            return runtime.network.destinationById[id]
        }
        if let selection = runtime.selection, let deviceId = selection.deviceId,
           let device = runtime.network.deviceById[deviceId] {
            return device.edges.sorted { $0.liveQueries > $1.liveQueries }.first?.destination
        }
        return runtime.network.destinations.sorted { $0.liveQueries > $1.liveQueries }.first
    }

}
