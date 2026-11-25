import Foundation
import AppKit
import Darwin

// MARK: - Scope and domain

enum HostScope: String, CaseIterable, Identifiable {
    case internet
    case lan
    case vpn
    case loopback

    var id: String { rawValue }

    var title: String {
        switch self {
        case .internet: return "Internet"
        case .lan: return "LAN"
        case .vpn: return "VPN"
        case .loopback: return "Loopback"
        }
    }

    static func classify(_ host: String) -> HostScope {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" || h.hasPrefix("127.") || h.hasPrefix("fe80:")
            || h.hasPrefix("::ffff:127.") {
            return .loopback
        }
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            let b = withUnsafeBytes(of: &addr4.s_addr) { Array($0) }
            guard b.count == 4 else { return .internet }
            let first = b[0], second = b[1]
            if first == 10 { return .lan }
            if first == 192 && second == 168 { return .lan }
            if first == 172 && (16...31).contains(second) { return .lan }
            if first == 169 && second == 254 { return .lan }
            if first == 100 && (64...127).contains(second) { return .vpn }
            return .internet
        }
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            let b = withUnsafeBytes(of: &addr6) { Array($0) }
            if b.count == 16 {
                if b[0] & 0xfe == 0xfc { return .lan }        // fc00::/7 ULA
                if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 {
                    return .vpn                              // 2001:db8::/32 documentation range
                }
            }
            return .internet
        }
        return .internet
    }
}

enum HostDomainConfidence: Int, Comparable {
    case none = 0
    case service = 1
    case ptr = 2
    case temporal = 3
    case exact = 4

    static func < (lhs: HostDomainConfidence, rhs: HostDomainConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .none: return "IP ONLY"
        case .service: return "SERVICE"
        case .ptr: return "PTR"
        case .temporal: return "LIKELY"
        case .exact: return "MATCH"
        }
    }
}

struct HostDomainMatch: Equatable {
    let domain: String
    let confidence: HostDomainConfidence
    var service: String? = nil
}

// MARK: - Snapshot models

struct HostEndpointStat: Identifiable {
    let id: String
    let appID: String
    let remoteHost: String
    let remotePort: Int
    let proto: String
    let service: String
    let scope: HostScope
    var domain: String?
    var confidence: HostDomainConfidence
    var rxPerSecond: Double
    var txPerSecond: Double
    var rxTotal: UInt64
    var txTotal: UInt64
    var socketCount: Int
    var lastSeen: Date

    var displayName: String { domain ?? "\(remoteHost):\(remotePort)" }
}

struct HostAppStat: Identifiable {
    let id: String
    let name: String
    let detail: String
    let path: String
    let isSystem: Bool
    let icon: NSImage?
    var pids: Set<Int>
    var rxPerSecond: Double
    var txPerSecond: Double
    var rxTotal: UInt64
    var txTotal: UInt64
    var socketCount: Int
    var endpoints: [HostEndpointStat]

    var totalPerSecond: Double { rxPerSecond + txPerSecond }
}

struct HostDomainStat: Identifiable {
    let id: String
    let name: String
    let isDomain: Bool
    let scope: HostScope
    let confidence: HostDomainConfidence
    let service: String
    var rxPerSecond: Double
    var txPerSecond: Double
    var rxTotal: UInt64
    var txTotal: UInt64
    var appIDs: Set<String>
    var endpointIDs: Set<String>
    var lastSeen: Date

    var totalPerSecond: Double { rxPerSecond + txPerSecond }
}

struct HostTransfer: Identifiable {
    let id: String
    let appID: String
    let domainID: String
    let endpointID: String
    let domain: String?
    let service: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    let at: Date
}

struct HostRatePoint: Identifiable {
    let id = UUID()
    let rx: Double
    let tx: Double
}

struct HostSnapshot {
    let date: Date
    let apps: [HostAppStat]
    let endpoints: [HostEndpointStat]
    let domains: [HostDomainStat]
    let transfers: [HostTransfer]
    let history: [HostRatePoint]
    let rxPerSecond: Double
    let txPerSecond: Double
    let sessionRx: UInt64
    let sessionTx: UInt64
    let available: Bool
    let note: String?
    let enabledScopes: Set<HostScope>

