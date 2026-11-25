import SwiftUI
import AppKit

/// A still composite used by --ui. The globe is the renderer's own image, so
/// the UI can be inspected without depending on screen-capture permissions.
struct SnapshotRootView: View {
    @ObservedObject var runtime: AtlasRuntime
    let globe: NSImage
    let showBoot: Bool

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(width: geo.size.width, height: geo.size.height)
            ZStack {
                Image(nsImage: globe)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                LabelOverlay(store: runtime.labels)
                    .allowsHitTesting(false)
                    .zIndex(2)
                LabelOverlay(store: runtime.hostLabels)
                    .allowsHitTesting(false)
                    .zIndex(2)
                AtlasChrome(runtime: runtime, metrics: metrics)
                    .zIndex(5)
                if AtlasRenderFlags.snapshot && runtime.replayJumpOpen {
                    VStack {
                        Spacer()
                        ReplayJumpCard(runtime: runtime, metrics: metrics)
                            .padding(.bottom, 168)
                    }
                    .zIndex(30)
                }
                if showBoot {
                    BootOverlay(runtime: runtime)
                        .zIndex(40)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Palette.deep.color)
        }
        .background(Palette.deep.color)
        .preferredColorScheme(.dark)
    }
}

enum UISnapshot {
    static func render(runtime: AtlasRuntime, globe: NSImage, size: CGSize, showBoot: Bool, path: URL) throws {
        let root = SnapshotRootView(runtime: runtime, globe: globe, showBoot: showBoot)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "AtlasSnapshot", code: 1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "AtlasSnapshot", code: 2)
        }
        try data.write(to: path)
    }
}
