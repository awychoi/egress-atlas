import Foundation

// The product model from app/src/data/network.js. Reference types are used for
// the graph because the live source mutates counts on devices, destinations
// and edges in place, exactly like the web model.

enum DNSStatus: String, Hashable {
    case allowed
    case blocked
}

/// How much of the live Pi-hole snapshot is admitted to the globe. The
/// compact choices keep a live graph readable; `all` is available deliberately
/// for users who want to see every body and accept the overlap.
enum LivePopulation: CaseIterable, Identifiable {
    case top25
    case top50
    case top100
    case all

    static let defaultChoice: LivePopulation = .top100

    var id: String { storageValue }

    var limit: Int? {
        switch self {
        case .top25: return 25
        case .top50: return 50
        case .top100: return 100
        case .all: return nil
        }
    }

    var title: String { limit.map(String.init) ?? "All" }

    var detail: String {
        guard let limit else { return "Every client and domain in the loaded snapshot." }
        return "The busiest \(limit) clients and \(limit) destinations."
    }

    var storageValue: String { limit.map(String.init) ?? "all" }

    static func stored(_ raw: String) -> LivePopulation? {
        // Migrate the retired choices onto the four compact ones.
        if raw == "focused" || raw == "12" { return .top25 }
        if raw == "250" || raw == "500" { return .top100 }
        return allCases.first { $0.storageValue == raw }
    }
}

final class Device: Identifiable {
    /// The live source gives every client the same generic kind. The network
    /// index draws a compact glyph for it instead of repeating the words on
    /// every row, leaving room for the full IP address.
    static let piHoleClientKind = "Pi-hole client"

    let id: String
    let name: String
    let kind: String
    let ip: String
    let os: String
    let lat: Float
    let lon: Float
    let weight: Float
    let thisMac: Bool
    let tone: String

    var surface: Vec3
    var normal: Vec3
    var homeNormal: Vec3
    var baseQueries = 0
    var baseBlocked = 0
    var liveQueries = 0
    var liveBlocked = 0
    var lastSeen: Double = 0
    var qps: Float = 0
    var windowVisible = true
    var pendingAppearance = false
    var destinations: [Destination] = []
    var edges: [Edge] = []

    var isPiHoleClient: Bool { kind == Self.piHoleClientKind }

    init(_ spec: DeviceSpec, surface: Vec3, normal: Vec3) {
        id = spec.id
        name = spec.name
        kind = spec.kind
        ip = spec.ip
        os = spec.os
        lat = spec.lat
        lon = spec.lon
        weight = spec.weight
        thisMac = spec.thisMac
        tone = spec.tone
        self.surface = surface
        self.normal = normal
        homeNormal = normal
    }
}

struct DeviceSpec {
    let id: String
    let name: String
    let kind: String
    let ip: String
    let os: String
    let lat: Float
    let lon: Float
    let weight: Float
    let thisMac: Bool
    let tone: String
}

final class Destination: Identifiable {
    let id: String
    let lastSeenHoursAgo: Float
    let domain: String
    let short: String
    let category: String
    let status: DNSStatus
    let weight: Float
    let impactId: String
    let birthId: String
    let tone: String

    var baseQueries = 0
    var baseBlocked = 0
    var liveQueries = 0
    var liveBlocked = 0
    var firstSeen: Double
    var lastSeen: Double
    var windowVisible = true
    var homeDirection = Vec3.zero
    var radialFraction: Float = 0.5
    var avgLatencyMs: Int?
    var devices: [Device] = []
    var edges: [Edge] = []
    var position = Vec3.zero
    var direction = Vec3.zero
    var radius: Float = 0
    var visualRadius: Float = 0.2

    var key: String { String(category.prefix(3)).uppercased() }

    init(_ spec: DestinationSpec) {
        id = spec.id
        lastSeenHoursAgo = spec.lastSeenHoursAgo
        domain = spec.domain
        short = spec.short
        category = spec.category
        status = spec.status
        weight = spec.weight
        impactId = spec.impactId
        birthId = spec.birthId
        tone = spec.tone
        firstSeen = 0
        lastSeen = 0
    }
}

struct DestinationSpec {
    let id: String
    let lastSeenHoursAgo: Float
    let domain: String
    let short: String
    let category: String
    let status: DNSStatus
    let weight: Float
    let impactId: String
    let birthId: String
    let tone: String
}

