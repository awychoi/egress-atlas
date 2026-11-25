import Foundation
import simd
import AppKit

// MARK: - Selection

enum HostSelection: Equatable {
    case app(String)
    case domain(String)

    var appID: String? {
        if case .app(let id) = self { return id }
        return nil
    }

    var domainID: String? {
        if case .domain(let id) = self { return id }
        return nil
    }
}

// MARK: - Scene

/// The host instrument: apps on the shell, remote domains inside, byte flow on
/// the wires. It is deliberately independent of the Pi-hole DNS graph: the two
/// globes share only the camera and the renderer, not their data or chrome.
final class HostGlobeScene {
    let stage = GlobeStage(theme: .host)
    private(set) var snapshot: HostSnapshot = .empty
    private(set) var appNodes: [String: AppNode] = [:]
    private(set) var domainNodes: [String: DomainNode] = [:]
    private(set) var wires: [String: WireView] = [:]
    private(set) var labels: [AtlasLabel] = []
    private(set) var draw = DrawList()

    var selection: HostSelection?
    var hover: HostSelection?

    private var signals: [Signal] = []
    private var bursts: [HostBurst] = []
    private var wireSignalCounts: [String: Int] = [:]
    private var elapsed: Float = 0
    private var lastUpdate: Float = 0
    private var layoutDirty = true
    private var appSlot: [String: Int] = [:]
    private var nextSlot = 0
    private var rng = RNG(0x48a17)
    private var detail: Float = 1
    private var isActive = true
    private var lastSnapshotDate = Date.distantPast

    static let maxApps = 7
    static let maxDomains = 14
    static let maxSignals = 28
    static let appSlots = 48
    private static let golden = Float.pi * (3 - sqrt(5))

    struct AppNode {
        let device: Device
        let view: DeviceView
        var stat: HostAppStat
        let normal: Vec3
        var presence: Float = 0
        var targetPresence: Float = 1
        var lastSeen: Date
    }

    struct DomainNode {
        let destination: Destination
        let view: NodeView
        var stat: HostDomainStat
        var presence: Float = 0
        var targetPresence: Float = 1
        var lastSeen: Date
        var appIDs: Set<String>
    }

    private struct HostBurst {
        var position: Vec3
        var age: Float = 0
        let duration: Float
        let color: SRGB
        let accent: SRGB
        let size: Float
        let opacity: Float
    }

    // MARK: lifecycle

    func reset() {
        appNodes.removeAll()
        domainNodes.removeAll()
        wires.removeAll()
        signals.removeAll()
        bursts.removeAll()
        wireSignalCounts.removeAll()
        labels.removeAll()
        appSlot.removeAll()
        nextSlot = 0
        layoutDirty = true
        draw.reset()
        elapsed = 0
    }

    /// Headless-only: the snapshot hooks install the demo graph at the same
    /// instant as the focus freeze, so prime its presence instead of showing
    /// the first fade-in frame of every body.
    func primeForSnapshot() {
        for (id, var node) in appNodes {
            node.presence = 1
            node.targetPresence = 1
            node.view.windowPresence = 1
            appNodes[id] = node
        }
        for (id, var node) in domainNodes {
            node.presence = 1
            node.targetPresence = 1
            node.view.presence = 1
            domainNodes[id] = node
        }
        for (_, wire) in wires { wire.reveal = 1 }
        lastUpdate = 1.0
    }

    func setDetail(_ detail: Float, active: Bool) {
        let next = max(0, min(1, detail))
        if abs(next - self.detail) > 0.01 {
            // Rebuild immediately when the role (and therefore the LOD
            // profile) changes; otherwise the first handoff frame can still
            // contain the previous bokeh-only draw list.
            lastUpdate = 1.0
        }
        self.detail = next
        self.isActive = active
    }

