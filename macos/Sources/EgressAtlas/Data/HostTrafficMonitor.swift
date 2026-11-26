import Foundation

// MARK: - Monitor

/// Samples the Mac's own sockets once per second, diffs cumulative counters and
/// publishes a host-traffic snapshot. No root, no entitlements, no packet
/// capture: it reads `/usr/bin/nettop` first and falls back to Apple-signed
/// `/usr/sbin/netstat`.
final class HostTrafficMonitor {
    private(set) var snapshot: HostSnapshot = .empty
    var onSnapshot: ((HostSnapshot) -> Void)?

    /// The runtime installs a domain resolver here once a Pi-hole source is
    /// available. The closure must be thread-safe; it is called on the sampler
    /// queue.
    var domainLookup: ((_ host: String, _ port: Int, _ at: Date) -> HostDomainMatch?)?

    /// Lock-backed so SwiftUI never waits on the sampler queue, which can be
    /// inside nettop for hundreds of milliseconds.
    var enabledScopes: Set<HostScope> {
        get {
            scopeLock.lock()
            defer { scopeLock.unlock() }
            return storedScopes
        }
        set {
            scopeLock.lock()
            storedScopes = newValue
            scopeLock.unlock()
            queue.async { [weak self] in
                self?.publishCurrent()
            }
        }
    }
    private let scopeLock = NSLock()
    private var storedScopes: Set<HostScope> = [.internet, .lan, .vpn]

    private let queue = DispatchQueue(label: "atlas.host.sampler", qos: .utility)
    private var timer: Timer?
    private var sampling = false
    private var stopped = true
    private var lastSampleDate: Date?
    private var didBaseline = false

    // Raw socket state.
    private var previous: [String: HostSocketSample] = [:]
    private var endpointAccum: [String: EndpointAccum] = [:]
    private var appAccum: [String: AppAccum] = [:]
    private var identityCache: [Int: HostProcessIdentity] = [:]
    private var failedSamples = 0
    private var note: String?

    private var history: [HostRatePoint] = []
    private var sessionRx: UInt64 = 0
    private var sessionTx: UInt64 = 0

    private struct EndpointAccum {
        var appID: String
        var host: String
        var port: Int
        var proto: String
        var service: String
        var scope: HostScope
        var domain: String?
        var confidence: HostDomainConfidence
        var domainCheckedAt = Date.distantPast
        var rxTotal: UInt64 = 0
        var txTotal: UInt64 = 0
        var rxRate: Double = 0
        var txRate: Double = 0
        var sockets = 0
        var lastSeen = Date()
        var firstSeen = Date()
    }

    private struct AppAccum {
        var identity: HostProcessIdentity
        var pids: Set<Int> = []
        var rxTotal: UInt64 = 0
        var txTotal: UInt64 = 0
        var rxRate: Double = 0
        var txRate: Double = 0
        var sockets = 0
        var endpointIDs: Set<String> = []
    }

    // MARK: lifecycle

    func start() {
        guard timer == nil else { return }
        stopped = false
        queue.async { [weak self] in
            self?.sample(first: true)
        }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
    }

    func setPaused(_ paused: Bool) {
        if paused {
            stop()
        } else if timer == nil {
            start()
        }
    }

    private func tick() {
        guard !sampling else { return }
        sampling = true
        queue.async { [weak self] in
            self?.sample(first: false)
            self?.sampling = false
        }
    }

    // MARK: sampling

    private func sample(first: Bool) {
        guard !stopped else { return }
        let now = Date()
        let dt = max(0.2, now.timeIntervalSince(lastSampleDate ?? now.addingTimeInterval(-1)))
        lastSampleDate = now
        var sockets = HostNettopSampler.sampleSystem()
        if sockets.isEmpty {
            // Nettop is the reliable path for a normally signed app. Keep
            // netstat as a fallback for environments where nettop is absent.
            sockets = HostTrafficParser.sampleSystem()
        }
        if sockets.isEmpty {
            failedSamples += 1
            if failedSamples >= 2 {
                note = "Host monitor unavailable — nettop and netstat returned no sockets."
            }
            publish(now: now, dt: dt, sockets: [], available: failedSamples < 2)
            return
        }
        failedSamples = 0
        note = nil
        process(sockets: sockets, now: now, dt: dt, baseline: first || !didBaseline)
    }

