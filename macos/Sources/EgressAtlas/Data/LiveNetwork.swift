import Foundation

/// Turn a bounded Pi-hole query sample into the same graph contract the demo
/// globe already renders. `population` decides whether every client/domain in
/// the sample is admitted or only the compact top-N graph; the history window
/// is applied later by the runtime, not by this builder.
enum LiveNetworkBuilder {
    private static let goldenAngle = Float.pi * (3 - sqrt(5))

    private struct ClientAgg {
        var ip: String
        var name: String = ""
        var total = 0
        var blocked = 0
        var lastSeen = 0.0
    }

    private struct DomainAgg {
        var domain: String
        var total = 0
        var blocked = 0
        var firstSeen = Double.infinity
        var lastSeen = 0.0
        var latencies: [Int] = []
    }

    private struct PairAgg {
        var clientIP: String
        var domain: String
        var total = 0
        var blocked = 0
        var lastSeen = 0.0
    }

    static func make(snapshot: PiHoleSnapshot, seed: Int = 20261116,
                     population: LivePopulation = .all) throws -> DemoNetwork {
        let rows = snapshot.rows
        guard !rows.isEmpty else {
            throw PiHoleError.malformed("No usable Pi-hole queries were returned.")
        }

        var clients: [String: ClientAgg] = [:]
        var domains: [String: DomainAgg] = [:]
        var pairs: [String: PairAgg] = [:]

        for row in rows {
            let ip = row.clientIP
            let domain = row.domain
            guard !ip.isEmpty, !domain.isEmpty else { continue }

            var client = clients[ip] ?? ClientAgg(ip: ip)
            if client.name.isEmpty, let name = row.clientName, !name.isEmpty, name != "pi.hole" {
                client.name = name
            }
            client.total += 1
            client.blocked += row.blocked ? 1 : 0
            client.lastSeen = max(client.lastSeen, row.timestamp)
            clients[ip] = client

            var destination = domains[domain] ?? DomainAgg(domain: domain)
            destination.total += 1
            destination.blocked += row.blocked ? 1 : 0
            destination.firstSeen = min(destination.firstSeen, row.timestamp)
            destination.lastSeen = max(destination.lastSeen, row.timestamp)
            if let latency = row.latencyMs, latency > 0 { destination.latencies.append(latency) }
            domains[domain] = destination

            let key = "\(ip)\u{0}\(domain)"
            var pair = pairs[key] ?? PairAgg(clientIP: ip, domain: domain)
            pair.total += 1
            pair.blocked += row.blocked ? 1 : 0
            pair.lastSeen = max(pair.lastSeen, row.timestamp)
            pairs[key] = pair
        }

        let sortedClients = clients.values.sorted {
            $0.total == $1.total ? $0.ip < $1.ip : $0.total > $1.total
        }
        let chosenClients: [ClientAgg]
        let chosenDomains: [DomainAgg]
        if let limit = population.limit {
            chosenClients = Array(sortedClients.prefix(limit))
            chosenDomains = chooseTop(domains, limit: limit)
        } else {
            chosenClients = sortedClients
            chosenDomains = domains.values.sorted {
                $0.total == $1.total ? $0.domain < $1.domain : $0.total > $1.total
            }
        }
        guard !chosenClients.isEmpty else {
            throw PiHoleError.malformed("No usable Pi-hole clients were returned.")
        }
        guard !chosenDomains.isEmpty else {
            throw PiHoleError.malformed("No usable Pi-hole destinations were returned.")
        }

        let clientIPs = Set(chosenClients.map(\.ip))
        let domainNames = Set(chosenDomains.map(\.domain))
        let includedPairs = pairs.values.filter {
            clientIPs.contains($0.clientIP) && domainNames.contains($0.domain)
        }

        var devices: [Device] = []
        for (index, client) in chosenClients.enumerated() {
            let y = 1 - ((Float(index) + 0.5) * 2) / Float(max(1, chosenClients.count))
            let ring = sqrt(max(0, 1 - y * y))
            let angle = Float(index) * goldenAngle
            let normal = Vec3(cos(angle) * ring, y, sin(angle) * ring).normalized
            let name = cleanName(client.name, fallback: client.ip)
            let spec = DeviceSpec(
                id: "live-device-\(index)",
                name: name,
                kind: "Pi-hole client",
                ip: client.ip,
                os: "live DNS client",
                lat: 0,
                lon: 0,
                weight: Float(client.total),
                thisMac: false,
                tone: "signal"
            )
            let device = Device(spec, surface: normal * 6, normal: normal)
            device.baseQueries = client.total
            device.baseBlocked = client.blocked
            device.liveQueries = client.total
            device.liveBlocked = client.blocked
            device.lastSeen = client.lastSeen
            devices.append(device)
        }

        var destinations: [Destination] = []
        for (index, domain) in chosenDomains.enumerated() {
            let blocked = isBlocked(domain)
            let status: DNSStatus = blocked ? .blocked : .allowed
            let now = Date().timeIntervalSince1970 * 1000
            let lastSeenHours = Float(max(0, (now - domain.lastSeen) / 3_600_000))
            let hash = fnv1a(domain.domain)
            let impact = blocked ? "containment" : ["eclipse", "prism", "ember", "resonance"][hash % 4]
            let birth = blocked ? "redaction" : ["spiral", "scan", "arc-weld", "seed"][hash % 4]
            let spec = DestinationSpec(
                id: "live-dest-\(index)",
                lastSeenHoursAgo: lastSeenHours,
                domain: domain.domain,
                short: String(domain.domain.split(separator: ".").first ?? "dns").prefix(22).description,
                category: category(for: domain.domain),
                status: status,
                weight: Float(domain.total),
                impactId: impact,
                birthId: birth,
                tone: blocked ? "blocked" : "allowed"
            )
            let destination = Destination(spec)
            destination.firstSeen = domain.firstSeen
            destination.lastSeen = domain.lastSeen
            destination.baseQueries = domain.total
            destination.baseBlocked = domain.blocked
            destination.liveQueries = domain.total
            destination.liveBlocked = domain.blocked
            destination.avgLatencyMs = blocked ? nil : average(domain.latencies)
            destinations.append(destination)
        }

        var edges: [Edge] = []
        for pair in includedPairs {
            guard let device = devices.first(where: { $0.ip == pair.clientIP }),
                  let destination = destinations.first(where: { $0.domain == pair.domain }) else { continue }
            let edge = Edge(device: device, destination: destination, weight: Float(pair.total))
            edge.baseQueries = pair.total
            edge.baseBlocked = pair.blocked
            edge.liveQueries = pair.total
            edge.liveBlocked = pair.blocked
            edge.lastSeen = pair.lastSeen
            edges.append(edge)
            device.edges.append(edge)
            destination.edges.append(edge)
            device.destinations.append(destination)
            destination.devices.append(device)
        }

        // Totals describe the admitted graph: every pair for `.all`, or only
        // the pairs inside the selected top-N cut. The history window is applied by
        // the runtime afterward.
        for device in devices {
            device.baseQueries = device.edges.reduce(0) { $0 + $1.baseQueries }
            device.baseBlocked = device.edges.reduce(0) { $0 + $1.baseBlocked }
            device.liveQueries = device.baseQueries
            device.liveBlocked = device.baseBlocked
        }
        for destination in destinations {
            destination.baseQueries = destination.edges.reduce(0) { $0 + $1.baseQueries }
            destination.baseBlocked = destination.edges.reduce(0) { $0 + $1.baseBlocked }
            destination.liveQueries = destination.baseQueries
            destination.liveBlocked = destination.baseBlocked
        }

        let network = DemoNetwork(seed: seed, devices: devices, destinations: destinations,
                                  edges: edges, localFlows: [])
        network.windowHours = Windows.defaultHours
        placeDestinations(network)
        for destination in destinations {
            destination.devices.sort { $0.weight > $1.weight }
        }
        network.rebuildTotals()
        return network
    }