    func apply(_ snapshot: HostSnapshot) {
        guard snapshot.date != lastSnapshotDate else { return }
        lastSnapshotDate = snapshot.date
        self.snapshot = snapshot

        let apps = snapshot.apps.sorted {
            if $0.totalPerSecond != $1.totalPerSecond { return $0.totalPerSecond > $1.totalPerSecond }
            if $0.rxTotal + $0.txTotal != $1.rxTotal + $1.txTotal {
                return $0.rxTotal + $0.txTotal > $1.rxTotal + $1.txTotal
            }
            return $0.id < $1.id
        }
        let topApps = Array(apps.prefix(Self.maxApps))
        var appIDs = Set(topApps.map(\.id))
        if let selected = selection?.appID { appIDs.insert(selected) }

        for stat in apps where appIDs.contains(stat.id) {
            if var node = appNodes[stat.id] {
                node.stat = stat
                node.lastSeen = snapshot.date
                node.targetPresence = 1
                appNodes[stat.id] = node
            } else {
                let node = makeAppNode(stat, at: snapshot.date)
                appNodes[stat.id] = node
                spawnBurst(at: node.view.position, color: Palette.hostApp,
                           accent: Palette.hostAppHover, size: 0.72, duration: 0.72)
                layoutDirty = true
            }
        }
        for (id, var node) in appNodes where !appIDs.contains(id) {
            if node.targetPresence != 0 {
                spawnBurst(at: node.view.position, color: Palette.hostApp,
                           accent: Palette.hostFaint, size: 0.9, duration: 0.82)
            }
            node.targetPresence = 0
            appNodes[id] = node
        }

        let domains = snapshot.domains.sorted {
            if $0.totalPerSecond != $1.totalPerSecond { return $0.totalPerSecond > $1.totalPerSecond }
            if $0.rxTotal + $0.txTotal != $1.rxTotal + $1.txTotal {
                return $0.rxTotal + $0.txTotal > $1.rxTotal + $1.txTotal
            }
            return $0.id < $1.id
        }
        let topDomains = Array(domains.prefix(Self.maxDomains))
        var domainIDs = Set(topDomains.map(\.id))
        if let selected = selection?.domainID { domainIDs.insert(selected) }

        for stat in domains where domainIDs.contains(stat.id) {
            if var node = domainNodes[stat.id] {
                node.stat = stat
                node.lastSeen = snapshot.date
                node.targetPresence = 1
                node.appIDs = stat.appIDs
                domainNodes[stat.id] = node
            } else {
                let node = makeDomainNode(stat, at: snapshot.date)
                domainNodes[stat.id] = node
                spawnBurst(at: node.view.basePosition, color: Palette.hostRemote,
                           accent: Palette.hostRemoteHot, size: 0.62, duration: 0.72)
                layoutDirty = true
            }
        }
        for (id, var node) in domainNodes where !domainIDs.contains(id) {
            if node.targetPresence != 0 {
                spawnBurst(at: node.view.basePosition, color: Palette.hostRemote,
                           accent: Palette.hostFaint, size: 0.8, duration: 0.82)
            }
            node.targetPresence = 0
            domainNodes[id] = node
        }

        if layoutDirty { relayout() }
        reconcileWires()
        if detail > 0.45 {
            emit(snapshot.transfers)
        }
    }

