import SwiftUI
import AppKit

enum AtlasRenderFlags {
    static var snapshot = false
}

// Shared chrome primitives. Sizes and colours come straight from
// app/src/styles.css.

/// One legibility floor for the whole native chrome. The web mirror uses the
/// same idea; the reference's 5–8 pt instrument labels are not readable at arm's
/// length. Layout tokens were widened to match.
enum AtlasType {
    static let scale: CGFloat = 1.15
    static let floor: CGFloat = 11
    static func size(_ authored: CGFloat) -> CGFloat { max(floor, authored * scale) }
}

extension Font {
    static func atlasSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: AtlasType.size(size), weight: weight)
    }
    static func atlasMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: AtlasType.size(size), weight: weight, design: .monospaced)
    }
}

struct Eyebrow: View {
    var text: String
    var size: CGFloat = 8
    var color: Color = Palette.muted.color
    var trackingEm: CGFloat = 0.16
    var body: some View {
        Text(text.uppercased())
            .font(.atlasMono(size, .medium))
            .tracking(size * trackingEm)
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Hairline: View {
    var color: Color = Palette.text.opacity(0.062)
    var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blending
        nsView.state = .active
    }
}

/// Warm dark glass used by the rails, dock, palette and settings.
struct WarmGlass: View {
    var radius: CGFloat = 12
    var strong = false
    var body: some View {
        ZStack {
            if !AtlasRenderFlags.snapshot {
                VisualEffectView(material: .hudWindow, blending: .withinWindow)
                    .opacity(0.55)
            }
            LinearGradient(
                stops: [
                    .init(color: Color.rgba("2c180f", strong ? 0.78 : 0.58), location: 0),
                    .init(color: Color.rgba("0d0704", strong ? 0.94 : 0.78), location: 0.58),
                    .init(color: Color.rgba("0c0604", strong ? 0.97 : 0.86), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Palette.text.opacity(0.11), lineWidth: 1)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.rgba("fff0da", 0.045))
                .frame(height: 1)
                .padding(.horizontal, 1)
                .padding(.top, 1)
        }
    }
}

struct PanelShadow: ViewModifier {
    var radius: CGFloat
    var opacity: Double
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(opacity), radius: radius, x: 0, y: 18)
    }
}

struct HoverButtonStyle: ButtonStyle {
    var hoverColor: Color = Palette.gold.color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Plain buttons keep their authored materials but must hit-test their whole
/// padded frame, not only the glyph/text run. SwiftUI's plain style otherwise
/// leaves the transparent padding around a label non-clickable.
struct AtlasPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct TinyDot: View {
    var color: Color
    var size: CGFloat = 4
    var glow: CGFloat = 7
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.8), radius: glow / 2)
    }
}

struct MiniActionButton: View {
    var title: String
    var primary = false
    var danger = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.atlasMono(6.8, .regular))
                .tracking(6.8 * 0.08)
                .foregroundColor(primary ? Color.rgba("241108", 1) : (danger ? Palette.coral.color : Palette.text2.color))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(primary ? Palette.gold.color
                              : (hover ? Palette.gold.opacity(0.1)
                                 : Color.rgba("120a06", 0.55)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(primary ? Color.rgba("ffdb8f", 0.8)
                                      : (danger ? Palette.coral.opacity(0.26)
                                         : (hover ? Palette.gold.opacity(0.28) : Palette.text.opacity(0.11))),
                                      lineWidth: 1)
                )
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .onHover { hover = $0 }
    }
}

struct SegmentButton: View {
    var title: String
    var active: Bool
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.atlasMono(6.8, .regular))
                .tracking(6.8 * 0.04)
                .foregroundColor(active ? Palette.gold.color : (hover ? Palette.text2.color : Palette.dim.color))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(active ? Palette.gold.opacity(0.09) : .clear)
                )
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .onHover { hover = $0 }
    }
}

