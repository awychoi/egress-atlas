import Foundation

/// One DNS query, the same event shape as LiveSource.js.
final class QueryEvent: Identifiable {
    let id: String
    let ts: Double
    let deviceId: String
    let destinationId: String
    let status: DNSStatus
    let latency: Int?
    unowned let device: Device
    unowned let destination: Destination
    unowned let edge: Edge

    init(id: String, ts: Double, device: Device, destination: Destination, edge: Edge, latency: Int?) {
        self.id = id
        self.ts = ts
        self.deviceId = device.id
        self.destinationId = destination.id
        self.status = destination.status
        self.latency = latency
        self.device = device
        self.destination = destination
        self.edge = edge
    }
}

struct LocalTrafficEvent {
    let source: Device
    let target: Device
    let service: String
}

/// Deterministic synthetic DNS traffic from app/src/data/LiveSource.js.
final class LiveSource: AtlasTrafficSource {
    let network: DemoNetwork
    var rng: RNG
    var baseRate: Float
    var rate: Float
    var effectiveRate: Float
    var paused = false
    var speed: Float = 1
    var accumulator: Float = 0
    var nextGap: Float
    var recent: [QueryEvent] = []
    var totalLive = 0
    var eventClock = 0
    private var deviceWindows: [String: [Double]] = [:]
    private var burst: (deviceId: String, factor: Float, remaining: Float)?
    private var nextBurst: Float
    private let localRate: Float = 0.68
    private var localAccumulator: Float = 0
    private var nextLocalGap: Float
    private var localCount = 0
    private var wakeClock: Float = 0
    private var nextWake: Float

    var queryListeners: [(QueryEvent) -> Void] = []
    var localListeners: [(LocalTrafficEvent) -> Void] = []

    var kind = "demo"
    var label = "Demo source"
    var endpoint: String? = nil
    var pollSeconds: Float? = nil

    init(network: DemoNetwork, seed: Int = 20261116, rate: Float = 2.85) {
        self.network = network
        self.rng = RNG(seed)
        let base = min(8, max(0.5, rate))
        self.baseRate = base
        self.baseRateOverride = base
        self.rate = base
        self.effectiveRate = base
        self.nextBurst = 16
        self.nextLocalGap = 2.2
        self.nextWake = 7
        self.nextGap = -log(1 - self.rng.next() * 0.999) / max(0.1, base)
        self.nextBurst = 16 + self.rng.next() * 10
        self.nextLocalGap = 2.2 + self.rng.next() * 1.6
        self.nextWake = 7 + self.rng.next() * 5
        for device in network.devices { deviceWindows[device.id] = [] }
        seedRecent()
    }

    private func gap() -> Float {
        -log(1 - rng.next() * 0.999) / max(0.1, rate)
    }

    private func localGap() -> Float {
        -log(1 - rng.next() * 0.999) / max(0.05, localRate)
    }

    private func seedRecent() {
        let now = Date().timeIntervalSince1970 * 1000
        for i in 0..<9 {
            guard let device = weightedDevice(), let edge = weightedEdge(device) else { continue }
            let ts = now - Double(9 - i) * Double(900 + rng.next() * 2600)
            _ = record(edge, ts: ts, push: true, count: false)
        }
    }

    private func weightedDevice() -> Device? {
        var total: Float = 0
        var weights: [Float] = []
        for d in network.devices {
            var w = d.weight
            if burst?.deviceId == d.id { w *= burst?.factor ?? 1 }
            total += w
            weights.append(w)
        }
        var pick = rng.next() * total
        for (i, d) in network.devices.enumerated() {
            pick -= weights[i]
            if pick <= 0 { return d }
        }
        return network.devices.last
    }

    private func weightedEdge(_ device: Device) -> Edge? {
        guard !device.edges.isEmpty else { return nil }
        var total: Float = 0
        var weights: [Float] = []
        for e in device.edges {
            var w = e.weight
            if e.destination.status == .blocked { w *= 0.78 }
            total += w
            weights.append(w)
        }
        var pick = rng.next() * total
        for (i, e) in device.edges.enumerated() {
            pick -= weights[i]
            if pick <= 0 { return e }
        }
        return device.edges.last
    }