    func update(dt rawDt: Float, camera: Camera) {
        let dt = min(0.1, max(0, rawDt))
        elapsed += dt
        lastUpdate += dt

        // The background globe runs at a lower simulation rate; its stage and
        // motions are deliberately calmer so the focused globe owns the eye.
        let motionDt = isActive ? dt : dt * 0.35

        for (id, var node) in appNodes {
            node.presence += (node.targetPresence - node.presence) * min(1, motionDt * 5.5)
            node.view.setWindowVisible(node.targetPresence > 0.5)
            node.view.windowPresence = node.presence
            let focusDepth = camera.viewDepth(of: .zero)
            let delta = camera.viewDepth(of: node.view.position) - focusDepth
            node.view.defocus = delta > 0 ? clamp01(delta * 0.16) : 0
            node.view.stagger = Float(stableSeed(id) % 7) / 7 * 0.10
            node.view.update(dt: motionDt, elapsed: elapsed, camera: camera)
            node.view.windowPresence = node.presence
            node.view.setHovered(selection?.appID == id || hover?.appID == id)
            node.view.setSelected(selection?.appID == id)
            node.view.setDimmed(selection?.appID != nil && selection?.appID != id)
            appNodes[id] = node
        }
        for (id, var node) in domainNodes {
            node.presence += (node.targetPresence - node.presence) * min(1, motionDt * 5.5)
            node.view.presence = node.presence
            node.view.update(dt: motionDt, elapsed: elapsed)
            node.view.setHovered(hover?.domainID == id)
            node.view.setSelected(selection?.domainID == id)
            node.view.setDimmed(selection?.domainID != nil && selection?.domainID != id)
            domainNodes[id] = node
        }

        // Remove fully faded bodies and their wires.
        for (id, node) in appNodes where node.presence < 0.01 && node.targetPresence == 0 {
            appNodes.removeValue(forKey: id)
            appSlot.removeValue(forKey: id)
        }
        for (id, node) in domainNodes where node.presence < 0.01 && node.targetPresence == 0 {
            domainNodes.removeValue(forKey: id)
            // Drop the wire in the same turn as its domain view. Marking it
            // invisible leaves a strong wire holding a NodeView whose
            // unowned DNS Destination has already been released.
            let retired = wires.filter { $0.value.nodeView?.id == node.view.id }.map(\.key)
            for wireID in retired {
                wires[wireID]?.setVisible(false)
                wires.removeValue(forKey: wireID)
            }
        }
        if layoutDirty { relayout() }

        updateWires(camera: camera, dt: motionDt)
        updateSignals(motionDt)
        for i in bursts.indices {
            bursts[i].age += motionDt
        }
        bursts.removeAll { $0.age >= $0.duration }
        if isActive, lastUpdate >= 1.0 / 60.0 || !isActive {
            buildDrawList()
            lastUpdate = 0
        }
        if !isActive, lastUpdate >= 1.0 / 15.0 {
            buildDrawList()
            lastUpdate = 0
        }
    }

    // MARK: graph construction

    private func makeAppNode(_ stat: HostAppStat, at date: Date) -> AppNode {
        let slot = appSlot[stat.id] ?? {
            // A coprime stride scatters successive app bodies around the whole
            // shell instead of stacking them in the first few Fibonacci slots.
            var candidate = (nextSlot * 17) % Self.appSlots
            nextSlot += 1
            while appSlot.values.contains(candidate) {
                candidate = (candidate + 1) % Self.appSlots
            }
            appSlot[stat.id] = candidate
            return candidate
        }()
        let y = 1 - (Float(slot) + 0.5) * 2 / Float(Self.appSlots)
        let ring = sqrt(max(0, 1 - y * y))
        let angle = Float(slot) * Self.golden
        let normal = Vec3(cos(angle) * ring, y, sin(angle) * ring).normalized
        let surface = normal * 6
        let spec = DeviceSpec(
            id: "host-app:\(stat.id)",
            name: stat.name,
            kind: stat.isSystem ? "Service" : "App",
            ip: stat.detail,
            os: "this Mac",
            lat: 0, lon: 0,
            weight: Float(stat.rxTotal + stat.txTotal),
            thisMac: false,
            tone: "host"
        )
        let device = Device(spec, surface: surface, normal: normal)
        device.liveQueries = Int(stat.rxTotal + stat.txTotal)
        let viewSpec = DeviceSpecView(id: spec.id, name: stat.name, kind: spec.kind,
                                      ip: stat.detail, thisMac: false)
        let view = DeviceView(spec: viewSpec, position: surface, normal: normal,
                              radius: 0.085, rng: RNG(stableSeed(stat.id)))
        view.windowPresence = 0
        view.bodyBase = Palette.hostApp
        view.bodyHot = Palette.hostAppHot
        view.deviceRef = device
        view.setWindowVisible(true, animated: true, style: .bloom)
        return AppNode(device: device, view: view, stat: stat, normal: normal,
                       presence: 0, targetPresence: 1, lastSeen: date)
    }