    /// Test hook: feed a socket table through the same delta/aggregation path
    /// without spawning nettop/netstat or waiting for the timer.
    func debugIngest(_ sockets: [HostSocketSample], at now: Date, dt: Double,
                     baseline: Bool = false) {
        process(sockets: sockets, now: now, dt: dt, baseline: baseline)
    }

    private func process(sockets: [HostSocketSample], now: Date, dt: Double,
                         baseline: Bool) {
        if baseline {
            didBaseline = true
            previous = Dictionary(uniqueKeysWithValues: sockets.map { (key($0), $0) })
            publish(now: now, dt: dt, sockets: sockets, available: true)
            return
        }

        var tickEndpointRx: [String: Double] = [:]
        var tickEndpointTx: [String: Double] = [:]
        var tickEndpointSockets: [String: Int] = [:]
        var transfers: [HostTransfer] = []

        for socket in sockets {
            let k = key(socket)
            let old = previous[k]
            var drx: UInt64 = 0
            var dtx: UInt64 = 0
            if let old {
                // A counter decrease means the socket was reset/reused.
                drx = socket.rxBytes >= old.rxBytes ? socket.rxBytes - old.rxBytes : socket.rxBytes
                dtx = socket.txBytes >= old.txBytes ? socket.txBytes - old.txBytes : socket.txBytes
            } else {
                // First observation after the baseline: every byte on this
                // socket was transferred since the previous sample.
                drx = socket.rxBytes
                dtx = socket.txBytes
            }
            guard drx > 0 || dtx > 0 else { continue }

            let scope = HostScope.classify(socket.remoteAddress)
            guard enabledScopes.contains(scope) else { continue }
            let identity = identity(for: socket.pid, scope: scope)
            let endpointID = endpointKey(appID: identity.appID, socket: socket)
            let service = HostServiceNames.name(port: socket.remotePort, proto: socket.proto)

            var endpoint = endpointAccum[endpointID] ?? EndpointAccum(
                appID: identity.appID, host: socket.remoteAddress, port: socket.remotePort,
                proto: socket.proto, service: service, scope: scope, domain: nil,
                confidence: .none
            )
            let shouldCheckDomain = endpoint.domain == nil
                || (endpoint.confidence < .exact
                    && now.timeIntervalSince(endpoint.domainCheckedAt) > 5)
            if shouldCheckDomain, let lookup = domainLookup {
                if let match = lookup(socket.remoteAddress, socket.remotePort, now),
                   endpoint.domain == nil || match.confidence >= endpoint.confidence {
                    endpoint.domain = match.domain
                    endpoint.confidence = match.confidence
                }
                endpoint.domainCheckedAt = now
            }
            endpoint.rxTotal += drx
            endpoint.txTotal += dtx
            endpoint.lastSeen = now
            endpoint.sockets += 1
            endpointAccum[endpointID] = endpoint

            var app = appAccum[identity.appID] ?? AppAccum(identity: identity)
            app.pids.insert(socket.pid)
            app.rxTotal += drx
            app.txTotal += dtx
            app.sockets += 1
            app.endpointIDs.insert(endpointID)
            appAccum[identity.appID] = app

            tickEndpointRx[endpointID, default: 0] += Double(drx)
            tickEndpointTx[endpointID, default: 0] += Double(dtx)
            tickEndpointSockets[endpointID, default: 0] += 1
            sessionRx += drx
            sessionTx += dtx

            if drx + dtx > 0 {
                transfers.append(HostTransfer(
                    id: "\(endpointID)-\(Int(now.timeIntervalSince1970 * 1000))-\(transfers.count)",
                    appID: identity.appID,
                    domainID: domainID(domain: endpoint.domain, host: endpoint.host,
                                       port: endpoint.port),
                    endpointID: endpointID,
                    domain: endpoint.domain,
                    service: service,
                    bytesIn: drx,
                    bytesOut: dtx,
                    at: now
                ))
            }
        }

        previous = Dictionary(uniqueKeysWithValues: sockets.map { (key($0), $0) })

        // Decay rates for endpoints that did not move this tick, then apply
        // the new deltas. A 1 s cadence with a short EMA keeps labels steady.
        let alpha = 0.42
        for (id, var endpoint) in endpointAccum {
            let rx = (tickEndpointRx[id] ?? 0) / dt
            let tx = (tickEndpointTx[id] ?? 0) / dt
            endpoint.rxRate = endpoint.rxRate * (1 - alpha) + rx * alpha
            endpoint.txRate = endpoint.txRate * (1 - alpha) + tx * alpha
            endpoint.sockets = tickEndpointSockets[id] ?? 0
            if now.timeIntervalSince(endpoint.lastSeen) > 60, endpoint.rxRate < 1, endpoint.txRate < 1 {
                endpointAccum.removeValue(forKey: id)
                for (appID, var app) in appAccum {
                    app.endpointIDs.remove(id)
                    appAccum[appID] = app
                }
            } else {
                endpointAccum[id] = endpoint
            }
        }
        for (id, var app) in appAccum {
            let rx = app.rxRate
            let tx = app.txRate
            app.rxRate = rx * (1 - alpha)
            app.txRate = tx * (1 - alpha)
            appAccum[id] = app
        }
        // App socket counts are the sum of their current endpoints.
        for (id, var app) in appAccum {
            app.sockets = app.endpointIDs.compactMap { endpointAccum[$0]?.sockets }.reduce(0, +)
            appAccum[id] = app
        }
        // Add the current tick's app deltas with a per-app accumulator.
        for (endpointID, rx) in tickEndpointRx {
            guard let endpoint = endpointAccum[endpointID] else { continue }
            var app = appAccum[endpoint.appID] ?? AppAccum(identity: identity(for: endpoint.appID))
            app.rxRate += (rx / dt) * alpha
            appAccum[endpoint.appID] = app
        }
        for (endpointID, tx) in tickEndpointTx {
            guard let endpoint = endpointAccum[endpointID] else { continue }
            var app = appAccum[endpoint.appID] ?? AppAccum(identity: identity(for: endpoint.appID))
            app.txRate += (tx / dt) * alpha
            appAccum[endpoint.appID] = app
        }

        // Remove apps that have had no sockets and no rate for a while.
        for (id, app) in appAccum {
            let last = app.endpointIDs.compactMap { endpointAccum[$0]?.lastSeen }.max()
            if app.sockets == 0, app.rxRate < 1, app.txRate < 1,
               let last, now.timeIntervalSince(last) > 90 {
                appAccum.removeValue(forKey: id)
            }
        }

        publish(now: now, dt: dt, sockets: sockets, available: true,
                transfers: transfers)
    }

