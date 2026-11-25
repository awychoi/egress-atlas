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
        let globeFailed = runtime.debugGlobeChecks()
        print("globe checks failed=\(globeFailed)")
        let panFailed = runtime.debugCameraPanChecks()
        print("pan checks failed=\(panFailed)")
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
        if args.contains("--domain-log") {
            guard let rawURL = value("--url") else {
                print("usage: EgressAtlas --live-test --url https://pihole --domain-log [--insecure]")
                exit(2)
            }
            do {
                let client = try PiHoleClient(rawURL: rawURL, password: password, insecure: insecure)
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    do {
                        let page = try await client.dnsmasqLog()
                        let clients = HostLocalAddresses.current()
                        var parser = HostDnsmasqParser()
                        let observations = parser.ingest(page.lines, localClients: clients)
                        print("domain-log lines=\(page.lines.count) nextID=\(page.nextID) pid=\(page.pid.map(String.init) ?? "-") clients=\(clients.count) observations=\(observations.count)")
                        for observation in observations.prefix(5) {
                            print("  \(observation.domain) -> \(observation.ip)")
                        }
                    } catch {
                        print("domain-log failed: \(error.localizedDescription)")
                    }
                    semaphore.signal()
                }
                semaphore.wait()
            } catch {
                print("domain-log client failed: \(error.localizedDescription)")
            }
            exit(0)
        }
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

