import Foundation

/// The small surface the runtime needs from either the deterministic demo
/// source or the live Pi-hole poller. Keeping this explicit makes the source
/// swappable without teaching the renderer or the inspector about HTTP.
protocol AtlasTrafficSource: AnyObject {
    var network: DemoNetwork { get }
    var kind: String { get }
    var label: String { get }
    var endpoint: String? { get }
    var pollSeconds: Float? { get }
    var baseRate: Float { get }
    var rate: Float { get }
    var effectiveRate: Float { get }
    var paused: Bool { get }
    var speed: Float { get }
    var recent: [QueryEvent] { get }
    var totalLive: Int { get }
    var queryListeners: [(QueryEvent) -> Void] { get set }
    var localListeners: [(LocalTrafficEvent) -> Void] { get set }

    func start()
    func stop()
    func update(realDt: Float)
    func setPaused(_ paused: Bool)
    func setSpeed(_ speed: Float)
    func setRate(_ rate: Float)
    func getQps(_ deviceId: String?) -> Float
}

extension AtlasTrafficSource {
    func getQps() -> Float { getQps(nil) }
}