    @discardableResult
    private func record(_ edge: Edge, ts: Double, push: Bool = true, count: Bool = true) -> QueryEvent {
        let destination = edge.destination
        let latency: Int? = destination.status == .blocked
            ? nil
            : Int(((destination.avgLatencyMs.map(Float.init) ?? 30) * (0.72 + rng.next() * 0.62)).rounded())
        eventClock += 1
        let event = QueryEvent(
            id: "q-\(Int(ts))-\(recent.count)-\(eventClock)",
            ts: ts,
            device: edge.device,
            destination: destination,
            edge: edge,
            latency: latency
        )
        edge.activity += 1
        if count {
            edge.liveQueries += 1
            edge.liveBlocked += destination.status == .blocked ? 1 : 0
            edge.lastSeen = ts
            edge.device.liveQueries += 1
            edge.device.liveBlocked += destination.status == .blocked ? 1 : 0
            edge.device.lastSeen = ts
            destination.liveQueries += 1
            destination.liveBlocked += destination.status == .blocked ? 1 : 0
            destination.lastSeen = ts
            network.rebuildTotals()
            totalLive += 1
        }
        if push {
            recent.insert(event, at: 0)
            if recent.count > 40 { recent.removeLast(recent.count - 40) }
            var window = deviceWindows[edge.deviceId] ?? []
            window.append(ts)
            let cutoff = ts - 6000
            while let first = window.first, first < cutoff { window.removeFirst() }
            deviceWindows[edge.deviceId] = window
        }
        return event
    }

    func start() {}
    func stop() {}

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused { accumulator = 0 }
    }

    func setSpeed(_ speed: Float) {
        guard speed > 0 else { return }
        self.speed = min(8, max(0.25, speed))
        rate = baseRate
        effectiveRate = baseRate * self.speed
    }

    func setRate(_ rate: Float) {
        guard rate > 0 else { return }
        baseRate = min(8, max(0.5, rate))
        self.rate = baseRate
        effectiveRate = baseRate * speed
    }

    private var baseRateOverride: Float = 2.85

    func update(realDt: Float) {
        guard !paused else { return }
        let dt = min(0.25, max(0, realDt)) * speed

        nextBurst -= dt
        if nextBurst <= 0 {
            let device = network.devices[Int(rng.next() * Float(network.devices.count)) % network.devices.count]
            burst = (device.id, 1.9, 3.2)
            nextBurst = 19 + rng.next() * 16
        }
        if var current = burst {
            current.remaining -= dt
            burst = current.remaining <= 0 ? nil : current
        }

        localAccumulator += dt
        var localSpawn = 0
        while localAccumulator >= nextLocalGap && localSpawn < 6 {
            localAccumulator -= nextLocalGap
            localSpawn += 1
            spawnLocal()
            nextLocalGap = localGap()
        }

        wakeClock += dt
        if wakeClock >= nextWake {
            wakeClock = 0
            nextWake = 8 + rng.next() * 6
            contactHiddenDestination()
        }

        accumulator += dt
        var spawn = 0
        while accumulator >= nextGap && spawn < 48 {
            accumulator -= nextGap
            spawn += 1
            spawnQuery()
            nextGap = gap()
        }
        if spawn >= 48 { accumulator = 0 }

        let decay = exp(-dt / 22)
        for edge in network.edges where edge.activity != 0 {
            edge.activity *= decay
        }
    }

    private func contactHiddenDestination() {
        let hidden = network.destinations.filter { !$0.windowVisible && !$0.edges.isEmpty }
        guard !hidden.isEmpty else { return }
        let destination = hidden[Int(rng.next() * Float(hidden.count)) % hidden.count]
        let edge = destination.edges[Int(rng.next() * Float(destination.edges.count)) % destination.edges.count]
        let event = record(edge, ts: Date().timeIntervalSince1970 * 1000)
        emit(event)
    }

    private func spawnQuery() {
        guard let device = weightedDevice(), let edge = weightedEdge(device) else { return }
        let event = record(edge, ts: Date().timeIntervalSince1970 * 1000)
        emit(event)
    }

    private func spawnLocal() {
        guard !network.localFlows.isEmpty else { return }
        var total: Float = 0
        for flow in network.localFlows { total += flow.weight }
        var pick = rng.next() * total
        var chosen = network.localFlows.last!
        for flow in network.localFlows {
            pick -= flow.weight
            if pick <= 0 { chosen = flow; break }
        }
        localCount += 1
        let pairKey = [chosen.source.id, chosen.target.id].sorted().joined(separator: "::")
        network.localActivity[pairKey, default: 0] += 1
        for listener in localListeners {
            listener(LocalTrafficEvent(source: chosen.source, target: chosen.target, service: chosen.service))
        }
    }

    private func emit(_ event: QueryEvent) {
        for listener in queryListeners { listener(event) }
    }

    func getQps(_ deviceId: String? = nil) -> Float {
        let now = Date().timeIntervalSince1970 * 1000
        if let deviceId {
            let window = deviceWindows[deviceId] ?? []
            return Float(window.filter { $0 >= now - 6000 }.count) / 6
        }
        var total = 0
        for window in deviceWindows.values {
            total += window.filter { $0 >= now - 6000 }.count
        }
        return Float(total) / 6
    }
}
