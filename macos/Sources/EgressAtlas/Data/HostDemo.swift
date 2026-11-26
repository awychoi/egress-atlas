import Foundation

/// Deterministic host traffic used by headless snapshots and UI tests before a
/// live monitor is attached. It exercises every confidence level and both
/// directions so the host globe and chrome can be reviewed without the network.
enum HostDemo {
    static func snapshot(includeLocal: Bool = false) -> HostSnapshot {
        let now = Date()
        let apps: [(String, String, Bool)] = [
            ("app:com.brave.Browser", "Brave Browser", false),
            ("svc:/usr/libexec/apsd", "Apple Push", true),
            ("svc:/usr/sbin/mDNSResponder", "DNS resolver", true),
            ("app:com.tailscale.macos", "Tailscale", false),
            ("app:com.microsoft.VSCode", "Code", false),
            ("app:com.egressatlas.app", "Egress Atlas", false),
        ]
        let domains: [(String, String, HostDomainConfidence, Double, Double)] = [
            ("github.com", "HTTPS", .exact, 1_240_000, 32_000),
            ("api.github.com", "HTTPS", .exact, 680_000, 41_000),
            ("cdn.jsdelivr.net", "HTTPS", .temporal, 430_000, 9_000),
            ("courier.push.apple.com", "APNs", .exact, 96_000, 12_000),
            ("gateway.icloud.com", "HTTPS", .temporal, 210_000, 18_000),
            ("www.google.com", "HTTPS", .exact, 88_000, 4_000),
            ("slack.com", "HTTPS", .temporal, 64_000, 7_000),
            ("104.18.21.219:443", "HTTPS", .none, 52_000, 3_000),
            ("time.apple.com", "NTP", .ptr, 4_000, 2_000),
            ("17.57.147.6:5223", "APNs", .none, 38_000, 6_000),
        ] + (includeLocal ? [
            ("localhost:8765", "Loopback", .none, 180_000, 26_000),
            ("127.0.0.1:8888", "Local", .none, 92_000, 14_000),
        ] : [])
        var appStats: [HostAppStat] = []
        var endpoints: [HostEndpointStat] = []
        var domainStats: [HostDomainStat] = []
        for (index, app) in apps.enumerated() {
            let scale = 1.0 - Double(index) * 0.08
            let selected = domains.enumerated().filter { ($0.offset + index) % 3 == 0 }.prefix(4)
            var appEndpoints: [HostEndpointStat] = []
            for (dIndex, domain) in selected {
                let endpoint = makeEndpointStat(appID: app.0, domain: domain,
                                                index: index, dIndex: dIndex,
                                                scale: scale, now: now)
                appEndpoints.append(endpoint)
                endpoints.append(endpoint)
                let domainID = "d:\(domain.0)"
                let existing = domainStats.first { $0.id == domainID }
                domainStats.removeAll { $0.id == domainID }
                domainStats.append(makeDomainStat(existing: existing, domain: domain,
                                                  endpoint: endpoint, appID: app.0, now: now))
            }
            appStats.append(makeAppStat(app: app, index: index, endpoints: appEndpoints))
        }
        appStats.sort { $0.totalPerSecond > $1.totalPerSecond }
        domainStats.sort { $0.totalPerSecond > $1.totalPerSecond }
        endpoints.sort { $0.rxPerSecond + $0.txPerSecond > $1.rxPerSecond + $1.txPerSecond }
        var transfers: [HostTransfer] = []
        for (index, domain) in domainStats.prefix(6).enumerated() {
            let app = domain.appIDs.sorted().first ?? apps[0].0
            let outbound = index % 3 == 2
            transfers.append(HostTransfer(
                id: "demo-t-\(index)", appID: app, domainID: domain.id,
                endpointID: domain.endpointIDs.sorted().first ?? "",
                domain: domain.name, service: domain.service,
                bytesIn: UInt64(outbound ? 9_000 + index * 2_000 : 120_000 + index * 24_000),
                bytesOut: UInt64(outbound ? 240_000 + index * 30_000 : 8_000 + index * 3_000),
                at: now
            ))
        }
        var history: [HostRatePoint] = []
        for i in 0..<60 {
            let wave = 0.6 + 0.4 * sin(Double(i) * 0.22)
            history.append(HostRatePoint(rx: 2_600_000 * wave, tx: 160_000 * wave))
        }
        let totalRx = appStats.reduce(0) { $0 + $1.rxPerSecond }
        let totalTx = appStats.reduce(0) { $0 + $1.txPerSecond }
        return HostSnapshot(
            date: now, apps: appStats, endpoints: endpoints, domains: domainStats,
            transfers: transfers, history: history,
            rxPerSecond: totalRx, txPerSecond: totalTx,
            sessionRx: UInt64(totalRx * 120), sessionTx: UInt64(totalTx * 120),
            available: true, note: nil,
            enabledScopes: includeLocal ? [.internet, .lan, .vpn, .loopback] : [.internet, .lan, .vpn]
        )
    }

