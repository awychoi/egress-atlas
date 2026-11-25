import Foundation

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
