import Foundation

/// One query kept for time-travel playback. It is deliberately a value type:
/// the archive can hold tens of thousands of rows without retaining the whole
/// QueryEvent graph, and the graph objects are resolved again when the event is
/// actually played.
struct ReplayEvent: Equatable, Identifiable {
    let id: String
    let ts: Double              // milliseconds
    let deviceId: String
    let destinationId: String
    let latency: Int?
    let blocked: Bool
}

/// A bounded, chronologically sorted slice of traffic plus the density buckets
/// the transport timeline draws. The archive is independent of the source: the
/// demo synthesises one, the Pi-hole source fills it from the on-disk query
/// database.
struct ReplayArchive {
    var events: [ReplayEvent] = []
    var start: Double = 0       // milliseconds
    var end: Double = 0         // milliseconds
    var scannedRows = 0
    var skippedRows = 0
    var sampled = false
    var sourceLabel = ""
    var bucketSeconds: Double = 0
    var buckets: [PulseBucket] = []
    var maxBucket = 1
    var earliestAvailable: Double?

    var isEmpty: Bool { events.isEmpty }
    var duration: Double { max(1, end - start) }

    /// First event at or after `time`; a binary search keeps scrubbing cheap on
    /// a multi-day archive.
    func index(at time: Double) -> Int {
        guard !events.isEmpty else { return 0 }
        var low = 0
        var high = events.count
        while low < high {
            let mid = (low + high) / 2
            if events[mid].ts < time { low = mid + 1 }
            else { high = mid }
        }
        return low
    }

    /// Build the derived timeline data once. Events are sorted and (only if a
    /// caller exceeded the hard ceiling) evenly sampled so every part of the
    /// range stays represented.
    static func build(events rawEvents: [ReplayEvent],
                      start: Double,
                      end: Double,
                      scannedRows: Int,
                      skippedRows: Int,
                      sourceLabel: String,
                      earliestAvailable: Double? = nil,
                      bucketCount: Int = 120,
                      maxEvents: Int = 80_000) -> ReplayArchive {
        var events = rawEvents.sorted { $0.ts < $1.ts }
        var sampled = false
        if events.count > maxEvents, maxEvents > 0 {
            sampled = true
            let step = Double(events.count) / Double(maxEvents)
            var kept: [ReplayEvent] = []
            kept.reserveCapacity(maxEvents)
            var cursor = 0.0
            while kept.count < maxEvents, Int(cursor) < events.count {
                kept.append(events[min(events.count - 1, Int(cursor))])
                cursor += step
            }
            events = kept
        }

        var archive = ReplayArchive()
        archive.events = events
        archive.start = start
        archive.end = max(start + 1, end)
        archive.scannedRows = scannedRows
        archive.skippedRows = skippedRows
        archive.sourceLabel = sourceLabel
        archive.earliestAvailable = earliestAvailable
        archive.sampled = sampled
        archive.bucketSeconds = archive.duration / 1000 / Double(max(1, bucketCount))
        archive.buckets = Array(repeating: PulseBucket(), count: max(1, bucketCount))
        for event in events {
            let fraction = (event.ts - archive.start) / archive.duration
            let index = min(archive.buckets.count - 1,
                            max(0, Int(fraction * Double(archive.buckets.count))))
            if event.blocked { archive.buckets[index].blocked += 1 }
            else { archive.buckets[index].allowed += 1 }
        }
        archive.maxBucket = max(1, archive.buckets.map(\.total).max() ?? 1)
        return archive
    }
}