    static let empty = HostSnapshot(
        date: Date(), apps: [], endpoints: [], domains: [], transfers: [],
        history: [], rxPerSecond: 0, txPerSecond: 0,
        sessionRx: 0, sessionTx: 0, available: true, note: nil,
        enabledScopes: [.internet, .lan, .vpn]
    )
}

// MARK: - Process identity

struct HostProcessIdentity {
    let appID: String
    let name: String
    let detail: String
    let path: String
    let isSystem: Bool
}

// MARK: - Monitor

/// Samples the Mac's own sockets once per second, diffs cumulative counters and
/// publishes a host-traffic snapshot. No root, no entitlements, no packet
/// capture: the data comes from the system's Apple-signed `netstat`.
final class HostTrafficMonitor {
    private(set) var snapshot: HostSnapshot = .empty
    var onSnapshot: ((HostSnapshot) -> Void)?

    /// The runtime installs a domain resolver here once a Pi-hole source is
    /// available. The closure must be thread-safe; it is called on the sampler
    /// queue.
    var domainLookup: ((_ host: String, _ port: Int, _ at: Date) -> HostDomainMatch?)?

    var enabledScopes: Set<HostScope> {
        get { queue.sync { scopes } }
        set {
            queue.async { [weak self] in
                guard let self else { return }
                self.scopes = newValue
                self.publishCurrent()
            }
        }
    }
    private var scopes: Set<HostScope> = [.internet, .lan, .vpn]

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
    private var iconCache: [String: NSImage?] = [:]
    private var failedSamples = 0
    private var note: String?

    private var history: [HostRatePoint] = []
    private var sessionRx: UInt64 = 0
    private var sessionTx: UInt64 = 0
    private var lastAppRates: [String: (rx: Double, tx: Double)] = [:]
    private var lastEndpointRates: [String: (rx: Double, tx: Double)] = [:]

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
    /// without spawning netstat or waiting for the timer.
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
        var seenKeys = Set<String>()
        _ = seenKeys

        for socket in sockets {
            let k = key(socket)
            seenKeys.insert(k)
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
            guard scopes.contains(scope) else { continue }
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
                    domainID: domainID(domain: endpoint.domain, endpoint: endpoint),
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
                icon: icon(for: app.identity),
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
            let id = domainID(domain: endpoint.domain, endpoint: (
                appID: endpoint.appID, host: endpoint.remoteHost, port: endpoint.remotePort,
                proto: endpoint.proto, service: endpoint.service, scope: endpoint.scope))
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
            enabledScopes: scopes
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

    private func domainID(domain: String?, endpoint: EndpointAccum) -> String {
        if let domain { return "d:\(domain)" }
        return "e:\(endpoint.host):\(endpoint.port)"
    }

    private func domainID(domain: String?, endpoint: (appID: String, host: String, port: Int, proto: String, service: String, scope: HostScope)) -> String {
        if let domain { return "d:\(domain)" }
        return "e:\(endpoint.host):\(endpoint.port)"
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

    private func icon(for identity: HostProcessIdentity) -> NSImage? {
        if let cached = iconCache[identity.appID] { return cached }
        var image: NSImage?
        if identity.path.contains(".app/") {
            image = NSWorkspace.shared.icon(forFile: identity.path)
        }
        if image == nil, identity.detail.contains("."),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: identity.detail).first {
            image = app.icon
        }
        iconCache[identity.appID] = image
        return image
    }
}

// MARK: - Process identity resolution

enum HostProcessIdentityResolver {
    private static let friendly: [String: String] = [
        "apsd": "Apple Push",
        "mDNSResponder": "DNS resolver",
        "rapportd": "Continuity",
        "nsurlsessiond": "Background downloads",
        "syslogd": "System log",
        "netbiosd": "NetBIOS",
        "configd": "Network config",
        "identityservicesd": "Identity services",
        "cloudd": "iCloud",
        "bird": "iCloud Drive",
        "sharingd": "AirDrop",
        "wifip2pd": "Wi-Fi peer-to-peer",
        "nesessionmanage": "Network sessions",
        "securityd": "Security",
    ]