struct TinyToggle: View {
    @Binding var isOn: Bool
    var label: String = "Toggle"
    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Palette.signal.opacity(0.1) : Color.rgba("0b0603", 0.6))
                    .overlay(Capsule().strokeBorder(isOn ? Palette.signal.opacity(0.42) : Palette.text.opacity(0.2), lineWidth: 1))
                    .frame(width: 30, height: 16)
                Circle()
                    .fill(isOn ? Palette.signal.color : Palette.dim.color)
                    .frame(width: 12, height: 12)
                    .shadow(color: isOn ? Palette.signal.opacity(0.55) : .clear, radius: 3.5)
                    .padding(1)
            }
            .frame(width: 42, height: 30)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.22), value: isOn)
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint("Double-tap to toggle")
    }
}

/// CSS range input: gradient track and a glowing 10 px thumb.
struct AtlasSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var label: String = "Slider"
    var onChanged: (Double) -> Void = { _ in }
    @State private var dragging = false

    private func adjust(_ direction: Int) {
        let delta = step > 0 ? step : (range.upperBound - range.lowerBound) / 20
        let next = min(range.upperBound, max(range.lowerBound, value + Double(direction) * delta))
        value = next
        onChanged(next)
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fraction = (value - range.lowerBound) / max(0.0001, range.upperBound - range.lowerBound)
            let x = min(width, max(0, width * fraction))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(colors: [Palette.signal.opacity(0.55), Palette.gold.opacity(0.52)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(height: 2)
                Circle()
                    .fill(Palette.text.color)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Palette.gold.opacity(0.9), lineWidth: 1))
                    .shadow(color: Palette.gold.opacity(0.35), radius: 5)
                    .shadow(color: Palette.gold.opacity(0.1), radius: 2)
                    .offset(x: x - 5)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        let f = min(1, max(0, g.location.x / width))
                        var v = range.lowerBound + f * (range.upperBound - range.lowerBound)
                        if step > 0 { v = (v / step).rounded() * step }
                        value = min(range.upperBound, max(range.lowerBound, v))
                        onChanged(value)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: step >= 1 ? "%.0f" : "%.1f", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(1)
            case .decrement: adjust(-1)
            @unknown default: break
            }
        }
    }
}

struct SectionKicker: View {
    var title: String
    var value: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Eyebrow(text: title, size: 7.5, color: Palette.gold.color, trackingEm: 0.14)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .font(.atlasMono(6, .regular))
                    .tracking(6 * 0.04)
                    .foregroundColor(Palette.faint.color)
            }
        }
    }
}

// ── custom marks ─────────────────────────────────────────────────────────