final class Edge: Identifiable {
    let id: String
    let deviceId: String
    let destinationId: String
    unowned let device: Device
    unowned let destination: Destination
    let weight: Float
    var activity: Float = 0
    var baseQueries = 0
    var baseBlocked = 0
    var liveQueries = 0
    var liveBlocked = 0
    var lastSeen: Double = 0

    init(device: Device, destination: Destination, weight: Float) {
        deviceId = device.id
        destinationId = destination.id
        self.device = device
        self.destination = destination
        self.weight = weight
        id = "\(device.id)::\(destination.id)"
    }
}

final class LocalFlow: Identifiable {
    let source: Device
    let target: Device
    let weight: Float
    let service: String
    let id: String

    init(source: Device, target: Device, weight: Float, service: String) {
        self.source = source
        self.target = target
        self.weight = weight
        self.service = service
        id = "\(source.id)>\(target.id)"
    }
}

struct NetworkTotals: Equatable {
    var queries = 0
    var blocked = 0
    var allowed = 0
    var devices = 0
    var destinations = 0
    var paths = 0
    var blockedDestinations = 0
}

struct WindowStats: Equatable {
    var devices = 0
    var destinations = 0
    var allowed = 0
    var blockedDestinations = 0
    var queries = 0
    var blocked = 0
    var paths = 0
}

final class DemoNetwork {
    let seed: Int
    let radius: Float = 6
    let devices: [Device]
    let deviceById: [String: Device]
    let destinations: [Destination]
    let destinationById: [String: Destination]
    let edges: [Edge]
    let localFlows: [LocalFlow]
    var localActivity: [String: Int] = [:]
    var totals = NetworkTotals()
    var windowHours: Float = 168

