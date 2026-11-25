import Foundation

/// `nettop` is the primary sampler and works without root or a private
/// entitlement. In one sample it emits a process row followed by that process's
/// connection rows, all in CSV:
///
///     time,Process.123,,,bytes_in,bytes_out,...
///     time,tcp4 10.0.0.2:50000<->93.184.216.34:443,en0,Established,1234,567,...
///
/// Per-connection counters are cumulative, like netstat's, so the monitor can
/// diff the same way. It is slower than netstat (one second per sample) and
/// does not include every kernel socket, but it covers the app traffic the
/// HOST globe needs; netstat is the fallback when nettop returns nothing.
enum HostNettopParser {
    static func parse(_ text: String) -> [HostSocketSample] {
        var current: (pid: pid_t, name: String)?
        var samples: [HostSocketSample] = []

        for raw in text.split(separator: "\n") {
            let fields = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { continue }
            let nameField = fields[1]
            let first = nameField.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            let isConnection = ["tcp4", "tcp6", "udp4", "udp6"].contains(first)

            if isConnection {
                guard let current else { continue }
                let parts = nameField.split(separator: " ", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let proto = String(parts[0])
                let pair = parts[1].split(separator: "<->", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2,
                      let local = parseEndpoint(String(pair[0])),
                      let remote = parseEndpoint(String(pair[1])),
                      remote.address != "*", remote.address != "0.0.0.0",
                      remote.port > 0 else { continue }
                // Listening sockets carry no remote traffic. UDP rows often
                // have an empty state; their counters are still useful.
                if fields[3] == "Listen" { continue }
                let rx = UInt64(fields[4]) ?? 0
                let tx = UInt64(fields[5]) ?? 0
                guard rx > 0 || tx > 0 else { continue }
                samples.append(HostSocketSample(
                    proto: proto,
                    localAddress: local.address,
                    localPort: local.port,
                    remoteAddress: remote.address,
                    remotePort: remote.port,
                    pid: Int(current.pid),
                    rxBytes: rx,
                    txBytes: tx
                ))
                continue
            }

            // A process row has a name.pid in column 1 and no interface.
            guard fields[2].isEmpty else { continue }
            let components = nameField.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count >= 2,
                  let pid = Int32(components.last!) else { continue }
            let name = components.dropLast().joined(separator: ".")
            guard !name.isEmpty else { continue }
            current = (pid, name)
        }
        return samples
    }

    static func parseEndpoint(_ raw: String) -> (address: String, port: Int)? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value == "*" || value == "*:*" || value == "*.*" { return ("*", 0) }

        // Bracketed IPv6: [fe80::1]:443.
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let address = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
            let portText = rest.dropFirst()
            guard let port = Int(portText) else { return nil }
            return (stripScope(address), port)
        }

        // nettop prints IPv4 as a.b.c.d:port and unbracketed IPv6 as
        // fe80::1%en0.port, where the port is after the final dot.
        if let dot = value.lastIndex(of: "."),
           let port = Int(value[value.index(after: dot)...]),
           value[value.startIndex..<dot].contains(":") {
            let address = String(value[value.startIndex..<dot])
            return (stripScope(address), port)
        }

        if let colon = value.lastIndex(of: ":"),
           let port = Int(value[value.index(after: colon)...]) {
            return (stripScope(String(value[value.startIndex..<colon])), port)
        }
        return nil
    }

    private static func stripScope(_ address: String) -> String {
        guard let percent = address.firstIndex(of: "%") else { return address }
        return String(address[address.startIndex..<percent])
    }
}

enum HostNettopSampler {
    static func sampleSystem() -> [HostSocketSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-L", "1", "-n"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard !data.isEmpty else { return [] }
            return HostNettopParser.parse(String(decoding: data, as: UTF8.self))
        } catch {
            return []
        }
    }
}
