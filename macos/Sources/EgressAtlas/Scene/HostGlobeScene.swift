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
    /// Mirrors the app's existing "Node recoil" preference. Impacts on host
    /// apps and destinations use the same switch as the DNS globe.
    var recoilEnabled = true
    /// Display-only host aliases supplied by the runtime. Keys are normalized
    /// app ids / destination names, matching the runtime preference keys.
    var hostAppAliases: [String: String] = [:]
    var hostDestinationAliases: [String: String] = [:]
    var showHostAliasWithAddress = false

    func setHostAliases(apps: [String: String], destinations: [String: String],
                        showBoth: Bool) {
        hostAppAliases = apps
        hostDestinationAliases = destinations
        showHostAliasWithAddress = showBoth
    }

    private func hostAliasKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var signals: [Signal] = []
    let effects = EffectHost()
    private var wireSignalCounts: [String: Int] = [:]
    private enum PendingBirth: Equatable {
        case app(String)
        case domain(String)
        var id: String {
            switch self {
            case .app(let id), .domain(let id): return id
            }
        }
    }
    private var birthQueue: [(birth: PendingBirth, at: Float)] = []
    private var pendingBirthIDs: Set<String> = []
    private var nextBirthAt: Float = 0
    private static let birthStride: Float = 0.055
    private var elapsed: Float = 0
    private var lastUpdate: Float = 0
    private var layoutDirty = true
    private var appSlot: [String: Int] = [:]
    private var nextSlot = 0
    private var rng = RNG(0x48a17)
    /// Separate stream for motion selection so layout/wire seeds stay stable.
    private var motionRng = RNG(0x4f3a21)
    private var motionStyleOverride: HostMotionStyle?
    /// Interface addresses captured once per scene. Used to recognise a
    /// destination that is this Mac itself, not only loopback.
    private let localHosts = HostLocalAddresses.current()
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
        var presenceDriven = false
        var lastSeen: Date
    }

    struct DomainNode {
        let destination: Destination
        let view: NodeView
        var stat: HostDomainStat
        var presence: Float = 0
        var targetPresence: Float = 1
        var presenceDriven = false
        var lastSeen: Date
        var appIDs: Set<String>
    }

    // MARK: lifecycle

    func reset() {
        appNodes.removeAll()
        domainNodes.removeAll()
        wires.removeAll()
        signals.removeAll()
        effects.clear()
        birthQueue.removeAll()
        pendingBirthIDs.removeAll()
        nextBirthAt = 0
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
        effects.clear()
        birthQueue.removeAll()
        pendingBirthIDs.removeAll()
        nextBirthAt = 0
        for (id, var node) in appNodes {
            node.presence = 1
            node.targetPresence = 1
            node.presenceDriven = false
            node.view.windowPresence = 1
            appNodes[id] = node
        }
        for (id, var node) in domainNodes {
            node.presence = 1
            node.targetPresence = 1
            node.presenceDriven = false
            node.view.presence = 1
            domainNodes[id] = node
        }
        for (_, wire) in wires {
            wire.reveal = 1
            wire.visibility = 1
            wire.endpointFade = 1
        }
        lastUpdate = 1.0
    }

    func clearEffectsForSnapshot() {
        effects.clear()
        for (id, var node) in appNodes {
            node.presenceDriven = false
            node.presence = node.targetPresence
            node.view.windowPresence = node.presence
            appNodes[id] = node
        }
        for (id, var node) in domainNodes {
            node.presenceDriven = false
            node.presence = node.targetPresence
            node.view.presence = node.presence
            domainNodes[id] = node
        }
    }

    func setRecoilEnabled(_ enabled: Bool) {
        recoilEnabled = enabled
        guard !enabled else { return }
        for (id, var node) in appNodes {
            node.view.stopRecoil()
            appNodes[id] = node
        }
        for (id, var node) in domainNodes {
            node.view.stopRecoil()
            domainNodes[id] = node
        }
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

        var newApps: [String] = []
        for stat in apps where appIDs.contains(stat.id) {
            if var node = appNodes[stat.id] {
                node.stat = stat
                node.lastSeen = snapshot.date
                node.targetPresence = pendingBirthIDs.contains(stat.id) ? 0 : 1
                let deathKey = "host:death:app:\(stat.id)"
                if effects.isActive(deathKey) {
                    effects.cancel(deathKey)
                    node.presenceDriven = false
                    node.presence = max(node.presence, 0.10)
                    node.view.windowPresence = node.presence
                }
                appNodes[stat.id] = node
            } else {
                var node = makeAppNode(stat, at: snapshot.date)
                node.targetPresence = 0
                appNodes[stat.id] = node
                newApps.append(stat.id)
                layoutDirty = true
            }
        }
        for (id, var node) in appNodes where !appIDs.contains(id) {
            birthQueue.removeAll { $0.birth == .app(id) }
            pendingBirthIDs.remove(id)
            let wasPresent = node.targetPresence != 0
            node.targetPresence = 0
            appNodes[id] = node
            if wasPresent {
                spawnAppRetire(node)
            }
            // Removing an app changes the affinity centroid of every domain
            // it touched, so the interior field needs a retarget pass.
            layoutDirty = true
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

        var newDomains: [String] = []
        for stat in domains where domainIDs.contains(stat.id) {
            if var node = domainNodes[stat.id] {
                node.stat = stat
                node.lastSeen = snapshot.date
                node.targetPresence = pendingBirthIDs.contains(stat.id) ? 0 : 1
                if node.appIDs != stat.appIDs { layoutDirty = true }
                node.appIDs = stat.appIDs
                let deathKey = "host:death:domain:\(stat.id)"
                if effects.isActive(deathKey) {
                    effects.cancel(deathKey)
                    node.presenceDriven = false
                    node.presence = max(node.presence, 0.10)
                    node.view.presence = node.presence
                }
                domainNodes[stat.id] = node
            } else {
                var node = makeDomainNode(stat, at: snapshot.date)
                node.targetPresence = 0
                node.view.presence = 0
                domainNodes[stat.id] = node
                newDomains.append(stat.id)
                layoutDirty = true
            }
        }
        for (id, var node) in domainNodes where !domainIDs.contains(id) {
            birthQueue.removeAll { $0.birth == .domain(id) }
            pendingBirthIDs.remove(id)
            let wasPresent = node.targetPresence != 0
            node.targetPresence = 0
            domainNodes[id] = node
            if wasPresent {
                spawnDomainRetire(node)
            }
            // Removing a domain changes the pairwise clearance for every
            // remaining inner body.
            layoutDirty = true
        }

        if layoutDirty { relayout() }
        for id in newApps { enqueueBirth(.app(id)) }
        for id in newDomains { enqueueBirth(.domain(id)) }
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
        releaseBirths()

        for (id, var node) in appNodes {
            if !node.presenceDriven {
                node.presence += (node.targetPresence - node.presence) * min(1, motionDt * 5.5)
            }
            // Only touch the visibility flag when the role actually changes.
            // Calling the setter every frame cleared the entry study before it
            // could play, which made new apps pop in with no arrival motion.
            if node.targetPresence > 0.5 && !node.view.windowVisible {
                // The host birth studies own the reveal now; keep the old
                // DeviceView bloom out of the way.
                node.view.setWindowVisible(true, animated: true, style: nil)
            } else if node.targetPresence <= 0.5 && node.view.windowVisible {
                node.view.setWindowVisible(false)
            }
            node.view.windowPresence = node.presence
            node.view.presenceScale = 0.32 + 0.68 * smoothstep(0, 0.55, node.presence)
            node.view.stagger = Float(stableSeed(id) % 7) / 7 * 0.10
            node.view.update(dt: motionDt, elapsed: elapsed, camera: camera)
            node.view.windowPresence = node.presence
            node.view.setHovered(selection?.appID == id || hover?.appID == id)
            node.view.setSelected(selection?.appID == id)
            node.view.setDimmed(selection?.appID != nil && selection?.appID != id)
            appNodes[id] = node
        }
        for (id, var node) in domainNodes {
            if !node.presenceDriven {
                node.presence += (node.targetPresence - node.presence) * min(1, motionDt * 5.5)
            }
            node.view.presence = node.presence
            node.view.presenceScale = 0.3 + 0.7 * smoothstep(0, 0.55, node.presence)
            node.view.update(dt: motionDt, elapsed: elapsed)
            // Keep the destination's derived fields on the travelling body,
            // not on the target slot it has not reached yet.
            let p = node.view.basePosition
            node.destination.position = p
            node.destination.direction = p.normalized
            node.destination.radius = p.length
            node.destination.homeDirection = p.normalized
            node.destination.radialFraction = p.length / 6
            node.view.setHovered(hover?.domainID == id)
            node.view.setSelected(selection?.domainID == id)
            node.view.setDimmed(selection?.domainID != nil && selection?.domainID != id)
            domainNodes[id] = node
        }

        // Remove fully faded bodies. Their wires are retired separately so the
        // line dissolves over a few frames instead of vanishing with the node.
        for (id, node) in appNodes where node.presence < 0.01 && node.targetPresence == 0
            && !pendingBirthIDs.contains(id) {
            appNodes.removeValue(forKey: id)
            appSlot.removeValue(forKey: id)
            for wire in wires.values where wire.deviceView?.spec.id == node.device.id {
                wire.retiring = true
            }
        }
        for (id, node) in domainNodes where node.presence < 0.01 && node.targetPresence == 0
            && !pendingBirthIDs.contains(id) {
            domainNodes.removeValue(forKey: id)
            for wire in wires.values where wire.nodeView?.id == node.view.id {
                wire.retiring = true
            }
        }
        if layoutDirty { relayout() }

        updateWires(camera: camera, dt: motionDt)
        updateSignals(motionDt)
        // The companion used to rebuild at 20 Hz. At background LOD that
        // stepping is visible as jitter, so it now follows the display rate.
        let rebuildInterval: Float = 1.0 / 60.0
        if lastUpdate >= rebuildInterval {
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
        view.setWindowVisible(true, animated: true, style: nil)
        return AppNode(device: device, view: view, stat: stat, normal: normal,
                       presence: 0, targetPresence: 1, lastSeen: date)
    }

    private func makeDomainNode(_ stat: HostDomainStat, at date: Date) -> DomainNode {
        let radius = max(0.16, 0.14 + log10(1 + Double(stat.rxTotal + stat.txTotal)) * 0.045)
        let local = isLocalDestination(stat)
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
            tone: local ? "hostLocal" : "host"
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
            tone: local ? "hostLocal" : "hostDomain"
        )
        let view = NodeView(spec: nodeSpec, radius: Float(radius),
                            index: domainNodes.count, rng: RNG(stableSeed(stat.id)))
        view.destinationRef = destination
        view.presence = 0
        view.presenceScale = 0.3
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
            node.view.setSurfacePosition(normal * 6, normal, animated: node.presence > 0.05)
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
            // A brand-new body starts at its final slot and plays its arrival
            // study there. An existing body is retargeted and travels.
            node.view.setBasePosition(position, animated: node.view.presence > 0.05)
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
        for (key, wire) in wires {
            if wanted[key] == nil {
                // Retire in place. Removing here made the line pop out while
                // its endpoints were still on stage.
                wire.retiring = true
            } else {
                wire.retiring = false
            }
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
            wire.visibility = 0
            wire.endpointFade = 0
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
        // A travelling body drags its wires with it. Rebuilding the curve is
        // cheap for the capped host population and makes the motion literal
        // instead of a stale line snapping at the end of a layout change.
        let moving = wires.values.contains {
            $0.deviceView.isMoving || $0.nodeView.isMoving
        }
        if moving { rebuildWirePaths() }

        var remove: [String] = []
        for (key, wire) in wires {
            wire.reveal = min(1, wire.reveal + dt * 2.8)
            wire.setDim(0.92)
            if let device = wire.deviceView {
                wire.setFacing(device.displayVisibility)
            }
            if wire.retiring {
                wire.visibility = max(0, wire.visibility - dt * 3.2)
            } else {
                wire.visibility = min(1, wire.visibility + dt * 3.2)
            }
            // A wire belongs to both bodies; it grows and dissolves with them.
            wire.endpointFade = min(wire.deviceView?.windowPresence ?? 0,
                                    wire.nodeView?.presence ?? 0)
            wire.setVisible(true)
            if wire.retiring && wire.visibility <= 0.001 { remove.append(key) }
        }
        for key in remove { wires.removeValue(forKey: key) }
    }

    // MARK: effects

    /// A fresh snapshot can return many new bodies at once. Releasing their
    /// arrival studies on a short stride gives a readable ripple instead of a
    /// stack of giant rings, and the body itself stays at zero presence until
    /// its slot is called.
    private func enqueueBirth(_ birth: PendingBirth) {
        guard !pendingBirthIDs.contains(birth.id) else { return }
        pendingBirthIDs.insert(birth.id)
        let due = max(elapsed, nextBirthAt)
        birthQueue.append((birth, due))
        nextBirthAt = due + Self.birthStride
    }

    private func releaseBirths() {
        while let first = birthQueue.first, elapsed + 0.0001 >= first.at {
            birthQueue.removeFirst()
            pendingBirthIDs.remove(first.birth.id)
            switch first.birth {
            case .app(let id):
                guard var node = appNodes[id], node.targetPresence == 0 else { continue }
                node.targetPresence = 1
                appNodes[id] = node
                spawnAppBirth(id)
            case .domain(let id):
                guard var node = domainNodes[id], node.targetPresence == 0 else { continue }
                node.targetPresence = 1
                domainNodes[id] = node
                spawnDomainBirth(id)
            }
        }
    }

    private func isLocalDestination(_ stat: HostDomainStat) -> Bool {
        if stat.scope == .loopback || stat.name == "localhost" || stat.name.hasPrefix("localhost:")
            || stat.name.hasPrefix("127.") || stat.name == "::1" || stat.name.hasPrefix("[::1]") {
            return true
        }
        var host = stat.name.split(separator: ":", maxSplits: 1).first.map(String.init) ?? stat.name
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return localHosts.contains(host)
    }

    @discardableResult
    private func addEffect(_ effect: EffectStudy, key: String, kind: String) -> Bool {
        guard effects.entries.count < 40 else { return false }
        effects.add(effect, origin: .zero, key: key, kind: kind)
        return true
    }

    private func pickMotionStyle(_ styles: [HostMotionStyle]) -> HostMotionStyle {
        if let override = motionStyleOverride, styles.contains(override) {
            return override
        }
        return styles[max(0, min(styles.count - 1, motionRng.int(styles.count)))]
    }

    private func safeNormal(_ value: Vec3, fallback: Vec3 = Vec3(0, 0, -1)) -> Vec3 {
        let length = value.lengthSq
        return length > 0.000001 ? value.normalized : fallback
    }

    /// Camera-facing halo normal with a little body bias, matching the web
    /// lab's readable birth/death rings.
    private func hostMotionNormal(for center: Vec3, bias: Vec3) -> Vec3 {
        let toCam = safeNormal(currentCamera.position - center, fallback: Vec3(0, 0, 1))
        return safeNormal(toCam + safeNormal(bias) * 0.28, fallback: toCam)
    }

    private func applyAppPresence(_ id: String, _ value: Float) {
        guard var node = appNodes[id] else { return }
        node.presence = clamp(value, 0, 1.08)
        node.view.windowPresence = node.presence
        appNodes[id] = node
    }

    private func finishAppPresence(_ id: String, value: Float, target: Float) {
        guard var node = appNodes[id] else { return }
        node.presenceDriven = false
        node.presence = clamp(value, 0, 1)
        node.targetPresence = target
        node.view.windowPresence = node.presence
        appNodes[id] = node
    }

    private func applyDomainPresence(_ id: String, _ value: Float) {
        guard var node = domainNodes[id] else { return }
        node.presence = clamp(value, 0, 1.08)
        node.view.presence = node.presence
        domainNodes[id] = node
    }

    private func finishDomainPresence(_ id: String, value: Float, target: Float) {
        guard var node = domainNodes[id] else { return }
        node.presenceDriven = false
        node.presence = clamp(value, 0, 1)
        node.targetPresence = target
        node.view.presence = node.presence
        domainNodes[id] = node
    }

    private func spawnAppBirth(_ id: String) {
        guard var node = appNodes[id] else { return }
        effects.cancel("host:birth:app:\(id)")
        node.presenceDriven = true
        node.presence = 0
        node.view.windowPresence = 0
        appNodes[id] = node
        let center = node.view.visualCenter
        let normal = hostMotionNormal(for: center, bias: node.normal)
        let style = pickMotionStyle(HostMotionCatalog.births(for: .app))
        let effect = HostMotionBirthEffect(style: style, point: center, normal: normal,
                                           radius: 0.3, body: .app,
                                           camera: currentCamera, rng: motionRng)
        effect.onPresence = { [weak self] value in
            self?.applyAppPresence(id, value)
        }
        effect.onFinish = { [weak self] in
            self?.finishAppPresence(id, value: 1, target: 1)
        }
        if !addEffect(effect, key: "host:birth:app:\(id)", kind: "host-birth-app") {
            finishAppPresence(id, value: 1, target: 1)
        }
    }

    private func spawnAppRetire(_ node: AppNode) {
        let id = node.stat.id
        effects.cancel("host:birth:app:\(id)")
        effects.cancel("host:death:app:\(id)")
        guard var current = appNodes[id] else { return }
        let start = clamp(current.presence, 0.05, 1)
        current.presenceDriven = true
        current.presence = start
        current.view.windowPresence = start
        appNodes[id] = current
        let center = current.view.visualCenter
        let normal = hostMotionNormal(for: center, bias: current.normal)
        let style = pickMotionStyle(HostMotionCatalog.deaths(for: .app))
        let effect = HostMotionDeathEffect(style: style, point: center, normal: normal,
                                           radius: 0.3, body: .app,
                                           camera: currentCamera,
                                           initialPresence: start, rng: motionRng)
        effect.onPresence = { [weak self] value in
            self?.applyAppPresence(id, value)
        }
        effect.onFinish = { [weak self] in
            self?.finishAppPresence(id, value: 0, target: 0)
        }
        if !addEffect(effect, key: "host:death:app:\(id)", kind: "host-death-app") {
            finishAppPresence(id, value: 0, target: 0)
        }
    }

    private func spawnDomainBirth(_ id: String) {
        guard var node = domainNodes[id] else { return }
        effects.cancel("host:birth:domain:\(id)")
        node.presenceDriven = true
        node.presence = 0
        node.view.presence = 0
        domainNodes[id] = node
        let center = node.view.basePosition
        let normal = hostMotionNormal(for: center, bias: center)
        let radius = max(0.24, node.view.radius * 1.55)
        let style = pickMotionStyle(HostMotionCatalog.births(for: .destination))
        let effect = HostMotionBirthEffect(style: style, point: center, normal: normal,
                                           radius: radius, body: .destination,
                                           camera: currentCamera, rng: motionRng)
        effect.onPresence = { [weak self] value in
            self?.applyDomainPresence(id, value)
        }
        effect.onFinish = { [weak self] in
            self?.finishDomainPresence(id, value: 1, target: 1)
        }
        if !addEffect(effect, key: "host:birth:domain:\(id)", kind: "host-birth-domain") {
            finishDomainPresence(id, value: 1, target: 1)
        }
    }

    private func spawnDomainRetire(_ node: DomainNode) {
        let id = node.stat.id
        effects.cancel("host:birth:domain:\(id)")
        effects.cancel("host:death:domain:\(id)")
        guard var current = domainNodes[id] else { return }
        let start = clamp(current.presence, 0.05, 1)
        current.presenceDriven = true
        current.presence = start
        current.view.presence = start
        domainNodes[id] = current
        let center = current.view.basePosition
        let normal = hostMotionNormal(for: center, bias: center)
        let radius = max(0.24, current.view.radius * 1.55)
        let style = pickMotionStyle(HostMotionCatalog.deaths(for: .destination))
        let effect = HostMotionDeathEffect(style: style, point: center, normal: normal,
                                           radius: radius, body: .destination,
                                           camera: currentCamera,
                                           initialPresence: start, rng: motionRng)
        effect.onPresence = { [weak self] value in
            self?.applyDomainPresence(id, value)
        }
        effect.onFinish = { [weak self] in
            self?.finishDomainPresence(id, value: 0, target: 0)
        }
        if !addEffect(effect, key: "host:death:domain:\(id)", kind: "host-death-domain") {
            finishDomainPresence(id, value: 0, target: 0)
        }
    }

    /// An external site answers with its reserved impact pair; a local address
    /// (this Mac) keeps the existing spark-free pulse. `normal` is the arrival
    /// tangent from the app, so the ring faces the direction of travel.
    private func spawnTransferArrival(node: DomainNode, normal: Vec3) {
        guard isActive, let current = domainNodes[node.stat.id] else { return }
        let local = isLocalDestination(current.stat)
        if local {
            current.view.flashAge = 0
            let effect = HostFieldEffect(style: .pulse, point: current.view.basePosition,
                                         normal: normal,
                                         radius: max(0.24, current.view.radius * 1.5),
                                         node: current.view, local: true, rng: rng)
            _ = addEffect(effect, key: "host:pulse:domain:\(current.stat.id)",
                          kind: "host-pulse")
            return
        }
        current.view.onHit(normal, recoil: recoilEnabled)
        let style = pickMotionStyle(HostMotionCatalog.impacts(for: .destination))
        let effect = HostMotionImpactEffect(style: style,
                                            point: current.view.basePosition,
                                            normal: normal,
                                            radius: max(0.24, current.view.radius * 1.55),
                                            body: .destination, rng: motionRng)
        _ = addEffect(effect, key: "host:impact:domain:\(current.stat.id)",
                      kind: "host-impact-destination")
    }

    private func spawnAppImpact(appID: String, normal: Vec3) {
        guard isActive, let node = appNodes[appID] else { return }
        let direction = safeNormal(normal, fallback: node.normal)
        node.view.onHit(direction, recoil: recoilEnabled)
        let style = pickMotionStyle(HostMotionCatalog.impacts(for: .app))
        let effect = HostMotionImpactEffect(style: style,
                                            point: node.view.visualCenter,
                                            normal: direction,
                                            radius: 0.3,
                                            body: .app, rng: motionRng)
        _ = addEffect(effect, key: "host:impact:app:\(appID)",
                      kind: "host-impact-app")
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
            node.view.appendDraw(draw, elapsed: elapsed, camera: currentCamera,
                                 detail: detail, depthFocus: false)
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
        // Presence studies must advance even while this globe is the dim
        // background companion. Draw into a scratch list at low detail so the
        // authored birth/death curves still finish, without adding foreground
        // effect geometry to the background layer.
        let effectsVisible = isActive && detail > 0.2
        if !effectsVisible { effectScratch.reset() }
        let ctx = EffectContext(camera: currentCamera, node: nil, radius: 0.3,
                                point: .zero, normal: .up, elapsed: elapsed,
                                onShake: { _ in }, rng: rng)
        effects.update(dt: max(0.001, min(0.1, lastUpdate)), ctx: ctx,
                       draw: effectsVisible ? draw : effectScratch)
        if isActive { HemisphereFocus.apply(to: draw, camera: currentCamera) }
    }

    private var currentCamera = Camera()
    private var effectScratch = DrawList()

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
            guard let wire = wires[wireKey], !wire.retiring,
                  wire.controlPoints.count >= 2,
                  appNodes[transfer.appID] != nil else { continue }
            let control = wire.controlPoints
            let arrivalNormal = wire.tangent
            let ingress = transfer.bytesIn > transfer.bytesOut
            // An inbound packet arrives at the app travelling from the
            // interior to the shell, i.e. opposite the app->domain tangent.
            let inboundNormal: Vec3
            if let curve = wire.curve {
                inboundNormal = safeNormal(curve.tangentAt(0) * -1,
                                           fallback: Vec3(0, 0, -1))
            } else {
                inboundNormal = safeNormal(arrivalNormal * -1,
                                           fallback: Vec3(0, 0, -1))
            }
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
                    if self.appNodes[appID] != nil {
                        self.spawnAppImpact(appID: appID, normal: inboundNormal)
                    }
                } else if let domain = self.domainNodes[targetNodeID] {
                    self.spawnTransferArrival(node: domain, normal: arrivalNormal)
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
        let host = hostAppAliases[hostAliasKey(node.stat.id)] ?? node.stat.name
        let detail = "↓\(Format.bytes(node.stat.rxPerSecond))/s ↑\(Format.bytes(node.stat.txPerSecond))/s"
        let interactive = hover?.appID == node.stat.id || selection?.appID == node.stat.id
        let opacity = HemisphereFocus.labelOpacity(node.view.visualCenter, camera: camera, interactive: interactive)
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
            size: size,
            accessibilityLabel: "\(host), \(node.stat.name), \(detail)",
            tone: .host,
            opacity: opacity
        )
    }

    private func domainLabel(_ node: DomainNode, camera: Camera, viewport: SIMD2<Float>) -> AtlasLabel {
        let screen = camera.project(node.view.labelPosition, viewport: viewport)
        let alias = hostDestinationAliases[hostAliasKey(node.stat.name)]
        let host = alias ?? shortLabel(node.stat.name)
        let local = isLocalDestination(node.stat)
        let badge = local ? "LOCAL" : node.stat.confidence.label.uppercased()
        let rate = "↓\(Format.bytes(node.stat.rxPerSecond))/s ↑\(Format.bytes(node.stat.txPerSecond))/s"
        let detail = alias != nil && showHostAliasWithAddress
            ? "\(node.stat.name) · \(rate)" : rate
        let interactive = hover?.domainID == node.stat.id || selection?.domainID == node.stat.id
        let opacity = HemisphereFocus.labelOpacity(node.view.basePosition, camera: camera, interactive: interactive)
        let size = labelSize(host: host, key: String(node.stat.service.prefix(3)).uppercased(),
                             badge: badge, detail: detail)
        return AtlasLabel(
            id: "host-domain-label-\(node.stat.id)",
            kind: .destination,
            anchor: CGPoint(x: CGFloat(screen.x), y: CGFloat(screen.y)),
            key: String(node.stat.service.prefix(3)).uppercased(),
            host: host,
            badge: badge,
            meta: local ? "THIS MAC" : (node.stat.isDomain ? "DOMAIN" : "IP:PORT"),
            detail: detail,
            blocked: false,
            hovered: hover?.domainID == node.stat.id,
            selected: selection?.domainID == node.stat.id,
            size: size,
            accessibilityLabel: local
                ? "\(host), \(node.stat.name), this Mac, \(detail)"
                : "\(host), \(node.stat.name), \(detail)",
            tone: .host,
            opacity: opacity
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

    // MARK: debug / self-test

    func debugEffectKinds() -> [String] { effects.entries.map(\.kind) }

    func debugEffectStyles() -> [String] {
        effects.entries.compactMap { entry in
            if let effect = entry.effect as? HostMotionImpactEffect { return effect.style.rawValue }
            if let effect = entry.effect as? HostMotionBirthEffect { return effect.style.rawValue }
            if let effect = entry.effect as? HostMotionDeathEffect { return effect.style.rawValue }
            return nil
        }
    }

    func debugSetMotionStyle(_ id: String?) {
        if let id, let style = HostMotionStyle(rawValue: id) {
            motionStyleOverride = style
        } else {
            motionStyleOverride = nil
        }
    }

    @discardableResult
    func debugTriggerArrival(domainID: String) -> Bool {
        guard let node = domainNodes[domainID] else { return false }
        spawnTransferArrival(node: node, normal: .up)
        return true
    }

    @discardableResult
    func debugTriggerAppImpact(appID: String) -> Bool {
        guard let node = appNodes[appID] else { return false }
        spawnAppImpact(appID: appID, normal: node.normal)
        return true
    }

    @discardableResult
    func debugRetireDomain(_ id: String) -> Bool {
        guard var node = domainNodes[id] else { return false }
        node.targetPresence = 0
        domainNodes[id] = node
        spawnDomainRetire(node)
        return true
    }

    @discardableResult
    func debugRetireApp(_ id: String) -> Bool {
        guard var node = appNodes[id] else { return false }
        node.targetPresence = 0
        appNodes[id] = node
        spawnAppRetire(node)
        return true
    }

    @discardableResult
    func debugMoveDomain(_ id: String, by offset: Vec3) -> Bool {
        guard let node = domainNodes[id] else { return false }
        node.view.setBasePosition(node.view.basePosition + offset, animated: true)
        return true
    }

    var debugPendingBirthCount: Int { birthQueue.count }

    /// Headless coverage for the HOST motion guarantees: every body gets an
    /// authored birth/death, app and destination impact pairs are distinct,
    /// impact recoil moves the right body, retirements outlive their topology
    /// change, and a relayout travels instead of teleporting.
    static func motionChecks() -> [String] {
        var failed: [String] = []
        failed.append(contentsOf: HostMotionCatalog.selfCheck())
        let styleDraw = motionStyleDrawChecks()
        failed.append(contentsOf: styleDraw)

        let scene = HostGlobeScene()
        let camera = Camera()
        scene.setCamera(camera)
        scene.setDetail(1, active: true)

        let base = HostDemo.snapshot(includeLocal: true)
        guard let external = base.domains.first(where: { $0.id == "d:github.com" }),
              let local = base.domains.first(where: { $0.scope == .loopback }) else {
            return failed + ["host-demo-missing-fixtures"]
        }
        let appID = "app:com.brave.Browser"
        guard base.apps.contains(where: { $0.id == appID }) else {
            return failed + ["host-app-fixture"]
        }
        scene.apply(base)
        if scene.appNodes.count != base.apps.count { failed.append("host-app-count") }
        if scene.domainNodes.count != base.domains.count { failed.append("host-domain-count") }
        if scene.debugPendingBirthCount == 0 { failed.append("host-birth-not-queued") }
        // The birth queue releases one body per stride, apps first. Give it
        // enough frames to include at least one app and one domain.
        for _ in 0..<14 { scene.update(dt: 0.05, camera: camera) }
        let birthKinds = scene.debugEffectKinds()
        if !birthKinds.contains("host-birth-app") { failed.append("host-birth-app-effect") }
        if !birthKinds.contains("host-birth-domain") { failed.append("host-birth-domain-effect") }
        if !scene.appNodes.values.contains(where: { $0.presenceDriven }) {
            failed.append("host-app-birth-presence")
        }
        if !scene.domainNodes.values.contains(where: { $0.presenceDriven }) {
            failed.append("host-domain-birth-presence")
        }

        for _ in 0..<48 { scene.update(dt: 0.05, camera: camera) }
        for app in scene.appNodes.values where app.presence < 0.9 {
            failed.append("host-app-settle")
            break
        }
        for node in scene.domainNodes.values where node.presence < 0.9 {
            failed.append("host-domain-settle")
            break
        }
        if scene.debugPendingBirthCount != 0 { failed.append("host-birth-queue-stuck") }

        // A local destination is mint and carries the THIS MAC badge.
        if scene.domainNodes[local.id]?.view.spec.tone != "hostLocal" {
            failed.append("host-local-tone")
        }
        scene.selection = .domain(local.id)
        scene.resolveLabels(camera: camera, viewSize: CGSize(width: 1600, height: 1000),
                            labelMode: .selected)
        if scene.labels.first?.badge != "LOCAL" { failed.append("host-local-badge") }
        if scene.labels.first?.meta != "THIS MAC" { failed.append("host-local-meta") }
        scene.selection = nil

        // The focus cut follows the camera, not the data. A body on the back
        // side must get a dimmer card than the same body after orbiting to the
        // front, and HOST aliases must reach both app and domain cards.
        let viewport = CGSize(width: 1600, height: 1000)
        let centerDepth = camera.viewDepth(of: .zero)
        let rankedApps = scene.appNodes.values.map {
            ($0.stat.id, camera.viewDepth(of: $0.view.visualCenter) - centerDepth)
        }.sorted { $0.1 < $1.1 }
        if let front = rankedApps.first, let back = rankedApps.last, front.0 != back.0 {
            func appCardOpacity(_ id: String, camera: Camera) -> Double? {
                scene.selection = .app(id)
                scene.resolveLabels(camera: camera, viewSize: viewport, labelMode: .selected)
                return scene.labels.first(where: { $0.id == "host-app-label-\(id)" })?.opacity
            }
            let frontOpacity = appCardOpacity(front.0, camera: camera)
            let backOpacity = appCardOpacity(back.0, camera: camera)
            let opposite = Camera(position: -camera.position, target: camera.target,
                                  fov: camera.fov, near: camera.near, far: camera.far,
                                  aspect: camera.aspect, up: camera.up)
            let flippedOpacity = appCardOpacity(back.0, camera: opposite)
            if (frontOpacity ?? 0) < 0.9 { failed.append("host-focus-front-card") }
            if (backOpacity ?? 1) > 0.8 { failed.append("host-focus-back-card") }
            if (flippedOpacity ?? 0) < 0.9 { failed.append("host-focus-camera-flip") }

            let appKey = back.0.lowercased()
            scene.setHostAliases(apps: [appKey: "Lab app"],
                                 destinations: [external.name.lowercased(): "Lab destination"],
                                 showBoth: true)
            scene.selection = .app(back.0)
            scene.resolveLabels(camera: camera, viewSize: viewport, labelMode: .selected)
            if scene.labels.first(where: { $0.id == "host-app-label-\(back.0)" })?.host != "Lab app" {
                failed.append("host-app-alias-card")
            }
            scene.selection = .domain(external.id)
            scene.resolveLabels(camera: camera, viewSize: viewport, labelMode: .selected)
            if let label = scene.labels.first(where: { $0.id == "host-domain-label-\(external.id)" }) {
                if label.host != "Lab destination" { failed.append("host-domain-alias-card") }
                if !label.detail.contains(external.name) { failed.append("host-domain-alias-show-both-card") }
            } else {
                failed.append("host-domain-alias-card-missing")
            }
            scene.setHostAliases(apps: [:], destinations: [:], showBoth: false)
        } else {
            failed.append("host-focus-fixture")
        }
        scene.selection = nil

        // Both destination impact picks are reachable; external arrivals
        // recoil; local addresses keep the existing spark-free pulse.
        for style in HostMotionCatalog.destinationImpacts {
            scene.effects.clear()
            scene.domainNodes[external.id]?.view.stopRecoil()
            scene.debugSetMotionStyle(style.rawValue)
            if !scene.debugTriggerArrival(domainID: external.id) {
                failed.append("host-external-trigger-\(style.rawValue)")
            }
            if !scene.debugEffectKinds().contains("host-impact-destination") {
                failed.append("host-impact-destination-\(style.rawValue)")
            }
            if !scene.debugEffectStyles().contains(style.rawValue) {
                failed.append("host-destination-style-\(style.rawValue)")
            }
            // The spring is authored for display-rate ticks; evaluate its
            // first frame at 60 Hz so the explicit integrator does not step
            // across zero in this headless harness.
            scene.update(dt: 1.0 / 60.0, camera: camera)
            if let node = scene.domainNodes[external.id] {
                if node.view.recoilOffset.length < 0.0005 {
                    failed.append("host-destination-recoil-\(style.rawValue)")
                }
                if node.view.recoilOffset.dot(.up) <= 0.00001 {
                    failed.append("host-destination-recoil-sign-\(style.rawValue)")
                }
            } else {
                failed.append("host-destination-recoil-missing")
            }
        }
        scene.effects.clear()
        scene.debugSetMotionStyle(nil)
        if !scene.debugTriggerArrival(domainID: local.id) { failed.append("host-local-trigger") }
        if !scene.debugEffectKinds().contains("host-pulse") { failed.append("host-pulse-effect") }
        scene.effects.clear()

        // Both app impact picks are reachable, and the app orb — not its pad —
        // takes the spring kick.
        for style in HostMotionCatalog.appImpacts {
            guard let app = scene.appNodes[appID] else {
                failed.append("host-app-impact-missing")
                break
            }
            scene.effects.clear()
            scene.appNodes[appID]?.view.stopRecoil()
            scene.debugSetMotionStyle(style.rawValue)
            if !scene.debugTriggerAppImpact(appID: appID) {
                failed.append("host-app-impact-trigger-\(style.rawValue)")
            }
            if !scene.debugEffectKinds().contains("host-impact-app") {
                failed.append("host-impact-app-\(style.rawValue)")
            }
            if !scene.debugEffectStyles().contains(style.rawValue) {
                failed.append("host-app-style-\(style.rawValue)")
            }
            scene.update(dt: 0.05, camera: camera)
            if let node = scene.appNodes[appID] {
                let moved = node.view.recoilOffset
                if moved.length < 0.0005 {
                    failed.append("host-app-recoil-\(style.rawValue)")
                }
                if moved.dot(app.normal) <= 0.00001 {
                    failed.append("host-app-recoil-sign-\(style.rawValue)")
                }
            } else {
                failed.append("host-app-recoil-missing")
            }
        }
        scene.effects.clear()
        scene.debugSetMotionStyle(nil)

        // Movement: remove a busy app, which changes the centroids of the
        // remaining domains. The target updates, but the body must not jump.
        let movedID = "d:api.github.com"
        guard let mover = scene.domainNodes[movedID] else { return failed + ["host-move-fixture"] }
        let before = mover.view.basePosition
        let cutDate = base.date.addingTimeInterval(1)
        let cut = HostSnapshot(
            date: cutDate,
            apps: base.apps,
            endpoints: base.endpoints,
            domains: base.domains.filter {
                $0.id != "d:github.com" && $0.id != "d:cdn.jsdelivr.net"
            },
            transfers: [], history: base.history,
            rxPerSecond: base.rxPerSecond, txPerSecond: base.txPerSecond,
            sessionRx: base.sessionRx, sessionTx: base.sessionTx,
            available: base.available, note: base.note,
            enabledScopes: base.enabledScopes)
        scene.apply(cut)
        // Direct spring check. The same code path is used by a graph retarget;
        // this fixture is independent of how much the relaxation happened to
        // shift a particular domain.
        if !scene.debugMoveDomain(movedID, by: Vec3(1.15, 0.25, -0.4)) {
            failed.append("host-move-fixture")
        }
        let targetAfter = scene.domainNodes[movedID]?.view.debugTargetPosition
        if targetAfter == nil { failed.append("host-move-no-target") }
        if let targetAfter {
            if scene.domainNodes[movedID]!.view.basePosition.distance(to: before) > 0.01 {
                failed.append("host-move-teleport")
            }
            scene.update(dt: 0.05, camera: camera)
            let moved = scene.domainNodes[movedID]!.view.basePosition.distance(to: before)
            let total = targetAfter.distance(to: before)
            if moved <= 0.0001 || moved >= total * 0.6 { failed.append("host-move-step") }
            for _ in 0..<48 { scene.update(dt: 0.05, camera: camera) }
            if scene.domainNodes[movedID]!.view.basePosition.distance(to: targetAfter) > 0.03 {
                failed.append("host-move-settle")
            }
        }

        // Retirement keeps the body alive long enough to animate out.
        let retiredApp = "app:com.tailscale.macos"
        let retiredDomain = "d:slack.com"
        let retire = HostSnapshot(
            date: cutDate.addingTimeInterval(1),
            apps: cut.apps.filter { $0.id != retiredApp },
            endpoints: cut.endpoints,
            domains: cut.domains.filter { $0.id != retiredDomain },
            transfers: [], history: cut.history,
            rxPerSecond: cut.rxPerSecond, txPerSecond: cut.txPerSecond,
            sessionRx: cut.sessionRx, sessionTx: cut.sessionTx,
            available: cut.available, note: cut.note,
            enabledScopes: cut.enabledScopes)
        scene.apply(retire)
        if let app = scene.appNodes[retiredApp] {
            if app.targetPresence != 0 { failed.append("host-retire-app-target") }
            if app.presence < 0.05 { failed.append("host-retire-app-pop") }
        } else {
            failed.append("host-retire-app-missing:\(scene.appNodes.keys.sorted())")
        }
        if let node = scene.domainNodes[retiredDomain] {
            if node.targetPresence != 0 { failed.append("host-retire-domain-target") }
            if node.presence < 0.05 { failed.append("host-retire-domain-pop") }
        } else {
            failed.append("host-retire-domain-missing")
        }
        let retireKinds = scene.debugEffectKinds()
        if !retireKinds.contains("host-death-app") { failed.append("host-death-app-effect") }
        if !retireKinds.contains("host-death-domain") { failed.append("host-death-domain-effect") }
        let retiringWire = scene.wires.values.first {
            $0.retiring || ($0.nodeView?.id.contains("slack.com") == true)
        }
        if retiringWire == nil { failed.append("host-retire-wire-missing") }
        for _ in 0..<48 { scene.update(dt: 0.05, camera: camera) }
        if scene.appNodes[retiredApp] != nil { failed.append("host-retire-app-stuck") }
        if scene.domainNodes[retiredDomain] != nil { failed.append("host-retire-domain-stuck") }

        return failed
    }

    /// Constructs and updates every reserved style once. This is a crash guard
    /// for the authored branches, not a pixel test.
    private static func motionStyleDrawChecks() -> [String] {
        var failed: [String] = []
        let camera = Camera()
        let normal = Vec3(0.3, 0.2, 0.93).normalized
        let point = Vec3(0, 5.1, 0)
        let context = EffectContext(camera: camera, node: nil, radius: 0.3,
                                    point: .zero, normal: .up, elapsed: 0.4,
                                    onShake: { _ in }, rng: RNG(11))
        for style in HostMotionStyle.allCases {
            let draw = DrawList()
            let rng = RNG(0x51a7)
            if style.isImpact {
                let effect = HostMotionImpactEffect(style: style, point: point,
                                                    normal: normal, radius: 0.4,
                                                    body: style == .ember || style == .prism
                                                        ? .destination : .app,
                                                    rng: rng)
                effect.update(dt: 1.0 / 60.0, age: 0.05, ctx: context, draw: draw)
                effect.update(dt: 1.0 / 60.0, age: effect.duration * 0.8,
                              ctx: context, draw: draw)
            } else if style.isBirth {
                let effect = HostMotionBirthEffect(style: style, point: point,
                                                   normal: normal, radius: 0.4,
                                                   body: style == .condense || style == .seed
                                                       ? .destination : .app,
                                                   camera: camera, rng: rng)
                effect.update(dt: 1.0 / 60.0, age: 0.05, ctx: context, draw: draw)
                effect.update(dt: 1.0 / 60.0, age: effect.duration * 0.8,
                              ctx: context, draw: draw)
            } else {
                let effect = HostMotionDeathEffect(style: style, point: point,
                                                   normal: normal, radius: 0.4,
                                                   body: style == .implode || style == .shear
                                                       ? .destination : .app,
                                                   camera: camera, initialPresence: 1,
                                                   rng: rng)
                effect.update(dt: 1.0 / 60.0, age: 0.05, ctx: context, draw: draw)
                effect.update(dt: 1.0 / 60.0, age: effect.duration * 0.8,
                              ctx: context, draw: draw)
            }
        }
        return failed
    }
}
