import SwiftUI
import AppKit

struct RootView: View {
    @ObservedObject var runtime: AtlasRuntime
    @State private var showBoot = true
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(width: geo.size.width, height: geo.size.height)
            ZStack {
                GlobeMetalView(runtime: runtime)
                    .ignoresSafeArea()
                LabelOverlay(store: runtime.labels)
                    .allowsHitTesting(false)
                    .zIndex(2)
                LabelOverlay(store: runtime.hostLabels)
                    .allowsHitTesting(false)
                    .zIndex(2)
                AtlasChrome(runtime: runtime, metrics: metrics)
                    .zIndex(5)
                if showBoot {
                    BootOverlay(runtime: runtime)
                        .zIndex(40)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .background(runtime.displayedGlobe == .host ? Palette.hostBg.color : Palette.deep.color)
            .onAppear {
                runtime.start()
                installKeyboard()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation(.easeOut(duration: 0.9)) { showBoot = false }
                }
            }
            .onDisappear {
                if let keyMonitor {
                    NSEvent.removeMonitor(keyMonitor)
                    self.keyMonitor = nil
                }
            }
        }
        .ignoresSafeArea()
        .background(runtime.displayedGlobe == .host ? Palette.hostBg.color : Palette.deep.color)
        .preferredColorScheme(.dark)
    }

    private func installKeyboard() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            let typing = NSApp.keyWindow?.firstResponder is NSTextView
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            if modifiers.contains(.command), key == "k" {
                runtime.helpOpen = false
                runtime.settingsOpen = false
                runtime.filterOpen = false
                runtime.commandOpen.toggle()
                return nil
            }
            if event.keyCode == 53 { // escape
                if runtime.commandOpen {
                    runtime.commandOpen = false
                } else if runtime.helpOpen {
                    runtime.helpOpen = false
                } else if runtime.filterOpen {
                    runtime.filterOpen = false
                } else if runtime.settingsOpen {
                    runtime.settingsOpen = false
                } else if runtime.hostSelection != nil {
                    runtime.clearHostSelection()
                } else if runtime.selection != nil {
                    runtime.navigateBack()
                } else {
                    runtime.leftRailOpen = false
                    runtime.rightRailOpen = false
                }
                return nil
            }
            if runtime.commandOpen || typing { return event }
            if modifiers.contains(.command) {
                if key == "1" {
                    runtime.focusGlobe(.dns)
                    return nil
                }
                if key == "2" {
                    runtime.focusGlobe(.host)
                    return nil
                }
                return event
            }
            if !modifiers.isEmpty { return event }

            switch key {
            case "g":
                runtime.toggleGlobe()
                return nil
            case " ":
                if runtime.displayedGlobe == .host {
                    runtime.setHostPaused(!runtime.hostPaused)
                } else {
                    runtime.setPaused(!runtime.paused)
                }
                return nil
            case "f":
                guard runtime.displayedGlobe == .dns else { return event }
                let order: [OutcomeFilter] = [.all, .allowed, .blocked]
                let next = (order.firstIndex(of: runtime.filter) ?? 0) + 1
                runtime.setFilter(order[next % order.count])
                return nil
            case "?", "/":
                runtime.settingsOpen = false
                runtime.helpOpen.toggle()
                return nil
            case "r":
                runtime.resetCamera()
                return nil
            case "l":
                guard runtime.displayedGlobe == .dns else { return event }
                if runtime.isReplay {
                    runtime.goLive()
                } else {
                    runtime.setPaused(false)
                    runtime.setSpeed(1)
                }
                return nil
            case "o":
                runtime.setSpin(!runtime.spinEnabled)
                runtime.showToast(runtime.spinEnabled ? "Auto orbit on" : "Auto orbit off",
                                  tone: .signal)
                return nil
            case "t":
                guard runtime.displayedGlobe == .dns else { return event }
                runtime.setAutoTour(!runtime.autoTour)
                return nil
            case "h":
                guard runtime.displayedGlobe == .dns else { return event }
                runtime.faceHitCamera()
                return nil
            case "+", "=":
                runtime.zoomBy(0.82)
                return nil
            case "-", "_":
                runtime.zoomBy(1.22)
                return nil
            case "1":
                guard runtime.displayedGlobe == .dns else { return event }
                runtime.setSpeed(1)
                return nil
            case "2":
                guard runtime.displayedGlobe == .dns else { return event }
                runtime.setSpeed(2)
                return nil
            case "4":
                guard runtime.displayedGlobe == .dns else { return event }
                runtime.setSpeed(4)
                return nil
            case "[":
                runtime.leftRailOpen.toggle()
                return nil
            case "]":
                runtime.rightRailOpen.toggle()
                return nil
            case "\u{F700}": // up arrow
                runtime.orbitStep(yaw: 0, pitch: 0.18)
                return nil
            case "\u{F701}": // down arrow
                runtime.orbitStep(yaw: 0, pitch: -0.18)
                return nil
            case "\u{F702}": // left arrow
                runtime.orbitStep(yaw: -0.22)
                return nil
            case "\u{F703}": // right arrow
                runtime.orbitStep(yaw: 0.22)
                return nil
            default:
                return event
            }
        }
    }
}