    private func publish(now: Date, dt: Double, sockets: [HostSocketSample],
                         available: Bool, transfers: [HostTransfer] = []) {
        var apps: [HostAppStat] = []
        var endpoints: [HostEndpointStat] = []
        for app in appAccum.values {
            let domainEndpoints = app.endpointIDs.compactMap { endpointAccum[$0] }
            guard !domainEndpoints.isEmpty || app.rxRate + app.txRate > 0 else { continue }
            let endpointStats = domainEndpoints.map { endpoint in
                HostEndpointStat(
                    id: endpointKey(appID: endpoint.appID, host: endpoint.host,
                                    port: endpoint.port, proto: endpoint.proto),
                    appID: endpoint.appID,
                    remoteHost: endpoint.host,
                    remotePort: endpoint.port,
                    proto: endpoint.proto,
                    service: endpoint.service,
                    scope: endpoint.scope,
                    domain: endpoint.domain,
                    confidence: endpoint.confidence,
                    rxPerSecond: endpoint.rxRate,
                    txPerSecond: endpoint.txRate,
                    rxTotal: endpoint.rxTotal,
                    txTotal: endpoint.txTotal,
                    socketCount: endpoint.sockets,
                    lastSeen: endpoint.lastSeen
                )
            }.sorted { $0.rxPerSecond + $0.txPerSecond > $1.rxPerSecond + $1.txPerSecond }
            endpoints.append(contentsOf: endpointStats)
            apps.append(HostAppStat(
                id: app.identity.appID,
                name: app.identity.name,
                detail: app.identity.detail,
                path: app.identity.path,
                isSystem: app.identity.isSystem,
                pids: app.pids,
                rxPerSecond: app.rxRate,
                txPerSecond: app.txRate,
                rxTotal: app.rxTotal,
                txTotal: app.txTotal,
                socketCount: endpointStats.count,
                endpoints: endpointStats
            ))
        }
        apps.sort { $0.totalPerSecond > $1.totalPerSecond }
        endpoints.sort { $0.rxPerSecond + $0.txPerSecond > $1.rxPerSecond + $1.txPerSecond }

        // Domain rollup: inferred domains win over IP:port endpoints.
        var domainsByID: [String: HostDomainStat] = [:]
        for endpoint in endpoints {
            let id = domainID(domain: endpoint.domain, host: endpoint.remoteHost,
                              port: endpoint.remotePort)
            let name = endpoint.domain ?? "\(endpoint.remoteHost):\(endpoint.remotePort)"
            var domain = domainsByID[id] ?? HostDomainStat(
                id: id, name: name, isDomain: endpoint.domain != nil,
                scope: endpoint.scope, confidence: endpoint.confidence,
                service: endpoint.service, rxPerSecond: 0, txPerSecond: 0,
                rxTotal: 0, txTotal: 0, appIDs: [], endpointIDs: [],
                lastSeen: endpoint.lastSeen
            )
            domain.rxPerSecond += endpoint.rxPerSecond
            domain.txPerSecond += endpoint.txPerSecond
            domain.rxTotal += endpoint.rxTotal
            domain.txTotal += endpoint.txTotal
            domain.appIDs.insert(endpoint.appID)
            domain.endpointIDs.insert(endpoint.id)
            domain.lastSeen = max(domain.lastSeen, endpoint.lastSeen)
            domainsByID[id] = domain
        }
        let domains = domainsByID.values.sorted {
            $0.rxPerSecond + $0.txPerSecond > $1.rxPerSecond + $1.txPerSecond
        }

        let totalRx = apps.reduce(0) { $0 + $1.rxPerSecond }
        let totalTx = apps.reduce(0) { $0 + $1.txPerSecond }
        history.append(HostRatePoint(rx: totalRx, tx: totalTx))
        if history.count > 90 { history.removeFirst(history.count - 90) }

        let snapshot = HostSnapshot(
            date: now,
            apps: apps,
            endpoints: endpoints,
            domains: domains,
            transfers: transfers.sorted { $0.bytesIn + $0.bytesOut > $1.bytesIn + $1.bytesOut },
            history: history,
            rxPerSecond: totalRx,
            txPerSecond: totalTx,
            sessionRx: sessionRx,
            sessionTx: sessionTx,
            available: available,
            note: note,
            enabledScopes: enabledScopes
        )
        self.snapshot = snapshot
        DispatchQueue.main.async { [weak self] in
            self?.onSnapshot?(snapshot)
        }
    }