    private func makeDomainNode(_ stat: HostDomainStat, at date: Date) -> DomainNode {
        let radius = max(0.16, 0.14 + log10(1 + Double(stat.rxTotal + stat.txTotal)) * 0.045)
        let spec = DestinationSpec(
            id: "host-domain:\(stat.id)",
            lastSeenHoursAgo: 0,
            domain: stat.name,
            short: shortName(stat.name),
            category: stat.service,
            status: .allowed,
            weight: Float(stat.rxTotal + stat.txTotal),
            impactId: "eclipse",
            birthId: "spiral",
            tone: "host"
        )
        let destination = Destination(spec)
        destination.visualRadius = Float(radius)
        destination.avgLatencyMs = nil
        let nodeSpec = NodeSpec(
            id: spec.id,
            key: String(stat.service.prefix(3)).uppercased(),
            domain: stat.name,
            meta: stat.service,
            latency: "",
            status: .allowed,
            position: Vec3(0, 0, -3),
            tone: "hostDomain"
        )
        let view = NodeView(spec: nodeSpec, radius: Float(radius),
                            index: domainNodes.count, rng: RNG(stableSeed(stat.id)))
        view.destinationRef = destination
        view.presence = 0
        return DomainNode(destination: destination, view: view, stat: stat,
                          presence: 0, targetPresence: 1, lastSeen: date,
                          appIDs: stat.appIDs)
    }

    // MARK: layout

    private func relayout() {
        layoutDirty = false
        // Apps sit on fixed Fibonacci slots so adding one does not reshuffle
        // the whole shell. Sorted keys keep the pass identical run to run.
        for id in appNodes.keys.sorted() {
            guard let node = appNodes[id] else { continue }
            let slot = appSlot[id] ?? 0
            let y = 1 - (Float(slot) + 0.5) * 2 / Float(Self.appSlots)
            let ring = sqrt(max(0, 1 - y * y))
            let angle = Float(slot) * Self.golden
            let normal = Vec3(cos(angle) * ring, y, sin(angle) * ring).normalized
            node.view.setSurfacePosition(normal * 6, normal)
        }

        var positions: [String: Vec3] = [:]
        for id in domainNodes.keys.sorted() {
            guard let node = domainNodes[id] else { continue }
            let seed = stableSeed(id)
            let angle = Float(seed % 997) / 997 * TAU
            var centroid = Vec3.zero
            for appID in node.appIDs.sorted() {
                guard let app = appNodes[appID] else { continue }
                let w = Float(max(1, app.stat.rxTotal + app.stat.txTotal))
                centroid += app.normal * w
            }
            let base = centroid.lengthSq > 0.001
                ? centroid.normalized
                : Vec3(sin(angle), cos(angle * 0.7), cos(angle)).normalized
            var tangent = base.cross(.up)
            if tangent.lengthSq < 1e-4 { tangent = Vec3(1, 0, 0) }
            tangent = tangent.normalized
            let bitangent = base.cross(tangent).normalized
            let spread = 0.55 + Float(seed % 71) / 71 * 0.65
            let offset = tangent * (cos(angle * 2.3) * spread)
                + bitangent * (sin(angle * 1.7) * spread)
            let radial = 2.5 + Float(seed % 53) / 53 * 2.5
            var position = (base + offset * 0.55).normalized * radial
            position = position.withLength(min(4.85, max(1.7, position.length)))
            positions[id] = position
        }

        // Light relaxation so the inside constellation reads as a field, not
        // a pile. The population is capped, so this is cheap and only runs on
        // a graph change. The ordered local field keeps the pairwise passes
        // deterministic; dictionary key order is not stable across runs.
        let ids = positions.keys.sorted()
        if ids.count > 1 {
            var field: [(id: String, position: Vec3)] = []
            field.reserveCapacity(ids.count)
            for id in ids {
                guard let position = positions[id] else { continue }
                field.append((id: id, position: position))
            }
            for _ in 0..<28 {
                for i in 0..<field.count {
                    for j in (i + 1)..<field.count {
                        var a = field[i].position
                        var b = field[j].position
                        var delta = a - b
                        let distance = max(0.0001, delta.length)
                        if distance < 1.82 {
                            let push = (1.82 - distance) * 0.5
                            delta = delta.normalized
                            a += delta * push
                            b -= delta * push
                            field[i].position = a
                            field[j].position = b
                        }
                    }
                }
                for i in field.indices {
                    field[i].position = field[i].position.withLength(
                        min(4.85, max(1.7, field[i].position.length)))
                }
            }
            for entry in field {
                positions[entry.id] = entry.position
            }
        }
        for id in domainNodes.keys.sorted() {
            guard let node = domainNodes[id], let position = positions[id] else { continue }
            node.view.setBasePosition(position)
            node.destination.position = position
            node.destination.direction = position.normalized
            node.destination.radius = position.length
            node.destination.homeDirection = position.normalized
            node.destination.radialFraction = position.length / 6
        }
        rebuildWirePaths()
    }

