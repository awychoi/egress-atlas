import Foundation

// ── Globe deck ───────────────────────────────────────────────────────────

enum GlobeKind: String, CaseIterable, Identifiable {
    case dns
    case host
    var id: String { rawValue }
    var title: String { self == .dns ? "DNS" : "HOST" }
    var subtitle: String { self == .dns ? "Pi-hole network" : "This Mac" }
}

/// Presentation math shared by the live host scene and the render composer.
/// The runtime owns the camera and deck timing; deriving detail, liveness and
/// layer order here keeps the two paths from drifting.
struct GlobeDeckPresentation {
    /// Detail floor for the globe that is not the active instrument.
    static let backgroundDetail: Float = 0.32
    /// The DNS stage shell keeps its own curve: it is already present behind
    /// the host globe, so it fades later than the globe itself.
    private static let dnsGeometryStart: Float = 0.55
    private static let dnsGeometrySpan: Float = 0.3

    let dnsDetail: Float
    let hostDetail: Float
    let hostIsLive: Bool
    /// Detail for the DNS globe's stage geometry and contents. It follows the
    /// draw-list curve, not the globe layer's crossfade: the shell is still
    /// present behind the host globe, so it fades later.
    let dnsGeometryDetail: Float

    private let activeGlobe: GlobeKind
    private let deckActive: Bool
    private let deckTo: GlobeKind

    init(activeGlobe: GlobeKind, deckActive: Bool, deckTo: GlobeKind, progress: Float) {
        self.activeGlobe = activeGlobe
        self.deckActive = deckActive
        self.deckTo = deckTo
        let p = clamp01(progress)
        if deckActive {
            let incoming = min(1, max(Self.backgroundDetail, (p - 0.35) / 0.3))
            let outgoing = p < 0.45 ? 1 : max(0, 1 - (p - 0.45) / 0.3)
            dnsDetail = deckTo == .dns ? incoming : outgoing
            hostDetail = deckTo == .host ? incoming : outgoing
            hostIsLive = deckTo == .host ? p > 0.45 : p < 0.6
            let geometryIncoming = min(1, max(Self.backgroundDetail,
                                              (p - Self.dnsGeometryStart) / Self.dnsGeometrySpan))
            let geometryOutgoing = p < Self.dnsGeometryStart
                ? 1 : max(0, 1 - (p - Self.dnsGeometryStart) / Self.dnsGeometrySpan)
            dnsGeometryDetail = deckTo == .dns ? geometryIncoming : geometryOutgoing
        } else {
            dnsDetail = activeGlobe == .dns ? 1 : Self.backgroundDetail
            hostDetail = activeGlobe == .host ? 1 : Self.backgroundDetail
            hostIsLive = activeGlobe == .host
            dnsGeometryDetail = activeGlobe == .dns ? 1 : Self.backgroundDetail
        }
    }

    /// The globe drawn at its world position rather than the origin: the
    /// incoming globe while the camera travels, otherwise the inactive globe.
    var backgroundKind: GlobeKind {
        deckActive ? deckTo : (activeGlobe == .dns ? .host : .dns)
    }

    /// Background-first draw order; the incoming (or active) globe is last.
    static func layerOrder(active: GlobeKind, deckActive: Bool, deckTo: GlobeKind) -> [GlobeKind] {
        let foreground = deckActive ? deckTo : active
        return foreground == .host ? [.dns, .host] : [.host, .dns]
    }
}
