import Foundation

/// Live query poller. The heavy six-hour graph is built once at connect time;
/// this class only imports new rows into that bounded graph and counts anything
/// outside the top-N snapshot as off-graph.
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

    // MARK: - Replay

    /// Fetch a historical range from FTL's on-disk query database and map the
    /// rows onto the current graph. Long ranges are fetched in six-hour chunks
    /// so sampling stays spread across the whole window instead of keeping only
    /// the newest rows. Rows for clients or domains outside the current top-N
    /// graph are counted as skipped.
    func loadReplay(from startMS: Double, until endMS: Double,
                    maxEvents: Int = 60_000) async throws -> ReplayArchive {
        let span = max(1, endMS - startMS)
        let chunkMS = 6.0 * 3_600_000
        let chunks = max(1, min(28, Int(ceil(span / chunkMS))))
        let budget = max(300, maxEvents / chunks)
        // Read beyond the per-chunk budget before sampling. Picking evenly
        // across the scanned slice is much more representative than keeping
        // only the newest rows of every chunk.
        let scanBudget = min(10_000, max(budget * 4, 1_000))
        var events: [ReplayEvent] = []
        var seen = Set<String>()
        var scanned = 0
        var skipped = 0
        var earliest: Double?
        var diskSupported = true
        var truncated = false

        for index in 0..<chunks {
            let from = startMS + span * Double(index) / Double(chunks)
            let to = startMS + span * Double(index + 1) / Double(chunks)
            var snapshot: PiHoleSnapshot
            do {
                snapshot = try await client.history(from: from, until: to,
                                                    limit: scanBudget, disk: diskSupported)
            } catch {
                // Older FTL builds may reject the disk parameter. Fall back to
                // the in-memory log once, but do not hide a real network or
                // authentication failure.
                guard diskSupported,
                      let hole = error as? PiHoleError,
                      case .http(let message) = hole,
                      message.contains("400") || message.lowercased().contains("disk") else {
                    throw error
                }
                diskSupported = false
                snapshot = try await client.history(from: from, until: to,
                                                    limit: scanBudget, disk: false)
            }
            if earliest == nil {
                earliest = snapshot.earliestTimestampDisk ?? snapshot.earliestTimestamp
            }
            // FTL's recordsFiltered is the whole-database count, not the
            // range count, so use the scan budget saturation instead.
            if snapshot.rows.count >= scanBudget { truncated = true }
            scanned += snapshot.rows.count
            var chunkEvents: [ReplayEvent] = []
            for row in snapshot.rows {
                guard seen.insert(row.id).inserted else { continue }
                guard let event = replayEvent(row) else {
                    skipped += 1
                    continue
                }
                chunkEvents.append(event)
            }
            if chunkEvents.count > budget {
                chunkEvents = evenlySample(chunkEvents, target: budget)
                truncated = true
            }
            events.append(contentsOf: chunkEvents)
        }

        var archive = ReplayArchive.build(
            events: events,
            start: startMS,
            end: endMS,
            scannedRows: scanned,
            skippedRows: skipped,
            sourceLabel: diskSupported ? "Pi-hole history" : "Pi-hole recent",
            earliestAvailable: earliest
        )
        archive.sampled = archive.sampled || truncated
        return archive
    }

    private func evenlySample(_ events: [ReplayEvent], target: Int) -> [ReplayEvent] {
        guard events.count > target, target > 0 else { return events }
        var sampled: [ReplayEvent] = []
        sampled.reserveCapacity(target)
        let step = Double(events.count) / Double(target)
        for index in 0..<target {
            let offset = min(events.count - 1, Int(Double(index) * step))
            sampled.append(events[offset])
        }
        return sampled
    }

    private func replayEvent(_ row: PiHoleQueryRow) -> ReplayEvent? {
        guard let device = deviceByIP[row.clientIP],
              let destination = destinationByDomain[row.domain],
              edgeByKey["\(device.id)::\(destination.id)"] != nil else {
            return nil
        }
        return ReplayEvent(
            id: row.id,
            ts: row.timestamp,
            deviceId: device.id,
            destinationId: destination.id,
            latency: row.latencyMs,
            blocked: destination.status == .blocked
        )
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
