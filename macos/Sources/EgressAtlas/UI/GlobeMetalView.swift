import SwiftUI
import MetalKit
import AppKit
import QuartzCore

/// How the field's frame loop is pumped.
///
/// `displayLink` schedules callbacks in step with the display the view is on
/// and is the shipping default. The others exist so frame pacing can be
/// compared from the command line without rebuilding:
///
///     ATLAS_CLOCK=displaylink EgressAtlas   (default)
///     ATLAS_CLOCK=timer                     (60 Hz RunLoop timer)
///     ATLAS_CLOCK=async                     (main-queue timer chain)
private enum FrameClockMode: String {
    case displayLink
    case timer
    case async
}

final class GlobeMTKView: MTKView {
    weak var runtime: AtlasRuntime?
    private var clickOrigin: CGPoint?
    private var dragOrigin: CGPoint?
    private var panOrigin: CGPoint?
    private var windowOriginAtMouseDown: CGPoint?
    private var tracking: NSTrackingArea?
    private var occlusionObserver: NSObjectProtocol?
    private var moveObservers: [NSObjectProtocol] = []
    private var frameGeneration = 0
    private var sceneVisible = true
    private var frameWorkSamples = 0
    private var accumulatedWork: Double = 0
    private var framesDrawn = 0

    // Frame pacing diagnostics. These describe the delivered cadence (the
    // thing the eye sees), not just the render cost.
    private var clockMode: FrameClockMode = .displayLink
    private var frameLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var pacingStart: CFTimeInterval = 0
    private var pacingLast: CFTimeInterval = 0
    private var pacingSamples = 0
    private var pacingIntervalSum: Double = 0
    private var pacingIntervalMax: Double = 0
    private var pacingLateSum: Double = 0
    private var pacingLateMax: Double = 0
    private var scheduledDeadline: CFTimeInterval = 0

    override var acceptsFirstResponder: Bool { true }

    deinit {
        frameGeneration += 1
        stopClock()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        for observer in moveObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func stopClock() {
        frameLink?.invalidate()
        frameLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        AtlasDiagnostics.log("viewDidMoveToWindow window=\(window != nil) gen=\(frameGeneration)")
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        for observer in moveObservers { NotificationCenter.default.removeObserver(observer) }
        moveObservers.removeAll()
        guard let window else {
            frameGeneration += 1
            stopClock()
            return
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            self.sceneVisible = window.occlusionState.contains(.visible)
            if self.sceneVisible { (self.delegate as? GlobeRenderer)?.resetClock() }
        }
        // Moving the frame should not disturb the camera unless the optional
        // window-drag coupling is enabled. The runtime decides; this view only
        // reports the window's move lifecycle.
        let willMove = NotificationCenter.default.addObserver(
            forName: NSWindow.willMoveNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.runtime?.setWindowMoving(true)
        }
        let didMove = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.runtime?.setWindowMoving(false)
        }
        moveObservers = [willMove, didMove]
        sceneVisible = window.occlusionState.contains(.visible)

        // Drive the field from a clock that is synchronised to the display.
        // The old loop paired a main-queue `asyncAfter` chain with a
        // per-frame `needsDisplay`/`isPaused` toggle; that produced only
        // ~22–24 presented frames/s even though the renderer itself used
        // 0.8 ms CPU and 1.6 ms GPU. The display link fires with the display's
        // refresh and the single `draw()` path below is the only one that
        // presents. See FrameClockMode for the measurement fallbacks.
        frameGeneration += 1
        startClock()
    }