struct AtlasDeviceMark: View {
    var color: Color
    var size: CGFloat = 22
    var body: some View {
        Canvas { ctx, s in
            let k = min(s.width, s.height) / 22
            var p = Path(ellipseIn: CGRect(x: 2.4 * k, y: 2.4 * k, width: 17.2 * k, height: 17.2 * k))
            ctx.stroke(p, with: .color(color.opacity(0.26)), lineWidth: 1 * k)
            p = Path(ellipseIn: CGRect(x: 1.6 * k, y: (11 - 3.2) * k, width: 18.8 * k, height: 6.4 * k))
            p = p.applying(CGAffineTransform(translationX: 11 * k, y: 11 * k)
                .rotated(by: -28 * .pi / 180).translatedBy(x: -11 * k, y: -11 * k))
            ctx.stroke(p, with: .color(color.opacity(0.34)), lineWidth: 1 * k)
            p = Path(ellipseIn: CGRect(x: (11 - 4.2) * k, y: (11 - 9.1) * k, width: 8.4 * k, height: 18.2 * k))
            p = p.applying(CGAffineTransform(translationX: 11 * k, y: 11 * k)
                .rotated(by: 18 * .pi / 180).translatedBy(x: -11 * k, y: -11 * k))
            ctx.stroke(p, with: .color(color.opacity(0.2)), lineWidth: 1 * k)
            ctx.fill(Path(ellipseIn: CGRect(x: 8.5 * k, y: 8.5 * k, width: 5 * k, height: 5 * k)),
                     with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

struct AtlasDestinationMark: View {
    var color: Color
    var size: CGFloat = 22
    var body: some View {
        Canvas { ctx, s in
            let k = min(s.width, s.height) / 22
            var p = Path(ellipseIn: CGRect(x: 2.8 * k, y: 2.8 * k, width: 16.4 * k, height: 16.4 * k))
            ctx.stroke(p, with: .color(color.opacity(0.4)), lineWidth: 1 * k)
            p = Path(ellipseIn: CGRect(x: 1.6 * k, y: (11 - 3.6) * k, width: 18.8 * k, height: 7.2 * k))
            p = p.applying(CGAffineTransform(translationX: 11 * k, y: 11 * k)
                .rotated(by: -22 * .pi / 180).translatedBy(x: -11 * k, y: -11 * k))
            ctx.stroke(p, with: .color(color.opacity(0.34)), lineWidth: 0.8 * k)
            ctx.fill(Path(ellipseIn: CGRect(x: 7.9 * k, y: 7.9 * k, width: 6.2 * k, height: 6.2 * k)),
                     with: .color(color))
            ctx.stroke(Path(ellipseIn: CGRect(x: 0.5 * k, y: 0.5 * k, width: 21 * k, height: 21 * k)),
                       with: .color(color.opacity(0.12)), lineWidth: 1 * k)
        }
        .frame(width: size, height: size)
    }
}

struct SearchGlyph: View {
    var size: CGFloat = 12
    var color: Color = .white
    var body: some View {
        Canvas { ctx, s in
            let k = min(s.width, s.height) / 16
            ctx.stroke(Path(ellipseIn: CGRect(x: 2.4 * k, y: 2.4 * k, width: 9.2 * k, height: 9.2 * k)),
                       with: .color(color), lineWidth: 1.2 * k)
            var p = Path()
            p.move(to: CGPoint(x: 10.5 * k, y: 10.5 * k))
            p.addLine(to: CGPoint(x: 13.7 * k, y: 13.7 * k))
            ctx.stroke(p, with: .color(color), lineWidth: 1.2 * k)
        }
        .frame(width: size, height: size)
    }
}

struct ChevronGlyph: View {
    var left: Bool
    var size: CGFloat = 12
    var color: Color = .white
    var body: some View {
        Canvas { ctx, s in
            let k = min(s.width, s.height) / 16
            var p = Path()
            if left {
                p.move(to: CGPoint(x: 10 * k, y: 3 * k))
                p.addLine(to: CGPoint(x: 5 * k, y: 8 * k))
                p.addLine(to: CGPoint(x: 10 * k, y: 13 * k))
            } else {
                p.move(to: CGPoint(x: 6 * k, y: 3 * k))
                p.addLine(to: CGPoint(x: 11 * k, y: 8 * k))
                p.addLine(to: CGPoint(x: 6 * k, y: 13 * k))
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.3 * k, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

struct CloseGlyph: View {
    var size: CGFloat = 12
    var color: Color = .white
    var body: some View {
        Canvas { ctx, s in
            let k = min(s.width, s.height) / 16
            var p = Path()
            p.move(to: CGPoint(x: 4 * k, y: 4 * k)); p.addLine(to: CGPoint(x: 12 * k, y: 12 * k))
            p.move(to: CGPoint(x: 12 * k, y: 4 * k)); p.addLine(to: CGPoint(x: 4 * k, y: 12 * k))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.2 * k, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
}

struct PlayGlyph: View {
    var size: CGFloat = 14
    var color: Color = .white
    var body: some View {
        Canvas { ctx, s in
            let k = min(s.width, s.height) / 16
            var p = Path()
            p.move(to: CGPoint(x: 5 * k, y: 2.8 * k))
            p.addLine(to: CGPoint(x: 13 * k, y: 8 * k))
            p.addLine(to: CGPoint(x: 5 * k, y: 13.2 * k))
            p.closeSubpath()
            ctx.fill(p, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

struct PauseGlyph: View {
    var size: CGFloat = 14
    var color: Color = .white
    var body: some View {
        Canvas { ctx, s in
            let k = min(s.width, s.height) / 16
            let r = CGRect(x: 4 * k, y: 3 * k, width: 2.6 * k, height: 10 * k)
            let r2 = CGRect(x: 9.4 * k, y: 3 * k, width: 2.6 * k, height: 10 * k)
            ctx.fill(Path(roundedRect: r, cornerRadius: 0.6 * k), with: .color(color))
            ctx.fill(Path(roundedRect: r2, cornerRadius: 0.6 * k), with: .color(color))
        }
        .frame(width: size, height: size)
    }
}
