import Foundation

enum HostTestTool {
    static func run(args: [String]) {
        if let index = args.firstIndex(of: "--out"), index + 1 < args.count {
            freopen(args[index + 1], "w", stdout)
        }
        let report = HostChecks.run()
        var failed = report.failures

        if args.contains("--brief") {
            print(failed.isEmpty ? "host-test OK" : "host-test FAILED \(failed)")
            exit(failed.isEmpty ? 0 : 1)
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

        if let summary = report.synthetic {
            print("host-test synthetic apps=\(summary.apps) endpoints=\(summary.endpoints) rx=\(summary.rx)")
        }
        print(failed.isEmpty ? "host-test OK" : "host-test FAILED \(failed)")
        exit(failed.isEmpty ? 0 : 1)
    }
}
