import AppKit
import SwiftUI
import Foundation

@main
struct EgressAtlasMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--snapshot") {
            SnapshotTool.run(args: args)
            return
        }
        if args.contains("--self-test") {
            SelfTestTool.run()
            return
        }
        if args.contains("--scene-probe") {
            StateProbeTool.run(args: args)
            return
        }
        if args.contains("--host-test") {
            HostTestTool.run(args: args)
            return
        }
        if args.contains("--live-test") {
            LiveTestTool.run(args: args)
            return
        }
        if args.contains("--make-icon") {
            let index = args.firstIndex(of: "--make-icon") ?? 0
            let path = index + 1 < args.count ? args[index + 1] : "AppIcon.iconset"
            IconTool.run(path: path)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var runtime: AtlasRuntime!
    private var clampingWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        installAppIcon()
    }

    /// A bundled launch gets AppIcon.icns from Launch Services. A direct
    /// SwiftPM executable has no bundle icon, so set the official artwork
    /// explicitly for every launch path.
    private func installAppIcon() {
        guard let icon = BrandAssets.appIcon() else {
            AtlasDiagnostics.log("app icon unavailable; using bundle/default icon")
            return
        }
        NSApp.applicationIconImage = icon
        NSApp.dockTile.display()
        AtlasDiagnostics.log("app icon set \(Int(icon.size.width))x\(Int(icon.size.height)) reps=\(icon.representations.count)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let runtime = AtlasRuntime()
        self.runtime = runtime
        let root = RootView(runtime: runtime)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: AtlasLayout.windowDefault)

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0,
                                                           width: 1600, height: 1000)
        let contentSize = NSSize(
            width: max(AtlasLayout.windowMinimum.width,
                       min(AtlasLayout.windowDefault.width, visible.width - 48)),
            height: max(AtlasLayout.windowMinimum.height,
                        min(AtlasLayout.windowDefault.height, visible.height - 48))
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Egress Atlas"
        window.isRestorable = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(srgbRed: 0.031, green: 0.016, blue: 0.008, alpha: 1)
        window.minSize = AtlasLayout.windowMinimum
        window.contentMinSize = window.contentRect(
            forFrameRect: NSRect(origin: .zero, size: AtlasLayout.windowMinimum)
        ).size
        window.delegate = self
        window.center()
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        self.window = window
        AtlasDiagnostics.log("window content=\(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height)) visible=\(Int(visible.width))x\(Int(visible.height))")
        runtime.start()
        runtime.restoreLastSourceIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        installAppIcon()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// `minSize` alone was not enough to keep the compact composition intact,
    /// so clamp every user resize at the window edge as well.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: max(frameSize.width, AtlasLayout.windowMinimum.width),
               height: max(frameSize.height, AtlasLayout.windowMinimum.height))
    }

    /// A backstop for programmatic resizes (window managers, tiling and
    /// restoration paths) that bypass `windowWillResize`.
    func windowDidResize(_ notification: Notification) {
        guard !clampingWindow,
              let window = notification.object as? NSWindow else { return }
        var frame = window.frame
        let minimum = AtlasLayout.windowMinimum
        guard frame.width < minimum.width || frame.height < minimum.height else { return }
        frame.size.width = max(frame.width, minimum.width)
        frame.size.height = max(frame.height, minimum.height)
        clampingWindow = true
        window.setFrame(frame, display: true, animate: false)
        clampingWindow = false
    }

    @objc private func openSettings() { runtime.helpOpen = false; runtime.settingsOpen = true }
    @objc private func togglePaused() { runtime.setPaused(!runtime.paused) }
    @objc private func filterAll() { runtime.setFilter(.all) }
    @objc private func filterAllowed() { runtime.setFilter(.allowed) }
    @objc private func filterBlocked() { runtime.setFilter(.blocked) }
    @objc private func toggleLeft() { runtime.leftRailOpen.toggle() }
    @objc private func toggleRight() { runtime.rightRailOpen.toggle() }
    @objc private func resetCamera() { runtime.resetCamera() }

    @objc private func showFieldGuide() {
        runtime.filterOpen = false
        runtime.settingsOpen = false
        runtime.helpOpen = true
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Egress Atlas", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Egress Atlas", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Egress Atlas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let atlasItem = NSMenuItem()
        main.addItem(atlasItem)
        let atlasMenu = NSMenu(title: "Atlas")
        atlasItem.submenu = atlasMenu
        let pause = NSMenuItem(title: "Pause / Resume", action: #selector(togglePaused), keyEquivalent: "p")
        pause.keyEquivalentModifierMask = [.command, .option]
        pause.target = self
        atlasMenu.addItem(pause)
        let all = NSMenuItem(title: "All Outcomes", action: #selector(filterAll), keyEquivalent: "1")
        all.target = self; atlasMenu.addItem(all)
        let allowed = NSMenuItem(title: "Allowed Only", action: #selector(filterAllowed), keyEquivalent: "2")
        allowed.target = self; atlasMenu.addItem(allowed)
        let blocked = NSMenuItem(title: "Blocked Only", action: #selector(filterBlocked), keyEquivalent: "3")
        blocked.target = self; atlasMenu.addItem(blocked)
        atlasMenu.addItem(.separator())
        let network = NSMenuItem(title: "Toggle Network Panel", action: #selector(toggleLeft), keyEquivalent: "[")
        network.target = self; atlasMenu.addItem(network)
        let traffic = NSMenuItem(title: "Toggle Live Traffic Panel", action: #selector(toggleRight), keyEquivalent: "]")
        traffic.target = self; atlasMenu.addItem(traffic)
        let reset = NSMenuItem(title: "Reset Camera", action: #selector(resetCamera), keyEquivalent: "r")
        reset.keyEquivalentModifierMask = [.command, .shift]
        reset.target = self; atlasMenu.addItem(reset)

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        let guide = NSMenuItem(title: "How to Read This Field", action: #selector(showFieldGuide), keyEquivalent: "")
        guide.target = self
        helpMenu.addItem(guide)

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}
