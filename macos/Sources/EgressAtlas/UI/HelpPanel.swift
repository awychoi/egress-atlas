import SwiftUI

/// The field guide that replaced the permanent gesture hint strip. It opens
/// from the top-bar "?" and carries the same movement, legend and keyboard
/// information without occupying the field during normal use.
struct HelpPanel: View {
    @ObservedObject var runtime: AtlasRuntime
    let metrics: Metrics

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionKicker(title: "Moving around")
                        .padding(.top, 10)
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)],
                        spacing: 1
                    ) {
                        gesture("Drag", "Orbit the globe")
                        gesture("Right-drag", "Move the globe freely")
                        gesture("Scroll", "Zoom the field")
                        gesture("Click", "Open details")
                        gesture("Double-click", "Fly to a node")
                    }
                    .padding(.top, 6)

                    Text("Right-drag shifts the globe around the viewport. With auto-orbit on, the globe keeps spinning on its own axis while it moves.")
                        .font(.atlasSans(8.5, .regular))
                        .lineSpacing(1.5)
                        .foregroundColor(Palette.dim.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    Text(runtime.windowDragSpinsGlobe
                         ? "Moving the window also orbits the field."
                         : "Moving the window leaves the field still. Enable Display → Window drag spins globe to couple them.")
                        .font(.atlasSans(8.5, .regular))
                        .lineSpacing(1.5)
                        .foregroundColor(Palette.dim.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)

                    Text("Select a device or destination to set a local alias in the inspector. Aliases never leave this Mac. A device alias replaces the name while its IP stays visible; Display → Show domain with alias puts the original domain back beside a destination alias.")
                        .font(.atlasSans(8.5, .regular))
                        .lineSpacing(1.5)
                        .foregroundColor(Palette.dim.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)

                    Text("The dock timeline is the time machine. Open History, choose a range and a start time, then play the archive back. Drag the timeline to any moment, click 1×, 60×, 600× or 3600× to change the compression, and press Live to return to the Pi-hole clock.")
                        .font(.atlasSans(8.5, .regular))
                        .lineSpacing(1.5)
                        .foregroundColor(Palette.dim.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)

                    legendSection
                        .padding(.top, 12)

                    keysSection
                        .padding(.top, 12)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            foot
        }
        .frame(width: metrics.helpWidth)
        .frame(height: min(metrics.helpHeight, max(280, metrics.height - metrics.railTop - 28)))
        .background(WarmGlass(radius: 12, strong: true))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.text.opacity(0.11), lineWidth: 1))
        .shadow(color: .black.opacity(0.52), radius: 40, x: 0, y: 28)
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How to read this field")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(text: "Field guide", size: 8, color: Palette.muted.color, trackingEm: 0.16)
                Text("How to read this field")
                    .font(.atlasSans(20, .medium))
                    .tracking(-20 * 0.03)
                    .foregroundColor(Palette.text.color)
            }
            Spacer(minLength: 8)
            Button {
                runtime.helpOpen = false
            } label: {
                CloseGlyph(size: 12, color: Palette.muted.color)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.rgba("090503", 0.28)))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Palette.text.opacity(0.062), lineWidth: 1))
            }
            .buttonStyle(AtlasPlainButtonStyle())
            .accessibilityLabel("Close field guide")
        }
        .padding(.horizontal, 15)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func gesture(_ key: String, _ copy: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key.uppercased())
                .font(.atlasMono(6.4, .regular))
                .tracking(6.4 * 0.08)
                .foregroundColor(Palette.gold.color)
                .lineLimit(1)
            Text(copy)
                .font(.atlasSans(9, .regular))
                .foregroundColor(Palette.muted.color)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.rgba("0b0604", 0.54))
    }

    private var legendSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Reading the field")
            VStack(alignment: .leading, spacing: 0) {
                legendRow(Palette.signal.color, "Blue orb", "a local device, on the shell")
                legendRow(Palette.gold.color, "Gold orb", "an allowed DNS destination, inside the globe")
                legendRow(Palette.coral.color, "Coral orb", "a blocked destination with a dashed label")
                legendRow(Palette.signalIce.color, "Icy arc", "device-to-device traffic, not DNS")
            }
            .padding(.top, 7)
        }
    }

    private func legendRow(_ color: Color, _ title: String, _ copy: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .shadow(color: color.opacity(0.75), radius: 3)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 1 }
                Text(title)
                    .font(.atlasSans(9.4, .medium))
                    .foregroundColor(Palette.text2.color)
                    .frame(width: 66, alignment: .leading)
            }
            .frame(width: 78, alignment: .leading)
            Text(copy)
                .font(.atlasSans(9, .regular))
                .foregroundColor(Palette.dim.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.text.opacity(0.045)).frame(height: 1)
        }
    }

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionKicker(title: "Keys", value: "at any time")
            VStack(alignment: .leading, spacing: 0) {
                keyRow("⌘K", "Search and run an action")
                keyRow("[  ]", "Toggle the network and query panels")
                keyRow("Space", "Pause or resume live traffic or replay")
                keyRow("L", "Return to live traffic")
                keyRow("F", "Cycle All · Allowed · Blocked")
                keyRow("R", "Reset the camera")
                keyRow("O", "Toggle auto-orbit")
                keyRow("H", "Face the last impact")
            }
            .padding(.top, 7)
        }
    }

    private func keyRow(_ keys: String, _ copy: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.atlasMono(6.6, .regular))
                .foregroundColor(Palette.muted.color)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.rgba("090503", 0.45)))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Palette.text.opacity(0.08), lineWidth: 1))
                .frame(width: 78, alignment: .leading)
            Text(copy)
                .font(.atlasSans(9, .regular))
                .foregroundColor(Palette.dim.color)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var foot: some View {
        HStack(spacing: 7) {
            Circle().fill(Palette.gold.color).frame(width: 4, height: 4)
                .shadow(color: Palette.gold.opacity(0.8), radius: 3)
            Text("ESC CLOSES · ? REOPENS THIS GUIDE")
                .font(.atlasMono(6.4, .regular))
                .tracking(6.4 * 0.07)
                .foregroundColor(Palette.faint.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Hairline() }
    }
}
