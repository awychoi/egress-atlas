import Foundation

/// Headless deterministic live dump. `--replay` follows the demo archive's
/// minute-seeded phase, so compare paired runs in the same clock window.
enum StateProbeTool {
    static func run(args: [String]) {
        AtlasPreferences.persists = false
        let runtime = AtlasRuntime()
        runtime.advanceForSnapshot(seconds: 3)
        if args.contains("--replay") {
            let info = runtime.debugReplay(hours: 6, progress: 0.55, settle: 0.35)
            print("probe replay events=\(info.events) buckets=\(info.buckets)")
        }
        print(runtime.debugSceneProbe(), terminator: "")
        exit(0)
    }
}
