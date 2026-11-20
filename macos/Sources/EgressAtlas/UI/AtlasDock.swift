import SwiftUI

struct AtlasDock: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: metrics.tiny ? 9 : 16) {
                clock.layoutPriority(1)
                timeline.layoutPriority(2)
                transport.fixedSize(horizontal: true, vertical: false).layoutPriority(3)
            }
            .padding(.bottom, metrics.tiny ? 7 : 8)
            HStack(spacing: 12) {
                legend
                Spacer(minLength: 8)
                Rectangle()
                    .fill(Palette.text.opacity(0.08))
                    .frame(width: 1, height: 15)
                    .padding(.horizontal, 2)
                CameraHUD(runtime: runtime, compact: metrics.tiny)
            }
            .padding(.top, 5)
            .overlay(alignment: .top) { Hairline() }
        }
        .padding(.horizontal, metrics.tiny ? 10 : 13)
        .padding(.top, metrics.tiny ? 8 : 10)
        .padding(.bottom, metrics.tiny ? 8 : 9)
        .frame(width: metrics.dockWidth)
        .background(WarmGlass(radius: 11))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: .black.opacity(0.46), radius: 30, x: 0, y: 20)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.rgba("fff1dd", 0.05)).frame(height: 1).padding(.top, 1).padding(.horizontal, 1)
        }
    }

    private var clock: some View {
        Button {
            runtime.replayJumpOpen.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Eyebrow(text: runtime.isReplay ? "Replay" : "Live",
                            size: 6.5,
                            color: runtime.isReplay ? Palette.gold.opacity(0.8) : Palette.dim.color,
                            trackingEm: 0.16)
                    if runtime.isReplay {
                        Text(Format.shortDate(runtime.replayTime).uppercased())
                            .font(.atlasMono(5.7, .regular))
                            .tracking(5.7 * 0.06)
                            .foregroundColor(Palette.dim.color)
                            .lineLimit(1)
                    } else if !metrics.tiny {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 7.5, weight: .regular))
                            .foregroundColor(Palette.faint.color)
                    }
                }
                Text(runtime.isReplay ? runtime.replayTimeText : runtime.clock)
                    .font(.atlasMono(metrics.tiny ? 16 : 18, .regular))
                    .tracking(-18 * 0.055)
                    .foregroundColor(Palette.gold.color)
                    .monospacedDigit()
                Text(clockSubtitle)
                    .font(.atlasMono(6.3, .regular))
                    .tracking(6.3 * 0.11)
                    .foregroundColor(runtime.paused ? Palette.coral.color : Palette.faint.color)
                    .lineLimit(1)
            }
            .frame(minWidth: metrics.tiny ? 100 : 118, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .help(runtime.isReplay ? "Jump to another time" : "Replay the last hours or days")
        .accessibilityLabel(runtime.isReplay ? "Replay time, choose another time" : "Live time, open history")
    }

    private var clockSubtitle: String {
        if runtime.isReplay {
            if runtime.paused { return "PAUSED · \(Int(runtime.replayRate))×" }
            if runtime.replayFinished { return "COMPLETE" }
            return "PLAYING · \(Int(runtime.replayRate))×"
        }
        if runtime.paused { return "PAUSED" }
        return runtime.speed == 1 ? "STREAMING" : "STREAMING · \(Format.rate(runtime.speed))×"
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Button {
                    runtime.replayJumpOpen.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: runtime.isReplay ? "calendar" : "clock.arrow.circlepath")
                            .font(.system(size: 7.5, weight: .regular))
                        Text(timelineTitle)
                            .font(.atlasMono(6.2, .regular))
                            .tracking(6.2 * 0.07)
                            .lineLimit(1)
                        if runtime.replaySampled && !metrics.compact {
                            Text("SAMPLE")
                                .font(.atlasMono(5.2, .regular))
                                .tracking(5.2 * 0.06)
                                .foregroundColor(Palette.coral.opacity(0.7))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(Palette.coral.opacity(0.18), lineWidth: 1))
                        }
                    }
                    .foregroundColor(runtime.isReplay ? Palette.gold.opacity(0.82) : Palette.dim.color)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AtlasPlainButtonStyle())
                .help("Choose a time range and a start time")

                Spacer(minLength: 4)

                Text(timelineMeta)
                    .font(.atlasMono(5.8, .regular))
                    .tracking(5.8 * 0.04)
                    .foregroundColor(runtime.replayLoading ? Palette.gold.color : Palette.faint.color)
                    .lineLimit(1)
            }
            if runtime.replayLoading {
                loadingStrip
            } else {
                AtlasTimelineChart(
                    buckets: runtime.isReplay ? runtime.replayBuckets : runtime.pulse,
                    scaleMax: runtime.isReplay ? runtime.replayMaxBucket : runtime.pulseScaleMax,
                    progress: runtime.isReplay ? runtime.replayProgress : nil,
                    isReplay: runtime.isReplay,
                    onScrub: runtime.isReplay ? { fraction in
                        runtime.seekReplay(fraction: fraction)
                    } : nil
                )
                .frame(height: 29)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !runtime.isReplay { runtime.replayJumpOpen = true }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timelineTitle: String {
        let short = metrics.compact
        if runtime.replayLoading {
            return short ? "LOADING · \(runtime.replayRangeTitle)"
                : "READING HISTORY · \(runtime.replayRangeTitle)"
        }
        if runtime.isReplay {
            return short
                ? "\(runtime.replayRangeTitle) · \(Format.compact(runtime.replayTotal))"
                : "\(runtime.replayRangeTitle) · \(Format.compact(runtime.replayTotal)) QUERIES"
        }
        return short ? "HISTORY" : "HISTORY · LAST \(ReplayRange.nearest(hours: runtime.replayRangeHours).title)"
    }

    private var timelineMeta: String {
        if runtime.replayLoading { return "LOADING…" }
        if runtime.isReplay {
            let percent = "\(Int((runtime.replayProgress * 100).rounded()))%"
            if metrics.compact { return runtime.replayLoop ? "\(percent) · LOOP" : percent }
            let loop = runtime.replayLoop ? " · LOOP" : ""
            return "\(percent) · \(runtime.replaySourceLabel.uppercased())\(loop)"
        }
        return metrics.compact
            ? Format.compact(runtime.pulseTotal)
            : "\(Format.compact(runtime.pulseTotal)) / 90S"
    }

    private var loadingStrip: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { geo in
                let phase = CGFloat(timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.1) / 1.1)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.text.opacity(0.055))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.clear, Palette.gold.opacity(0.5), .clear],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(40, geo.size.width * 0.28))
                        .offset(x: max(0, (geo.size.width * 1.28) * phase - geo.size.width * 0.28))
                }
            }
        }
        .frame(height: 29)
    }

    private var speedStops: [Float] {
        runtime.isReplay ? [1, 60, 600, 3_600] : [1, 2, 4]
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Button {
                if runtime.isReplay {
                    if runtime.replayFinished {
                        runtime.seekReplay(to: runtime.replayStart, preRoll: false)
                        runtime.setPaused(false)
                    } else {
                        runtime.setPaused(!runtime.paused)
                    }
                } else {
                    runtime.setPaused(!runtime.paused)
                }
            } label: {
                Group {
                    if runtime.paused || (runtime.isReplay && runtime.replayFinished) {
                        PlayGlyph(size: 14, color: Palette.gold.color)
                    } else {
                        PauseGlyph(size: 14, color: Palette.muted.color)
                    }
                }
                .frame(width: 31, height: 31)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(runtime.paused ? Palette.gold.opacity(0.09) : Color.rgba("0f0805", 0.62)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(runtime.paused ? Palette.gold.opacity(0.36) : Palette.text.opacity(0.11), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .help(playHelp)
            .accessibilityLabel(playHelp)

            HStack(spacing: 1) {
                ForEach(speedStops, id: \.self) { value in
                    let active = runtime.isReplay ? runtime.replayRate == value : runtime.speed == value
                    Button {
                        if runtime.isReplay {
                            runtime.setReplayRate(value)
                        } else {
                            runtime.setSpeed(value)
                            if runtime.paused { runtime.setPaused(false) }
                        }
                    } label: {
                        Text(String(Int(value)) + "×")
                            .font(.atlasMono(7, .regular))
                            .tracking(7 * 0.02)
                            .foregroundColor(active ? Palette.gold.color : Palette.dim.color)
                            .padding(.horizontal, metrics.tiny ? 3 : 5)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(active ? Palette.gold.opacity(0.09) : .clear))
                    }
                    .buttonStyle(AtlasPlainButtonStyle())
                    .disabled(!runtime.isReplay && runtime.isLiveSource)
                }
            }
            .opacity(!runtime.isReplay && runtime.isLiveSource ? 0.35 : 1)
            .help(speedHelp)
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("090503", 0.35)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))

            Button {
                if runtime.isReplay {
                    runtime.goLive()
                } else {
                    runtime.setPaused(false)
                    runtime.setSpeed(1)
                }
            } label: {
                Text(runtime.isReplay ? "LIVE" : (runtime.paused ? "RESUME" : "LIVE"))
                    .font(.atlasMono(6.8, .regular))
                    .tracking(6.8 * 0.1)
                    .foregroundColor(liveButtonActive ? Palette.sage.color : Palette.faint.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(liveButtonActive ? Palette.sage.opacity(0.05) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(liveButtonActive ? Palette.sage.opacity(0.22) : Palette.text.opacity(0.062),
                                      lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .help(runtime.isReplay ? "Leave replay and follow live traffic" : "Resume live traffic")
        }
    }

    private var playHelp: String {
        if runtime.isReplay {
            if runtime.replayFinished { return "Replay from the start" }
            return runtime.paused ? "Resume replay (Space)" : "Pause replay (Space)"
        }
        return runtime.paused ? "Resume live traffic (Space)" : "Pause live traffic (Space)"
    }

    private var speedHelp: String {
        if runtime.isReplay { return "Replay speed across the selected range" }
        if runtime.isLiveSource { return "Speed is demo-only; Pi-hole is the live clock" }
        return "Demo stream speed; the settings pane owns study speed"
    }

    private var liveButtonActive: Bool {
        runtime.isReplay || runtime.paused || runtime.speed != 1
    }

    private var legend: some View {
        HStack(spacing: 11) {
            legendItem("Device", color: Palette.signal.color)
            legendItem("Local flow", color: Palette.signalIce.color)
            legendItem("Allowed DNS", color: Palette.gold.color)
            legendItem("Blocked DNS", color: Palette.coral.color)
        }
    }

    private func legendItem(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 4, height: 4)
                .shadow(color: color.opacity(0.75), radius: 3.5)
            Text(text.uppercased())
                .font(.atlasMono(6.3, .regular))
                .tracking(6.3 * 0.09)
                .foregroundColor(Palette.dim.color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// Density strip shared by the live 90-second readout and the replay scrubber.
/// Bars before the playhead are lit; bars after it stay legible but dim so the
/// shape of the selected range is visible while scrubbing.
struct AtlasTimelineChart: View {
    let buckets: [PulseBucket]
    let scaleMax: Int
    var progress: Double? = nil
    var isReplay = false
    var onScrub: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let height = max(1, geo.size.height)
            let count = max(1, buckets.count)
            let step = width / CGFloat(count)
            let barWidth = max(1, step - 0.9)
            let maxValue = CGFloat(max(1, scaleMax))
            let playhead = progress.map { min(1, max(0, $0)) }

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    for (index, bucket) in buckets.enumerated() {
                        let total = bucket.total
                        guard total > 0 else { continue }
                        let ratio = min(1, CGFloat(total) / maxValue)
                        let barHeight = max(1, (size.height - 1) * pow(ratio, 0.68))
                        let rect = CGRect(x: CGFloat(index) * step,
                                          y: size.height - barHeight - 1,
                                          width: barWidth,
                                          height: barHeight)
                        let blocked = bucket.blocked > bucket.allowed
                        let isNow = !isReplay && index == buckets.count - 1
                        let future = isReplay
                            && playhead.map { Double(index) / Double(count) > $0 } == true
                        let colors: [Color]
                        if isNow {
                            colors = [Palette.white.color, Palette.gold.opacity(0.5)]
                        } else if blocked {
                            colors = [Color.rgba("e08068", 0.94), Color.rgba("e08068", 0.28)]
                        } else {
                            colors = [Color.rgba("f8c65b", 0.9), Color.rgba("f8c65b", 0.3)]
                        }
                        let opacity: Double = future ? 0.28 : 1
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                                 with: .linearGradient(Gradient(colors: colors),
                                                       startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                       endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                        if opacity < 1 {
                            ctx.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                                     with: .color(Color.rgba("060301", 0.72)))
                        }
                    }
                }
                .frame(height: height)

                if let playhead, isReplay {
                    let x = width * CGFloat(playhead)
                    Rectangle()
                        .fill(Palette.text.opacity(0.055))
                        .frame(width: max(0, x), height: height)
                    Rectangle()
                        .fill(LinearGradient(colors: [Palette.gold.opacity(0.2), Palette.white.opacity(0.92)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 1, height: height)
                        .offset(x: max(0, min(width - 1, x)))
                        .shadow(color: Palette.gold.opacity(0.7), radius: 4)
                    Circle()
                        .fill(Palette.white.color)
                        .frame(width: 4, height: 4)
                        .overlay(Circle().strokeBorder(Palette.gold.opacity(0.9), lineWidth: 1))
                        .offset(x: max(0, min(width - 4, x - 2)), y: 0)
                        .shadow(color: Palette.gold.opacity(0.6), radius: 3)
                }

                Rectangle()
                    .fill(Palette.text.opacity(0.062))
                    .frame(height: 1)
                    .offset(y: height - 1)

                if let onScrub {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let fraction = min(1, max(0, value.location.x / width))
                                    onScrub(Double(fraction))
                                }
                        )
                }
            }
        }
        .frame(height: 29)
        .accessibilityElement()
        .accessibilityLabel(isReplay ? "Replay timeline" : "Live activity, last 90 seconds")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if isReplay {
            let percent = Int(((progress ?? 0) * 100).rounded())
            return "\(percent) percent, \(buckets.reduce(0) { $0 + $1.total }) queries"
        }
        return "\(buckets.reduce(0) { $0 + $1.total }) queries"
    }
}

struct FieldCaption: View {
    @ObservedObject var runtime: AtlasRuntime
    var body: some View {
        VStack(spacing: 5) {
            Eyebrow(text: runtime.isReplay ? "Replay" : "Live", size: 7,
                    color: runtime.isReplay ? Palette.gold.opacity(0.7) : Palette.faint.color,
                    trackingEm: 0.22)
            HStack(spacing: 6) {
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Palette.gold.opacity(0.28), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 34, height: 1)
                Text((runtime.paused ? "paused" : runtime.lastEventAgo).uppercased())
                    .font(.atlasMono(6.5, .regular))
                    .tracking(6.5 * 0.14)
                    .foregroundColor(Palette.muted.opacity(0.55))
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Palette.gold.opacity(0.28), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 34, height: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