    // MARK: - Layout

    private static func placeDestinations(_ network: DemoNetwork) {
        guard !network.destinations.isEmpty else { return }
        for (index, destination) in network.destinations.enumerated() {
            let total = destination.edges.reduce(0) { $0 + $1.weight }
            var centroid = Vec3.zero
            for edge in destination.edges {
                centroid += edge.device.normal * edge.weight
            }
            if centroid.lengthSq < 1e-5 {
                centroid = Vec3(0, 1, 0)
            }
            let concentration = total > 0 ? min(1, centroid.length / total) : 0
            let cameraDir = Vec3(13.2, 9.1, 26.4).normalized
            let right = Vec3.up.cross(cameraDir).normalized
            let upDir = cameraDir.cross(right).normalized
            let t = (Float(index) + 0.5) / Float(network.destinations.count)
            let screenAngle = goldenAngle * Float(index) + 0.38
            let affinityAngle = atan2(centroid.dot(upDir), centroid.dot(right))
            let angle = screenAngle * 0.72 + affinityAngle * 0.28
            let screenRadius = 6 * (0.34 + 0.5 * sqrt(t))
            let depth = (Float(index) / Float(max(1, network.destinations.count)) - 0.5) * 2.6 * (0.6 + concentration * 0.4)
            var direction = right * (cos(angle) * screenRadius)
                + upDir * (sin(angle) * screenRadius)
                + cameraDir * depth
            if direction.lengthSq < 0.01 {
                direction = centroid * 2.4
            }
            if direction.length > 4.82 {
                direction = direction.withLength(4.82)
            }
            destination.direction = direction.normalized
            destination.radius = direction.length
            destination.position = direction
        }

        let minGap: Float = 1.08
        for _ in 0..<90 {
            for i in 0..<network.destinations.count {
                for j in (i + 1)..<network.destinations.count {
                    let a = network.destinations[i]
                    let b = network.destinations[j]
                    var delta = a.position - b.position
                    let distance = max(0.0001, delta.length)
                    if distance < minGap {
                        let push = (minGap - distance) * 0.5
                        delta = delta.normalized
                        a.position += delta * push
                        b.position -= delta * push
                    }
                }
            }
            for destination in network.destinations {
                let radius = min(max(destination.position.length, 1.62), 4.86)
                destination.position = destination.position.withLength(radius)
                destination.direction = destination.position.normalized
                destination.radius = radius
            }
        }

        for destination in network.destinations {
            let volume = Float(destination.liveQueries)
            destination.visualRadius = 0.16 + log10(1 + volume) * 0.047
            destination.homeDirection = destination.direction.normalized
            destination.radialFraction = destination.position.length / 6
        }
    }