    static func resolve(pid: Int) -> HostProcessIdentity {
        let path = procPath(pid)
        let running = NSRunningApplication(processIdentifier: pid_t(pid))
        let bundleID = running?.bundleIdentifier ?? ""
        let isSystem = isSystemPath(path)
        let display: String
        let detail: String
        let appID: String

        if let path, let appRange = path.range(of: ".app/") {
            let bundlePath = String(path[..<appRange.lowerBound]) + ".app"
            let bundleName = (bundlePath as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
            display = running?.localizedName ?? bundleName
            detail = bundleID.isEmpty ? bundleName : bundleID
            appID = bundleID.isEmpty ? "app:\(bundlePath)" : "app:\(bundleID)"
        } else if let path {
            let base = (path as NSString).lastPathComponent
            display = friendly[base] ?? base
            detail = isSystem ? "system service" : path
            appID = "svc:\(path)"
        } else if let running {
            display = running.localizedName ?? "pid \(pid)"
            detail = bundleID.isEmpty ? "pid \(pid)" : bundleID
            appID = bundleID.isEmpty ? "pid:\(pid)" : "app:\(bundleID)"
        } else {
            display = "pid \(pid)"
            detail = "process"
            appID = "pid:\(pid)"
        }
        return HostProcessIdentity(appID: appID, name: display, detail: detail,
                                   path: path ?? "", isSystem: isSystem)
    }

    private static func procPath(_ pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let count = proc_pidpath(Int32(pid), &buffer, UInt32(MAXPATHLEN))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func isSystemPath(_ path: String?) -> Bool {
        guard let path else { return true }
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/")
            || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/sbin/")
            || path.hasPrefix("/Library/SystemExtensions/")
    }
}

// MARK: - Service names

enum HostServiceNames {
    private static let known: [Int: String] = [
        20: "FTP data", 21: "FTP", 22: "SSH", 25: "SMTP", 53: "DNS",
        67: "DHCP", 68: "DHCP", 80: "HTTP", 88: "Kerberos", 110: "POP",
        123: "NTP", 135: "RPC", 137: "NetBIOS", 138: "NetBIOS", 139: "SMB",
        143: "IMAP", 161: "SNMP", 162: "SNMP", 179: "BGP", 389: "LDAP",
        443: "HTTPS", 445: "SMB", 465: "SMTPS", 500: "IKE", 514: "Syslog",
        548: "AFP", 587: "SMTP", 631: "IPP", 636: "LDAPS", 853: "DoT",
        993: "IMAPS", 995: "POP3S", 1900: "SSDP", 3306: "MySQL",
        3478: "STUN", 5222: "XMPP", 5223: "APNs", 5228: "FCM",
        5353: "mDNS", 5432: "Postgres", 7000: "AirPlay", 8000: "HTTP alt",
        8080: "HTTP alt", 8443: "HTTPS alt", 9090: "HTTP alt",
        49152: "Ephemeral", 51820: "WireGuard",
    ]

    static func name(port: Int, proto: String) -> String {
        if let name = known[port] { return name }
        if proto.hasPrefix("udp"), port > 1024 { return port == 5353 ? "mDNS" : "UDP" }
        if proto.hasPrefix("tcp") { return "TCP" }
        return "Socket"
    }
}

// MARK: - Local addresses

enum HostLocalAddresses {
    static func current() -> Set<String> {
        var addresses = Set<String>()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return addresses }
        defer { freeifaddrs(ifap) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let ifa = entry.pointee
            guard let addr = ifa.ifa_addr else {
                cursor = ifa.ifa_next
                continue
            }
            let family = addr.pointee.sa_family
            if family == AF_INET || family == AF_INET6 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                          &host, socklen_t(NI_MAXHOST), nil, 0,
                                          NI_NUMERICHOST)
                if result == 0 {
                    var text = String(cString: host)
                    if let percent = text.firstIndex(of: "%") {
                        text = String(text[..<percent])
                    }
                    let scope = HostScope.classify(text)
                    if scope == .lan || scope == .internet || scope == .vpn {
                        addresses.insert(text)
                    }
                }
            }
            cursor = ifa.ifa_next
        }
        return addresses
    }
}
