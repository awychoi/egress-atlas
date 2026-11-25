import Foundation
import Darwin

/// Maps live socket remote addresses to domain names using only unprivileged
/// data:
///
/// 1. recent DNS queries made by this Mac (fed from Pi-hole),
/// 2. local resolution of those domains (`getaddrinfo`), which gives exact
///    IP→domain mappings for the addresses the resolver currently returns,
/// 3. a short temporal window for a connection that follows a query,
/// 4. reverse DNS as a weaker fallback.
///
/// The method is deliberately explicit about confidence: an exact IP match is
/// different from "a domain was queried two seconds before this connection".
/// Unmatched endpoints stay IP:port in the UI.
final class HostDomainAttributor {
    enum Source {
        case piholeLog
        case active
        case ptr
    }

    struct Query {
        let domain: String
        let at: Date
    }

    private struct Candidate {
        let domain: String
        let at: Date
        let confidence: HostDomainConfidence
        let source: Source
    }

    private struct Resolution {
        let domain: String
        let at: Date
    }

    private let lock = NSLock()
    private let resolverQueue = DispatchQueue(label: "atlas.host.domain.resolve", qos: .utility)
    private let ptrQueue = DispatchQueue(label: "atlas.host.domain.ptr", qos: .utility)

    private var recent: [Query] = []
    private var ipCandidates: [String: [Candidate]] = [:]
    private var resolvedIPs: [String: (ips: Set<String>, at: Date)] = [:]
    private var pending: Set<String> = []
    private var ptrCache: [String: (name: String?, at: Date)] = [:]
    private var lastResolveAt = Date.distantPast
    private var enabled = true

    /// Injectable for tests. The default performs a real system lookup.
    var resolveHost: (String) -> [String] = HostDomainAttributor.systemResolve

    // MARK: input

