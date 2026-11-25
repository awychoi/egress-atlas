import Foundation
import Darwin

// MARK: - Observations

struct HostDnsObservation {
    let ip: String
    /// The application-facing name (the original query), not a CDN canonical.
    let domain: String
    let chain: [String]
    let at: Date
    let source: HostDomainAttributor.Source
}

// MARK: - dnsmasq log parser

/// Parses the lines exposed by Pi-hole v6 `/api/logs/dnsmasq` into exact
/// IP→domain observations. Only queries from this Mac are used; answer lines
/// are correlated to their query burst by name and time, with CNAME markers
/// kept in the chain so an Akamai/CloudFront canonical does not become the
/// label.
struct HostDnsmasqParser {
    private struct Burst {
        var domain: String       // original query, lower-case
        var client: String
        var at: Date
        var chain: [String]
    }

    private var bursts: [Burst] = []

    mutating func reset() {
        bursts.removeAll()
    }

    mutating func ingest(_ lines: [PiHoleLogLine],
                         localClients: Set<String>) -> [HostDnsObservation] {
        var observations: [HostDnsObservation] = []
        for line in lines {
            let at = Date(timeIntervalSince1970: line.timestamp)
            prune(at)
            let message = line.message
            let lower = message.lowercased()
            if lower.hasPrefix("query[") {
                parseQuery(message, at: at)
                continue
            }
            guard let answer = parseAnswer(message) else { continue }
            let name = answer.name.lowercased()
            if answer.value == "<cname>" {
                attachCNAME(name, at: at)
                continue
            }
            guard let ip = normalizedIP(answer.value) else { continue }
            guard let burst = matchBurst(name, at: at),
                  localClients.contains(burst.client) else { continue }
            observations.append(HostDnsObservation(
                ip: ip, domain: burst.domain, chain: burst.chain,
                at: at, source: .piholeLog
            ))
        }
        // A query burst can produce the same IP answer more than once (cache
        // replay, canonical and original names). Keep one observation per
        // application-facing name and address.
        var seen = Set<String>()
        return observations.filter { seen.insert("\($0.domain)|\($0.ip)").inserted }
    }

    private mutating func parseQuery(_ message: String, at: Date) {
        // query[A] example.com from 192.168.1.108
        let parts = message.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[2].lowercased() == "from" else { return }
        let domain = String(parts[1]).lowercased()
        let client = String(parts[3]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        guard !domain.isEmpty else { return }
        bursts.append(Burst(domain: domain, client: client, at: at, chain: [domain]))
        if bursts.count > 240 { bursts.removeFirst(bursts.count - 240) }
    }

    private func parseAnswer(_ message: String) -> (name: String, value: String)? {
        let parts = message.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }
        let kind = parts[0].lowercased()
        guard kind == "cached" || kind == "cached-stale" || kind == "reply" else { return nil }
        guard parts[2].lowercased() == "is" else { return nil }
        let name = String(parts[1])
        let value = String(parts[3]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        guard !name.isEmpty, !value.isEmpty else { return nil }
        return (name, value)
    }

    private mutating func attachCNAME(_ name: String, at: Date) {
        guard let index = burstIndex(containing: name, at: at, window: 5)
            ?? latestBurstIndex(at: at, window: 2.5) else { return }
        if !bursts[index].chain.contains(name) {
            bursts[index].chain.append(name)
            if bursts[index].chain.count > 12 { bursts[index].chain.removeFirst() }
        }
    }

    private func matchBurst(_ name: String, at: Date) -> Burst? {
        // Only an answer whose name is the query or part of its CNAME chain
        // is attributable. Guessing "the latest query" mislabels shared CDN
        // answers, which is exactly the failure mode this design avoids.
        if let index = burstIndex(containing: name, at: at, window: 5) {
            return bursts[index]
        }
        return nil
    }

    private func burstIndex(containing name: String, at: Date, window: TimeInterval) -> Int? {
        for index in bursts.indices.reversed() {
            let burst = bursts[index]
            guard abs(at.timeIntervalSince(burst.at)) <= window else { break }
            if burst.domain == name || burst.chain.contains(name) { return index }
        }
        return nil
    }

    private func latestBurstIndex(at: Date, window: TimeInterval) -> Int? {
        for index in bursts.indices.reversed() {
            let dt = abs(at.timeIntervalSince(bursts[index].at))
            if dt <= window { return index }
            if dt > 12 { break }
        }
        return nil
    }

    private mutating func prune(_ now: Date) {
        let cutoff = now.addingTimeInterval(-12)
        while let first = bursts.first, first.at < cutoff {
            bursts.removeFirst()
        }
    }

    private func normalizedIP(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        var addr4 = in_addr()
        var addr6 = in6_addr()
        if inet_pton(AF_INET, text, &addr4) == 1 { return text }
        if inet_pton(AF_INET6, text, &addr6) == 1 {
            if let percent = text.firstIndex(of: "%") { return String(text[..<percent]) }
            return text
        }
        return nil
    }
}

// MARK: - Poller

/// Long-lived cursor over `/api/logs/dnsmasq`. Pi-hole returns a ring of log
/// lines plus a `nextID`; this loop follows it, resets on an FTL restart and
/// never pretends a gap did not happen.
final class PiHoleDnsmasqStream {
    typealias Fetcher = (Int?) async throws -> PiHoleLogPage

    private let fetcher: Fetcher
    private let localClients: Set<String>
    private let interval: TimeInterval
    private var parser = HostDnsmasqParser()
    private var task: Task<Void, Never>?
    private var cursor: Int?
    private var pid: Int?
    private var stopped = true

    var onObservations: (([HostDnsObservation]) -> Void)?
    var onStatus: ((String?) -> Void)?

    init(localClients: Set<String>, interval: TimeInterval = 0.8,
         fetcher: @escaping Fetcher) {
        self.localClients = localClients
        self.interval = interval
        self.fetcher = fetcher
    }

    deinit {
        task?.cancel()
    }

    func start() {
        guard task == nil else { return }
        stopped = false
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
    }

    private func run() async {
        while !stopped, !Task.isCancelled {
            do {
                let page = try await fetcher(cursor)
                if let pid, page.pid != pid {
                    // FTL restarted its log; the old cursor is meaningless.
                    parser.reset()
                    cursor = page.nextID
                } else {
                    let observations = parser.ingest(page.lines, localClients: localClients)
                    if !observations.isEmpty {
                        onObservations?(observations)
                    }
                    cursor = page.nextID
                }
                if let pagePID = page.pid { pid = pagePID }
                postStatus(nil)
            } catch {
                postStatus(error.localizedDescription)
            }
            let ns = UInt64(max(0.2, interval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
        }
    }

    private func postStatus(_ message: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(message)
        }
    }
}
