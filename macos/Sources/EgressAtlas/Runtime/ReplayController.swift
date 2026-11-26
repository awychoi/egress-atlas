import Foundation

/// Immutable replay state the transport and inspector draw from. The runtime
/// mirrors this into its existing `@Published` replay properties so SwiftUI
/// keeps observing `AtlasRuntime` rather than a nested object.
struct ReplayPresentation: Equatable {
    var active = false
    var rangeHours: Float = ReplayRange.defaultChoice.hours
    var start: Double = 0
    var end: Double = 0
    var time: Double = 0
    var rate: Float = 600
    var buckets: [PulseBucket] = []
    var maxBucket = 1
    var total = 0
    var scanned = 0
    var skipped = 0
    var sampled = false
    var sourceLabel = ""
    var loading = false
    var finished = false
}

/// Where the requested archive can come from. The demo synthesises one inline;
/// a Pi-hole archive is loaded from FTL's on-disk query database off the main
/// thread.
enum ReplayArchiveSource {
    case demo(ReplayArchive)
    case pihole(() async throws -> ReplayArchive)
    case unavailable
}

/// Owns the time-travel engine: archive, playhead, emit budget, recent events,
/// request token and the state the replay UI shows. Presentation is pushed to
/// the runtime through `onPresentationChange`; scene work, source work and UI
/// work arrive as closures so the controller never reaches into `AtlasRuntime`.
final class ReplayController {
    struct Services {
        var nowMS: () -> Double
        var isReady: () -> Bool
        var archiveSource: (_ start: Double, _ end: Double) -> ReplayArchiveSource
        var resolveEvent: (ReplayEvent) -> QueryEvent?
        var playEvent: (QueryEvent) -> Void
        var clearEffects: () -> Void
        var applyLiveWindow: () -> Void
        var isPaused: () -> Bool
        /// Raw assignment used by install/goLive, which deliberately bypass the
        /// transport's finished-at-end restart rule.
        var setPausedFlag: (Bool) -> Void
        /// The transport resume path (`AtlasRuntime.setPaused(false)`), used
        /// when changing rate while paused.
        var resumePlayback: () -> Void
        var closeJump: () -> Void
        var isLoopEnabled: () -> Bool
        var setSourcePaused: (Bool) -> Void
        var noteSourceResumed: () -> Void
        var refreshUI: () -> Void
        var showToast: (_ text: String, _ tone: ToastMessage.Tone) -> Void
    }

    private(set) var presentation = ReplayPresentation()
    /// Recent replayed events, newest first, capped at 40.
    private(set) var recent: [QueryEvent] = []
    /// Current archive playhead in milliseconds.
    private(set) var cursor: Double = 0

    private var archive: ReplayArchive?
    private var index = 0
    private var emitBudget: Double = 0
    private var requestToken = 0
    private var lastPublished: Double = -1
    private var rateAuto = true
    private var services: Services?

    /// Runtime sink. Set once after the runtime finishes `super.init()`.
    var onPresentationChange: ((ReplayPresentation) -> Void)?

    func attach(_ services: Services) {
        self.services = services
    }

    // ── transport ────────────────────────────────────────────────────────

    /// Load the last `hours` of traffic and start playing at `at` (or at the
    /// beginning). The demo archive is built locally; a Pi-hole archive is
    /// fetched from FTL's on-disk query database off the main thread.
    func enterReplay(hours: Float = ReplayRange.defaultChoice.hours, at anchorMS: Double? = nil) {
        guard let services, services.isReady() else { return }
        let range = ReplayRange.nearest(hours: hours)
        let previousFraction: Double = {
            guard presentation.active, presentation.end > presentation.start else { return 0 }
            return min(1, max(0, (cursor - presentation.start) / (presentation.end - presentation.start)))
        }()
        let end = services.nowMS()
        let start = max(0, end - Double(range.hours) * 3_600_000)
        let anchor = anchorMS.map { min(end - 1, max(start, $0)) }
            ?? (presentation.active ? start + (end - start) * previousFraction : start)

        presentation.rangeHours = range.hours
        requestToken += 1
        let token = requestToken
        services.closeJump()
        publish()

        switch services.archiveSource(start, end) {
        case .pihole(let load):
            presentation.loading = true
            publish()
            Task { [weak self] in
                do {
                    let archive = try await load()
                    await MainActor.run {
                        self?.installReplay(archive, at: anchor, token: token, range: range)
                    }
                } catch {
                    await MainActor.run {
                        self?.failReplay(error, token: token, range: range)
                    }
                }
            }
        case .demo(let archive):
            installReplay(archive, at: anchor, token: token, range: range)
        case .unavailable:
            services.showToast("This source cannot be replayed.", .coral)
        }
    }

