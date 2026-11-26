import Foundation

struct PiHoleQueryRow {
    let id: String
    let timestamp: Double        // milliseconds
    let clientIP: String
    let clientName: String?
    let domain: String
    let status: String
    let blocked: Bool
    let latencyMs: Int?
    let type: String
}

struct PiHoleSnapshot {
    let rows: [PiHoleQueryRow]
    let endpoint: String
    let windowSeconds: Int
    let truncated: Bool
    let fetchedAt: Date
    /// Oldest query still held in memory / in the on-disk database, in
    /// milliseconds. The replay range picker uses this to avoid promising a
    /// window the Pi-hole has already pruned.
    var earliestTimestamp: Double? = nil
    var earliestTimestampDisk: Double? = nil
}

struct PiHoleLogLine {
    let timestamp: Double      // seconds since epoch
    let message: String
}

struct PiHoleLogPage {
    let lines: [PiHoleLogLine]
    let nextID: Int
    let pid: Int?
}

enum PiHoleError: LocalizedError {
    case invalidURL(String)
    case http(String)
    case auth(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let message), .http(let message),
             .auth(let message), .malformed(let message):
            return message
        }
    }
}

/// Direct, read-only Pi-hole v6 client. Credentials are held by the runtime's
/// Keychain helper and never written to defaults or logs.
final class PiHoleClient {
    private let baseURL: URL
    private let password: String
    private let insecure: Bool
    private var sid: String?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        let delegate: URLSessionDelegate? = insecure
            ? InsecureTrustDelegate()
            : nil
        return URLSession(configuration: configuration,
                          delegate: delegate,
                          delegateQueue: nil)
    }()

    var normalizedURL: String { baseURL.absoluteString }

    var endpoint: String {
        guard let host = baseURL.host else { return baseURL.absoluteString }
        let authority = baseURL.port.map { "\(host):\($0)" } ?? host
        let path = baseURL.path
        return path.isEmpty || path == "/" ? authority : "\(authority)\(path)"
    }

    init(rawURL: String, password: String, insecure: Bool) throws {
        let clean = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw PiHoleError.invalidURL("Enter the Pi-hole URL.") }
        let candidate = clean.contains("://") ? clean : "http://\(clean)"
        guard var components = URLComponents(string: candidate) else {
            throw PiHoleError.invalidURL("The Pi-hole URL is not valid.")
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw PiHoleError.invalidURL("The Pi-hole URL must start with http:// or https://.")
        }
        guard components.host != nil else {
            throw PiHoleError.invalidURL("The Pi-hole URL has no host.")
        }
        if components.user != nil || components.password != nil {
            throw PiHoleError.invalidURL("Put the API password in the password field, not in the URL.")
        }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/api") { path.removeLast(4) }
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw PiHoleError.invalidURL("The Pi-hole URL is not valid.")
        }
        self.baseURL = url
        self.password = password
        self.insecure = insecure
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - API

    func snapshot(seconds: Int = 21_600, limit: Int = 5_000) async throws -> PiHoleSnapshot {
        if !password.isEmpty {
            try await authenticate(force: true)
        }
        return try await fetchQueries(seconds: seconds, limit: limit)
    }

    func poll(seconds: Int = 180, limit: Int = 1_000) async throws -> PiHoleSnapshot {
        if !password.isEmpty && sid == nil {
            try await authenticate(force: false)
        }
        do {
            return try await fetchQueries(seconds: seconds, limit: limit)
        } catch let error as PiHoleError {
            // A stale session is the common 401; refresh once, then report
            // the second failure.
            if case .http(let message) = error, message.contains("401"), !password.isEmpty {
                try await authenticate(force: true)
                return try await fetchQueries(seconds: seconds, limit: limit)
            }
            throw error
        }
    }

    /// Pull a bounded historical range, following the API cursor until the
    /// caller's budget is spent. `disk` asks FTL for the long-term database
    /// rather than the in-memory recent log, which is what makes replay across
    /// days possible. Callers split long ranges into chunks so a busy week is
    /// sampled across the whole window instead of truncated to its newest rows.
    func history(from startMS: Double, until endMS: Double,
                 limit: Int, disk: Bool = true) async throws -> PiHoleSnapshot {
        if !password.isEmpty && sid == nil {
            try await authenticate(force: false)
        }
        let from = max(0, Int(startMS / 1000))
        let until = max(from + 1, Int(endMS / 1000))
        let target = max(1, limit)
        let pageSize = min(5_000, target)
        var byID: [String: PiHoleQueryRow] = [:]
        var cursor: Int?
        var start = 0
        var pages = 0
        var earliest: Double?
        var earliestDisk: Double?

        while byID.count < target && pages < 32 {
            let length = min(pageSize, target - byID.count)
            let page: PiHoleQueryPage
            do {
                page = try await fetchPage(from: from, until: until, length: length,
                                           cursor: cursor, start: start, disk: disk)
            } catch let error as PiHoleError {
                if case .http(let message) = error, message.contains("401"), !password.isEmpty {
                    try await authenticate(force: true)
                    page = try await fetchPage(from: from, until: until, length: length,
                                               cursor: cursor, start: start, disk: disk)
                } else {
                    throw error
                }
            }
            pages += 1
            if earliest == nil { earliest = page.earliestTimestamp }
            if earliestDisk == nil { earliestDisk = page.earliestTimestampDisk }
            guard !page.rows.isEmpty else { break }
            for row in page.rows where byID[row.id] == nil {
                byID[row.id] = row
            }
            // FTL freezes the result with the cursor returned by the first
            // page and paginates from it with `start`. Keep that anchor while
            // advancing the offset; passing the anchor back is what stops new
            // queries from shifting the pages.
            if cursor == nil { cursor = page.cursor }
            start += page.rows.count
            // FTL caps a page at 10,000 rows and this caller asks for at most
            // 5,000, so a short page means the range is exhausted.
            if page.rawCount < length { break }
            if start >= page.recordsFiltered { break }
            guard let next = page.cursor, next > 0 else { break }
            if cursor == nil { cursor = next }
        }

        let rows = byID.values.sorted { $0.timestamp < $1.timestamp }
        return PiHoleSnapshot(
            rows: rows,
            endpoint: endpoint,
            windowSeconds: max(1, until - from),
            truncated: rows.count >= target,
            fetchedAt: Date(),
            earliestTimestamp: earliest,
            earliestTimestampDisk: earliestDisk
        )
    }

    private func authenticate(force: Bool) async throws {
        if sid != nil && !force { return }
        if password.isEmpty { sid = nil; return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/auth"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["password": password])
        let (data, response) = try await session.data(for: request)
        let object = try jsonObject(data)
        let sessionInfo = object["session"] as? [String: Any]
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            let message = sessionInfo?["message"] as? String
                ?? object["error"] as? String
                ?? "Pi-hole authentication failed. Check the API password."
            throw PiHoleError.auth(message)
        }
        try validate(response, data: data)
        guard sessionInfo?["valid"] as? Bool == true,
              let sid = sessionInfo?["sid"] as? String,
              !sid.isEmpty else {
            let message = sessionInfo?["message"] as? String
                ?? object["error"] as? String
                ?? "Pi-hole authentication failed. Check the API password."
            throw PiHoleError.auth(message)
        }
        self.sid = sid
    }

    private struct PiHoleQueryPage {
        let rows: [PiHoleQueryRow]
        let rawCount: Int
        let cursor: Int?
        let recordsFiltered: Int
        let earliestTimestamp: Double?
        let earliestTimestampDisk: Double?
    }

    private func fetchQueries(seconds: Int, limit: Int) async throws -> PiHoleSnapshot {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - max(5, seconds)
        let page = try await fetchPage(from: from, until: now, length: max(1, limit),
                                       cursor: nil, start: 0, disk: false)
        return PiHoleSnapshot(
            rows: page.rows.sorted { $0.timestamp < $1.timestamp },
            endpoint: endpoint,
            windowSeconds: seconds,
            truncated: page.rows.count >= limit || page.recordsFiltered > page.rows.count,
            fetchedAt: Date(),
            earliestTimestamp: page.earliestTimestamp,
            earliestTimestampDisk: page.earliestTimestampDisk
        )
    }

    private func fetchPage(from: Int, until: Int, length: Int,
                           cursor: Int?, start: Int, disk: Bool) async throws -> PiHoleQueryPage {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/queries"),
                                       resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "until", value: String(until)),
            URLQueryItem(name: "length", value: String(max(1, length))),
        ]
        if let cursor, cursor > 0 {
            items.append(URLQueryItem(name: "cursor", value: String(cursor)))
        }
        if start > 0 {
            items.append(URLQueryItem(name: "start", value: String(start)))
        }
        if disk {
            items.append(URLQueryItem(name: "disk", value: "true"))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw PiHoleError.invalidURL("The Pi-hole URL is not valid.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let sid { request.setValue(sid, forHTTPHeaderField: "X-FTL-SID") }
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let object = try jsonObject(data)
        let rawRows = object["queries"] as? [[String: Any]] ?? []
        var rows: [PiHoleQueryRow] = []
        rows.reserveCapacity(rawRows.count)
        for raw in rawRows {
            if let row = parseRow(raw) { rows.append(row) }
        }
        let filtered = (object["recordsFiltered"] as? NSNumber)?.intValue ?? rawRows.count
        let cursorValue = (object["cursor"] as? NSNumber)?.intValue
        let earliest = (object["earliest_timestamp"] as? NSNumber)?.doubleValue
        let earliestDisk = (object["earliest_timestamp_disk"] as? NSNumber)?.doubleValue
        return PiHoleQueryPage(
            rows: rows,
            rawCount: rawRows.count,
            cursor: cursorValue,
            recordsFiltered: filtered,
            earliestTimestamp: earliest.map { $0 * 1000 },
            earliestTimestampDisk: earliestDisk.map { $0 * 1000 }
        )
    }

    /// Pi-hole v6 exposes dnsmasq's own log with real answer IPs and a cursor.
    /// This is the only zero-privilege source of exact IP→domain evidence; the
    /// structured `/api/queries` endpoint has no answer address.
    func dnsmasqLog(nextID: Int? = nil) async throws -> PiHoleLogPage {
        if !password.isEmpty && sid == nil {
            try await authenticate(force: false)
        }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/logs/dnsmasq"),
                                       resolvingAgainstBaseURL: false)
        if let nextID, nextID > 0 {
            components?.queryItems = [URLQueryItem(name: "nextID", value: String(nextID))]
        }
        guard let url = components?.url else {
            throw PiHoleError.invalidURL("The Pi-hole URL is not valid.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let sid { request.setValue(sid, forHTTPHeaderField: "X-FTL-SID") }
        var (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401, !password.isEmpty {
            try await authenticate(force: true)
            request.setValue(sid, forHTTPHeaderField: "X-FTL-SID")
            (data, response) = try await session.data(for: request)
        }
        try validate(response, data: data)
        let object = try jsonObject(data)
        let rawLines = object["log"] as? [[String: Any]] ?? []
        var lines: [PiHoleLogLine] = []
        lines.reserveCapacity(rawLines.count)
        for raw in rawLines {
            let stamp = (raw["timestamp"] as? NSNumber)?.doubleValue ?? 0
            let message = String(raw["message"] as? String ?? "")
            guard stamp > 0, !message.isEmpty else { continue }
            lines.append(PiHoleLogLine(timestamp: stamp, message: message))
        }
        let next = (object["nextID"] as? NSNumber)?.intValue
            ?? Int((object["nextID"] as? String) ?? "") ?? 0
        let pid = (object["pid"] as? NSNumber)?.intValue
        return PiHoleLogPage(lines: lines, nextID: next, pid: pid)
    }

    // MARK: - Parsing

    private func parseRow(_ raw: [String: Any]) -> PiHoleQueryRow? {
        let rawTime = (raw["time"] as? NSNumber)?.doubleValue
            ?? (raw["timestamp"] as? NSNumber)?.doubleValue
        guard let rawTime, rawTime > 0 else { return nil }
        let timestamp = rawTime > 1e12 ? rawTime : rawTime * 1000

        let clientObject = raw["client"] as? [String: Any]
        let clientIP = String(clientObject?["ip"] as? String
            ?? raw["client"] as? String
            ?? "").trimmingCharacters(in: .whitespaces)
        let domain = String(raw["domain"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !clientIP.isEmpty, !domain.isEmpty else { return nil }
        if clientIP == "::" || clientIP == "127.0.0.1" || clientIP == "0.0.0.0" || clientIP == "localhost" {
            return nil
        }
        if domain == "localhost" || domain == "pi.hole" { return nil }
        let status = String(describing: raw["status"] ?? "UNKNOWN")
        let reply = raw["reply"] as? [String: Any]
        let replyTime = (reply?["time"] as? NSNumber)?.doubleValue ?? 0
        let latency = replyTime > 0 ? Int((replyTime * 1000).rounded()) : nil
        let id = String(describing: raw["id"] ?? "\(clientIP)|\(domain)|\(timestamp)")
        return PiHoleQueryRow(
            id: id,
            timestamp: timestamp,
            clientIP: clientIP,
            clientName: clientObject?["name"] as? String,
            domain: domain,
            status: status,
            blocked: Self.isBlocked(status),
            latencyMs: latency,
            type: String(describing: raw["type"] ?? "DNS")
        )
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PiHoleError.http("Pi-hole returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? jsonObject(data)) ?? [:]
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String
                ?? object["message"] as? String
                ?? "Pi-hole API returned HTTP \(http.statusCode)."
            throw PiHoleError.http("\(http.statusCode) \(message)")
        }
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PiHoleError.malformed("Pi-hole returned a non-JSON response.")
        }
        return object
    }

    private static let blockedNames: Set<String> = [
        "GRAVITY", "REGEX", "DENYLIST", "EXTERNAL_BLOCKED_IP",
        "EXTERNAL_BLOCKED_NULL", "EXTERNAL_BLOCKED_NXRA", "GRAVITY_CNAME",
        "REGEX_CNAME", "DENYLIST_CNAME", "DBBUSY", "SPECIAL_DOMAIN",
        "EXTERNAL_BLOCKED_EDE15",
    ]
    private static let blockedNumbers: Set<Int> = [1, 4, 5, 6, 7, 8, 9, 10, 11, 15, 16, 18]

    static func isBlocked(_ status: String) -> Bool {
        let upper = status.uppercased()
        if blockedNames.contains(upper) { return true }
        if let number = Int(upper), blockedNumbers.contains(number) { return true }
        return false
    }
}

private final class InsecureTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