    // MARK: - Aggregation helpers

    private static func isBlocked(_ domain: DomainAgg) -> Bool {
        guard domain.total > 0 else { return false }
        return Double(domain.blocked) / Double(domain.total) >= 0.5
    }

    private static func chooseTop(_ domains: [String: DomainAgg], limit: Int) -> [DomainAgg] {
        let blocked = domains.values.filter { isBlocked($0) }
            .sorted { $0.total > $1.total }
        let allowed = domains.values.filter { !isBlocked($0) }
            .sorted { $0.total > $1.total }
        let blockedSlots = min(blocked.count, Swift.max(3, Int(ceil(Double(limit) * 0.22))))
        return (Array(blocked.prefix(blockedSlots)) + Array(allowed.prefix(limit - blockedSlots)))
            .sorted { $0.total > $1.total }
            .prefix(limit)
            .map { $0 }
    }

    private static func cleanName(_ raw: String, fallback: String) -> String {
        let clean = raw
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "&", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"\.local$"#, with: "", options: [.regularExpression, .caseInsensitive])
        let trimmed = String(clean.prefix(64))
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func category(for domain: String) -> String {
        let rules: [(String, String)] = [
            ("Tracking", #"(^|\.)(ads?|adservice|analytics|track|tracker|telemetry|metrics|doubleclick|pixel|sentry|stats?)\."#),
            ("CDN", #"(cdn|static|assets?|img|images?|edge|cloudfront|akamai|fastly|aaplimg|gstatic)"#),
            ("Developer", #"(github|gitlab|npmjs|pypi|stackoverflow|vercel|netlify|cloudflare)"#),
            ("Apple", #"(apple|icloud|mzstatic|aapl)"#),
            ("Google", #"(google|gstatic|youtube|ytimg|android|firebase)"#),
            ("Microsoft", #"(microsoft|windows|msft|bing|office|azure)"#),
            ("Local", #"(\.local$|\.lan$|\.home\.arpa$|\.arpa$)"#),
        ]
        for (name, pattern) in rules where domain.range(of: pattern, options: .regularExpression) != nil {
            return name
        }
        return "DNS"
    }

    private static func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    private static func fnv1a(_ value: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in value.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash)
    }
}
