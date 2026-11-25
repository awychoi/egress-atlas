import Foundation
import AppKit
import Darwin

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
