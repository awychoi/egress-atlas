import SwiftUI

struct AtlasDock: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: metrics.tiny ? 9 : 16) {
                clock.layoutPriority(1)
                pulse
                transport.fixedSize(horizontal: true, vertical: false).layoutPriority(2)
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
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(text: "Live", size: 6.5, color: Palette.dim.color, trackingEm: 0.16)
            Text(runtime.clock)
                .font(.atlasMono(metrics.tiny ? 16 : 18, .regular))
                .tracking(-18 * 0.055)
                .foregroundColor(Palette.gold.color)
                .monospacedDigit()
            Text((runtime.paused ? "PAUSED" : (runtime.speed == 1 ? "STREAMING" : "STREAMING · \(Format.rate(runtime.speed))×")).uppercased())
                .font(.atlasMono(6.3, .regular))
                .tracking(6.3 * 0.11)
                .foregroundColor(runtime.paused ? Palette.coral.color : Palette.faint.color)
        }
        .frame(minWidth: metrics.tiny ? 100 : 118, alignment: .leading)
    }

    private var pulse: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !metrics.tiny {
                    Text("QUERIES / SECOND")
                        .font(.atlasMono(6.4, .regular))
                        .tracking(6.4 * 0.11)
                        .foregroundColor(Palette.dim.color)
                }
                Text(Format.rate(runtime.qps))
                    .font(.atlasMono(11, .regular))
                    .tracking(-0.2)
                    .foregroundColor(Palette.text2.color)
                    .monospacedDigit()
                if !metrics.tiny {
                    Spacer(minLength: 4)
                    Text("\(Format.count(runtime.pulseTotal)) IN THE LAST 90S")
                        .font(.atlasMono(6, .regular))
                        .tracking(6 * 0.03)
                        .foregroundColor(Palette.faint.color)
                }
            }
            PulseChart(buckets: runtime.pulse, scaleMax: runtime.pulseScaleMax, current: runtime.pulseCurrent)
                .frame(height: 28)
                .animation(.easeOut(duration: 0.24), value: runtime.pulseCurrent.total)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Button {
                runtime.setPaused(!runtime.paused)
            } label: {
                Group {
                    if runtime.paused { PlayGlyph(size: 14, color: Palette.gold.color) }
                    else { PauseGlyph(size: 14, color: Palette.muted.color) }
                }
                .frame(width: 31, height: 31)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(runtime.paused ? Palette.gold.opacity(0.09) : Color.rgba("0f0805", 0.62)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(runtime.paused ? Palette.gold.opacity(0.36) : Palette.text.opacity(0.11), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .help(runtime.paused ? "Resume live traffic (Space)" : "Pause live traffic (Space)")
            .accessibilityLabel(runtime.paused ? "Resume live traffic" : "Pause live traffic")

            HStack(spacing: 1) {
                ForEach([Float(1), 2, 4], id: \.self) { value in
                    Button {
                        runtime.setSpeed(value)
                        if runtime.paused { runtime.setPaused(false) }
                    } label: {
                        Text("\(Int(value))×")
                            .font(.atlasMono(7, .regular))
                            .tracking(7 * 0.02)
                            .foregroundColor(runtime.speed == value ? Palette.gold.color : Palette.dim.color)
                            .padding(.horizontal, metrics.tiny ? 4 : 6)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 3)
                                .fill(runtime.speed == value ? Palette.gold.opacity(0.09) : .clear))
                    }
                    .buttonStyle(AtlasPlainButtonStyle())
                    .disabled(runtime.isLiveSource)
                }
            }
            .opacity(runtime.isLiveSource ? 0.35 : 1)
            .help(runtime.isLiveSource ? "Speed is demo-only; Pi-hole is the live clock" : "")
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("090503", 0.35)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))

            Button {
                runtime.setPaused(false)
                runtime.setSpeed(1)
            } label: {
                Text(runtime.paused ? "RESUME" : "LIVE")
                    .font(.atlasMono(6.8, .regular))
                    .tracking(6.8 * 0.1)
                    .foregroundColor(runtime.paused || runtime.speed != 1 ? Palette.sage.color : Palette.faint.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(runtime.paused || runtime.speed != 1 ? Palette.sage.opacity(0.05) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(runtime.paused || runtime.speed != 1 ? Palette.sage.opacity(0.22) : Palette.text.opacity(0.062),
                                      lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
        }
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

struct PulseChart: View {
    let buckets: [PulseBucket]
    let scaleMax: Int
    let current: PulseBucket

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let step = width / 90
            let barWidth = max(1, step - 1)
            let maxValue = CGFloat(max(1, scaleMax))
            Canvas { ctx, size in
                var time = 0.0
                for (i, bucket) in buckets.enumerated() {
                    let total = bucket.total
                    guard total > 0 else { continue }
                    let ratio = min(1, CGFloat(total) / maxValue)
                    let barHeight = max(1, (size.height - 1) * ratio)
                    let rect = CGRect(x: CGFloat(i) * step, y: size.height - barHeight - 1,
                                      width: barWidth, height: barHeight)
                    let isNow = i == buckets.count - 1
                    let blocked = bucket.blocked > bucket.allowed
                    let colors: [Color]
                    if isNow {
                        colors = [Palette.white.color, Palette.gold.opacity(0.5)]
                    } else if blocked {
                        colors = [Color.rgba("e08068", 0.94), Color.rgba("e08068", 0.28)]
                    } else {
                        colors = [Color.rgba("f8c65b", 0.9), Color.rgba("f8c65b", 0.3)]
                    }
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 0.8),
                             with: .linearGradient(Gradient(colors: colors),
                                                   startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                   endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                    time += 1
                }
            }
            .frame(height: height)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Palette.text.opacity(0.062)).frame(height: 1)
            }
        }
        .frame(height: 28)
    }
}

struct FieldCaption: View {
    @ObservedObject var runtime: AtlasRuntime
    var body: some View {
        VStack(spacing: 5) {
            Eyebrow(text: "Live", size: 7, color: Palette.faint.color, trackingEm: 0.22)
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