    private static func makeEndpointStat(
        appID: String,
        domain: (String, String, HostDomainConfidence, Double, Double),
        index: Int,
        dIndex: Int,
        scale: Double,
        now: Date
    ) -> HostEndpointStat {
        let rx = domain.3 * scale
        let tx = domain.4 * scale
        let target = domain.0.contains(":")
            ? domain.0.components(separatedBy: ":")
            : ["104.18.\(index).\(dIndex)"]
        let remoteHost = target.first ?? domain.0
        let remotePort = Int(target.last ?? "") ?? 443
        return HostEndpointStat(
            id: "\(appID)|tcp4|\(domain.0)|\(remotePort)",
            appID: appID,
            remoteHost: remoteHost,
            remotePort: remotePort,
            proto: "tcp4",
            service: domain.1,
            scope: HostScope.classify(remoteHost),
            domain: domain.0.contains(":") ? nil : domain.0,
            confidence: domain.2,
            rxPerSecond: rx,
            txPerSecond: tx,
            rxTotal: UInt64(rx * 30),
            txTotal: UInt64(tx * 30),
            socketCount: 1 + (index % 3),
            lastSeen: now
        )
    }

    private static func makeDomainStat(
        existing: HostDomainStat?,
        domain: (String, String, HostDomainConfidence, Double, Double),
        endpoint: HostEndpointStat,
        appID: String,
        now: Date
    ) -> HostDomainStat {
        return HostDomainStat(
            id: "d:\(domain.0)", name: domain.0, isDomain: !domain.0.contains(":"),
            scope: endpoint.scope, confidence: domain.2, service: domain.1,
            rxPerSecond: (existing?.rxPerSecond ?? 0) + endpoint.rxPerSecond,
            txPerSecond: (existing?.txPerSecond ?? 0) + endpoint.txPerSecond,
            rxTotal: (existing?.rxTotal ?? 0) + endpoint.rxTotal,
            txTotal: (existing?.txTotal ?? 0) + endpoint.txTotal,
            appIDs: (existing?.appIDs ?? []).union([appID]),
            endpointIDs: (existing?.endpointIDs ?? []).union([endpoint.id]),
            lastSeen: now
        )
    }

    private static func makeAppStat(app: (String, String, Bool), index: Int,
                                    endpoints: [HostEndpointStat]) -> HostAppStat {
        let rx = endpoints.reduce(0) { $0 + $1.rxPerSecond }
        let tx = endpoints.reduce(0) { $0 + $1.txPerSecond }
        return HostAppStat(
            id: app.0, name: app.1, detail: app.2 ? "system service" : app.0,
            path: "", isSystem: app.2,
            pids: [1000 + index], rxPerSecond: rx, txPerSecond: tx,
            rxTotal: UInt64(rx * 30), txTotal: UInt64(tx * 30),
            socketCount: endpoints.reduce(0) { $0 + $1.socketCount },
            endpoints: endpoints
        )
    }
}
