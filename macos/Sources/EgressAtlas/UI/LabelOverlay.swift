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
                    // anchor/opacity moved; those stay outside the equatable
                    // boundary.
                    AtlasLabelView(label: label)
                        .equatable()
                        .transition(.opacity)
                        .position(x: clampedX(label, width: geo.size.width),
                                  y: clampedY(label, height: geo.size.height))
                        .opacity(label.opacity)
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

    private func clampedX(_ label: AtlasLabel, width: CGFloat) -> CGFloat {
        let half = label.size.width / 2 + 8
        return min(max(label.anchor.x, half), max(half, width - half))
    }

    private func clampedY(_ label: AtlasLabel, height: CGFloat) -> CGFloat {
        let desired = label.anchor.y - label.size.height / 2 - 10
        let top = label.size.height / 2 + 112
        let bottom = height - 152
        return min(max(desired, top), max(top, bottom))
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

    private var hostAccent: SRGB {
        label.kind == .device ? Palette.hostApp : Palette.hostRemote
    }

    private var hostAccentHot: SRGB {
        label.kind == .device ? Palette.hostAppHot : Palette.hostRemoteHot
    }

    private var accent: Color {
        if label.tone == .host {
            return (label.hovered || label.selected) ? hostAccentHot.color : hostAccent.color
        }
        if label.kind == .device { return Palette.signal.color }
        return label.blocked ? Palette.coral.color : Palette.gold.color
    }

    private var borderColor: Color {
        if label.tone == .host {
            return (label.hovered || label.selected)
                ? hostAccentHot.opacity(0.62) : hostAccent.opacity(0.32)
        }
        if label.kind == .device {
            return (label.hovered || label.selected) ? Palette.signalIce.opacity(0.62) : Palette.signal.opacity(0.3)
        }
        if label.blocked {
            return (label.hovered || label.selected) ? Palette.coralHot.opacity(0.6) : Palette.coral.opacity(0.34)
        }
        return (label.hovered || label.selected) ? Palette.signal.opacity(0.52) : Palette.gold.opacity(0.25)
    }

    private var hostColor: Color {
        if label.tone == .host {
            return (label.hovered || label.selected) ? Palette.hostText.color : Palette.hostText2.color
        }
        if label.kind == .device { return Palette.signalIce.color }
        if label.blocked { return SRGB(hex: "ffe8e0").color }
        return (label.hovered || label.selected) ? Palette.signalIce.color : Palette.text2.color
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                if label.kind == .device {
                    let dot = label.tone == .host ? hostAccent : Palette.signal
                    ZStack {
                        Circle().strokeBorder(dot.opacity(0.42), lineWidth: 1)
                        TinyDot(color: dot.color, size: 5, glow: 7)
                    }
                    .frame(width: 12, height: 12)
                } else {
                    let keyColor = label.tone == .host ? hostAccent
                        : (label.blocked ? Palette.coral : Palette.gold)
                    Text(label.key)
                        .font(.atlasMono(5.6, .regular))
                        .tracking(5.6 * 0.06)
                        .foregroundColor(keyColor.color)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 16, minHeight: 13)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(keyColor.opacity(0.4), lineWidth: 1)
                        )
                }

                Text(label.host)
                    .font(.atlasMono(8.2, .regular))
                    .tracking(8.2 * 0.012)
                    .foregroundColor(hostColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let badge = label.badge {
                    let badgeColor = label.tone == .host ? hostAccent
                        : (label.blocked ? Palette.coral : Palette.signal)
                    Text(badge.uppercased())
                        .font(.atlasMono(5.4, .regular))
                        .tracking(5.4 * 0.12)
                        .foregroundColor(badgeColor.color)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .strokeBorder(badgeColor.opacity(0.36), lineWidth: 1)
                        )
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(label.tone == .host ? Color.rgba("050d11", 0.88) : Color.rgba("0c0704", 0.82))
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
                    .foregroundColor(label.tone == .host ? Palette.hostMuted.color
                                     : (label.blocked ? Color.rgba("e08068", 0.75)
                                        : (label.kind == .device ? Color.rgba("45b8e8", 0.7)
                                           : Color.rgba("8fbea0", 0.8))))
                Circle().fill(Palette.faint.color).frame(width: 2, height: 2)
                Text(label.detail)
                    .font(.atlasMono(6.2, .regular))
                    .tracking(6.2 * 0.08)
                    .foregroundColor(label.tone == .host ? Palette.hostMeta.color : Palette.dim.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: max(40, label.size.width - 14), alignment: .leading)
            .clipped()

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
    /// and `opacity` are deliberately excluded: they are applied by modifiers
    /// outside the equatable view and change every frame while the camera
    /// moves. Everything the view body reads is compared.
    static func == (lhs: AtlasLabelView, rhs: AtlasLabelView) -> Bool {
        let a = lhs.label
        let b = rhs.label
        return a.id == b.id
            && a.kind == b.kind
            && a.tone == b.tone
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
