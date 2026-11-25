import Foundation

/// Owns the live HOST pipeline: the socket monitor, the domain attributor, the
/// Pi-hole dnsmasq stream, this Mac's interface addresses and the scope/pause
/// lifecycle. `AtlasRuntime` keeps the published state and the scene; results
/// travel back through the callbacks below, and a scope change resets the
/// passed-in scene because it invalidates every body.
final class HostInstrument {
    /// Called on the main queue with every sampled snapshot.
    var onSnapshot: ((HostSnapshot) -> Void)?
    /// Called on the main queue with the dnsmasq stream error, or nil when the
    /// stream stops or recovers.
    var onStatus: ((String?) -> Void)?

    private let scene: HostGlobeScene
    private var monitor: HostTrafficMonitor?
    private var domains: HostDomainAttributor?
    private var domainStream: PiHoleDnsmasqStream?
    private var localAddresses = HostLocalAddresses.current()

    init(scene: HostGlobeScene) {
        self.scene = scene
    }

    // MARK: sockets

    /// One-shot: `AtlasRuntime.start()` calls this once. Once the monitor
    /// exists (including after `stop()`) this is a no-op; the instrument is
    /// not restartable.
    func start() {
        guard monitor == nil else { return }
        localAddresses = HostLocalAddresses.current()
        let domains = HostDomainAttributor()
        let monitor = HostTrafficMonitor()
        installDomainLookup(on: monitor, domains: domains)
        monitor.onSnapshot = { [weak self] snapshot in
            // HostTrafficMonitor dispatches this to the main queue.
            self?.onSnapshot?(snapshot)
        }
        self.domains = domains
        self.monitor = monitor
        monitor.start()
    }

    /// Stop the sampler and the dnsmasq stream. The runtime calls this from
    /// its deinit and `deinit` below covers a standalone release. Teardown
    /// must not publish status, so this never calls `onStatus`.
    func stop() {
        monitor?.stop()
        domainStream?.stop()
        domainStream = nil
    }

    deinit {
        stop()
    }

    func setPaused(_ paused: Bool) {
        monitor?.setPaused(paused)
    }

    // MARK: scopes

    var scopes: Set<HostScope> {
        monitor?.enabledScopes ?? [.internet, .lan, .vpn]
    }

    func setScope(_ scope: HostScope, enabled: Bool) {
        guard let monitor else { return }
        var scopes = monitor.enabledScopes
        if enabled { scopes.insert(scope) } else { scopes.remove(scope) }
        if scopes.isEmpty { scopes.insert(.internet) }
        monitor.enabledScopes = scopes
        if scope == .loopback || !enabled { scene.reset() }
    }

    func setScopes(_ scopes: Set<HostScope>) {
        guard let monitor else { return }
        monitor.enabledScopes = scopes.isEmpty ? [.internet] : scopes
        scene.reset()
    }

    // MARK: domains

    func startDomainStream(client: PiHoleClient) {
        stopDomainStream()
        if domains == nil {
            let domains = HostDomainAttributor()
            self.domains = domains
            if let monitor {
                installDomainLookup(on: monitor, domains: domains)
            }
        }
        let clients = HostLocalAddresses.current()
        localAddresses = clients
        let stream = PiHoleDnsmasqStream(localClients: clients) {
            try await client.dnsmasqLog(nextID: $0)
        }
        stream.onObservations = { [weak self] observations in
            guard let self else { return }
            for observation in observations {
                self.domains?.recordAnswer(domain: observation.domain,
                                           ip: observation.ip,
                                           at: observation.at,
                                           chain: observation.chain)
            }
        }
        stream.onStatus = { [weak self] error in
            // PiHoleDnsmasqStream dispatches this to the main queue.
            self?.onStatus?(error)
        }
        domainStream = stream
        stream.start()
        AtlasDiagnostics.log("host domain stream started clients=\(clients.count)")
    }

    func stopDomainStream() {
        domainStream?.stop()
        domainStream = nil
        onStatus?(nil)
    }

    /// Record a DNS query made by this Mac. The caller filters to local client
    /// addresses with `isLocal(_:)` first.
    func record(domain: String, at date: Date) {
        domains?.record(domain: domain, at: date)
    }

    /// True when `ip` belongs to one of this Mac's interfaces.
    func isLocal(_ ip: String) -> Bool {
        localAddresses.contains(ip)
    }

    /// Seed the attributor from a live Pi-hole graph: recent local edges are
    /// already-known domain evidence.
    func seed(devices: [Device]) {
        guard let domains else { return }
        localAddresses = HostLocalAddresses.current()
        let cutoff = Date().addingTimeInterval(-300)
        for device in devices where localAddresses.contains(device.ip) {
            for edge in device.edges {
                let date = Date(timeIntervalSince1970: edge.lastSeen / 1000)
                guard date > cutoff else { continue }
                domains.record(domain: edge.destination.domain, at: date)
            }
        }
    }

    // MARK: private

    /// The monitor calls the installed lookup on its sampler queue;
    /// `HostDomainAttributor` guards its own state with a lock. The closure
    /// captures the attributor weakly so the monitor does not keep it alive.
    private func installDomainLookup(on monitor: HostTrafficMonitor,
                                     domains: HostDomainAttributor) {
        monitor.domainLookup = { [weak domains] host, port, date in
            guard let domains else { return nil }
            if let match = domains.match(host: host, port: port, at: date) {
                return match
            }
            domains.requestPTR(host: host)
            return nil
        }
    }
}
