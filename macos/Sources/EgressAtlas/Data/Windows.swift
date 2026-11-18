import Foundation

struct WindowStop {
    let hours: Float
    let label: String
}

enum Windows {
    /// Same non-linear scale as app/src/data/windows.js: every hour up to 12,
    /// then every day up to 7 days.
    static let stops: [WindowStop] = {
        var out: [WindowStop] = []
        for h in 1...12 {
            out.append(WindowStop(hours: Float(h), label: "\(h) hour\(h == 1 ? "" : "s")"))
        }
        for d in 1...7 {
            out.append(WindowStop(hours: Float(d * 24), label: "\(d) day\(d == 1 ? "" : "s")"))
        }
        return out
    }()

    static let defaultHours: Float = 7 * 24

    static func label(hours: Float) -> String {
        if let stop = stops.first(where: { abs($0.hours - hours) < 0.5 }) { return stop.label }
        if hours >= 24 {
            let days = max(1, Int((hours / 24).rounded()))
            return "\(days) day\(days == 1 ? "" : "s")"
        }
        let h = max(1, Int(hours.rounded()))
        return "\(h) hours"
    }

    static func index(hours: Float) -> Int {
        var best = 0
        var distance = Float.infinity
        for (i, stop) in stops.enumerated() {
            let d = abs(stop.hours - hours)
            if d < distance { distance = d; best = i }
        }
        return best
    }

    static func normalize(_ hours: Float) -> Float {
        stops[index(hours: min(168, max(1, hours)))].hours
    }
}
