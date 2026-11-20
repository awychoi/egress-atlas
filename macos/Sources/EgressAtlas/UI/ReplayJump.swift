import SwiftUI

/// Popover for entering time travel: pick a range, pick the moment to start
/// from, then play. In replay it doubles as a jump-to-time control.
struct ReplayJumpCard: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    @State private var range: ReplayRange = .sixHours
    @State private var date = Date()
    @State private var didLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 12) {
                rangePicker
                jumpField
                summary
                actions
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 13)
        }
        .frame(width: 328)
        .background(WarmGlass(radius: 10, strong: true))
        .shadow(color: .black.opacity(0.46), radius: 26, x: 0, y: 16)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Playback", size: 7, color: Palette.dim.color, trackingEm: 0.16)
                Text("Time travel")
                    .font(.atlasSans(17, .medium))
                    .tracking(-0.3)
                    .foregroundColor(Palette.text.color)
            }
            Spacer()
            Button {
                runtime.replayJumpOpen = false
            } label: {
                CloseGlyph(size: 10, color: Palette.muted.color)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.rgba("090503", 0.28)))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .accessibilityLabel("Close time travel")
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("RANGE")
                    .font(.atlasMono(6.4, .regular))
                    .tracking(6.4 * 0.1)
                    .foregroundColor(Palette.faint.color)
                Spacer()
                Text(range.detail.uppercased())
                    .font(.atlasMono(6.2, .regular))
                    .tracking(6.2 * 0.04)
                    .foregroundColor(Palette.dim.color)
            }
            HStack(spacing: 1) {
                ForEach(ReplayRange.allCases) { option in
                    SegmentButton(title: option.title, active: range == option) {
                        range = option
                        clampDate()
                    }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("090503", 0.35)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
        }
    }

    private var jumpField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("START AT")
                    .font(.atlasMono(6.4, .regular))
                    .tracking(6.4 * 0.1)
                    .foregroundColor(Palette.faint.color)
                Spacer()
                Text("LOCAL TIME")
                    .font(.atlasMono(5.8, .regular))
                    .tracking(5.8 * 0.06)
                    .foregroundColor(Palette.faint.color)
            }
            DatePicker("", selection: $date, in: dateBounds,
                       displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()
                .font(.atlasSans(10.5, .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Replay start time")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if runtime.replayLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).tint(Palette.gold.color)
                    Text("Reading history from Pi-hole…")
                        .font(.atlasSans(9, .regular))
                        .foregroundColor(Palette.muted.color)
                }
            } else if runtime.isReplay {
                HStack(spacing: 5) {
                    Circle().fill(Palette.gold.color).frame(width: 4, height: 4)
                        .shadow(color: Palette.gold.opacity(0.7), radius: 3)
                    Text("\(Format.compact(runtime.replayTotal)) playable · \(runtime.replayRangeTitle)")
                        .font(.atlasMono(6.5, .regular))
                        .tracking(6.5 * 0.03)
                        .foregroundColor(Palette.muted.color)
                    Spacer(minLength: 2)
                    Text(runtime.replaySourceLabel.uppercased())
                        .font(.atlasMono(5.8, .regular))
                        .foregroundColor(Palette.faint.color)
                }
                Text(replayDetail)
                    .font(.atlasSans(8.4, .regular))
                    .foregroundColor(Palette.dim.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(runtime.isLiveSource
                     ? "Pi-hole keeps this on its own disk. Atlas reads it once and plays it locally; nothing is written back."
                     : "The demo builds a local archive so you can rehearse time travel without a Pi-hole.")
                    .font(.atlasSans(8.6, .regular))
                    .lineSpacing(1.4)
                    .foregroundColor(Palette.dim.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("LOOP")
                    .font(.atlasMono(6.4, .regular))
                    .tracking(6.4 * 0.08)
                    .foregroundColor(Palette.faint.color)
                TinyToggle(isOn: $runtime.replayLoop, label: "Loop replay")
                Spacer()
                Text("SPACE PAUSES")
                    .font(.atlasMono(5.6, .regular))
                    .tracking(5.6 * 0.04)
                    .foregroundColor(Palette.faint.color)
            }
            .padding(.top, 2)
        }
    }

    private var replayDetail: String {
        let verb = runtime.isLiveSource ? "rows read" : "rows modelled"
        var parts = ["\(Format.count(runtime.replayScanned)) \(verb)"]
        if runtime.replaySkipped > 0 {
            parts.append("\(Format.count(runtime.replaySkipped)) outside the top-N graph")
        }
        if runtime.replaySampled {
            parts.append("sampled for a lighter archive")
        }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 6) {
            MiniActionButton(title: "Play", primary: true, action: play)
                .disabled(runtime.replayLoading)
            MiniActionButton(title: "Live", action: {
                runtime.goLive()
                runtime.replayJumpOpen = false
            })
            .disabled(!runtime.isReplay && !runtime.replayLoading)
            Spacer()
            Text(runtime.isReplay ? "JUMP" : "START")
                .font(.atlasMono(5.8, .regular))
                .tracking(5.8 * 0.08)
                .foregroundColor(Palette.faint.color)
        }
    }

    private var dateBounds: ClosedRange<Date> {
        if runtime.isReplay,
           range.hours == runtime.replayRangeHours,
           runtime.replayEnd > runtime.replayStart {
            let lower = Date(timeIntervalSince1970: runtime.replayStart / 1000)
            let upper = Date(timeIntervalSince1970: runtime.replayEnd / 1000)
            return lower...upper
        }
        let now = Date()
        let start = now.addingTimeInterval(-Double(range.hours) * 3_600 - 60)
        return start...now.addingTimeInterval(60)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        range = ReplayRange.nearest(hours: runtime.replayRangeHours)
        if runtime.isReplay, runtime.replayTime > 0 {
            date = Date(timeIntervalSince1970: runtime.replayTime / 1000)
        } else {
            date = Date().addingTimeInterval(-Double(range.hours) * 3_600)
        }
        clampDate()
    }

    private func clampDate() {
        let bounds = dateBounds
        if date < bounds.lowerBound { date = bounds.lowerBound }
        if date > bounds.upperBound { date = bounds.upperBound }
    }

    private func play() {
        let anchor = date.timeIntervalSince1970 * 1000
        let insideLoadedRange = runtime.isReplay
            && range.hours == runtime.replayRangeHours
            && anchor >= runtime.replayStart
            && anchor <= runtime.replayEnd
        if insideLoadedRange {
            runtime.seekReplay(to: anchor, preRoll: true)
            runtime.setPaused(false)
            runtime.replayJumpOpen = false
        } else {
            runtime.enterReplay(hours: range.hours, at: anchor)
        }
    }
}
