import Foundation

/// Live query poller. The heavy six-hour graph is built once at connect time;
/// this class only imports new rows into that bounded graph and counts anything
/// outside the top-N snapshot as off-graph, matching the web source's contract.
final class PiHoleSource: AtlasTrafficSource {
    let network: DemoNetwork
    let client: PiHoleClient
    let kind = "pihole"
    let label = "Pi-hole live"
    let endpoint: String?
    let pollSeconds: Float? = 1.5
    let baseRate: Float = 0
    let rate: Float = 0
    var effectiveRate: Float { getQps() }
    private(set) var paused = false
    private(set) var speed: Float = 1
    private(set) var recent: [QueryEvent] = []
    private(set) var totalLive = 0
    var queryListeners: [(QueryEvent) -> Void] = []
    var localListeners: [(LocalTrafficEvent) -> Void] = []
    var statusListener: ((String?) -> Void)?

    private let deviceByIP: [String: Device]
    private let destinationByDomain: [String: Destination]
    private let edgeByKey: [String: Edge]
    private var seen: Set<String> = []
    private var deviceWindows: [String: [Double]] = [:]
    private var pollTimer: Timer?
    private var polling = false
    private var cancelled = false

    init(network: DemoNetwork, client: PiHoleClient, initial: PiHoleSnapshot) {
        self.network = network
        self.client = client
        self.endpoint = initial.endpoint
        var byIP: [String: Device] = [:]
        for device in network.devices { byIP[device.ip] = device }
        deviceByIP = byIP
        var byDomain: [String: Destination] = [:]
        for destination in network.destinations { byDomain[destination.domain] = destination }
        destinationByDomain = byDomain
        var byEdge: [String: Edge] = [:]
        for edge in network.edges { byEdge[edge.id] = edge }
        edgeByKey = byEdge
        for device in network.devices { deviceWindows[device.id] = [] }

        for row in initial.rows { seen.insert(row.id) }
        for row in initial.rows.suffix(40) {
            if let event = canonical(row) {
                deviceWindows[event.deviceId, default: []].append(event.ts)
                recent.insert(event, at: 0)
            }
        }
        if recent.count > 40 { recent = Array(recent.prefix(40)) }
    }

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.start() }
            return
        }
        guard pollTimer == nil else { return }
        cancelled = false
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        cancelled = true
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func update(realDt: Float) {
        // Polling is scheduled independently; the render loop does not block on
        // HTTP. Kept for the AtlasTrafficSource contract.
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    func setSpeed(_ speed: Float) {
        self.speed = speed
    }

    func setRate(_ rate: Float) {
        // The demo source owns this control; live polling is fixed at 1.5 s.
    }

    func getQps(_ deviceId: String? = nil) -> Float {
        let now = Date().timeIntervalSince1970 * 1000
        if let deviceId {
            return Float((deviceWindows[deviceId] ?? []).filter { $0 >= now - 6000 }.count) / 6
        }
        var total = 0
        for window in deviceWindows.values {
            total += window.filter { $0 >= now - 6000 }.count
        }
        return Float(total) / 6
    }

    private func poll() {
        guard !cancelled, !paused, !polling else { return }
        polling = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await client.poll()
                await MainActor.run {
                    guard !self.cancelled else { self.polling = false; return }
                    self.ingest(snapshot)
                    self.polling = false
                }
            } catch {
                await MainActor.run {
                    guard !self.cancelled else { self.polling = false; return }
                    self.statusListener?(error.localizedDescription)
                    self.polling = false
                }
            }
        }
    }

    private func ingest(_ snapshot: PiHoleSnapshot) {
        var newEvents: [QueryEvent] = []
        for row in snapshot.rows {
            if seen.contains(row.id) { continue }
            seen.insert(row.id)
            guard let event = canonical(row) else { continue }
            record(event)
            newEvents.append(event)
        }
        statusListener?(nil)
        if seen.count > 20_000 { seen = Set(seen.suffix(10_000)) }
    }

    private func canonical(_ row: PiHoleQueryRow) -> QueryEvent? {
        guard let device = deviceByIP[row.clientIP],
              let destination = destinationByDomain[row.domain],
              let edge = edgeByKey["\(device.id)::\(destination.id)"] else {
            return nil
        }
        return QueryEvent(
            id: row.id,
            ts: row.timestamp,
            device: device,
            destination: destination,
            edge: edge,
            latency: row.latencyMs
        )
    }

    private func record(_ event: QueryEvent) {
        let blocked = event.status == .blocked
        event.device.liveQueries += 1
        if blocked { event.device.liveBlocked += 1 }
        event.destination.liveQueries += 1
        if blocked { event.destination.liveBlocked += 1 }
        event.edge.liveQueries += 1
        if blocked { event.edge.liveBlocked += 1 }
        event.device.lastSeen = max(event.device.lastSeen, event.ts)
        event.destination.lastSeen = max(event.destination.lastSeen, event.ts)
        event.edge.lastSeen = max(event.edge.lastSeen, event.ts)
        network.rebuildTotals()

        deviceWindows[event.deviceId, default: []].append(event.ts)
        let cutoff = event.ts - 6000
        deviceWindows[event.deviceId] = deviceWindows[event.deviceId, default: []].filter { $0 >= cutoff }
        recent.insert(event, at: 0)
        if recent.count > 40 { recent.removeLast(recent.count - 40) }
        totalLive += 1
        for listener in queryListeners { listener(event) }
    }
}