private func applyGlobeArgs(args: [String], runtime: AtlasRuntime) {
    if let index = args.firstIndex(of: "--deck"), index + 1 < args.count,
       let progress = Float(args[index + 1]) {
        runtime.debugShowDeck(progress: progress)
    } else if args.contains("--host-globe") {
        runtime.debugShowHostGlobe()
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
        applyGlobeArgs(args: args, runtime: runtime)
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
            runtime.rightRailOpen = width > 1020
        }
        if args.contains("--rails-right") {
            runtime.rightRailOpen = true
            runtime.leftRailOpen = width > 1020
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
        applyGlobeArgs(args: args, runtime: runtime)
        let deckSnapshot = args.contains("--deck")
        runtime.advanceForSnapshot(seconds: deckSnapshot ? 0.03 : 1.2)
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


// MARK: - Host traffic headless checks

enum HostTestTool {
    static func run(args: [String]) {
        if let index = args.firstIndex(of: "--out"), index + 1 < args.count {
            freopen(args[index + 1], "w", stdout)
        }
        var failed: [String] = []
        let fixture = """
        Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
        tcp4  2552737      0  192.168.1.108.62104    172.66.0.218.443       ESTABLISHED      9280774         1774 2552492  131072             curl:21720  00102 00000008 0000000000039086 00000081 04000900      2      0 000000
        tcp4       0      0  192.168.1.108.49301    17.57.147.6.5223       ESTABLISHED       192864       269503  131072  131072             apsd:393  00182 00020000 0000000000002024 00180081 04080900      2      0 000000
        tcp6       0      0  fe80::1418:1c0a:.55836 fe80::cdf:fb53:5.49395 ESTABLISHED        12288         4343  131072  131376         rapportd:671  00102 00000004 000000000001f7e7 20080083 01000800      3      0 000004
        udp4       0      0  192.168.1.108.63685    172.64.152.29.443                       9102         7945 1048576   29040   Brave Browser He:1472  00102 00000000 0000000000036c16 00000000 04200900      1      0 000002
        tcp4       0      0  *.7000                 *.*                    LISTEN                 0            0  131072  131072             launchd:1  00100 00000006 000000000001f0fa 00000001 00000800      1      0 000000
        """
        let rows = HostTrafficParser.parse(fixture)
        if rows.count != 4 { failed.append("parser row count \(rows.count)") }
        if let curl = rows.first(where: { $0.pid == 21720 }) {
            if curl.rxBytes != 9_280_774 || curl.txBytes != 1_774 { failed.append("curl bytes") }
            if curl.remotePort != 443 { failed.append("curl port") }
            if curl.proto != "tcp4" { failed.append("curl proto") }
        } else {
            failed.append("curl missing")
        }
        if let brave = rows.first(where: { $0.remotePort == 443 && $0.proto == "udp4" }) {
            if brave.remoteAddress != "172.64.152.29" { failed.append("udp host") }
            if brave.rxBytes != 9_102 || brave.txBytes != 7_945 { failed.append("udp bytes") }
        } else {
            failed.append("udp row missing")
        }
        if !rows.contains(where: { $0.proto == "tcp6" && $0.remotePort == 49395 }) {
            failed.append("ipv6 row missing")
        }
        if rows.contains(where: { $0.pid == 1 }) { failed.append("listener not skipped") }
        if HostScope.classify("192.168.1.4") != .lan { failed.append("scope lan") }
        if HostScope.classify("8.8.8.8") != .internet { failed.append("scope internet") }
        if HostScope.classify("127.0.0.1") != .loopback { failed.append("scope loopback") }
        if HostScope.classify("100.101.102.103") != .vpn { failed.append("scope vpn") }

        let attributor = HostDomainAttributor()
        attributor.resolveHost = { _ in ["93.184.216.34"] }
        attributor.record(domain: "example.com", at: Date())
        Thread.sleep(forTimeInterval: 0.8)
        if let match = attributor.match(host: "93.184.216.34", port: 443, at: Date()) {
            if match.confidence != .temporal || match.domain != "example.com" {
                failed.append("domain resolved \(match.confidence) \(match.domain)")
            }
        } else {
            failed.append("domain exact missing")
        }
        if attributor.match(host: "203.0.113.9", port: 9999, at: Date()) != nil {
            failed.append("unmatched ip")
        }

        if args.contains("--brief") {
            print(failed.isEmpty ? "host-test OK" : "host-test FAILED \(failed)")
            exit(failed.isEmpty ? 0 : 1)
        }

        let nowStamp = Date().timeIntervalSince1970
        let logLines: [PiHoleLogLine] = [
            PiHoleLogLine(timestamp: nowStamp - 1.0, message: "query[A] example.com from 192.168.1.108"),
            PiHoleLogLine(timestamp: nowStamp - 0.9, message: "cached example.com is 93.184.216.34"),
            PiHoleLogLine(timestamp: nowStamp - 0.8, message: "query[A] www.apple.com from 192.168.1.108"),
            PiHoleLogLine(timestamp: nowStamp - 0.7, message: "reply www.apple.com is <CNAME>"),
            PiHoleLogLine(timestamp: nowStamp - 0.6, message: "reply e6858.dscb.akamaiedge.net is 17.253.144.10"),
            PiHoleLogLine(timestamp: nowStamp - 0.5, message: "query[A] other.com from 10.0.0.9"),
            PiHoleLogLine(timestamp: nowStamp - 0.4, message: "cached other.com is 1.2.3.4"),
            PiHoleLogLine(timestamp: nowStamp - 0.3, message: "reply www.apple.com is 17.253.144.10"),
        ]
        var logParser = HostDnsmasqParser()
        let observations = logParser.ingest(logLines, localClients: ["192.168.1.108"])
        if observations.count != 2 { failed.append("dnsmasq observations \(observations.count)") }
        if !observations.contains(where: { $0.ip == "93.184.216.34" && $0.domain == "example.com" }) {
            failed.append("dnsmasq exact")
        }
        if !observations.contains(where: { $0.domain == "www.apple.com" && $0.ip == "17.253.144.10" }) {
            failed.append("dnsmasq cname")
        }
        if observations.contains(where: { $0.domain == "other.com" }) {
            failed.append("dnsmasq other client leaked")
        }
        attributor.recordAnswer(domain: "example.com", ip: "93.184.216.34", at: Date())
        if attributor.match(host: "93.184.216.34", port: 443, at: Date())?.confidence != .exact {
            failed.append("attributor log exact")
        }
        attributor.recordAnswer(domain: "www.example.com", ip: "93.184.216.34", at: Date())
        if attributor.match(host: "93.184.216.34", port: 443, at: Date())?.confidence != .temporal {
            failed.append("attributor ambiguity")
        }

        let nettopFixture = """
        time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
        12:00:00.000001,Brave Browser.42,,,500,100,0,0,0,,,,,,,,,,,,
        12:00:00.000002,tcp4 192.168.1.108:50000<->93.184.216.34:443,en0,Established,500,100,0,0,0,,,,,,,,,,,,
        12:00:00.000003,tcp4 *:443<->*:*,en0,Listen,,,,,,,,,,,,,,,,,,,,
        12:00:00.000004,trustd.7,,,20,30,0,0,0,,,,,,,,,,,,
        12:00:00.000005,tcp6 fe80::1418:1c0a:e074:ad98%en0.55836<->2606:4700:4700::1111.443,en0,Established,20,30,0,0,0,,,,,,,,,,,,
        """
        let nettopSamples = HostNettopParser.parse(nettopFixture)
        if nettopSamples.count != 2 { failed.append("nettop parse count \(nettopSamples.count)") }
        if nettopSamples.first?.pid != 42 || nettopSamples.first?.remoteAddress != "93.184.216.34"
            || nettopSamples.first?.remotePort != 443 {
            failed.append("nettop ipv4 parse")
        }
        if nettopSamples.last?.pid != 7 || nettopSamples.last?.remoteAddress != "2606:4700:4700::1111"
            || nettopSamples.last?.remotePort != 443 {
            failed.append("nettop ipv6 parse")
        }
        if args.contains("--nettop-live") {
            let live = HostNettopSampler.sampleSystem()
            print("nettop-live sockets=\(live.count) processes=\(Set(live.map(\.pid)).count)")
            if let first = live.first {
                print("nettop-live first pid=\(first.pid) \(first.proto) \(first.remoteAddress):\(first.remotePort)")
            }
            if live.isEmpty { failed.append("nettop live empty") }
        }
        if args.contains("--live-monitor") {
            let liveMonitor = HostTrafficMonitor()
            var latest: HostSnapshot?
            liveMonitor.onSnapshot = { snapshot in latest = snapshot }
            liveMonitor.start()
            RunLoop.current.run(until: Date().addingTimeInterval(4.2))
            liveMonitor.stop()
            if let latest {
                print("live-monitor apps=\(latest.apps.count) endpoints=\(latest.endpoints.count) domains=\(latest.domains.count) rx=\(Int(latest.rxPerSecond)) tx=\(Int(latest.txPerSecond)) available=\(latest.available)")
                for app in latest.apps.prefix(4) {
                    print("  live-monitor \(app.name) in=\(Int(app.rxPerSecond)) out=\(Int(app.txPerSecond)) sockets=\(app.socketCount)")
                }
                if latest.apps.isEmpty { failed.append("live monitor empty") }
            } else {
                failed.append("live monitor no snapshot")
            }
        }
        let monitor = HostTrafficMonitor()
        let t0 = Date()
        let first = HostSocketSample(proto: "tcp4", localAddress: "192.168.1.108",
                                     localPort: 50000, remoteAddress: "93.184.216.34",
                                     remotePort: 443, pid: 999999,
                                     rxBytes: 100, txBytes: 50)
        monitor.debugIngest([first], at: t0, dt: 1, baseline: true)
        let second = HostSocketSample(proto: "tcp4", localAddress: "192.168.1.108",
                                      localPort: 50000, remoteAddress: "93.184.216.34",
                                      remotePort: 443, pid: 999999,
                                      rxBytes: 1_000, txBytes: 200)
        monitor.debugIngest([second], at: t0.addingTimeInterval(1), dt: 1)
        let synthetic = monitor.snapshot
        if synthetic.apps.count != 1 { failed.append("monitor app count \(synthetic.apps.count)") }
        if synthetic.apps.first?.rxTotal != 900 { failed.append("monitor rx total \(String(describing: synthetic.apps.first?.rxTotal))") }
        if synthetic.apps.first?.txTotal != 150 { failed.append("monitor tx total") }
        if synthetic.endpoints.count != 1 { failed.append("monitor endpoint count") }
        if synthetic.transfers.first?.bytesIn != 900 { failed.append("monitor transfer") }
        print("host-test synthetic apps=\(synthetic.apps.count) endpoints=\(synthetic.endpoints.count) rx=\(synthetic.apps.first?.rxTotal ?? 0)")
        print(failed.isEmpty ? "host-test OK" : "host-test FAILED \(failed)")
        exit(failed.isEmpty ? 0 : 1)
    }
}