    private func installReplay(_ archive: ReplayArchive, at anchor: Double,
                               token: Int, range: ReplayRange) {
        guard token == requestToken else { return }
        guard !archive.events.isEmpty else {
            presentation.loading = false
            publish()
            services?.showToast("No playable queries in \(range.detail).", .coral)
            return
        }
        if rateAuto {
            presentation.rate = Self.autoRate(durationMS: archive.duration)
        }
        self.archive = archive
        presentation.start = archive.start
        presentation.end = archive.end
        presentation.buckets = archive.buckets
        presentation.maxBucket = archive.maxBucket
        presentation.total = archive.events.count
        presentation.scanned = archive.scannedRows
        presentation.skipped = archive.skippedRows
        presentation.sampled = archive.sampled
        presentation.sourceLabel = archive.sourceLabel
        presentation.loading = false
        presentation.active = true
        services?.setPausedFlag(false)
        services?.setSourcePaused(true)
        presentation.finished = false
        lastPublished = -1
        recent.removeAll()
        publish()
        seekReplay(to: anchor, preRoll: true)
        let sampled = archive.sampled ? " · sampled" : ""
        services?.showToast("Replay · \(range.title) · \(Format.count(archive.events.count)) queries\(sampled)",
                            .signal)
        services?.refreshUI()
    }

    private func failReplay(_ error: Error, token: Int, range: ReplayRange) {
        guard token == requestToken else { return }
        presentation.loading = false
        if archive != nil, presentation.end > presentation.start {
            presentation.rangeHours = Float((presentation.end - presentation.start) / 3_600_000)
        }
        publish()
        services?.showToast("History unavailable · \(error.localizedDescription)", .coral)
    }

    /// Leave playback and resume the live poller. Safe to call while a history
    /// request is still in flight; the token discards the late result.
    func goLive() {
        guard let services, presentation.active || presentation.loading else { return }
        requestToken += 1
        presentation.loading = false
        archive = nil
        presentation.buckets = []
        presentation.total = 0
        presentation.scanned = 0
        presentation.skipped = 0
        presentation.sampled = false
        presentation.sourceLabel = ""
        recent.removeAll()
        presentation.finished = false
        services.closeJump()
        presentation.start = 0
        presentation.end = 0
        presentation.time = 0
        lastPublished = -1
        rateAuto = true
        presentation.active = false
        publish()
        services.setPausedFlag(false)
        services.setSourcePaused(false)
        services.clearEffects()
        services.applyLiveWindow()
        services.noteSourceResumed()
        services.refreshUI()
        services.showToast("Live traffic", .signal)
    }

    func setRate(_ rate: Float) {
        guard let services else { return }
        rateAuto = false
        presentation.rate = clamp(rate, 1, 7_200)
        publish()
        if presentation.finished {
            seekReplay(to: presentation.start, preRoll: false)
        }
        if services.isPaused() { services.resumePlayback() }
        services.refreshUI()
    }

    func setRange(_ range: ReplayRange) {
        presentation.rangeHours = range.hours
        publish()
        if presentation.active || presentation.loading {
            enterReplay(hours: range.hours)
        }
    }

    /// Jump the playhead. Clearing the stage makes a scrub read as a jump cut
    /// rather than a pile-up of studies from the skipped interval. A short
    /// pre-roll seeds the new position with the queries that just landed.
    func seekReplay(to timeMS: Double, preRoll: Bool = true) {
        guard let services, let archive, !archive.events.isEmpty else { return }
        let target = min(presentation.end, max(presentation.start, timeMS))
        services.clearEffects()
        cursor = target
        presentation.time = target
        lastPublished = target
        index = archive.index(at: target)
        emitBudget = 0
        recent.removeAll()
        presentation.finished = target >= presentation.end - 1
        publish()
        if preRoll && !services.isPaused() {
            let from = archive.index(at: max(presentation.start, target - 1_500))
            var index = from
            var count = 0
            while index < self.index, count < 8 {
                playReplayEvent(archive.events[index])
                index += 1
                count += 1
            }
        }
        services.refreshUI()
    }

