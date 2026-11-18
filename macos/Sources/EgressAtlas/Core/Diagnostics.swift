import Foundation

/// Lightweight local diagnostics for verifying the shipped app's render loop.
/// Writes only when the environment variable ATLAS_DIAGNOSTICS=1 is set, so
/// normal use stays silent and file-free.
///
/// Logging is intentionally asynchronous. These probes run on the frame
/// thread, and a synchronous open/write/close there showed up as a dropped
/// frame roughly once every 120 samples — the probe was perturbing the thing
/// it was trying to measure.
enum AtlasDiagnostics {
    static let enabled = ProcessInfo.processInfo.environment["ATLAS_DIAGNOSTICS"] == "1"
    private static let url: URL = {
        if let path = ProcessInfo.processInfo.environment["ATLAS_LOG"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/EgressAtlas.log")
    }()
    private static let queue = DispatchQueue(label: "com.egressatlas.diagnostics", qos: .utility)
    /// Only touched on `queue`.
    private static var started = false
    private static let formatter = ISO8601DateFormatter()

    static func log(_ message: String) {
        guard enabled else { return }
        queue.async {
            let date = formatter.string(from: Date())
            let line = "[\(date)] \(message)\n"
            if !started {
                started = true
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? Data().write(to: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        }
    }
}
