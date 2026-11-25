import Foundation
import Metal

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
        let hostReport = HostChecks.run()
        print("host checks failed=\(hostReport.failures)")
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