    func seekReplay(fraction: Double, preRoll: Bool = false) {
        guard presentation.active else { return }
        let value = min(1, max(0, fraction))
        seekReplay(to: presentation.start + (presentation.end - presentation.start) * value,
                   preRoll: preRoll)
    }

    func advance(dt: Float) {
        guard let services else { return }
        guard presentation.active, !services.isPaused(), !presentation.loading,
              let archive, !archive.events.isEmpty else { return }
        guard cursor < presentation.end else {
            if services.isLoopEnabled() {
                seekReplay(to: presentation.start, preRoll: false)
            } else if !presentation.finished {
                presentation.finished = true
                publish()
            }
            return
        }
        if presentation.finished {
            presentation.finished = false
            publish()
        }
        emitBudget = min(1.5, emitBudget + Double(dt) * 30)
        let target = min(presentation.end, cursor + Double(dt) * Double(presentation.rate) * 1000)
        var allowed = min(8, Int(emitBudget))
        while index < archive.events.count,
              archive.events[index].ts <= target,
              allowed > 0 {
            playReplayEvent(archive.events[index])
            index += 1
            allowed -= 1
            emitBudget -= 1
        }
        // The renderer has a fixed signal/effect budget. When history is denser
        // than that, keep the playhead honest and drop the surplus events for
        // this slice instead of building an unbounded backlog.
        while index < archive.events.count,
              archive.events[index].ts <= target {
            index += 1
        }
        cursor = target
        if cursor >= presentation.end {
            if services.isLoopEnabled() {
                seekReplay(to: presentation.start, preRoll: false)
            } else {
                presentation.finished = true
                publish()
                services.refreshUI()
            }
        }
    }

    // ── runtime refresh support ──────────────────────────────────────────

    /// Mirror the playhead into the published clock when it moved. The UI
    /// refresh cadence owns this so replay time still steps at refresh rate.
    func syncPublishedTime() {
        guard presentation.active, cursor != lastPublished else { return }
        lastPublished = cursor
        presentation.time = cursor
        publish()
    }

    /// QPS read from the archive window around the playhead, or nil when the
    /// live source should be used instead.
    func currentQps() -> Float? {
        guard presentation.active, let archive, archive.bucketSeconds > 0 else { return nil }
        let fraction = (presentation.time - archive.start) / archive.duration
        let index = min(archive.buckets.count - 1,
                        max(0, Int(fraction * Double(archive.buckets.count))))
        // A single bucket can legitimately be empty between bursts. A short
        // rolling window keeps the inspector readable while still describing
        // the archive rather than the live stream.
        let low = max(0, index - 2)
        let high = min(archive.buckets.count - 1, index + 2)
        var total = 0
        for i in low...high { total += archive.buckets[i].total }
        let span = archive.bucketSeconds * Double(high - low + 1)
        return span > 0 ? Float(total) / Float(span) : 0
    }

    // ── lifecycle ────────────────────────────────────────────────────────

    /// Drop the archive and every playhead/request value. Range and rate are
    /// user preferences and survive a source switch, as they always have.
    func reset() {
        requestToken += 1
        archive = nil
        cursor = 0
        index = 0
        emitBudget = 0
        recent.removeAll()
        lastPublished = -1
        rateAuto = true
        presentation.active = false
        presentation.loading = false
        presentation.finished = false
        presentation.buckets = []
        presentation.total = 0
        presentation.scanned = 0
        presentation.skipped = 0
        presentation.sampled = false
        presentation.sourceLabel = ""
        presentation.start = 0
        presentation.end = 0
        presentation.time = 0
        publish()
    }

    // ── internals ────────────────────────────────────────────────────────

    private func playReplayEvent(_ event: ReplayEvent) {
        guard let services, let query = services.resolveEvent(event) else { return }
        services.playEvent(query)
        recent.insert(query, at: 0)
        if recent.count > 40 { recent.removeLast(recent.count - 40) }
    }

    private func publish() {
        onPresentationChange?(presentation)
    }

    /// Pick a default compression so the whole range plays in roughly three
    /// minutes. 1× stays available, but a multi-day range would otherwise take
    /// days to watch before the first useful movement.
    private static func autoRate(durationMS: Double) -> Float {
        let seconds = max(1, durationMS / 1000)
        let target: Double = 180
        let stops: [Float] = [1, 60, 600, 3_600]
        return stops.min {
            abs(log(seconds / Double($0) / target)) < abs(log(seconds / Double($1) / target))
        } ?? 600
    }
}