    func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled
    }

    /// Record a DNS query made by this Mac. Pi-hole is the source of truth for
    /// *which* domains were queried; this class only turns them into addresses.
    func record(domain raw: String, at date: Date) {
        let domain = normalizedDomain(raw)
        guard !domain.isEmpty else { return }
        lock.lock()
        guard enabled else { lock.unlock(); return }
        recent.append(Query(domain: domain, at: date))
        if recent.count > 320 { recent.removeFirst(recent.count - 320) }
        let cutoff = date.addingTimeInterval(-600)
        while let first = recent.first, first.at < cutoff { recent.removeFirst() }
        let needsResolve = resolvedIPs[domain].map { date.timeIntervalSince($0.at) > 300 } ?? true
        let shouldResolve = needsResolve && !pending.contains(domain) && pending.count < 24
        if shouldResolve { pending.insert(domain) }
        lock.unlock()

        if shouldResolve {
            scheduleResolve(domain)
        }
    }

    /// Exact evidence from Pi-hole's dnsmasq log: this Mac queried `domain`
    /// and the answer contained `ip`. The original query, not a CDN canonical,
    /// is the label.
    func recordAnswer(domain raw: String, ip: String, at date: Date, chain: [String] = []) {
        let domain = normalizedDomain(raw)
        guard !domain.isEmpty, !ip.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        var list = ipCandidates[ip] ?? []
        list.removeAll { $0.domain == domain }
        list.append(Candidate(domain: domain, at: date,
                              confidence: .exact, source: .piholeLog))
        if list.count > 8 { list.removeFirst(list.count - 8) }
        ipCandidates[ip] = list
        // Keep the domain in the recent ring so the active-resolution fallback
        // can verify a chain later without another Pi-hole query.
        recent.append(Query(domain: domain, at: date))
        if recent.count > 320 { recent.removeFirst(recent.count - 320) }
    }

    // MARK: lookup

    func match(host: String, port: Int, at date: Date) -> HostDomainMatch? {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return nil }

        // Candidate evidence for this IP. Pi-hole log answers are exact; a
        // current local resolution is only a suggestion, and several hostnames
        // on one CDN IP must never collapse silently into one "MATCH".
        if var candidates = ipCandidates[host] {
            candidates.removeAll { date.timeIntervalSince($0.at) > 1_800 }
            ipCandidates[host] = candidates
            let uniqueDomains = Set(candidates.map(\.domain))
            if let best = candidates.max(by: { $0.at < $1.at }) {
                if uniqueDomains.count > 1 {
                    return HostDomainMatch(domain: best.domain, confidence: .temporal)
                }
                switch best.source {
                case .piholeLog:
                    return HostDomainMatch(domain: best.domain, confidence: .exact)
                case .active, .ptr:
                    return HostDomainMatch(domain: best.domain, confidence: .temporal)
                }
            }
        }

        if let cached = ptrCache[host], date.timeIntervalSince(cached.at) < 900,
           let name = cached.name, !name.isEmpty {
            return HostDomainMatch(domain: name, confidence: .ptr)
        }
        return nil
    }

    /// Called by the monitor when it sees an external endpoint with no match;
    /// reverse lookups are best-effort and rate-limited by the PTR queue.
    func requestPTR(host: String) {
        guard !host.isEmpty, HostScope.classify(host) != .loopback else { return }
        lock.lock()
        let cached = ptrCache[host]
        let should = enabled && (cached == nil || Date().timeIntervalSince(cached!.at) > 900)
        lock.unlock()
        guard should else { return }
        ptrQueue.async { [weak self] in
            let name = HostDomainAttributor.reverseName(host)
            guard let self else { return }
            self.lock.lock()
            self.ptrCache[host] = (name, Date())
            self.lock.unlock()
        }
    }

    // MARK: resolution

    private func scheduleResolve(_ domain: String) {
        resolverQueue.async { [weak self] in
            guard let self else { return }
            // A gentle rate limit keeps a query burst from turning into a DNS
            // burst of our own.
            self.lock.lock()
            let wait = max(0, 0.18 - Date().timeIntervalSince(self.lastResolveAt))
            self.lastResolveAt = Date()
            self.lock.unlock()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }

            let ips = self.resolveHost(domain)
            self.lock.lock()
            self.pending.remove(domain)
            self.resolvedIPs[domain] = (Set(ips), Date())
            for ip in ips {
                var list = self.ipCandidates[ip] ?? []
                list.removeAll { $0.domain == domain }
                list.append(Candidate(domain: domain, at: Date(),
                                      confidence: .temporal, source: .active))
                if list.count > 8 { list.removeFirst(list.count - 8) }
                self.ipCandidates[ip] = list
            }
            self.lock.unlock()
        }
    }

    /// Resolve a domain through the system resolver and return numeric
    /// addresses. Private/reserved answers (blocked Pi-hole replies) are
    /// discarded.
    static func systemResolve(_ domain: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(domain, nil, &hints, &info) == 0, let first = info else {
            return []
        }
        defer { freeaddrinfo(info) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            guard let addr = node.pointee.ai_addr else { cursor = node.pointee.ai_next; continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(NI_MAXHOST), nil, 0, NI_NUMERICHOST) == 0 {
                var text = String(cString: host)
                if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                let scope = HostScope.classify(text)
                if scope == .internet || scope == .lan || scope == .vpn {
                    addresses.append(text)
                }
            }
            cursor = node.pointee.ai_next
        }
        return Array(Set(addresses))
    }

    static func reverseName(_ host: String) -> String? {
        var storage = sockaddr_storage()
        var length: socklen_t = 0
        var addr4 = in_addr()
        var addr6 = in6_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            var sa = sockaddr_in()
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_addr = addr4
            memcpy(&storage, &sa, MemoryLayout<sockaddr_in>.size)
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        } else if inet_pton(AF_INET6, host, &addr6) == 1 {
            var sa = sockaddr_in6()
            sa.sin6_family = sa_family_t(AF_INET6)
            sa.sin6_addr = addr6
            memcpy(&storage, &sa, MemoryLayout<sockaddr_in6>.size)
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            return nil
        }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &name, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let text = String(cString: name).lowercased()
        guard !text.hasSuffix("in-addr.arpa"), !text.hasSuffix("ip6.arpa") else { return nil }
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    private func normalizedDomain(_ raw: String) -> String {
        var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if d.hasSuffix(".") { d.removeLast() }
        if d.isEmpty || d == "localhost" || d.hasSuffix(".local") { return "" }
        return d
    }
}