    private func publishCurrent() {
        guard didBaseline else { return }
        publish(now: Date(), dt: 1, sockets: [], available: true)
    }

    // MARK: keys and identity

    private func key(_ socket: HostSocketSample) -> String {
        "\(socket.proto)|\(socket.localAddress):\(socket.localPort)|\(socket.remoteAddress):\(socket.remotePort)|\(socket.pid)"
    }

    private func endpointKey(appID: String, socket: HostSocketSample) -> String {
        endpointKey(appID: appID, host: socket.remoteAddress,
                    port: socket.remotePort, proto: socket.proto)
    }

    private func endpointKey(appID: String, host: String, port: Int, proto: String) -> String {
        "\(appID)|\(proto)|\(host)|\(port)"
    }

    private func domainID(domain: String?, host: String, port: Int) -> String {
        if let domain { return "d:\(domain)" }
        return "e:\(host):\(port)"
    }

    private func identity(for pid: Int, scope: HostScope? = nil) -> HostProcessIdentity {
        if let cached = identityCache[pid] { return cached }
        let resolved = HostProcessIdentityResolver.resolve(pid: pid)
        identityCache[pid] = resolved
        return resolved
    }

    private func identity(for appID: String) -> HostProcessIdentity {
        if let found = identityCache.values.first(where: { $0.appID == appID }) { return found }
        return HostProcessIdentity(appID: appID, name: appID, detail: "host process",
                                   path: "", isSystem: false)
    }
}

