import Foundation
import AppKit
import Metal
import MetalKit

enum SelfTestTool {
    static func run() {
        AtlasPreferences.persists = false
        AtlasDiagnostics.log("self-test start")
        print("Egress Atlas self-test")
        let net = DemoNetwork(seed: 20261116)
        print("devices=\(net.devices.count) destinations=\(net.destinations.count) edges=\(net.edges.count)")
        print("queries=\(net.totals.queries) blocked=\(net.totals.blocked)")
        let runtime = AtlasRuntime()
        runtime.advanceForSnapshot(seconds: 3)
        let picks = runtime.debugPickProbe()
        print("pick destination=\(picks.destination) device=\(picks.device)")
        let failed = runtime.debugEffectSmoke()
        print("effect smoke failed=\(failed)")
        let studyFailed = runtime.debugStudyChecks()
        print("study checks failed=\(studyFailed)")
        let focusFailed = runtime.debugFocusChecks()
        print("focus checks failed=\(focusFailed)")
        let interactionFailed = runtime.debugInteractionChecks()
        print("interaction checks failed=\(interactionFailed)")
        let windowFailed = runtime.debugWindowChecks()
        print("window checks failed=\(windowFailed)")
        let liveFailed = runtime.debugLiveChecks()
        print("live checks failed=\(liveFailed)")
        let replayFailed = runtime.debugReplayChecks()
        print("replay checks failed=\(replayFailed)")
        let net2 = DemoNetwork(seed: 20261116)
        let src = LiveSource(network: net2, seed: 20261123, rate: 2.85)
        var q = 0
        src.queryListeners.append { _ in q += 1 }
        for _ in 0..<50 { src.update(realDt: 0.12) }
        print("source queries=\(q) totalLive=\(src.totalLive) qps=\(src.getQps()) recent=\(src.recent.count)")
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("no Metal device"); exit(2)
        }
        do {
            _ = try GlobeRenderer(device: device)
            print("metal renderer OK")
        } catch {
            print("metal renderer FAILED: \(error)"); exit(3)
        }
        exit(0)
    }
}

