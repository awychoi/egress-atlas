import Foundation

/// One connected socket as reported by `netstat -anv`.
///
/// The text format is not a public contract, so this parser is deliberately
/// header-relative rather than fixed-width: the process column can contain
/// spaces and the numeric columns are anchored to the protocol/state tokens.
struct HostSocketSample: Equatable {
    let proto: String          // tcp4, tcp6, udp4, udp6
    let localAddress: String
    let localPort: Int
    let remoteAddress: String
    let remotePort: Int
    let pid: Int
    let rxBytes: UInt64        // cumulative for this socket
    let txBytes: UInt64
}

enum HostTrafficParser {
    /// Parse `netstat -anv` output. Listening and unconnected sockets are
    /// skipped; a row without a parsable pid is skipped rather than guessed.
    static func parse(_ text: String) -> [HostSocketSample] {
        var samples: [HostSocketSample] = []
        samples.reserveCapacity(64)
        for line in text.split(separator: "\n") {
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard t.count >= 19 else { continue }
            let proto = t[0]
            guard proto == "tcp4" || proto == "tcp6" || proto == "udp4" || proto == "udp6" else {
                continue
            }
            // Columns: proto, recv-q, send-q, local, foreign, [state], rx, tx,
            // rhiwat, shiwat, process:pid, state2, options, gencnt, flags,
            // flags1, usecnt, rtncnt, fltrs. UDP rows omit the first state
            // column, so the byte columns move one token left.
            let rxIndex = proto.hasPrefix("tcp") ? 6 : 5
            guard t.count > rxIndex + 1 else { continue }
            guard let rx = UInt64(t[rxIndex]), let tx = UInt64(t[rxIndex + 1]) else { continue }

            // The pid token is the ninth token from the end for both TCP and
            // UDP rows; eight fixed columns follow it.
            let pidToken = t[t.count - 9]
            guard let colon = pidToken.lastIndex(of: ":") else { continue }
            let pidPart = pidToken[pidToken.index(after: colon)...]
            guard let pid = Int(pidPart) else { continue }

            let local = splitAddress(t[3])
            let remote = splitAddress(t[4])
            // `*` / `*.*` means a listening or unconnected socket.
            guard remote.port > 0, !remote.host.isEmpty, remote.host != "*" else { continue }
            guard !local.host.isEmpty, local.host != "*" else { continue }

            samples.append(HostSocketSample(
                proto: proto,
                localAddress: local.host,
                localPort: local.port,
                remoteAddress: remote.host,
                remotePort: remote.port,
                pid: pid,
                rxBytes: rx,
                txBytes: tx
            ))
        }
        return samples
    }

    /// Split `1.2.3.4.443`, `fe80::1%en0.5223`, `*.443` or `*.*` into host and
    /// port. The port is the final dot component; IPv6 scopes are preserved.
    static func splitAddress(_ raw: String) -> (host: String, port: Int) {
        guard let dot = raw.lastIndex(of: ".") else { return (raw, 0) }
        let host = String(raw[..<dot])
        let portText = String(raw[raw.index(after: dot)...])
        guard let port = Int(portText), !host.isEmpty else { return (raw, 0) }
        return (host, port)
    }

    /// Sample the live system. The caller owns the queue; this spawns one
    /// short-lived process and returns its parsed sockets.
    static func sampleSystem(timeout: TimeInterval = 3.0) -> [HostSocketSample] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-anv"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let deadline = Date().addingTimeInterval(timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        guard !data.isEmpty else { return [] }
        return parse(String(decoding: data, as: UTF8.self))
    }
}
