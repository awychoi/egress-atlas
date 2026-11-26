import SwiftUI

/// Compact camera controls. They sit in the dock's utility row rather than a
/// second floating toolbar, so zoom, orbit, reset, top view, Face hit and
/// auto-orbit stay discoverable without competing with the field.
struct CameraHUD: View {
    @ObservedObject var runtime: AtlasRuntime
    var compact = false

    private var host: Bool { runtime.displayedGlobe == .host }
    private var accent: Color { host ? Palette.host.color : Palette.gold.color }
    private var inactive: Color { host ? Palette.hostMeta.color : Palette.dim.color }
    private var glyphColor: Color { host ? Palette.hostMuted.color : Palette.muted.color }
    private var separatorColor: Color { host ? Palette.hostText.opacity(0.08) : Palette.text.opacity(0.08) }

    var body: some View {
        HStack(spacing: 1) {
            glyph("minus.magnifyingglass", help: "Zoom out (−)") { runtime.zoomBy(1.22) }
            glyph("plus.magnifyingglass", help: "Zoom in (+)") { runtime.zoomBy(0.82) }
            separator
            glyph("arrow.counterclockwise", help: "Rotate left (←)") { runtime.orbitStep(yaw: -0.22) }
            glyph("arrow.clockwise", help: "Rotate right (→)") { runtime.orbitStep(yaw: 0.22) }
            separator
            glyph("viewfinder", help: "Face the last hit plane (H)") { runtime.faceHitCamera() }
            glyph("arrow.uturn.backward.circle", help: "Reset camera (R)") { runtime.resetCamera() }
            glyph("arrow.up.to.line", help: "Top view") { runtime.topCamera() }
            separator
            autoOrbit
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera controls")
    }

    private var autoOrbit: some View {
        Button {
            runtime.setSpin(!runtime.spinEnabled)
            runtime.showToast(runtime.spinEnabled ? "Auto orbit on" : "Auto orbit off", tone: .signal)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9.5, weight: .regular))
                    .foregroundColor(runtime.spinEnabled ? accent : inactive)
                if !compact {
                    Text("AUTO")
                        .font(.atlasMono(6.4, .regular))
                        .tracking(6.4 * 0.1)
                        .foregroundColor(runtime.spinEnabled ? accent : inactive)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(runtime.spinEnabled ? accent.opacity(0.09) : .clear))
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .help("Auto-orbit the camera when idle (O)")
        .accessibilityLabel("Auto orbit")
    }

    private func glyph(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 9.5, weight: .regular))
                .foregroundColor(glyphColor)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(AtlasPlainButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private var separator: some View {
        Rectangle()
            .fill(separatorColor)
            .frame(width: 1, height: 12)
            .padding(.horizontal, 1)
    }
}