    private func reconcileWires() {
        var wanted: [String: (appID: String, domainID: String)] = [:]
        for (domainID, node) in domainNodes {
            let apps = node.appIDs.compactMap { appID -> (String, HostAppNodeStat)? in
                guard let app = appNodes[appID] else { return nil }
                return (appID, HostAppNodeStat(total: app.stat.rxTotal + app.stat.txTotal))
            }.sorted {
                if $0.1.total != $1.1.total { return $0.1.total > $1.1.total }
                return $0.0 < $1.0
            }
            for (appID, _) in apps.prefix(3) {
                wanted["\(appID)|\(domainID)"] = (appID, domainID)
            }
        }
        for (key, wire) in wires where wanted[key] == nil {
            wire.setVisible(false)
            wires.removeValue(forKey: key)
        }
        // Creating in key order keeps the seeded per-wire offsets stable;
        // dictionary order would reshuffle them every launch.
        for key in wanted.keys.sorted() {
            guard wires[key] == nil, let pair = wanted[key] else { continue }
            guard let app = appNodes[pair.appID], let node = domainNodes[pair.domainID] else { continue }
            let wire = WireView(offset: rng.next(), tone: .allowed)
            wire.edgeId = key
            wire.deviceView = app.view
            wire.nodeView = node.view
            wire.hostTone = true
            wire.setVisible(false)
            wire.reveal = 0
            wires[key] = wire
        }
        rebuildWirePaths()
    }

    private struct HostAppNodeStat { let total: UInt64 }

    private func rebuildWirePaths() {
        for (_, wire) in wires {
            guard let device = wire.deviceView, let node = wire.nodeView else { continue }
            wire.setGlobePath(from: device.position, to: node.basePosition,
                              normal: device.normal, globeRadius: 6)
            wire.setVisible(true)
        }
    }

    private func updateWires(camera: Camera, dt: Float = 1.0 / 60.0) {
        for (_, wire) in wires {
            wire.reveal = min(1, wire.reveal + dt * 2.8)
            wire.setDim(0.92)
            if let device = wire.deviceView {
                wire.setFacing(device.displayVisibility)
            }
            wire.setVisible(true)
        }
    }

    // MARK: effects

    private func spawnBurst(at position: Vec3, color: SRGB, accent: SRGB,
                            size: Float, duration: Float) {
        guard bursts.count < 40 else { return }
        bursts.append(HostBurst(position: position, duration: duration,
                                color: color, accent: accent, size: size, opacity: 0.9))
    }

    private func drawBursts(visibility: Float) {
        for burst in bursts {
            let t = clamp01(burst.age / burst.duration)
            let grow = 0.35 + easeOutCubic(t) * 1.55
            let fade = pow(1 - t, 1.7)
            draw.shockShells.append(ShockShellUniforms(
                model: Mat4.translation(burst.position)
                    * Mat4.scale(Vec3(repeating: burst.size * grow)),
                color: rgba(burst.color, fade * burst.opacity * visibility),
                accent: rgba(burst.accent, fade * 0.65 * visibility),
                params: SIMD4(fade * 0.55 * visibility, burst.age, 0, 0)
            ))
            draw.sprites.append(.glow(burst.position,
                                      size: burst.size * (1.7 + grow * 2.4),
                                      color: burst.accent,
                                      opacity: fade * 0.16 * visibility))
        }
    }

    // MARK: draw

