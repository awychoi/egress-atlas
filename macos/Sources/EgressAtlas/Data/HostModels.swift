import Foundation
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

