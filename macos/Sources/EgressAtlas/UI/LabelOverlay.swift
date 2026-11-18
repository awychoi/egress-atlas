import SwiftUI

struct LabelOverlay: View {
    @ObservedObject var store: LabelStore
    @State private var hovered: String?

    var body: some View {
        GeometryReader { geo in
            // Dense label sets update at 24 Hz (12 Hz on very large fields);
            // a linear animation of exactly that interval lets the render
            // server carry the anchor between updates. Small sets resolve
            // every frame and need no animation.
            let anchorAnimation: Animation? = store.animates && store.cadence > 0
                ? .linear(duration: store.cadence)
                : nil
            ZStack(alignment: .topLeading) {
                ForEach(store.labels) { label in
                    // Labels resolve every frame, but their contents (host,
                    // status, badge, detail) change rarely. EquatableView lets
                    // SwiftUI skip rebuilding the text stack when only the
                    // anchor/blur moved; those stay outside the equatable
                    // boundary.
                    AtlasLabelView(label: label)
                        .equatable()
                        .position(x: label.anchor.x, y: label.anchor.y - label.size.height / 2 - 10)
                        .blur(radius: label.blur)
                        .animation(anchorAnimation, value: label.anchor)
                        .transition(.opacity)
                        .zIndex(label.zPriority)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.34), value: store.labels.map(\.id))
    }
}

private extension AtlasLabel {
    var zPriority: Double {
        if hovered { return 3 }
        if selected { return 2 }
        return 1
    }
}

struct AtlasLabelView: View {
    let label: AtlasLabel

    private var accent: Color {
        if label.kind == .device { return Palette.signal.color }
        return label.blocked ? Palette.coral.color : Palette.gold.color
    }

    private var borderColor: Color {
        if label.kind == .device {
            return (label.hovered || label.selected) ? Palette.signalIce.opacity(0.62) : Palette.signal.opacity(0.3)
        }
        if label.blocked {
            return (label.hovered || label.selected) ? Palette.coralHot.opacity(0.6) : Palette.coral.opacity(0.34)
        }
        return (label.hovered || label.selected) ? Palette.signal.opacity(0.52) : Palette.gold.opacity(0.25)
    }

    private var hostColor: Color {
        if label.kind == .device { return Palette.signalIce.color }
        if label.blocked { return SRGB(hex: "ffe8e0").color }
        return (label.hovered || label.selected) ? Palette.signalIce.color : Palette.text2.color
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if label.kind == .device {
                    ZStack {
                        Circle().strokeBorder(Palette.signal.opacity(0.42), lineWidth: 1)
                        TinyDot(color: Palette.signal.color, size: 5, glow: 7)
                    }
                    .frame(width: 12, height: 12)
                } else {
                    Text(label.key)
                        .font(.atlasMono(5.6, .regular))
                        .tracking(5.6 * 0.06)
                        .foregroundColor(label.blocked ? Palette.coral.color : Palette.gold.color)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 16, minHeight: 13)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(label.blocked ? Palette.coral.opacity(0.55) : Palette.gold.opacity(0.34),
                                              lineWidth: 1)
                        )
                }

                Text(label.host)
                    .font(.atlasMono(8.2, .regular))
                    .tracking(8.2 * 0.012)
                    .foregroundColor(hostColor)
                    .lineLimit(1)
                    .fixedSize()

                if let badge = label.badge {
                    Text(badge.uppercased())
                        .font(.atlasMono(5.4, .regular))
                        .tracking(5.4 * 0.12)
                        .foregroundColor(label.blocked ? Palette.coral.color : Palette.signal.color)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .background(label.blocked ? Palette.coral.opacity(0.08) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(label.blocked ? Palette.coral.opacity(0.42) : Palette.signal.opacity(0.3),
                                              lineWidth: 1)
                        )
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.rgba("0c0704", 0.82))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 9, x: 0, y: 4)
            .shadow(color: label.hovered || label.selected ? accent.opacity(0.14) : .clear, radius: 11)

            HStack(spacing: 6) {
                Text(label.meta.uppercased())
                    .font(.atlasMono(6.2, .regular))
                    .tracking(6.2 * 0.08)
                    .foregroundColor(label.blocked ? Color.rgba("e08068", 0.75)
                                     : (label.kind == .device ? Color.rgba("45b8e8", 0.7)
                                        : Color.rgba("8fbea0", 0.8)))
                Circle().fill(Palette.faint.color).frame(width: 2, height: 2)
                Text(label.detail)
                    .font(.atlasMono(6.2, .regular))
                    .tracking(6.2 * 0.08)
                    .foregroundColor(Palette.dim.color)
                    .lineLimit(1)
                    .fixedSize()
            }

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [borderColor.opacity(0.7), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 1, height: 8)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label.accessibilityLabel)
    }
}

extension AtlasLabelView: Equatable {
    /// Contents that require the SwiftUI text stack to be rebuilt. `anchor`
    /// and `blur` are deliberately excluded: they are applied by modifiers
    /// outside the equatable view and change every frame while the camera
    /// moves. Everything the view body reads is compared.
    static func == (lhs: AtlasLabelView, rhs: AtlasLabelView) -> Bool {
        let a = lhs.label
        let b = rhs.label
        return a.id == b.id
            && a.kind == b.kind
            && a.key == b.key
            && a.host == b.host
            && a.badge == b.badge
            && a.meta == b.meta
            && a.detail == b.detail
            && a.blocked == b.blocked
            && a.hovered == b.hovered
            && a.selected == b.selected
            && a.size == b.size
            && a.accessibilityLabel == b.accessibilityLabel
    }
}