    private func buildDrawList() {
        draw.reset()
        let stageLineStart = draw.stageLines.count
        let stagePointStart = draw.stagePoints.count
        stage.update(dt: min(0.1, max(0.001, lastUpdate)), elapsed: elapsed,
                     stageScale: 1, detail: max(0.51, detail), into: draw)
        let stageAlpha = 0.03 + 0.97 * smoothstep(0.28, 0.82, detail)
        for i in stageLineStart..<draw.stageLines.count { draw.stageLines[i].color.w *= stageAlpha }
        for i in stagePointStart..<draw.stagePoints.count { draw.stagePoints[i].color.w *= stageAlpha }
        drawBursts(visibility: max(0.22, detail))
        let domainLimit = Int(Float(64) + Float(Self.maxDomains - 64) * smoothstep(0.30, 0.90, detail))
        let domains = domainNodes.values
            .sorted {
                if $0.stat.totalPerSecond != $1.stat.totalPerSecond {
                    return $0.stat.totalPerSecond > $1.stat.totalPerSecond
                }
                return $0.stat.id < $1.stat.id
            }
            .prefix(domainLimit)
        for node in domains {
            guard node.presence > 0.004 else { continue }
            node.view.appendDraw(draw, elapsed: elapsed, camera: currentCamera, detail: detail)
        }
        let appLimit = Int(Float(20) + Float(Self.maxApps - 20) * smoothstep(0.30, 0.90, detail))
        let apps = appNodes.values
            .sorted {
                if $0.stat.totalPerSecond != $1.stat.totalPerSecond {
                    return $0.stat.totalPerSecond > $1.stat.totalPerSecond
                }
                return $0.stat.id < $1.stat.id
            }
            .prefix(appLimit)
        for node in apps {
            guard node.presence > 0.004 else { continue }
            node.view.appendDraw(draw, elapsed: elapsed, detail: detail)
        }
        let wireLimit = Int(Float(48) + 48 * smoothstep(0.30, 0.90, detail))
        // Host wires point at host NodeViews, which intentionally have no DNS
        // Destination. Never ask a host node for DNS stats (that reference is
        // unowned and nil here). Sorted keys keep the additive line batch in
        // the same order every launch.
        for key in wires.keys.sorted().prefix(wireLimit) {
            wires[key]?.appendDraw(draw, elapsed: elapsed, detail: detail)
        }
        if detail > 0.4 {
            for signal in signals {
                signal.appendDraw(draw, elapsed: elapsed)
            }
        }
    }

    private var currentCamera = Camera()

    // MARK: transfers

    private func emit(_ transfers: [HostTransfer]) {
        guard !transfers.isEmpty else { return }
        let candidates = transfers
            .sorted {
                if $0.bytesIn + $0.bytesOut != $1.bytesIn + $1.bytesOut {
                    return $0.bytesIn + $0.bytesOut > $1.bytesIn + $1.bytesOut
                }
                return $0.id < $1.id
            }
            .prefix(10)
        for transfer in candidates {
            guard signals.count < Self.maxSignals else { break }
            let domainKey = transfer.domainID
            guard domainNodes[domainKey] != nil else { continue }
            let wireKey = "\(transfer.appID)|\(transfer.domainID)"
            guard let wire = wires[wireKey], wire.controlPoints.count >= 2,
                  appNodes[transfer.appID] != nil else { continue }
            let control = wire.controlPoints
            let ingress = transfer.bytesIn > transfer.bytesOut
            let points = ingress ? Array(control.reversed()) : control
            let length = CatmullRom(points: points).length()
            let duration = max(0.35, min(1.1, 0.4 + length * 0.035))
            let appID = transfer.appID
            let targetNodeID = domainKey
            let signal = Signal(controlPoints: points, duration: duration,
                                seed: UInt32(truncatingIfNeeded: Int(elapsed * 1000) ^ points.count),
                                style: ingress ? .hostInbound : .hostOutbound) { [weak self] in
                guard let self else { return }
                let next = max(0, (self.wireSignalCounts[wireKey] ?? 1) - 1)
                if next == 0 { self.wireSignalCounts.removeValue(forKey: wireKey) }
                else { self.wireSignalCounts[wireKey] = next }
                self.wires[wireKey]?.setSignalActive(next > 0)
                if ingress {
                    if let app = self.appNodes[appID] {
                        app.view.onFire()
                        self.spawnBurst(at: app.view.position, color: Palette.hostGlow,
                                        accent: Palette.hostIce, size: 0.52, duration: 0.5)
                    }
                } else {
                    if let domain = self.domainNodes[targetNodeID] {
                        domain.view.flashAge = 0
                        self.spawnBurst(at: domain.view.basePosition, color: Palette.hostOutHot,
                                        accent: Palette.hostOut, size: 0.52, duration: 0.5)
                    }
                }
            }
            wireSignalCounts[wireKey, default: 0] += 1
            wire.setSignalActive(true)
            signals.append(signal)
        }
    }