enum LiveTestTool {
    static func run(args: [String]) {
        AtlasPreferences.persists = false
        func value(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if args.contains("--clear-source") {
            PiHoleCredentials.clear()
            print("source credentials cleared")
            exit(0)
        }
        let password = value("--password") ?? ""
        let insecure = args.contains("--insecure")
        if args.contains("--keychain-probe") {
            do {
                try PiHoleCredentials.save(password: "probe")
                print("keychain probe=ok has=\(PiHoleCredentials.hasPassword)")
            } catch {
                print("keychain probe=failed \(error.localizedDescription)")
            }
            PiHoleCredentials.clear()
            exit(0)
        }
        guard let rawURL = value("--url") else {
            print("usage: EgressAtlas --live-test --url http://127.0.0.1:PORT [--password pass] [--insecure]")
            exit(2)
        }
        Task {
            do {
                let client = try PiHoleClient(rawURL: rawURL, password: password, insecure: insecure)
                if args.contains("--history-test") {
                    let now = Date().timeIntervalSince1970 * 1000
                    let hours = Double(value("--history-hours") ?? "24") ?? 24
                    let from = now - hours * 3_600_000
                    let snapshot = try await client.history(from: from, until: now,
                                                            limit: 20_000, disk: true)
                    let network = try LiveNetworkBuilder.make(snapshot: snapshot)
                    let source = PiHoleSource(network: network, client: client, initial: snapshot)
                    let archive = try await source.loadReplay(from: from, until: now, maxEvents: 20_000)
                    print("history rows=\(snapshot.rows.count) earliest=\(snapshot.earliestTimestampDisk ?? -1)")
                    print("history network devices=\(network.devices.count) destinations=\(network.destinations.count)")
                    print("replay events=\(archive.events.count) scanned=\(archive.scannedRows) skipped=\(archive.skippedRows) buckets=\(archive.buckets.count) sampled=\(archive.sampled)")
                    if let first = archive.events.first, let last = archive.events.last {
                        print("replay span=\(Int((last.ts - first.ts) / 1000))s")
                    }
                    exit(0)
                }
                let snapshot = try await client.snapshot()
                let network = try LiveNetworkBuilder.make(snapshot: snapshot)
                print("endpoint=\(snapshot.endpoint)")
                print("rows=\(snapshot.rows.count) devices=\(network.devices.count) destinations=\(network.destinations.count) edges=\(network.edges.count)")
                print("queries=\(network.totals.queries) blocked=\(network.totals.blocked) allowed=\(network.totals.allowed)")
                for device in network.devices.prefix(3) {
                    print("device \(device.name) \(device.ip) q=\(device.liveQueries) b=\(device.liveBlocked)")
                }
                for destination in network.destinations.prefix(3) {
                    print("destination \(destination.domain) \(destination.status.rawValue) q=\(destination.liveQueries)")
                }
                let source = PiHoleSource(network: network, client: client, initial: snapshot)
                var live = 0
                source.queryListeners.append { _ in live += 1 }
                source.statusListener = { error in
                    if let error { print("source status: \(error)") }
                }
                source.start()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    let poll = try await client.poll()
                    print("direct poll rows=\(poll.rows.count) newest=\(poll.rows.last?.id ?? "none")")
                } catch {
                    print("direct poll failed: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                source.stop()
                print("source recent=\(source.recent.count) totalLive=\(source.totalLive) polled=\(live) qps=\(source.getQps())")

                let runtimeBox = await MainActor.run { () -> AtlasRuntime in
                    let runtime = AtlasRuntime()
                    runtime.start()
                    runtime.connectPiHole(url: rawURL, password: password, insecure: insecure,
                                          rememberChoice: false)
                    return runtime
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run {
                    print("runtime live=\(runtimeBox.isLiveSource) devices=\(runtimeBox.network.devices.count) destinations=\(runtimeBox.network.destinations.count) feed=\(runtimeBox.feed.count) error=\(runtimeBox.sourceError ?? "none")")
                    print("keychain hasPassword=\(PiHoleCredentials.hasPassword) savedURL=\(PiHoleCredentials.savedURL) notice=\(runtimeBox.sourceNotice ?? "none")")
                    runtimeBox.enterReplay(hours: 24)
                }
                let replayDeadline = Date().addingTimeInterval(30)
                while Date() < replayDeadline {
                    let state = await MainActor.run { (runtimeBox.isReplay, runtimeBox.replayLoading) }
                    if state.0 || !state.1 { break }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                await MainActor.run {
                    print("runtime replay=\(runtimeBox.isReplay) events=\(runtimeBox.replayTotal) scanned=\(runtimeBox.replayScanned) skipped=\(runtimeBox.replaySkipped) rate=\(runtimeBox.replayRate) error=\(runtimeBox.sourceError ?? "none")")
                    if runtimeBox.isReplay {
                        runtimeBox.seekReplay(fraction: 0.5)
                        print("runtime replay seek=\(Int(runtimeBox.replayProgress * 100))% label=\(runtimeBox.replaySourceLabel)")
                    }
                    runtimeBox.goLive()
                    print("runtime back live=\(!runtimeBox.isReplay)")
                }
                await MainActor.run {
                    runtimeBox.refreshLiveSource(rememberChoice: false)
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run {
                    print("refresh live=\(runtimeBox.isLiveSource) devices=\(runtimeBox.network.devices.count) error=\(runtimeBox.sourceError ?? "none")")
                    runtimeBox.useDemoSource(rememberChoice: false)
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    print("demo again=\(!runtimeBox.isLiveSource) devices=\(runtimeBox.network.devices.count)")
                }
                exit(0)
            } catch {
                print("live-test failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}

enum SnapshotTool {
    static func run(args: [String]) {
        AtlasPreferences.persists = false
        if args.contains("--rng") {
            let r = RNG(20261116)
            for _ in 0..<12 { print(String(format: "%.12f", r.next())) }
            exit(0)
        }
        if args.contains("--dump") {
            let net = DemoNetwork(seed: 20261116)
            for d in net.destinations {
                print(d.id, String(format: "%.3f,%.3f,%.3f", d.position.x, d.position.y, d.position.z),
                      String(format: "%.3f", d.radialFraction), String(format: "%.3f", d.visualRadius))
            }
            print("devices")
            for d in net.devices {
                print(d.id, String(format: "%.3f,%.3f,%.3f", d.normal.x, d.normal.y, d.normal.z))
            }
            exit(0)
        }
        if args.contains("--ui") {
            renderUI(args: args)
            return
        }
        let out = value(after: "--out", in: args) ?? "snapshot.png"
        let width = CGFloat(Double(value(after: "--width", in: args) ?? "1600") ?? 1600)
        let height = CGFloat(Double(value(after: "--height", in: args) ?? "1000") ?? 1000)
        let seconds = Float(Double(value(after: "--seconds", in: args) ?? "6.0") ?? 6.0)
        let scale = CGFloat(Double(value(after: "--scale", in: args) ?? "1.0") ?? 1.0)
        let runtime = AtlasRuntime()
        runtime.advanceForSnapshot(seconds: seconds)
        if args.contains("--quiet") || args.contains("--clear") {
            runtime.clearEffectsForSnapshot()
        }
        applyCamera(args: args, runtime: runtime)
        applyEffect(args: args, runtime: runtime, viewSize: CGSize(width: width, height: height))
        var state = runtime.makeRenderState(viewSize: CGSize(width: width, height: height))
        if args.contains("--no-dof") { state.dofEnabled = false }
        if args.contains("--no-bloom") { state.bloomEnabled = false }
        if args.contains("--no-post") { state.dofEnabled = false; state.bloomEnabled = false }
        runtime.settlePostForSnapshot()
        // Rebuild the state after the post easing settles so the snapshot uses
        // the same values the live loop would.
        state = runtime.makeRenderState(viewSize: CGSize(width: width, height: height))
        if args.contains("--no-dof") { state.dofEnabled = false }
        if args.contains("--no-bloom") { state.bloomEnabled = false }
        if args.contains("--no-post") { state.dofEnabled = false; state.bloomEnabled = false }

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("no Metal device"); exit(2)
        }
        do {
            let renderer = try GlobeRenderer(device: device)
            renderer.runtime = runtime
            let url = URL(fileURLWithPath: out)
            try renderer.snapshot(state: state,
                                  size: CGSize(width: width, height: height), scale: scale, path: url)
            print("wrote \(out)")
            exit(0)
        } catch {
            print("snapshot failed: \(error)"); exit(3)
        }
    }

    private static func renderUI(args: [String]) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        AtlasRenderFlags.snapshot = true
        let out = value(after: "--out", in: args) ?? "ui.png"
        let width = CGFloat(Double(value(after: "--width", in: args) ?? "1600") ?? 1600)
        let height = CGFloat(Double(value(after: "--height", in: args) ?? "1000") ?? 1000)
        let seconds = Float(Double(value(after: "--seconds", in: args) ?? "6.0") ?? 6.0)
        let scale = CGFloat(Double(value(after: "--scale", in: args) ?? "1.75") ?? 1.75)
        let runtime = AtlasRuntime()
        if let connectURL = value(after: "--connect-url", in: args) {
            runtime.connectPiHole(url: connectURL,
                                  password: value(after: "--connect-password", in: args) ?? "",
                                  insecure: args.contains("--connect-insecure"),
                                  rememberChoice: false)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if runtime.isLiveSource || (!runtime.sourceConnecting && runtime.sourceError != nil) { break }
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            if let error = runtime.sourceError {
                print("live snapshot connection failed: \(error)")
            }
        }
        runtime.advanceForSnapshot(seconds: seconds)
        if !args.contains("--live") && !args.contains("--replay") {
            runtime.clearEffectsForSnapshot()
        }
        applyCamera(args: args, runtime: runtime)
        if args.contains("--replay") {
            let hours = Float(Double(value(after: "--replay-hours", in: args) ?? "6") ?? 6)
            let progress = Double(value(after: "--replay-progress", in: args) ?? "0.55") ?? 0.55
            let info = runtime.debugReplay(hours: hours, progress: progress,
                                           settle: args.contains("--clear") ? 0 : 0.35)
            print("replay events=\(info.events) buckets=\(info.buckets)")
        }
        if let hours = value(after: "--window", in: args), let value = Float(hours) {
            runtime.setWindowHours(value)
            runtime.advanceForSnapshot(seconds: 2.5)
        }
        if let selection = value(after: "--select", in: args) {
            if selection.hasPrefix("device:") {
                runtime.select(.device(String(selection.dropFirst(7))))
            } else if selection.hasPrefix("destination:") {
                runtime.select(.destination(String(selection.dropFirst(12))))
            } else if selection.hasPrefix("path:") {
                let parts = selection.dropFirst(5).split(separator: ":")
                if parts.count == 2 {
                    runtime.select(.path(deviceId: String(parts[0]), destinationId: String(parts[1])))
                }
            }
        }
        for i in args.indices where i + 1 < args.count {
            if args[i] == "--alias-device" {
                let parts = args[i + 1].split(separator: "=", maxSplits: 1)
                if parts.count == 2,
                   let device = runtime.network.deviceById[String(parts[0])] {
                    runtime.setDeviceAlias(String(parts[1]), for: device)
                }
            } else if args[i] == "--alias-destination" {
                let parts = args[i + 1].split(separator: "=", maxSplits: 1)
                if parts.count == 2,
                   let destination = runtime.network.destinationById[String(parts[0])] {
                    runtime.setDestinationAlias(String(parts[1]), for: destination)
                }
            }
        }
        if args.contains("--show-both") {
            runtime.setShowAliasWithAddress(true)
        }
        if args.contains("--close-rails") {
            runtime.leftRailOpen = false
            runtime.rightRailOpen = false
        }
        if args.contains("--rails") {
            runtime.leftRailOpen = true
            runtime.rightRailOpen = true
        }
        if args.contains("--no-toast") { runtime.toast = nil }
        if args.contains("--replay-jump") { runtime.replayJumpOpen = true }
        if args.contains("--settings") { runtime.settingsOpen = true }
        if args.contains("--help") {
            runtime.settingsOpen = false
            runtime.helpOpen = true
        }
        if let i = args.firstIndex(of: "--settings-tab"), i + 1 < args.count,
           let tab = SettingsTab(rawValue: args[i + 1]) {
            runtime.settingsTab = tab
        }
        if args.contains("--command") { runtime.commandOpen = true }
        if let labelArg = value(after: "--labels", in: args),
           let mode = LabelMode(rawValue: labelArg) {
            runtime.setLabelMode(mode)
        }
        if let flashId = value(after: "--flash", in: args) {
            runtime.flashDestinationLabel(flashId, duration: 10)
        }
        if let hoverArg = value(after: "--hover", in: args) {
            runtime.setHovered(parseSelection(hoverArg))
        }
        if let selectArg = value(after: "--select-device", in: args) {
            runtime.select(.device(selectArg))
        }
        applyEffect(args: args, runtime: runtime, viewSize: CGSize(width: width, height: height))
        runtime.prepareForUISnapshot(size: CGSize(width: width, height: height))

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("no Metal device"); exit(2)
        }
        do {
            let renderer = try GlobeRenderer(device: device)
            renderer.runtime = runtime
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-ui-globe.png")
            var state = runtime.makeRenderState(viewSize: CGSize(width: width, height: height))
            if args.contains("--no-dof") { state.dofEnabled = false }
            if args.contains("--no-bloom") { state.bloomEnabled = false }
            if args.contains("--no-post") { state.dofEnabled = false; state.bloomEnabled = false }
            if let mult = value(after: "--bloom-mult", in: args), let m = Float(mult) {
                state.bloomStrength *= m
            }
            try renderer.snapshot(state: state, size: CGSize(width: width, height: height), scale: scale, path: tmp)
            guard let image = NSImage(contentsOf: tmp) else {
                throw NSError(domain: "AtlasSnapshot", code: 3)
            }
            try UISnapshot.render(runtime: runtime, globe: image,
                                  size: CGSize(width: width, height: height),
                                  showBoot: args.contains("--boot"),
                                  path: URL(fileURLWithPath: out))
            print("wrote \(out)")
            exit(0)
        } catch {
            print("ui snapshot failed: \(error)"); exit(3)
        }
    }

    private static func applyEffect(args: [String], runtime: AtlasRuntime, viewSize: CGSize) {
        guard let kind = value(after: "--effect", in: args) else { return }
        let style = value(after: "--style", in: args) ?? "eclipse"
        let destination = value(after: "--effect-dest", in: args)
        let age = Float(Double(value(after: "--effect-age", in: args) ?? "0.4") ?? 0.4)
        runtime.debugPreviewEffect(kind: kind, style: style, destinationId: destination,
                                   age: age, viewSize: viewSize)
        if args.contains("--hit-geometry") {
            runtime.showHitGeometry = true
        }
        if args.contains("--effect-face") || args.contains("--effect-front") || args.contains("--effect-side") {
            if kind == "impact" {
                runtime.debugFrameLastImpact(fromHitSide: args.contains("--effect-front"),
                                             fromSide: args.contains("--effect-side"))
            } else if let destination {
                runtime.debugFrameDestination(destination)
            }
        }
        if let labelMode = value(after: "--labels", in: args),
           let mode = LabelMode(rawValue: labelMode) {
            runtime.setLabelMode(mode)
        }
    }

    private static func parseSelection(_ value: String) -> Selection? {
        if value.hasPrefix("device:") { return .device(String(value.dropFirst(7))) }
        if value.hasPrefix("destination:") { return .destination(String(value.dropFirst(12))) }
        if value.hasPrefix("path:") {
            let parts = value.dropFirst(5).split(separator: ":")
            if parts.count == 2 { return .path(deviceId: String(parts[0]), destinationId: String(parts[1])) }
        }
        return nil
    }

    private static func applyCamera(args: [String], runtime: AtlasRuntime) {
        if let posString = value(after: "--camera", in: args) {
            let parts = posString.split(separator: ",").compactMap { Float($0) }
            if parts.count == 3 {
                let targetString = value(after: "--target", in: args) ?? "0,0.15,0"
                let targetParts = targetString.split(separator: ",").compactMap { Float($0) }
                let target = targetParts.count == 3
                    ? Vec3(targetParts[0], targetParts[1], targetParts[2])
                    : Vec3(0, 0.15, 0)
                runtime.setCameraForSnapshot(position: Vec3(parts[0], parts[1], parts[2]),
                                             target: target)
            }
        }
        // Apply the lens shift last: setCameraForSnapshot recentres it.
        if let panString = value(after: "--pan", in: args) {
            let parts = panString.split(separator: ",").compactMap { Float($0) }
            if parts.count == 2 {
                runtime.setPanForSnapshot(SIMD2<Float>(parts[0], parts[1]))
            }
        }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