    private func startClock() {
        stopClock()
        let raw = ProcessInfo.processInfo.environment["ATLAS_CLOCK"] ?? "displaylink"
        clockMode = FrameClockMode(rawValue: raw) ?? .displayLink
        isPaused = true
        // A restarted clock must not hand the renderer a stale dt.
        (delegate as? GlobeRenderer)?.resetClock()
        switch clockMode {
        case .displayLink:
            let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
            // Ask for the authored 60; the 30 minimum lets the system step
            // down on a low-power or idle display. Panels that cannot take a
            // frame-rate range present at their native refresh (the 72 Hz
            // development display does), which is the smoothest option there.
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            frameLink = link
        case .async:
            scheduleAsyncFrame(generation: frameGeneration)
        case .timer:
            let timer = Timer(timeInterval: 1.0 / 60.0, target: self,
                              selector: #selector(timerFired(_:)), userInfo: nil, repeats: true)
            timer.tolerance = 0.001
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
        resetPacing()
        AtlasDiagnostics.log("frame clock attached mode=\(clockMode.rawValue)")
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        frameStep()
    }

    @objc private func timerFired(_ timer: Timer) {
        frameStep()
    }

    private func scheduleAsyncFrame(generation: Int, after delay: Double = 1.0 / 60.0) {
        scheduledDeadline = CACurrentMediaTime() + delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.window != nil, generation == self.frameGeneration else { return }
            self.frameStep()
            self.scheduleAsyncFrame(generation: generation,
                                    after: max(0, 1.0 / 60.0 - self.lastFrameWork))
        }
    }

    private var lastFrameWork: Double = 0

    private func resetPacing() {
        pacingStart = 0
        pacingLast = 0
        pacingSamples = 0
        pacingIntervalSum = 0
        pacingIntervalMax = 0
        pacingLateSum = 0
        pacingLateMax = 0
        frameWorkSamples = 0
        accumulatedWork = 0
        scheduledDeadline = 0
    }

    private func recordPacing(work: Double) {
        let now = CACurrentMediaTime()
        if pacingLast > 0 {
            let interval = now - pacingLast
            pacingIntervalSum += interval
            pacingIntervalMax = max(pacingIntervalMax, interval)
            if scheduledDeadline > 0 {
                let late = max(0, now - scheduledDeadline)
                pacingLateSum += late
                pacingLateMax = max(pacingLateMax, late)
            }
            pacingSamples += 1
        } else {
            pacingStart = now
        }
        pacingLast = now
        lastFrameWork = work
        accumulatedWork += work
        frameWorkSamples += 1
        guard pacingSamples >= 120 else { return }

        let seconds = max(0.0001, now - pacingStart)
        let fps = Double(pacingSamples) / seconds
        let avgInterval = pacingIntervalSum / Double(pacingSamples) * 1000
        let avgWork = accumulatedWork / Double(frameWorkSamples) * 1000
        let active = NSApp.isActive ? 1 : 0
        let key = window?.isKeyWindow == true ? 1 : 0
        let visible = sceneVisible ? 1 : 0
        AtlasDiagnostics.log(String(
            format: "pacing mode=%@ fps=%.1f interval=%.2fms max=%.2fms late=%.2fms maxlate=%.2fms work=%.2fms active=%d key=%d visible=%d",
            clockMode.rawValue, fps, avgInterval, pacingIntervalMax * 1000,
            pacingLateSum / Double(pacingSamples) * 1000, pacingLateMax * 1000,
            avgWork, active, key, visible))
        resetPacing()
    }

    private func frameStep() {
        guard let window else { return }
        sceneVisible = window.occlusionState.contains(.visible)
        let forceVisible = ProcessInfo.processInfo.environment["ATLAS_ALWAYS_VISIBLE"] == "1"
        // Render the opening frames even if the window server reports the
        // window occluded during launch; otherwise a visible restored window
        // can sit black until it is clicked. After the warm-up, skip work for
        // genuinely hidden windows.
        let canDraw = (sceneVisible || forceVisible || framesDrawn < 90)
            && bounds.width > 1 && bounds.height > 1
        guard canDraw else { return }
        let workStart = CACurrentMediaTime()
        // A manual draw is the only path that may run. The old loop also set
        // `needsDisplay` and toggled `isPaused` around this call, which made
        // AppKit schedule a second, redundant display pass; even with a
        // display link firing at 72 Hz, only ~24 frames/s reached the screen.
        draw()
        framesDrawn += 1
        recordPacing(work: CACurrentMediaTime() - workStart)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func topPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private var windowDragSpinsGlobe: Bool { runtime?.windowDragSpinsGlobe == true }

    /// The top bar is window chrome, not field. The field starts below it.
    private func isOverTopBar(_ p: CGPoint) -> Bool { p.y < 104 }

    /// True when the frame itself moved since the mouse went down. A drag that
    /// moves the window must not also orbit the camera unless the coupling
    /// option is on.
    private func windowMovedSinceMouseDown() -> Bool {
        guard let start = windowOriginAtMouseDown,
              let current = window?.frame.origin else { return false }
        return abs(current.x - start.x) > 0.5 || abs(current.y - start.y) > 0.5
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = topPoint(event)
        if event.clickCount == 2 {
            clickOrigin = nil
            dragOrigin = nil
            windowOriginAtMouseDown = nil
            guard !isOverTopBar(p), let runtime,
                  let pick = runtime.globePick(at: p, viewSize: bounds.size) else { return }
            switch pick {
            case .dns(let selection):
                // The first click of the pair already selected this body.
                // Selecting again must not toggle it off before the camera
                // flight starts, which is why focus owns a non-toggling select.
                runtime.focus(on: selection)
            case .host(let selection):
                runtime.selectHost(selection)
                runtime.focusHostSelection()
            case .focusGlobe(let kind):
                runtime.focusGlobe(kind)
            }
            return
        }
        clickOrigin = p
        dragOrigin = p
        windowOriginAtMouseDown = window?.frame.origin
        if windowDragSpinsGlobe || !isOverTopBar(p) {
            runtime?.orbit(dx: 0, dy: 0, viewSize: bounds.size)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = topPoint(event)
        if let origin = clickOrigin, hypot(p.x - origin.x, p.y - origin.y) > 6 {
            clickOrigin = nil
        }

        // Field drags always orbit. The only exception is a gesture that is
        // really moving the window (top bar or a frame movement under the
        // cursor), and only while the optional coupling is off.
        if !windowDragSpinsGlobe {
            if let dragOrigin, isOverTopBar(dragOrigin) {
                runtime?.endDrag()
                return
            }
            if windowMovedSinceMouseDown() {
                runtime?.endDrag()
                return
            }
        }

        runtime?.orbit(dx: event.deltaX, dy: event.deltaY, viewSize: bounds.size)
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        let origin = clickOrigin
        clickOrigin = nil
        dragOrigin = nil
        windowOriginAtMouseDown = nil
        runtime?.endDrag()
        guard let origin else { return }
        let p = topPoint(event)
        guard hypot(p.x - origin.x, p.y - origin.y) <= 6, !isOverTopBar(p) else { return }
        guard let runtime else { return }
        guard let pick = runtime.globePick(at: p, viewSize: bounds.size) else {
            if runtime.activeGlobe == .host { runtime.clearHostSelection() }
            else { runtime.clearSelection() }
            return
        }
        switch pick {
        case .dns(let selection):
            runtime.select(selection)
        case .host(let selection):
            runtime.selectHost(selection)
        case .focusGlobe(let kind):
            runtime.focusGlobe(kind)
        }
    }

    /// The Metal view fills the window behind the SwiftUI chrome. AppKit still
    /// sends mouse-moved events here while the pointer is over the top bar,
    /// rails, dock, camera HUD or a modal, so blindly setting the globe cursor
    /// there fights the control's own cursor. Treat the chrome regions as
    /// arrow-cursor territory and keep the open/pointing hand for the field.
    private func isOverChrome(_ p: CGPoint, size: CGSize) -> Bool {
        let metrics = Metrics(width: size.width, height: size.height)
        // Top bar: brand, panel switch, source, filters, search, settings.
        if p.y < 104 { return true }
        // Rails.
        if runtime?.leftRailOpen == true, p.x < metrics.edge + metrics.railLeftWidth + 8 { return true }
        if runtime?.rightRailOpen == true, p.x > size.width - metrics.edge - metrics.railRightWidth - 8 { return true }
        // Dock.
        let dockTop = size.height - (metrics.tiny ? 112 : 132)
        if p.y > dockTop, abs(p.x - size.width / 2) < metrics.dockWidth / 2 + 24 { return true }
        // Camera HUD (bottom left, visible when the network rail is closed).
        if !metrics.tiny, runtime?.leftRailOpen == false,
           p.x < metrics.edge + 190, p.y > size.height - 230 { return true }
        return false
    }

    /// Both `mouseMoved` and `cursorUpdate` route through here. AppKit runs a
    /// cursor-rect pass around mouse movement, and its default
    /// `cursorUpdate(with:)` restores the view's arrow after the hand was set.
    /// The SwiftUI chrome above the field invalidates cursor rects often, so
    /// that pass kept winning and the cursor flickered hand → arrow while the
    /// pointer was nowhere near a pickable body. Owning `cursorUpdate` makes
    /// this the single source of truth for the field cursor.
    private func updateCursor(at p: CGPoint, interactive: Bool) {
        guard let runtime else { return }
        // A command palette owns its own I-beam cursor. Do not override it.
        if runtime.commandOpen { return }
        if runtime.settingsOpen || isOverChrome(p, size: bounds.size) {
            NSCursor.arrow.set()
            return
        }
        if clickOrigin != nil || (NSEvent.pressedMouseButtons & 1) != 0 {
            NSCursor.closedHand.set()
            return
        }
        (interactive ? NSCursor.pointingHand : NSCursor.openHand).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let runtime, !runtime.commandOpen else { return }
        let p = topPoint(event)
        let overChrome = runtime.settingsOpen || isOverChrome(p, size: bounds.size)
        let pick = overChrome ? nil : runtime.globePick(at: p, viewSize: bounds.size)
        updateCursor(at: p, interactive: pick != nil)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let runtime else { return }
        let p = topPoint(event)
        // A command palette owns its own I-beam cursor. Do not override it.
        if runtime.commandOpen {
            runtime.setGlobeHover(nil)
            return
        }
        if runtime.settingsOpen || isOverChrome(p, size: bounds.size) {
            runtime.setGlobeHover(nil)
            updateCursor(at: p, interactive: false)
            return
        }
        let pick = runtime.globePick(at: p, viewSize: bounds.size)
        runtime.setGlobeHover(pick)
        updateCursor(at: p, interactive: pick != nil)
    }

    override func mouseExited(with event: NSEvent) {
        runtime?.setGlobeHover(nil)
        NSCursor.arrow.set()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        clickOrigin = nil
        dragOrigin = nil
        windowOriginAtMouseDown = nil
        panOrigin = topPoint(event)
        runtime?.setHovered(nil)
        runtime?.beginPan()
    }

    override func rightMouseDragged(with event: NSEvent) {
        let p = topPoint(event)
        // Use view-space deltas rather than event.deltaY so the globe follows
        // the pointer: dragging down moves it down, dragging up moves it up.
        if let previous = panOrigin {
            runtime?.pan(dx: p.x - previous.x, dy: -(p.y - previous.y),
                         viewSize: bounds.size)
        }
        panOrigin = p
        NSCursor.closedHand.set()
    }

    override func rightMouseUp(with event: NSEvent) {
        panOrigin = nil
        runtime?.endPan()
        let p = topPoint(event)
        let overChrome = runtime?.settingsOpen == true || isOverChrome(p, size: bounds.size)
        let pick = overChrome ? nil : runtime?.globePick(at: p, viewSize: bounds.size)
        runtime?.setGlobeHover(pick)
        updateCursor(at: p, interactive: pick != nil)
    }

    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        clickOrigin = nil
    }

    override func otherMouseDragged(with event: NSEvent) {
        runtime?.orbit(dx: event.deltaX, dy: event.deltaY, viewSize: bounds.size)
    }

    override func otherMouseUp(with event: NSEvent) {
        runtime?.endDrag()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let runtime else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 4
        runtime.zoom(delta, viewSize: bounds.size)
    }

    override func magnify(with event: NSEvent) {
        runtime?.zoom(-event.magnification * 900, viewSize: bounds.size)
    }
}

struct GlobeMetalView: NSViewRepresentable {
    let runtime: AtlasRuntime

    func makeCoordinator() -> Coordinator {
        Coordinator(runtime: runtime)
    }

    func makeNSView(context: Context) -> GlobeMTKView {
        let device = MTLCreateSystemDefaultDevice()!
        let view = GlobeMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        // The display link installed in viewDidMoveToWindow calls draw()
        // directly; keep MTKView's own loop out of the way.
        view.isPaused = true
        view.autoResizeDrawable = true
        view.runtime = runtime
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Live 3D globe of devices and DNS destinations")
        do {
            let renderer = try GlobeRenderer(device: device)
            renderer.runtime = runtime
            context.coordinator.renderer = renderer
            view.delegate = renderer
            AtlasDiagnostics.log("metal view ready")
        } catch {
            AtlasDiagnostics.log("renderer creation failed: \(error)")
            NSLog("[atlas] failed to create renderer: \(error)")
        }
        return view
    }

    func updateNSView(_ nsView: GlobeMTKView, context: Context) {}

    final class Coordinator {
        let runtime: AtlasRuntime
        var renderer: GlobeRenderer?
        init(runtime: AtlasRuntime) { self.runtime = runtime }
    }
}