    /// Used by the live snapshot builder. The demo constructor below remains
    /// the deterministic baseline; both paths end with the same graph contract.
    init(seed: Int, devices: [Device], destinations: [Destination],
         edges: [Edge], localFlows: [LocalFlow]) {
        self.seed = seed
        self.devices = devices
        self.destinations = destinations
        self.edges = edges
        self.localFlows = localFlows
        self.deviceById = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        self.destinationById = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0) })
        self.windowHours = 168
        rebuildTotals()
    }

    init(seed: Int) {
        self.seed = seed
        let now = Date().timeIntervalSince1970 * 1000
        var rng = RNG(seed)

        // Network.get devices from DEVICES.
        var builtDevices: [Device] = []
        for spec in Self.deviceSpecs {
            let surface = spherical(lat: spec.lat, lon: spec.lon, radius: 6)
            builtDevices.append(Device(spec, surface: surface, normal: surface.normalized))
        }
        devices = builtDevices
        deviceById = Dictionary(uniqueKeysWithValues: builtDevices.map { ($0.id, $0) })

        var builtDestinations: [Destination] = []
        for spec in Self.destinationSpecs {
            let d = Destination(spec)
            d.firstSeen = now - Double((2 + rng.next() * 15) * 86_400_000)
            d.lastSeen = now - Double(spec.lastSeenHoursAgo * 3_600_000)
            d.avgLatencyMs = spec.status == .blocked ? nil : Int((11 + rng.next() * 94).rounded())
            builtDestinations.append(d)
        }
        destinations = builtDestinations
        destinationById = Dictionary(uniqueKeysWithValues: builtDestinations.map { ($0.id, $0) })

        // Edges, in the exact insertion order of PROFILES.
        var builtEdges: [Edge] = []
        for (deviceId, profile) in Self.profiles {
            guard let device = deviceById[deviceId] else { continue }
            for (destinationId, weight) in profile {
                guard let destination = destinationById[destinationId] else { continue }
                let edge = Edge(device: device, destination: destination, weight: weight)
                builtEdges.append(edge)
                device.edges.append(edge)
                destination.edges.append(edge)
                device.destinations.append(destination)
                destination.devices.append(device)
            }
        }
        edges = builtEdges

        // A day's baseline.
        let baselineScale: Float = 2450
        for device in devices {
            device.baseQueries = Int((device.weight * baselineScale * (0.9 + rng.next() * 0.2)).rounded())
            device.baseBlocked = Int((Float(device.baseQueries) * (0.075 + rng.next() * 0.07)).rounded())
            device.lastSeen = now - Double(Int(rng.next() * 24) * 1000)
            device.liveQueries = device.baseQueries
            device.liveBlocked = device.baseBlocked
        }

        var totalWeight: Float = 0
        for edge in edges {
            totalWeight += edge.weight * (0.85 + rng.next() * 0.3)
        }
        let deviceQuerySum = devices.reduce(0) { $0 + $1.baseQueries }
        for edge in edges {
            let share = edge.weight * (0.85 + rng.next() * 0.3) / totalWeight
            let dayQueries = Int((share * Float(deviceQuerySum) * 1.18).rounded())
            let blockedShare: Float = edge.destination.status == .blocked ? 0.92 : 0.012
            edge.baseQueries = dayQueries
            edge.baseBlocked = Int((Float(dayQueries) * blockedShare).rounded())
            edge.liveQueries = edge.baseQueries
            edge.liveBlocked = edge.baseBlocked
            edge.lastSeen = edge.destination.lastSeen - Double(Int(rng.next() * 45) * 60_000)
            edge.destination.baseQueries += edge.baseQueries
            edge.destination.baseBlocked += edge.baseBlocked
        }
        for device in devices {
            device.baseQueries = device.edges.reduce(0) { $0 + $1.baseQueries }
            device.baseBlocked = device.edges.reduce(0) { $0 + $1.baseBlocked }
            device.liveQueries = device.baseQueries
            device.liveBlocked = device.baseBlocked
        }
        for destination in destinations {
            destination.liveQueries = destination.baseQueries
            destination.liveBlocked = destination.baseBlocked

            let total = destination.edges.reduce(0) { $0 + $1.weight }
            var centroid = Vec3.zero
            for edge in destination.edges {
                centroid += edge.device.normal * edge.weight
            }
            if centroid.lengthSq < 1e-5 {
                centroid = spherical(lat: rng.next() * 120 - 60, lon: rng.next() * 360)
            }
            let affinityLength = centroid.length
            let concentration = total > 0 ? min(1, affinityLength / total) : 0

            let index = builtDestinations.firstIndex(where: { $0 === destination }) ?? 0
            let golden = Float.pi * (3 - sqrt(5))
            let cameraDir = Vec3(13.2, 9.1, 26.4).normalized
            let right = Vec3.up.cross(cameraDir).normalized
            let upDir = cameraDir.cross(right).normalized
            let t = (Float(index) + 0.5) / Float(destinations.count)
            let screenAngle = golden * Float(index) + 0.38
            let affinityAngle = atan2(centroid.dot(upDir), centroid.dot(right))
            let angle = screenAngle * 0.72 + affinityAngle * 0.28
            let screenRadius = 6 * (0.34 + 0.5 * sqrt(t))
            let depth = (rng.next() - 0.5) * 2.6 * (0.6 + concentration * 0.4)
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

        // Deterministic relaxation of the constellation.
        let minGap: Float = 1.08
        for _ in 0..<90 {
            for i in 0..<builtDestinations.count {
                let a = builtDestinations[i]
                for j in (i + 1)..<builtDestinations.count {
                    let b = builtDestinations[j]
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
            for d in builtDestinations {
                let radius = min(max(d.position.length, 1.62), 4.86)
                d.position = d.position.withLength(radius)
                d.direction = d.position.normalized
                d.radius = radius
            }
        }

        for destination in builtDestinations {
            let volume = Float(destination.baseQueries)
            destination.visualRadius = 0.16 + log10(1 + volume) * 0.047
            destination.homeDirection = destination.direction.normalized
            destination.radialFraction = destination.position.length / 6
        }

        for device in devices {
            device.destinations = rng.shuffle(device.destinations)
        }
        for destination in builtDestinations {
            destination.devices.sort { $0.weight > $1.weight }
        }

        let flowSpecs: [(String, String, Float, String)] = [
            ("iphone-15", "living-room-tv", 1.5, "AirPlay"),
            ("work-laptop", "studio-mac", 1.0, "Screen share"),
            ("kids-ipad", "homepod-mini", 0.8, "AirPlay"),
            ("atlas-nas", "living-room-tv", 1.25, "Plex"),
            ("work-laptop", "atlas-nas", 0.7, "Backup"),
            ("living-room-tv", "iphone-15", 0.55, "Remote"),
            ("roborock", "iphone-15", 0.35, "Status"),
        ]
        let lookup = deviceById
        localFlows = flowSpecs.compactMap { sourceId, targetId, weight, service in
            guard let source = lookup[sourceId], let target = lookup[targetId] else { return nil }
            return LocalFlow(source: source, target: target, weight: weight, service: service)
        }

        rebuildTotals()
    }

    func rebuildTotals() {
        totals.queries = devices.reduce(0) { $0 + $1.liveQueries }
        totals.blocked = devices.reduce(0) { $0 + $1.liveBlocked }
        totals.allowed = totals.queries - totals.blocked
        totals.devices = devices.count
        totals.destinations = destinations.count
        totals.paths = edges.count
        totals.blockedDestinations = destinations.filter { $0.status == .blocked }.count
    }

    func windowStats() -> WindowStats {
        let visible = destinations.filter(\.windowVisible)
        let visibleDevices = devices.filter(\.windowVisible)
        let paths = visible.reduce(0) { count, destination in
            count + destination.edges.reduce(0) { edgeCount, edge in
                edgeCount + (edge.device.windowVisible ? 1 : 0)
            }
        }
        return WindowStats(
            devices: visibleDevices.count,
            destinations: visible.count,
            allowed: visible.filter { $0.status == .allowed }.count,
            blockedDestinations: visible.filter { $0.status == .blocked }.count,
            queries: visible.reduce(0) { $0 + $1.liveQueries },
            blocked: visible.reduce(0) { $0 + $1.liveBlocked },
            paths: paths
        )
    }

    // ── Data (verbatim from network.js) ──────────────────────────────────

    static let deviceSpecs: [DeviceSpec] = [
        DeviceSpec(id: "work-laptop", name: "work-laptop", kind: "MacBook Pro", ip: "10.0.0.24", os: "macOS 15.2", lat: 26, lon: 10, weight: 1.35, thisMac: true, tone: "signal"),
        DeviceSpec(id: "studio-mac", name: "studio-mac", kind: "Mac Studio", ip: "10.0.0.12", os: "macOS 15.1", lat: 40, lon: 47, weight: 1.05, thisMac: false, tone: "signal"),
        DeviceSpec(id: "iphone-15", name: "iphone-15", kind: "iPhone 15 Pro", ip: "10.0.0.42", os: "iOS 18.2", lat: 2, lon: -35, weight: 1.5, thisMac: false, tone: "signal"),
        DeviceSpec(id: "living-room-tv", name: "living-room-tv", kind: "Apple TV 4K", ip: "10.0.0.31", os: "tvOS 18.1", lat: -13, lon: 30, weight: 0.95, thisMac: false, tone: "signal"),
        DeviceSpec(id: "kids-ipad", name: "kids-ipad", kind: "iPad Air", ip: "10.0.0.38", os: "iPadOS 18.2", lat: -39, lon: -12, weight: 0.8, thisMac: false, tone: "signal"),
        DeviceSpec(id: "homepod-mini", name: "homepod-mini", kind: "HomePod mini", ip: "10.0.0.17", os: "audioOS 18.1", lat: 49, lon: -55, weight: 0.5, thisMac: false, tone: "signal"),
        DeviceSpec(id: "atlas-nas", name: "atlas-nas", kind: "Synology NAS", ip: "10.0.0.8", os: "DSM 7.2", lat: -47, lon: 69, weight: 0.62, thisMac: false, tone: "signal"),
        DeviceSpec(id: "roborock", name: "roborock", kind: "Roborock S8", ip: "10.0.0.55", os: "firmware 02.31", lat: 16, lon: 122, weight: 0.24, thisMac: false, tone: "signal"),
        DeviceSpec(id: "office-printer", name: "office-printer", kind: "HP LaserJet", ip: "10.0.0.61", os: "firmware 4.8", lat: -24, lon: 142, weight: 0.16, thisMac: false, tone: "signal"),
    ]

    static let destinationSpecs: [DestinationSpec] = [
        DestinationSpec(id: "edge-cdn", lastSeenHoursAgo: 0.18, domain: "cdn.edge.example", short: "cdn.edge", category: "CDN", status: .allowed, weight: 1.55, impactId: "eclipse", birthId: "spiral", tone: "allowed"),
        DestinationSpec(id: "brand-assets", lastSeenHoursAgo: 0.45, domain: "assets.brand-cdn.net", short: "brand-cdn", category: "Assets", status: .allowed, weight: 0.95, impactId: "prism", birthId: "scan", tone: "allowed"),
        DestinationSpec(id: "github-api", lastSeenHoursAgo: 0.3, domain: "api.github.com", short: "github-api", category: "Developer", status: .allowed, weight: 0.78, impactId: "eclipse", birthId: "arc-weld", tone: "allowed"),
        DestinationSpec(id: "media-edge", lastSeenHoursAgo: 0.22, domain: "media-edge.example.net", short: "media-edge", category: "Streaming", status: .allowed, weight: 1.2, impactId: "ember", birthId: "seed", tone: "allowed"),
        DestinationSpec(id: "productivity", lastSeenHoursAgo: 0.6, domain: "productivity.cloud", short: "productivity", category: "SaaS", status: .allowed, weight: 0.68, impactId: "resonance", birthId: "scan", tone: "allowed"),
        DestinationSpec(id: "pihole-telemetry", lastSeenHoursAgo: 0.4, domain: "telemetry.pihole.local", short: "pihole", category: "Network", status: .allowed, weight: 0.55, impactId: "resonance", birthId: "spiral", tone: "allowed"),
        DestinationSpec(id: "quad9", lastSeenHoursAgo: 192, domain: "dns.quad9.net", short: "quad9", category: "DNS", status: .allowed, weight: 0.46, impactId: "eclipse", birthId: "arc-weld", tone: "allowed"),
        DestinationSpec(id: "apple-updates", lastSeenHoursAgo: 0.8, domain: "updates.apple.com", short: "apple-updates", category: "Software", status: .allowed, weight: 0.42, impactId: "eclipse", birthId: "scan", tone: "allowed"),
        DestinationSpec(id: "typekit", lastSeenHoursAgo: 2.5, domain: "fonts.typekit.net", short: "typekit", category: "Assets", status: .allowed, weight: 0.33, impactId: "prism", birthId: "seed", tone: "allowed"),
        DestinationSpec(id: "apple-time", lastSeenHoursAgo: 7, domain: "time.apple.com", short: "apple-time", category: "Network", status: .allowed, weight: 0.24, impactId: "eclipse", birthId: "spiral", tone: "allowed"),
        DestinationSpec(id: "ad-tracker", lastSeenHoursAgo: 0.12, domain: "ads.tracker.example", short: "ads.tracker", category: "Advertising", status: .blocked, weight: 1.02, impactId: "containment", birthId: "redaction", tone: "blocked"),
        DestinationSpec(id: "ad-metrics", lastSeenHoursAgo: 0.5, domain: "metrics.ad-network.com", short: "ad-metrics", category: "Advertising", status: .blocked, weight: 0.7, impactId: "containment", birthId: "redaction", tone: "blocked"),
        DestinationSpec(id: "trackhub", lastSeenHoursAgo: 72, domain: "beacon.trackhub.io", short: "trackhub", category: "Analytics", status: .blocked, weight: 0.48, impactId: "containment", birthId: "redaction", tone: "blocked"),
        DestinationSpec(id: "spyware", lastSeenHoursAgo: 30, domain: "telemetry.spyware.example", short: "spyware", category: "Malware", status: .blocked, weight: 0.28, impactId: "containment", birthId: "redaction", tone: "blocked"),
    ]

    static let profiles: [(String, [(String, Float)])] = [
        ("work-laptop", [("edge-cdn", 4.4), ("github-api", 3.3), ("productivity", 2.4), ("typekit", 1.1), ("brand-assets", 0.9), ("ad-tracker", 1.15), ("apple-updates", 0.5)]),
        ("studio-mac", [("edge-cdn", 3.2), ("github-api", 2.5), ("brand-assets", 2.2), ("productivity", 0.9), ("apple-time", 0.5), ("ad-metrics", 0.45)]),
        ("iphone-15", [("edge-cdn", 3.8), ("media-edge", 2.8), ("productivity", 0.8), ("ad-tracker", 2.1), ("ad-metrics", 1.5), ("trackhub", 0.9), ("apple-updates", 0.8), ("spyware", 0.28)]),
        ("living-room-tv", [("media-edge", 5.6), ("edge-cdn", 2.6), ("ad-tracker", 1.5), ("trackhub", 0.6), ("apple-updates", 0.3)]),
        ("kids-ipad", [("media-edge", 3.2), ("edge-cdn", 2.1), ("ad-tracker", 2.0), ("trackhub", 1.2), ("brand-assets", 0.5), ("spyware", 0.18)]),
        ("homepod-mini", [("edge-cdn", 2.0), ("pihole-telemetry", 0.8), ("apple-time", 0.6), ("ad-metrics", 0.4)]),
        ("atlas-nas", [("brand-assets", 3.0), ("apple-updates", 2.2), ("edge-cdn", 1.4), ("pihole-telemetry", 0.9), ("quad9", 0.7), ("ad-metrics", 0.2)]),
        ("roborock", [("edge-cdn", 1.0), ("apple-updates", 0.8), ("ad-tracker", 0.6), ("spyware", 0.22)]),
        ("office-printer", [("apple-updates", 0.9), ("apple-time", 0.35), ("edge-cdn", 0.3)]),
    ]
}

// ── Formatting helpers (network.js) ────────────────────────────────────────

enum Format {
    static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = 0
        return f
    }()

    static func count(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 10_000 { return String(format: "%.1fk", v / 1000) }
        return grouping.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Tighter count for chrome that must survive a 1,000-orb live graph.
    static func compact(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1_000_000 {
            return String(format: "%.1fM", v / 1_000_000)
                .replacingOccurrences(of: ".0M", with: "M")
        }
        if v >= 1_000 {
            return String(format: "%.1fk", v / 1_000)
                .replacingOccurrences(of: ".0k", with: "k")
        }
        return "\(value)"
    }

    static func clock(_ timestampMS: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: timestampMS / 1000))
    }

    static func clock(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func shortDate(_ timestampMS: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: Date(timeIntervalSince1970: timestampMS / 1000))
    }

    /// Compact local date + 24-hour clock for the replay transport, e.g.
    /// "Nov 19 · 14:32".
    static func dayTime(_ timestampMS: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d · HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestampMS / 1000))
    }

    static func dayTime(_ date: Date) -> String {
        dayTime(date.timeIntervalSince1970 * 1000)
    }

    static func ago(_ timestampMS: Double, now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        guard timestampMS > 0 else { return "—" }
        let s = max(0, Int(((now - timestampMS) / 1000).rounded()))
        if s < 3 { return "now" }
        if s < 60 { return "\(s)s ago" }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return "\(m)m ago" }
        let h = Int((Double(m) / 60).rounded())
        if h < 24 { return "\(h)h ago" }
        let d = Int((Double(h) / 24).rounded())
        if d < 7 { return "\(d) day\(d == 1 ? "" : "s") ago" }
        let w = Int((Double(d) / 7).rounded())
        return "\(w) week\(w == 1 ? "" : "s") ago"
    }

    static func rate(_ qps: Float) -> String {
        qps >= 10 ? String(Int(qps.rounded())) : String(format: "%.1f", qps)
    }

    /// Host-traffic data sizes. Binary units with the familiar KB/MB labels;
    /// the host panel is the only place that needs them.
    static func bytes(_ value: Double) -> String {
        let v = max(0, value)
        if v >= 1_073_741_824 { return String(format: "%.1f GB", v / 1_073_741_824) }
        if v >= 1_048_576 { return String(format: v >= 10_485_760 ? "%.0f MB" : "%.1f MB", v / 1_048_576) }
        if v >= 1024 { return String(format: v >= 10_240 ? "%.0f KB" : "%.1f KB", v / 1024) }
        return String(format: "%.0f B", v)
    }

    static func dataRate(_ value: Double) -> String {
        bytes(value) + "/s"
    }

    /// Narrow-rail rate: no space and a short unit. "1.4M/s" instead of
    /// "1.4 MB/s" keeps both directions on one line in a 300 px rail.
    static func rateCompact(_ value: Double) -> String {
        bytes(value).replacingOccurrences(of: " ", with: "") + "/s"
    }

    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }
}