    private func updateSignals(_ dt: Float) {
        signals.removeAll { !$0.update(dt: dt) }
    }

    // MARK: picking and labels

    func setCamera(_ camera: Camera) {
        currentCamera = camera
    }

    func pick(at point: CGPoint, viewSize: CGSize, camera: Camera) -> HostSelection? {
        let viewport = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
        var best: (HostSelection, Float)?
        for (id, node) in domainNodes where node.presence > 0.18 {
            let screen = camera.project(node.view.basePosition, viewport: viewport)
            let d = hypot(screen.x - Float(point.x), screen.y - Float(point.y))
            let depth = camera.position.distance(to: node.view.basePosition)
            let radiusPx = node.view.radius * Float(viewSize.height) / (2 * tan(camera.fov * .pi / 360)) / max(0.001, depth)
            let hit = max(10, radiusPx * 1.6)
            if d < hit, best == nil || d < best!.1 { best = (.domain(id), d) }
        }
        for (id, node) in appNodes where node.presence > 0.18 {
            let screen = camera.project(node.view.visualCenter, viewport: viewport)
            let d = hypot(screen.x - Float(point.x), screen.y - Float(point.y))
            if d < 14, best == nil || d < best!.1 { best = (.app(id), d) }
        }
        return best?.0
    }

    func resolveLabels(camera: Camera, viewSize: CGSize, labelMode: LabelMode) {
        // HOST has no event labels, so `.events` behaves like `.selected`.
        guard labelMode != .off else {
            labels = []
            return
        }
        let viewport = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
        var entries: [(AtlasLabel, Float)] = []
        if let selection, case .app(let id) = selection, let node = appNodes[id] {
            entries.append((appLabel(node, camera: camera, viewport: viewport), 120))
        }
        if let selection, case .domain(let id) = selection, let node = domainNodes[id] {
            entries.append((domainLabel(node, camera: camera, viewport: viewport), 120))
        }
        if let hover, case .app(let id) = hover, let node = appNodes[id] {
            entries.append((appLabel(node, camera: camera, viewport: viewport), 110))
        }
        if let hover, case .domain(let id) = hover, let node = domainNodes[id] {
            entries.append((domainLabel(node, camera: camera, viewport: viewport), 110))
        }
        // Ambient tags follow the shared label mode. The default `.selected`
        // mode must not leave the busiest bodies tagged all the time.
        if labelMode == .all {
            let topApps = appNodes.values
                .filter { $0.presence > 0.35 && $0.stat.totalPerSecond > 0 }
                .sorted {
                    if $0.stat.totalPerSecond != $1.stat.totalPerSecond {
                        return $0.stat.totalPerSecond > $1.stat.totalPerSecond
                    }
                    return $0.stat.id < $1.stat.id
                }
                .prefix(2)
            for node in topApps where node.stat.id != selection?.appID && node.stat.id != hover?.appID {
                entries.append((appLabel(node, camera: camera, viewport: viewport), 30))
            }
            let topDomains = domainNodes.values
                .filter { $0.presence > 0.35 && $0.stat.totalPerSecond > 0 }
                .sorted {
                    if $0.stat.totalPerSecond != $1.stat.totalPerSecond {
                        return $0.stat.totalPerSecond > $1.stat.totalPerSecond
                    }
                    return $0.stat.id < $1.stat.id
                }
                .prefix(2)
            for node in topDomains where node.stat.id != selection?.domainID && node.stat.id != hover?.domainID {
                entries.append((domainLabel(node, camera: camera, viewport: viewport), 20))
            }
        }
        entries.sort { $0.1 > $1.1 }
        var placed: [CGRect] = []
        var result: [AtlasLabel] = []
        let limit = isActive ? (viewSize.width < 760 ? 2 : 3) : 0
        for (label, priority) in entries {
            guard result.count < limit else { break }
            let rect = CGRect(x: label.anchor.x - label.size.width / 2,
                              y: label.anchor.y - label.size.height - 8,
                              width: label.size.width, height: label.size.height)
            if placed.contains(where: { $0.intersects(rect) }) && priority < 100 { continue }
            placed.append(rect.insetBy(dx: -4, dy: -3))
            result.append(label)
        }
        labels = result
    }

    private func appLabel(_ node: AppNode, camera: Camera, viewport: SIMD2<Float>) -> AtlasLabel {
        let screen = camera.project(node.view.labelPosition, viewport: viewport)
        let host = node.stat.name
        let detail = "↓\(Format.bytes(node.stat.rxPerSecond))/s ↑\(Format.bytes(node.stat.txPerSecond))/s"
        let size = labelSize(host: host, key: "APP", badge: nil, detail: detail)
        return AtlasLabel(
            id: "host-app-label-\(node.stat.id)",
            kind: .device,
            anchor: CGPoint(x: CGFloat(screen.x), y: CGFloat(screen.y)),
            key: "APP",
            host: host,
            badge: nil,
            meta: "APP",
            detail: detail,
            blocked: false,
            hovered: hover?.appID == node.stat.id,
            selected: selection?.appID == node.stat.id,
            blur: 0,
            size: size,
            accessibilityLabel: "\(host), \(detail)",
            tone: .host
        )
    }

    private func domainLabel(_ node: DomainNode, camera: Camera, viewport: SIMD2<Float>) -> AtlasLabel {
        let screen = camera.project(node.view.labelPosition, viewport: viewport)
        let host = shortLabel(node.stat.name)
        let badge = node.stat.confidence.label.uppercased()
        let detail = "↓\(Format.bytes(node.stat.rxPerSecond))/s ↑\(Format.bytes(node.stat.txPerSecond))/s"
        let size = labelSize(host: host, key: String(node.stat.service.prefix(3)).uppercased(),
                             badge: badge, detail: detail)
        return AtlasLabel(
            id: "host-domain-label-\(node.stat.id)",
            kind: .destination,
            anchor: CGPoint(x: CGFloat(screen.x), y: CGFloat(screen.y)),
            key: String(node.stat.service.prefix(3)).uppercased(),
            host: host,
            badge: badge,
            meta: node.stat.isDomain ? "DOMAIN" : "IP:PORT",
            detail: detail,
            blocked: false,
            hovered: hover?.domainID == node.stat.id,
            selected: selection?.domainID == node.stat.id,
            blur: 0,
            size: size,
            accessibilityLabel: "\(host), \(detail)",
            tone: .host
        )
    }

    private func labelSize(host: String, key: String, badge: String?, detail: String) -> CGSize {
        let hostFont = NSFont.monospacedSystemFont(ofSize: 8.2, weight: .regular)
        let detailFont = NSFont.monospacedSystemFont(ofSize: 6.2, weight: .regular)
        let hostWidth = (host as NSString).size(withAttributes: [.font: hostFont]).width
        let detailWidth = (detail as NSString).size(withAttributes: [.font: detailFont]).width
        let width = max(hostWidth, detailWidth)
            + CGFloat(key.count) * 5.2 + CGFloat((badge ?? "").count) * 4.6 + 34
        return CGSize(width: max(96, min(330, width + 70)), height: 64)
    }

    private func shortLabel(_ text: String) -> String {
        if text.count <= 34 { return text }
        return String(text.prefix(31)) + "…"
    }

    // MARK: stats access for chrome

    func app(for id: String) -> HostAppStat? { appNodes[id]?.stat ?? snapshot.apps.first { $0.id == id } }
    func domain(for id: String) -> HostDomainStat? { domainNodes[id]?.stat ?? snapshot.domains.first { $0.id == id } }

    func focusPoint(for selection: HostSelection) -> (position: Vec3, target: Vec3)? {
        switch selection {
        case .app(let id):
            guard let node = appNodes[id] else { return nil }
            return (node.normal * 18 + Vec3(0, 0.8, 0), .zero)
        case .domain(let id):
            guard let node = domainNodes[id] else { return nil }
            return (node.view.basePosition.normalized * 18 + Vec3(0, 0.4, 0), .zero)
        }
    }

    private func shortName(_ name: String) -> String {
        let parts = name.split(separator: ".")
        if parts.count >= 2 { return parts.suffix(2).joined(separator: ".") }
        return name
    }

    private func stableSeed(_ text: String) -> UInt32 {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return UInt32(truncatingIfNeeded: hash)
    }
}
