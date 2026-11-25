import Foundation
import SwiftUI
import AppKit
import QuartzCore
import simd

// ── UI-facing types ──────────────────────────────────────────────────────

enum OutcomeFilter: String, CaseIterable {
    case all, allowed, blocked
}

enum LabelMode: String, CaseIterable {
    case events, selected, all, off
}

enum MotionMode: String, CaseIterable {
    case cinematic, calm, off
}

enum AtlasMode {
    case live
    case replay
}

/// Preset windows for time travel. The values mirror the history-window stops
/// the app already exposes, but the replay picker only needs four useful
/// landing points.
enum ReplayRange: CaseIterable, Identifiable {
    case hour
    case sixHours
    case day
    case week

    static let defaultChoice: ReplayRange = .sixHours

    var id: Float { hours }

    var hours: Float {
        switch self {
        case .hour: return 1
        case .sixHours: return 6
        case .day: return 24
        case .week: return 168
        }
    }

    var title: String {
        switch self {
        case .hour: return "1H"
        case .sixHours: return "6H"
        case .day: return "24H"
        case .week: return "7D"
        }
    }

    var detail: String {
        switch self {
        case .hour: return "the last hour"
        case .sixHours: return "the last six hours"
        case .day: return "the last day"
        case .week: return "the last seven days"
        }
    }

    static func nearest(hours: Float) -> ReplayRange {
        allCases.min { abs($0.hours - hours) < abs($1.hours - hours) } ?? .sixHours
    }
}

enum Selection: Equatable {
    case device(String)
    case destination(String)
    case path(deviceId: String, destinationId: String)

    var deviceId: String? {
        switch self {
        case .device(let id): return id
        case .path(let deviceId, _): return deviceId
        default: return nil
        }
    }
    var destinationId: String? {
        switch self {
        case .destination(let id): return id
        case .path(_, let id): return id
        default: return nil
        }
    }
    var typeLabel: String {
        switch self {
        case .device: return "Device"
        case .destination: return "Destination"
        case .path: return "Path"
        }
    }
}

struct FeedRow: Identifiable, Equatable {
    let id: String
    let deviceId: String
    let destinationId: String
    let deviceName: String
    let domain: String
    let clock: String
    let status: DNSStatus
    let latency: Int?
    let ts: Double
}

struct PulseBucket: Equatable {
    var allowed = 0
    var blocked = 0
    var total: Int { allowed + blocked }
}

struct ToastMessage: Identifiable, Equatable {
    enum Tone { case gold, signal, coral }
    let id = UUID()
    let text: String
    let tone: Tone
}

struct AtlasLabel: Identifiable, Equatable {
    enum Kind { case device, destination }
    let id: String
    let kind: Kind
    let anchor: CGPoint
    let key: String
    let host: String
    let badge: String?
    let meta: String
    let detail: String
    let blocked: Bool
    let hovered: Bool
    let selected: Bool
    let blur: CGFloat
    let size: CGSize
    let accessibilityLabel: String
    /// Which globe's palette the shared overlay paints with; DNS is the
    /// common case and needs no site-specific argument.
    var tone: GlobeKind = .dns
}

final class LabelStore: ObservableObject {
    @Published var labels: [AtlasLabel] = []
    /// Seconds between label resolutions. Zero means every frame; a dense
    /// label set resolves at 24 Hz and lets Core Animation interpolate the
    /// anchor between updates instead of re-rendering the text stack at
    /// display rate.
    var cadence: TimeInterval = 0
    /// Very large live fields turn interpolation off so the dense fallback
    /// only pays for a 12 Hz step rather than continuous layer animation.
    var animates = true
}

struct CameraFlight {
    var t: Float = 0
    let duration: Float
    let fromPos: Vec3
    let toPos: Vec3
    let fromTarget: Vec3
    let toTarget: Vec3
    var arc = false
    var fromRadius: Float = 0
    var toRadius: Float = 0
    var fromDir = Vec3.forward
    var toDir = Vec3.forward
    var rotation = Quat(angle: 0, axis: .up)
    /// The lens shift is eased with the flight so a panned globe glides back
    /// to centre while the camera moves to its new subject.
    var fromPan = SIMD2<Float>.zero
    var toPan = SIMD2<Float>.zero
}

struct PathHalo {
    var curve: CatmullRom
    var wide: [TriangleVertex]
    var tight: [TriangleVertex]
    var blocked: Bool
}

struct LocalTrace {
    var baseTriangles: [TriangleVertex]
    var age: Float = 0
    let duration: Float
}

struct RingTrace {
    var center: Vec3
    var normal: Vec3
    var age: Float = 0
    let duration: Float
    let baseAlpha: Float
}

/// Last impact retained for the study HUD and the optional hit-plane overlay.
/// `normal` is the inbound wire tangent, so the blast plane is the plane whose
/// +Z is this vector (perpendicular to the packet's arrival direction).
struct ImpactRecord {
    let destinationId: String
    let blocked: Bool
    let at: Float
    let normal: Vec3
    let point: Vec3
    let impactId: String
    let impactName: String
}

struct StudyTelemetry: Equatable {
    let host: String
    let inbound: Vec3
    let axis: Vec3
    let centre: Vec3
    let faceAngle: Float
    let blocked: Bool
    let impactName: String

    var inboundText: String { Self.vectorText(inbound) }
    var axisText: String { Self.vectorText(axis) }
    var centreText: String { Self.vectorText(centre) }

    private static func vectorText(_ v: Vec3) -> String {
        String(format: "%+.2f  %+.2f  %+.2f", v.x, v.y, v.z)
    }
}

private struct TimerEntry {
    var remaining: Float
    let action: () -> Void
    let token: Int
}

private struct DeviceAppearanceLink {
    let device: Device
    let wire: WireView
    var t: Float = 0
    let duration: Float
    let onArrive: () -> Void
}

enum GlobePick {
    case dns(Selection)
    case host(HostSelection)
    case focusGlobe(GlobeKind)
}

// ── Runtime ──────────────────────────────────────────────────────────────

final class AtlasRuntime: NSObject, ObservableObject {
    // Data
    @Published private(set) var network: DemoNetwork
    @Published private(set) var source: any AtlasTrafficSource
    let seed: Int
    let reducedMotion: Bool

    // Scene
    private let stage = GlobeStage()
    private(set) var nodes: [NodeView] = []
    private(set) var devices: [DeviceView] = []
    private(set) var wires: [WireView] = []
    private var nodeByDest: [String: NodeView] = [:]
    private var deviceById: [String: DeviceView] = [:]
    private var wireByKey: [String: WireView] = [:]
    private var wireByEdge: [String: WireView] = [:]
    private var edgeByKey: [String: Edge] = [:]
    private let effects = EffectHost()
    private var signals: [Signal] = []
    private var deviceAppearanceLinks: [DeviceAppearanceLink] = []
    private var signalCounts: [String: Int] = [:]
    /// Cumulative local traffic by device, both directions. The layout used to
    /// rebuild a sorted "id::id" string for every visible device pair on every
    /// frame and scan the whole pair grid just to find the few pairs that have
    /// activity. This sparse index preserves the exact weights while making
    /// the per-frame layout loop proportional to active pairs, not population².
    private var localWeights: [String: [String: Float]] = [:]
    /// Stable network order for the sparse pull index. The original layout
    /// visited peers in `network.devices` order; summing the few active peers
    /// in that same order keeps the demo's floating-point layout reproducible
    /// across launches (dictionary iteration order is not).
    private var deviceRank: [String: Int] = [:]
    private var localTraces: [LocalTrace] = []
    private var ringTraces: [RingTrace] = []
    private var pathHalo: PathHalo?
    private var haloKey: String?
    private var trauma: Float = 0
    private var timerToken = 0
    private var timers: [TimerEntry] = []

    // Simulation
    private(set) var camera: Camera
    private var globeRadius: Float = 6
    var globeRadiusForRender: Float { globeRadius }
    private var layoutTick = 0
    private var lastFramingTarget: Float = 6
    private var dot = DrawList()
    private var rng = RNG(20261116)
    private var elapsed: Float = 0
    private var realTime: Float = 0
    private var lastRenderTime = 0.0
    private var lastSourceTime = 0.0
    private var frameViewSize = AtlasLayout.windowDefault
    private var didFrame = false
    private var wireClock: Float = 0
    private var haloClock: Float = 0
    private var windowClock: Float = 0
    private var statsClock: Float = 0
    private var labelResolveClock: Float = 0
    private var labelTimingSum: Double = 0
    private var labelTimingMax: Double = 0
    private var labelTimingCount = 0
    private var dofStrength: Float = 1
    private var dragging = false
    private var windowMoving = false
    private var windowMoveSettle: DispatchWorkItem?
    private var started = false
    private var ready = false
    private var birthScheduleStarted = false
    private var hitCounts = (impact: 0, birth: 0, death: 0)
    private var previewIndex = (impact: 0, birth: 0, death: 0)
    private var lastImpact: ImpactRecord?
    private var hitGeometryReplayAt: Float?
    private var eventLabels: [String: Double] = [:]
    private var lastInteraction: Double = 0
    private var sourceTimer: Timer?
    private var uiTimer: Timer?
    private var sourceRequestToken = 0
    private var liveSnapshot: PiHoleSnapshot?
    private var liveClient: PiHoleClient?
    private var activeSourcePassword: String?
    private var pulseTimer: Timer?
    private var lastPulseSecond = Int(Date().timeIntervalSince1970)
    private var replayArchive: ReplayArchive?
    private var replayCursor: Double = 0
    private var replayIndex = 0
    private var replayEmitBudget: Double = 0
    private var replayRecent: [QueryEvent] = []
    private var replayRequestToken = 0
    private var replayLastPublished: Double = -1
    private var replayRateAuto = true
    private var toasts: [ToastMessage] = []
    private var toastToken = 0

    // Orbit / camera
    private var cameraFlight: CameraFlight?
    private var orbitTarget = Vec3(0, 0.15, 0)
    private var sphericalDelta = SIMD2<Float>(0, 0)
    private var orbitScale: Float = 1
    private var autoResumeAt: Double = 0
    private var userZoomed = false
    private var fitDistance: Float = 30
    private var flightDelayRemaining: Float = 0
    private var pendingFlight: (position: Vec3, target: Vec3, duration: Float, arc: Bool)?
    private var cameraDragging = false
    private var panDragging = false
    private var tourClock: Float = 0
    private var tourPhase = 0
    private var tourInterval: Float = 0
    private var tourDestinationId: String?

    // Published UI state
    @Published var filter: OutcomeFilter = .all
    @Published var labelMode: LabelMode = .selected
    @Published var motionMode: MotionMode = .cinematic
    @Published var spinEnabled: Bool
    @Published var windowDragSpinsGlobe: Bool
    /// Local aliases keyed by device IP and destination domain. These are
    /// user-authored only; the Pi-hole client remains read-only.
    @Published private(set) var deviceAliases: [String: String]
    @Published private(set) var destinationAliases: [String: String]
    /// Alias-only cards are the default; this appends the original address.
    @Published private(set) var showAliasWithAddress: Bool
    @Published var recoilEnabled = true
    @Published var showHitGeometry = false
    @Published var autoTour = false
    @Published var studyTelemetry: StudyTelemetry?
    @Published var paused = false
    @Published var speed: Float = 1
    @Published private(set) var mode: AtlasMode = .live
    @Published private(set) var replayRangeHours: Float = ReplayRange.defaultChoice.hours
    @Published private(set) var replayStart: Double = 0
    @Published private(set) var replayEnd: Double = 0
    @Published private(set) var replayTime: Double = 0
    @Published private(set) var replayRate: Float = 600
    @Published private(set) var replayBuckets: [PulseBucket] = []
    @Published private(set) var replayMaxBucket = 1
    @Published private(set) var replayTotal = 0
    @Published private(set) var replayScanned = 0
    @Published private(set) var replaySkipped = 0
    @Published private(set) var replaySampled = false
    @Published private(set) var replaySourceLabel = ""
    @Published private(set) var replayLoading = false
    @Published private(set) var replayFinished = false
    @Published var replayJumpOpen = false
    @Published var replayLoop = false
    @Published var windowHours: Float
    @Published var selection: Selection?
    @Published private(set) var canGoBack = false
    private var selectionHistory: [Selection?] = [nil]

    @Published var leftRailOpen = false
    @Published var rightRailOpen = false {
        didSet {
            // The rail is always in the view tree (it slides), so its feed
            // rows must be current the moment it opens. While it is closed
            // the query handler skips rebuilding them entirely.
            if rightRailOpen && !oldValue { refreshFeed() }
        }
    }
    @Published var settingsOpen = false
    @Published var helpOpen = false
    @Published var filterOpen = false
    @Published var settingsTab: SettingsTab = .source
    @Published var commandOpen = false
    @Published var toast: ToastMessage?
    @Published var totals = NetworkTotals()
    @Published var windowStats = WindowStats()
    @Published var qps: Float = 0
    @Published var feed: [FeedRow] = []
    @Published var feedCount = 0
    @Published var clock = "--:--:--"
    @Published var inspectorRevision = 0
    @Published var pulse: [PulseBucket] = []
    @Published var pulseCurrent = PulseBucket()
    @Published var pulseTotal = 0
    @Published var pulseScaleMax = 1
    @Published var motionStateText = "streaming"
    @Published var sourceMessage = ""
    @Published var sourceMode = "demo"
    @Published var bootComplete = false
    @Published var hover: Selection?
    @Published var hoveredPath: (deviceId: String, destinationId: String)? {
        didSet {
            if hoveredPath?.deviceId != oldValue?.deviceId || hoveredPath?.destinationId != oldValue?.destinationId {
                applyVisualState()
            }
        }
    }
    @Published var readyFlag = false
    @Published var lastEventAgo = "observing now"
    @Published var sourceConnecting = false
    @Published var sourceError: String?
    @Published var sourceNotice: String?
    @Published var sourceEndpoint: String?
    @Published var sourceSnapshotWindow: String?
    @Published var livePopulation = PiHoleCredentials.livePopulation
    @Published var hasSavedPassword = PiHoleCredentials.hasPassword
    @Published var savedSourceURL = PiHoleCredentials.savedURL
    @Published var savedSourceInsecure = PiHoleCredentials.savedInsecure

    var labels = LabelStore()
    var hostLabels = LabelStore()
    private var labelSizeCache: [String: CGSize] = [:]

    // Host globe / deck state.
    @Published private(set) var activeGlobe: GlobeKind = .dns
    /// The instrument the chrome currently shows. It changes once, at the
    /// midpoint of a focus transition, so text and data never mix.
    @Published private(set) var displayedGlobe: GlobeKind = .dns
    @Published private(set) var backgroundHover: GlobeKind?
    @Published private(set) var hostSnapshot: HostSnapshot = .empty
    @Published var hostSelection: HostSelection?
    @Published var hostHover: HostSelection?
    @Published private(set) var hostAvailable = true
    @Published private(set) var hostNote: String?
    @Published private(set) var hostDomainStatus: String?
    @Published private(set) var hostPaused = false
    let hostScene: HostGlobeScene
    private let host: HostInstrument
    /// Headless tools opt back into the offline demo graph; the shipping app
    /// shows an empty DNS globe until a live Pi-hole is connected.
    private let allowsDemoGeometry = !AtlasPreferences.persists
    private var demoPreview = false
    private var dnsHasVisualData: Bool { isLiveSource || allowsDemoGeometry || demoPreview }
    private var deckTo: GlobeKind = .dns
    private var deckProgress: Float = 0
    private var deckDuration: Float = 1.45
    private var deckActive = false
    private var rearWorldOffset = Vec3.zero
    private var rearOrbitAxis = Vec3(0.55, 1, 0.28).normalized
    private var deckWorldBackground = Vec3.zero
    private var deckOrbitCenter = Vec3.zero
    private var deckOrbitStart = Vec3.zero
    private var deckOrbitRadiusEnd: Float = 35
    private var deckOrbitAxis = Vec3(0, 1, 0)
    private let deckOrbitAngle: Float = .pi
    private var deckTargetFrom = Vec3.zero

    /// Keep a restored study speed on one of the five segment stops even if the
    /// defaults were written by an older build or hand-edited.
    private static func nearestStudySpeed(_ value: Float?) -> Float {
        guard let value else { return 1 }
        let stops: [Float] = [0.25, 0.5, 1, 2, 4]
        return stops.min { abs($0 - value) < abs($1 - value) } ?? 1
    }

    override init() {
        let scene = HostGlobeScene()
        hostScene = scene
        host = HostInstrument(scene: scene)
        let seed = 20261116
        self.seed = seed
        let demoNetwork = DemoNetwork(seed: seed)
        network = demoNetwork
        source = LiveSource(network: demoNetwork, seed: seed + 7, rate: 2.85)
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        spinEnabled = AtlasPreferences.autoOrbit ?? !reducedMotion
        windowDragSpinsGlobe = AtlasPreferences.windowDragSpinsGlobe ?? false
        deviceAliases = AtlasPreferences.deviceAliases
        destinationAliases = AtlasPreferences.destinationAliases
        showAliasWithAddress = AtlasPreferences.showAliasWithAddress ?? false
        motionMode = AtlasPreferences.motionMode ?? (reducedMotion ? .calm : .cinematic)
        labelMode = AtlasPreferences.labelMode ?? .selected
        recoilEnabled = AtlasPreferences.recoil ?? true
        showHitGeometry = AtlasPreferences.hitPlane ?? false
        speed = Self.nearestStudySpeed(AtlasPreferences.speed)
        windowHours = Windows.normalize(AtlasPreferences.windowHours ?? Windows.defaultHours)
        // Verification lever for the label overlay: force a label mode
        // without touching the UI (paired with ATLAS_DIAGNOSTICS).
        if let raw = ProcessInfo.processInfo.environment["ATLAS_LABELS"],
           let mode = LabelMode(rawValue: raw) {
            labelMode = mode
        }
        var cam = Camera()
        let fit = AtlasRuntime.computeFitDistance(width: AtlasLayout.windowDefault.width,
                                                  height: AtlasLayout.windowDefault.height)
        let dir = Vec3(16.5, 12.4, 32.5).normalized
        cam.position = Vec3(0, 0.15, 0) + dir * fit
        cam.target = Vec3(0, 0.15, 0)
        camera = cam
        fitDistance = fit
        let initialForward = camera.forward
        let initialRight = initialForward.cross(.up).normalized
        let initialUp = initialRight.cross(initialForward).normalized
        let initialRearDirection = (initialForward * 0.82
            + initialRight * 0.24 + initialUp * 0.12).normalized
        rearWorldOffset = initialRearDirection * max(110, fit * 3.0)
        super.init()
        configureHostInstrument()
        buildScene()
        applyWindow(animate: false, initial: true)
        applyVisualState()
        updateLabels(force: true)
        attachSourceListeners()
        self.totals = network.totals
        self.windowStats = network.windowStats()
        self.labels.labels = []
        configureBoot()
        refreshUI()
    }

    deinit {
        source.stop()
        host.stop()
        sourceTimer?.invalidate()
        uiTimer?.invalidate()
        pulseTimer?.invalidate()
        windowMoveSettle?.cancel()
    }

    // ── source switching ─────────────────────────────────────────────────

    private func attachSourceListeners() {
        source.queryListeners.append { [weak self] event in
            guard let self, self.mode == .live else { return }
            self.handleQuery(event)
            if self.rightRailOpen { self.refreshFeed() }
            self.bumpPulse(event)
        }
        source.localListeners.append { [weak self] event in
            self?.handleLocal(event)
        }
        source.queryListeners.append { [weak self] event in
            guard let self, self.isLiveSource else { return }
            guard self.host.isLocal(event.device.ip) else { return }
            self.host.record(domain: event.destination.domain,
                             at: Date(timeIntervalSince1970: event.ts / 1000))
        }
        if isLiveSource { host.seed(devices: network.devices) }
        if let live = source as? PiHoleSource {
            live.statusListener = { [weak self] error in
                self?.sourceError = error
            }
        }
    }

    private func resetSceneForSource() {
        nodes.removeAll()
        devices.removeAll()
        wires.removeAll()
        nodeByDest.removeAll()
        deviceById.removeAll()
        wireByKey.removeAll()
        wireByEdge.removeAll()
        edgeByKey.removeAll()
        effects.clear()
        timers.removeAll()
        signals.removeAll()
        deviceAppearanceLinks.removeAll()
        signalCounts.removeAll()
        localWeights.removeAll()
        deviceRank.removeAll()
        localTraces.removeAll()
        ringTraces.removeAll()
        pathHalo = nil
        haloKey = nil
        eventLabels.removeAll()
        labels.labels = []
        selection = nil
        selectionHistory = [nil]
        canGoBack = false
        rightRailOpen = false
        feed = []
        feedCount = 0
        pulseHistory = []
        currentPulse = PulseBucket()
        pulseReady = true
        publishPulse()
        replayRequestToken += 1
        replayArchive = nil
        replayCursor = 0
        replayIndex = 0
        replayEmitBudget = 0
        replayRecent.removeAll()
        replayFinished = false
        replayLoading = false
        replayJumpOpen = false
        mode = .live
        replayBuckets = []
        replayTotal = 0
        replayScanned = 0
        replaySkipped = 0
        replaySampled = false
        replaySourceLabel = ""
        replayStart = 0
        replayEnd = 0
        replayTime = 0
        replayLastPublished = -1
        replayRateAuto = true
        hitCounts = (impact: 0, birth: 0, death: 0)
        previewIndex = (impact: 0, birth: 0, death: 0)
        lastImpact = nil
        studyTelemetry = nil
        lastSourceTime = CACurrentMediaTime()
        windowClock = 0
        statsClock = 0
        labelResolveClock = 0
    }

    private func switchSource(to nextNetwork: DemoNetwork, source nextSource: any AtlasTrafficSource) {
        source.stop()
        network = nextNetwork
        source = nextSource
        network.windowHours = windowHours
        resetSceneForSource()
        buildScene()
        applyWindow(animate: false, initial: true)
        applyVisualState()
        updateLabels(force: true)
        attachSourceListeners()
        source.start()
        totals = network.totals
        windowStats = network.windowStats()
        refreshUI()
        configureBoot()
    }

    func connectPiHole(url: String, password: String, insecure: Bool,
                       restoring: Bool = false, rememberChoice: Bool = true) {
        guard !sourceConnecting else { return }
        let entered = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = PiHoleCredentials.password ?? ""
        let effective = entered.isEmpty ? saved : entered
        let population = livePopulation
        sourceConnecting = true
        sourceError = nil
        sourceNotice = nil
        sourceRequestToken += 1
        let requestToken = sourceRequestToken
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try PiHoleClient(rawURL: url, password: effective, insecure: insecure)
                let snapshot = try await client.snapshot()
                let liveNetwork = try LiveNetworkBuilder.make(snapshot: snapshot, seed: seed,
                                                              population: population)
                let liveSource = PiHoleSource(network: liveNetwork, client: client, initial: snapshot)
                await MainActor.run {
                    guard requestToken == self.sourceRequestToken else { return }
                    PiHoleCredentials.savedURL = client.normalizedURL
                    PiHoleCredentials.savedInsecure = insecure
                    var notice: String?
                    if !restoring && !entered.isEmpty {
                        do {
                            try PiHoleCredentials.save(password: entered)
                        } catch {
                            notice = "Connected. The login Keychain is unavailable here, so the password will only be used for this session."
                        }
                    }
                    self.hasSavedPassword = PiHoleCredentials.hasPassword
                    self.activeSourcePassword = effective.isEmpty ? nil : effective
                    self.liveSnapshot = snapshot
                    self.liveClient = client
                    self.host.startDomainStream(client: client)
                    if rememberChoice {
                        PiHoleCredentials.lastSourceWasLive = true
                        PiHoleCredentials.livePopulation = population
                    }
                    self.sourceNotice = notice
                    self.savedSourceURL = PiHoleCredentials.savedURL
                    self.savedSourceInsecure = insecure
                    self.sourceEndpoint = snapshot.endpoint
                    self.sourceSnapshotWindow = "6 hours"
                    self.sourceError = nil
                    self.sourceConnecting = false
                    AtlasDiagnostics.log("source live connected endpoint=\(snapshot.endpoint) devices=\(liveNetwork.devices.count) destinations=\(liveNetwork.destinations.count) population=\(population.storageValue) restoring=\(restoring)")
                    self.switchSource(to: liveNetwork, source: liveSource)
                    self.showToast(restoring ? "Pi-hole session restored" : "Live Pi-hole connected")
                }
            } catch {
                await MainActor.run {
                    guard requestToken == self.sourceRequestToken else { return }
                    self.sourceConnecting = false
                    self.sourceError = error.localizedDescription
                    AtlasDiagnostics.log("source live failed restoring=\(restoring): \(error.localizedDescription)")
                    if restoring {
                        self.showToast("Pi-hole unavailable · demo source", tone: .coral)
                    }
                }
            }
        }
    }

    func useDemoSource(rememberChoice: Bool = true, preview: Bool = true) {
        if preview { demoPreview = true }
        sourceRequestToken += 1
        source.stop()
        host.stopDomainStream()
        liveSnapshot = nil
        liveClient = nil
        activeSourcePassword = nil
        sourceConnecting = false
        sourceError = nil
        sourceNotice = nil
        sourceEndpoint = nil
        sourceSnapshotWindow = nil
        if rememberChoice { PiHoleCredentials.lastSourceWasLive = false }
        let demo = DemoNetwork(seed: seed)
        let demoSource = LiveSource(network: demo, seed: seed + 7, rate: 2.85)
        switchSource(to: demo, source: demoSource)
        showToast("Demo source active")
    }

    /// Re-open the source the user was last watching. A live session is
    /// re-established with the stored URL, certificate preference and Keychain
    /// password; a failure falls back to the demo already on screen and leaves
    /// the preference set so the next launch can retry.
    func restoreLastSourceIfNeeded() {
        guard PiHoleCredentials.lastSourceWasLive else { return }
        let url = PiHoleCredentials.savedURL
        AtlasDiagnostics.log("source restore requested url=\(url) population=\(livePopulation.storageValue)")
        guard !url.isEmpty else {
            PiHoleCredentials.lastSourceWasLive = false
            showToast("No saved Pi-hole URL · demo source", tone: .coral)
            return
        }
        showToast("Restoring Pi-hole session…", tone: .signal)
        connectPiHole(url: url, password: PiHoleCredentials.password ?? "",
                      insecure: PiHoleCredentials.savedInsecure, restoring: true)
    }

    func setLivePopulation(_ population: LivePopulation) {
        guard population != livePopulation else { return }
        let previous = livePopulation
        livePopulation = population
        PiHoleCredentials.livePopulation = population
        guard isLiveSource, let snapshot = liveSnapshot, let client = liveClient else {
            showToast("Live population · \(population.title)", tone: .signal)
            return
        }
        do {
            let rebuilt = try LiveNetworkBuilder.make(snapshot: snapshot, seed: seed,
                                                      population: population)
            let nextSource = PiHoleSource(network: rebuilt, client: client, initial: snapshot)
            switchSource(to: rebuilt, source: nextSource)
            showToast("Live population · \(population.title)", tone: .signal)
        } catch {
            livePopulation = previous
            PiHoleCredentials.livePopulation = previous
            showToast("Could not rebuild the live graph", tone: .coral)
        }
    }

    func disconnectPiHole() {
        sourceRequestToken += 1
        activeSourcePassword = nil
        PiHoleCredentials.clear()
        hasSavedPassword = false
        savedSourceURL = ""
        savedSourceInsecure = false
        demoPreview = false
        useDemoSource(preview: false)
    }

    func refreshLiveSource(rememberChoice: Bool = true) {
        guard let endpoint = sourceEndpoint, !endpoint.isEmpty else { return }
        connectPiHole(url: savedSourceURL.isEmpty ? endpoint : savedSourceURL,
                      password: activeSourcePassword ?? "", insecure: savedSourceInsecure,
                      rememberChoice: rememberChoice)
    }

    // ── construction ─────────────────────────────────────────────────────

    private func buildScene() {
        for (index, destination) in network.destinations.enumerated() {
            let spec = NodeSpec(
                id: destination.id,
                key: destination.key,
                domain: destination.domain,
                meta: destination.status.rawValue,
                latency: Format.count(destination.liveQueries),
                status: destination.status,
                position: destination.position,
                tone: destination.tone
            )
            let node = NodeView(spec: spec, radius: destination.visualRadius, index: index, rng: rng)
            node.destinationRef = destination
            node.setPresence(0)
            nodes.append(node)
            nodeByDest[destination.id] = node
        }
        for device in network.devices {
            let position = device.surface + device.normal * 0.015
            let view = DeviceView(spec: DeviceSpecView(id: device.id, name: device.name,
                                                       kind: device.kind, ip: device.ip,
                                                       thisMac: device.thisMac),
                                  position: position, normal: device.normal, rng: rng)
            view.deviceRef = device
            devices.append(view)
            deviceById[device.id] = view
        }
        for (index, edge) in network.edges.enumerated() {
            guard let device = deviceById[edge.deviceId], let node = nodeByDest[edge.destinationId] else { continue }
            let wire = WireView(offset: 0.11 + Float(index) * 0.173,
                                tone: edge.destination.status)
            wire.deviceView = device
            wire.nodeView = node
            wire.edgeId = edge.id
            wire.setGlobePath(from: device.position, to: node.basePosition,
                              normal: device.normal, globeRadius: globeRadius)
            wires.append(wire)
            wireByKey["\(edge.deviceId)::\(edge.destinationId)"] = wire
            wireByEdge[edge.id] = wire
            edgeByKey[edge.id] = edge
        }
        rebuildLocalWeights()
        for view in devices {
            view.update(dt: 0, elapsed: 0, camera: camera)
        }
        for node in nodes {
            node.update(dt: 0, elapsed: 0)
        }
        stageScale = globeRadius / 6
    }

    /// Seed the sparse pull index from the graph's cumulative activity (a live
    /// snapshot can arrive with local traffic already recorded). Keys are the
    /// same sorted "a::b" form the source writes, so both directions share one
    /// weight exactly as before.
    private func rebuildLocalWeights() {
        localWeights.removeAll(keepingCapacity: true)
        deviceRank = Dictionary(uniqueKeysWithValues: network.devices.enumerated().map {
            ($0.element.id, $0.offset)
        })
        for (key, count) in network.localActivity {
            let parts = key.components(separatedBy: "::")
            guard parts.count == 2 else { continue }
            let weight = Float(count)
            localWeights[parts[0], default: [:]][parts[1], default: 0] += weight
            localWeights[parts[1], default: [:]][parts[0], default: 0] += weight
        }
    }

    private var stageScale: Float = 1

    private func configureBoot() {
        let visible = network.destinations.filter(\.windowVisible)
        if reducedMotion {
            for destination in visible {
                nodeByDest[destination.id]?.setPresence(1)
                setWireVisibility(destinationId: destination.id, visible: true)
            }
        } else {
            for (i, destination) in visible.enumerated() {
                after(0.55 + Float(i) * 0.145) { [weak self] in
                    guard let self else { return }
                    self.birthDestination(destination, fromBoot: true)
                }
            }
        }
        let fit = currentFitDistance()
        lastFramingTarget = targetGlobeRadius()
        updateCameraLimits()
        let dir = Vec3(13.2, 9.1, 26.4).normalized
        flyTo(position: orbitTarget + dir * fit, target: orbitTarget, duration: 2.6, delay: 0.15)
        ready = true
        readyFlag = true
    }

    private func restoreLastGlobe() {
        guard AtlasPreferences.activeGlobe == .host, activeGlobe == .dns else { return }
        activeGlobe = .host
        displayedGlobe = .host
        deckActive = false
        labels.labels = []
        hostLabels.labels = []
        selection = nil
        hostSelection = nil
        refreshUI()
    }

    func start() {
        guard !started else { return }
        started = true
        lastSourceTime = CACurrentMediaTime()
        lastRenderTime = CACurrentMediaTime()
        sourceTimer = Timer.scheduledTimer(timeInterval: 0.12, target: self,
                                           selector: #selector(sourceTick), userInfo: nil, repeats: true)
        uiTimer = Timer.scheduledTimer(timeInterval: 0.4, target: self,
                                       selector: #selector(uiTick), userInfo: nil, repeats: true)
        pulseTimer = Timer.scheduledTimer(timeInterval: 0.25, target: self,
                                          selector: #selector(pulseTick), userInfo: nil, repeats: true)
        source.start()
        host.start()
        if isLiveSource { host.seed(devices: network.devices) }
        restoreLastGlobe()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "atlas.startHost") {
            debugShowHostGlobe()
        }
        if UserDefaults.standard.bool(forKey: "atlas.autoFocusHost") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.focusGlobe(.host)
            }
        }
        #endif
        refreshUI()
    }

    // ── host globe / deck ────────────────────────────────────────────────

    private var deckPresentation: GlobeDeckPresentation {
        GlobeDeckPresentation(activeGlobe: activeGlobe, deckActive: deckActive,
                              deckTo: deckTo, progress: deckProgress)
    }

    /// Bridge the instrument's main-queue callbacks into published state. The
    /// instrument owns monitoring; the runtime owns what the UI observes.
    private func configureHostInstrument() {
        host.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.hostSnapshot = snapshot
            self.hostAvailable = snapshot.available
            self.hostNote = snapshot.note
            self.hostScene.apply(snapshot)
            self.inspectorRevision += 1
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "atlas.hostDebug") {
                let lines = snapshot.apps.prefix(8).map {
                    "\($0.name) in=\($0.rxPerSecond) out=\($0.txPerSecond) sockets=\($0.socketCount)"
                }
                let header = "available=\(snapshot.available) apps=\(snapshot.apps.count) domains=\(snapshot.domains.count) note=\(snapshot.note ?? "-")\n"
                try? (header + lines.joined(separator: "\n") + "\n")
                    .write(toFile: "/tmp/atlas-host-live.txt", atomically: true, encoding: .utf8)
            }
            #endif
        }
        host.onStatus = { [weak self] error in
            self?.hostDomainStatus = error
        }
    }

    var hostScopes: Set<HostScope> { host.scopes }

    func setHostScope(_ scope: HostScope, enabled: Bool) {
        host.setScope(scope, enabled: enabled)
    }

    func setHostScopes(_ scopes: Set<HostScope>) {
        host.setScopes(scopes)
    }

    func setHostPaused(_ paused: Bool) {
        hostPaused = paused
        host.setPaused(paused)
    }

    func selectHost(_ next: HostSelection?) {
        hostSelection = next
        hostScene.selection = next
        if next != nil {
            selection = nil
            // Match the DNS globe: selecting a body opens its inspector rail.
            rightRailOpen = true
        }
        inspectorRevision += 1
    }

    func clearHostSelection() {
        hostSelection = nil
        hostScene.selection = nil
        inspectorRevision += 1
    }

    func setHostHover(_ next: HostSelection?) {
        guard hostHover != next else { return }
        hostHover = next
        hostScene.hover = next
    }

    // ── unified globe picking ────────────────────────────────────────────

    /// One hit-test for both instruments and the background silhouette. The
    /// active globe's bodies always win over the background disc.
    func globePick(at point: CGPoint, viewSize: CGSize) -> GlobePick? {
        guard !deckActive else { return nil }
        switch activeGlobe {
        case .dns:
            if dnsHasVisualData, let pick = pick(at: point, viewSize: viewSize) {
                return .dns(pick)
            }
            if hitsInactiveGlobe(point: point, viewSize: viewSize) {
                return .focusGlobe(.host)
            }
        case .host:
            if let pick = hostScene.pick(at: point, viewSize: viewSize, camera: camera) {
                return .host(pick)
            }
            if dnsHasVisualData, hitsInactiveGlobe(point: point, viewSize: viewSize) {
                return .focusGlobe(.dns)
            }
        }
        return nil
    }

    func setGlobeHover(_ pick: GlobePick?) {
        switch pick {
        case .dns(let selection):
            setHostHover(nil)
            backgroundHover = nil
            setHovered(selection)
        case .host(let selection):
            setHovered(nil)
            backgroundHover = nil
            setHostHover(selection)
        case .focusGlobe(let kind):
            setHovered(nil)
            setHostHover(nil)
            backgroundHover = kind
        case nil:
            setHovered(nil)
            setHostHover(nil)
            backgroundHover = nil
        }
    }

    /// Screen anchor for the background-globe hover chip.
    func inactiveGlobeHint(viewSize: CGSize) -> (kind: GlobeKind, point: CGPoint, radius: CGFloat)? {
        guard !deckActive, let kind = backgroundHover,
              viewSize.width > 10, viewSize.height > 10 else { return nil }
        let viewport = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
        let offset = rearOffset()
        let center = camera.project(offset, viewport: viewport)
        let depth = camera.position.distance(to: offset)
        let radius = CGFloat(globeRadius * Float(viewSize.height)
            / (2 * tan(camera.fov * .pi / 360)) / max(0.001, depth))
        return (kind, CGPoint(x: CGFloat(center.x), y: CGFloat(center.y)), radius)
    }

    private func hitsInactiveGlobe(point: CGPoint, viewSize: CGSize) -> Bool {
        let viewport = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
        let activeCenter = camera.project(.zero, viewport: viewport)
        let activeRadius = globeRadius * Float(viewSize.height)
            / (2 * tan(camera.fov * .pi / 360)) / max(0.001, camera.position.length)
        let dActive = hypot(activeCenter.x - Float(point.x), activeCenter.y - Float(point.y))
        if dActive < activeRadius * 0.96 { return false }

        let offset = rearOffset()
        let center = camera.project(offset, viewport: viewport)
        let depth = camera.position.distance(to: offset)
        let radius = globeRadius * Float(viewSize.height)
            / (2 * tan(camera.fov * .pi / 360)) / max(0.001, depth)
        let d = hypot(center.x - Float(point.x), center.y - Float(point.y))
        return d < radius * 0.94
    }

    func focusHostSelection() {
        guard let hostSelection, let point = hostScene.focusPoint(for: hostSelection) else { return }
        autoResumeAt = CACurrentMediaTime() + 6
        lastInteraction = CACurrentMediaTime()
        flyTo(position: point.position, target: point.target, duration: 1.05, arc: true)
    }

    func focusGlobe(_ kind: GlobeKind) {
        guard !deckActive, kind != activeGlobe else { return }
        beginDeck(to: kind)
        showToast(kind == .host ? "Host traffic · this Mac" : "DNS · Pi-hole network",
                  tone: kind == .host ? .signal : .gold)
    }

    private func beginDeck(to kind: GlobeKind) {
        deckTo = kind
        let background = rearOffset()
        deckWorldBackground = background
        deckTargetFrom = orbitTarget
        // Orbit the camera 180° around the clicked globe's far side. The old
        // foreground never moves, so it becomes the background instead of
        // disappearing behind the camera.
        deckOrbitCenter = background
        deckOrbitStart = camera.position - background
        deckOrbitRadiusEnd = max(24, camera.position.distance(to: orbitTarget))
        deckOrbitAxis = .up
        deckProgress = 0
        deckDuration = reducedMotion ? 0.35 : 1.6
        deckActive = true
        autoResumeAt = CACurrentMediaTime() + 4
        lastInteraction = CACurrentMediaTime()
        labels.labels = []
        hostLabels.labels = []
    }

    func toggleGlobe() {
        focusGlobe(activeGlobe == .dns ? .host : .dns)
    }

    private var rearOrbitRadius: Float {
        // Keep the orbit outside the camera's maximum zoom-out radius. When
        // the far side of that circle is on the camera side, the globe is
        // behind the camera, not in front of the foreground.
        max(110, currentFitDistance() * 3.0)
    }

    private func rearOffset() -> Vec3 {
        // A real world-space orbit around the active globe. No depth clamp:
        // clamping produced the old back-and-forth motion instead of a full
        // orbit that passes behind the camera.
        rearWorldOffset
    }

    private func orbitRear(_ dt: Float) {
        let angle = dt * 0.018
        guard angle != 0, rearWorldOffset.lengthSq > 0.0001 else { return }
        let rotated = Quat(angle: angle, axis: rearOrbitAxis)
        let matrix = Mat4.rotation(quaternion: rotated)
        let p = matrix * SIMD4(rearWorldOffset.normalized, 1)
        rearWorldOffset = Vec3(p.x, p.y, p.z) * rearOrbitRadius
    }

    private func advanceDeck(dt: Float) {
        if !deckActive {
            orbitRear(dt)
            return
        }
        deckProgress += dt / max(0.3, deckDuration)
        if deckProgress >= 0.5, displayedGlobe != deckTo {
            displayedGlobe = deckTo
            labels.labels = []
            hostLabels.labels = []
        }
        if deckProgress >= 1 {
            completeDeck()
        }
    }

    private func completeDeck() {
        // Rebase the world around the globe that the camera just reached. Both
        // layers and the camera move by the same vector, so the final frame is
        // visually continuous; from here the new active globe is at the origin.
        let background = deckWorldBackground
        let direction: Vec3
        if deckOrbitStart.lengthSq > 0.0001 {
            direction = deckOrbitStart.normalized
        } else {
            direction = Vec3(0, 0, 1)
        }
        let rotated = Mat4.rotation(quaternion: Quat(angle: deckOrbitAngle, axis: deckOrbitAxis))
            * SIMD4(direction, 1)
        let endPosition = deckOrbitCenter + Vec3(rotated.x, rotated.y, rotated.z) * deckOrbitRadiusEnd
        camera.position = endPosition - background
        camera.target = .zero
        camera.pan = .zero
        orbitTarget = .zero
        rearWorldOffset = -background
        activeGlobe = deckTo
        displayedGlobe = deckTo
        AtlasPreferences.activeGlobe = deckTo
        deckActive = false
        labels.labels = []
        hostLabels.labels = []
        selection = nil
        hostSelection = nil
        hover = nil
        hostHover = nil
        refreshUI()
    }

    /// Headless review hook: populate the host globe with the deterministic demo
    /// snapshot and make it active without a live monitor.
    func debugShowHostGlobe() {
        let snapshot = HostDemo.snapshot()
        hostSnapshot = snapshot
        hostScene.apply(snapshot)
        hostScene.primeForSnapshot()
        activeGlobe = .host
        displayedGlobe = .host
        deckActive = false
        selection = nil
        hostSelection = nil
        labels.labels = []
        refreshUI()
    }

    /// Headless review hook: freeze the DNS→host focus transition at `progress`.
    func debugShowDeck(progress: Float) {
        let snapshot = HostDemo.snapshot()
        hostSnapshot = snapshot
        hostScene.apply(snapshot)
        hostScene.primeForSnapshot()
        beginDeck(to: .host)
        deckProgress = clamp01(progress)
        displayedGlobe = deckProgress >= 0.5 ? .host : .dns
        refreshUI()
    }

    private func updateHostScene(dt: Float, viewSize: CGSize) {
        let deck = deckPresentation
        hostScene.setCamera(camera)
        hostScene.setDetail(deck.hostDetail, active: deck.hostIsLive)
        hostScene.update(dt: dt, camera: camera)
        if activeGlobe == .host && !deckActive && viewSize.width > 10 {
            hostScene.resolveLabels(camera: camera, viewSize: viewSize, labelMode: labelMode)
            if hostLabels.labels != hostScene.labels {
                hostLabels.labels = hostScene.labels
            }
        } else if !hostLabels.labels.isEmpty {
            hostLabels.labels = []
        }
    }

    @objc private func sourceTick() {
        let now = CACurrentMediaTime()
        let dt = min(2, max(0, now - lastSourceTime))
        lastSourceTime = now
        guard !paused else { return }
        source.update(realDt: Float(dt))
    }

    @objc private func uiTick() {
        refreshUI()
    }

    @objc private func pulseTick() {
        let second = Int(Date().timeIntervalSince1970)
        if second != lastPulseSecond {
            lastPulseSecond = second
            if !paused && !isReplay { commitPulseSecond() }
        }
    }

    // ── replay ───────────────────────────────────────────────────────────

    var isReplay: Bool { mode == .replay }

    /// Pick a default compression so the whole range plays in roughly three
    /// minutes. 1× stays available, but a multi-day range would otherwise take
    /// days to watch before the first useful movement.
    private static func autoReplayRate(durationMS: Double) -> Float {
        let seconds = max(1, durationMS / 1000)
        let target: Double = 180
        let stops: [Float] = [1, 60, 600, 3_600]
        return stops.min {
            abs(log(seconds / Double($0) / target)) < abs(log(seconds / Double($1) / target))
        } ?? 600
    }

    var replayProgress: Double {
        guard isReplay, replayEnd > replayStart else { return 0 }
        return min(1, max(0, (replayTime - replayStart) / (replayEnd - replayStart)))
    }

    var replayRangeTitle: String {
        ReplayRange.nearest(hours: replayRangeHours).title
    }

    var replayDateText: String {
        guard replayTime > 0 else { return "--" }
        return Format.dayTime(replayTime)
    }

    var replayTimeText: String {
        guard replayTime > 0 else { return "--:--:--" }
        return Format.clock(replayTime)
    }

    /// Load the last `hours` of traffic and start playing at `at` (or at the
    /// beginning). The demo archive is built locally; a Pi-hole archive is
    /// fetched from FTL's on-disk query database off the main thread.
    func enterReplay(hours: Float = ReplayRange.defaultChoice.hours, at anchorMS: Double? = nil) {
        guard ready else { return }
        let range = ReplayRange.nearest(hours: hours)
        let previousFraction: Double = {
            guard isReplay, replayEnd > replayStart else { return 0 }
            return min(1, max(0, (replayCursor - replayStart) / (replayEnd - replayStart)))
        }()
        let end = Date().timeIntervalSince1970 * 1000
        let start = max(0, end - Double(range.hours) * 3_600_000)
        let anchor = anchorMS.map { min(end - 1, max(start, $0)) }
            ?? (isReplay ? start + (end - start) * previousFraction : start)

        replayRangeHours = range.hours
        replayRequestToken += 1
        let token = replayRequestToken
        replayJumpOpen = false

        if let live = source as? PiHoleSource {
            replayLoading = true
            Task { [weak self] in
                do {
                    let archive = try await live.loadReplay(from: start, until: end)
                    await MainActor.run {
                        self?.installReplay(archive, at: anchor, token: token, range: range)
                    }
                } catch {
                    await MainActor.run {
                        self?.failReplay(error, token: token, range: range)
                    }
                }
            }
        } else if let demo = source as? LiveSource {
            let archive = demo.makeReplay(from: start, until: end)
            installReplay(archive, at: anchor, token: token, range: range)
        } else {
            showToast("This source cannot be replayed.", tone: .coral)
        }
    }

    private func installReplay(_ archive: ReplayArchive, at anchor: Double,
                               token: Int, range: ReplayRange) {
        guard token == replayRequestToken else { return }
        guard !archive.events.isEmpty else {
            replayLoading = false
            showToast("No playable queries in \(range.detail).", tone: .coral)
            return
        }
        if replayRateAuto {
            replayRate = Self.autoReplayRate(durationMS: archive.duration)
        }
        replayArchive = archive
        replayStart = archive.start
        replayEnd = archive.end
        replayBuckets = archive.buckets
        replayMaxBucket = archive.maxBucket
        replayTotal = archive.events.count
        replayScanned = archive.scannedRows
        replaySkipped = archive.skippedRows
        replaySampled = archive.sampled
        replaySourceLabel = archive.sourceLabel
        replayLoading = false
        mode = .replay
        paused = false
        source.setPaused(true)
        replayFinished = false
        replayLastPublished = -1
        replayRecent.removeAll()
        clearReplayEffects()
        seekReplay(to: anchor, preRoll: true)
        let sampled = archive.sampled ? " · sampled" : ""
        showToast("Replay · \(range.title) · \(Format.count(archive.events.count)) queries\(sampled)",
                  tone: .signal)
        refreshUI()
    }

    private func failReplay(_ error: Error, token: Int, range: ReplayRange) {
        guard token == replayRequestToken else { return }
        replayLoading = false
        if replayArchive != nil, replayEnd > replayStart {
            replayRangeHours = Float((replayEnd - replayStart) / 3_600_000)
        }
        showToast("History unavailable · \(error.localizedDescription)", tone: .coral)
    }

    /// Leave playback and resume the live poller. Safe to call while a history
    /// request is still in flight; the token discards the late result.
    func goLive() {
        guard isReplay || replayLoading else { return }
        replayRequestToken += 1
        replayLoading = false
        replayArchive = nil
        replayBuckets = []
        replayTotal = 0
        replayScanned = 0
        replaySkipped = 0
        replaySampled = false
        replaySourceLabel = ""
        replayRecent.removeAll()
        replayFinished = false
        replayJumpOpen = false
        replayStart = 0
        replayEnd = 0
        replayTime = 0
        replayLastPublished = -1
        replayRateAuto = true
        mode = .live
        paused = false
        source.setPaused(false)
        clearReplayEffects()
        _ = applyWindow(animate: false, initial: false)
        lastSourceTime = CACurrentMediaTime()
        refreshUI()
        showToast("Live traffic", tone: .signal)
    }

    func setReplayRate(_ rate: Float) {
        replayRateAuto = false
        replayRate = clamp(rate, 1, 7_200)
        if replayFinished {
            seekReplay(to: replayStart, preRoll: false)
        }
        if paused { setPaused(false) }
        refreshUI()
    }

    func setReplayRange(_ range: ReplayRange) {
        replayRangeHours = range.hours
        if isReplay || replayLoading {
            enterReplay(hours: range.hours)
        }
    }

    /// Jump the playhead. Clearing the stage makes a scrub read as a jump cut
    /// rather than a pile-up of studies from the old position. A short
    /// pre-roll seeds the new position with the queries that just landed.
    func seekReplay(to timeMS: Double, preRoll: Bool = true) {
        guard let archive = replayArchive, !archive.events.isEmpty else { return }
        let target = min(replayEnd, max(replayStart, timeMS))
        clearReplayEffects()
        replayCursor = target
        replayTime = target
        replayLastPublished = target
        replayIndex = archive.index(at: target)
        replayEmitBudget = 0
        replayRecent.removeAll()
        replayFinished = target >= replayEnd - 1
        if preRoll && !paused {
            let from = archive.index(at: max(replayStart, target - 1_500))
            var index = from
            var count = 0
            while index < replayIndex, count < 8 {
                playReplayEvent(archive.events[index])
                index += 1
                count += 1
            }
        }
        refreshUI()
    }

    func seekReplay(fraction: Double, preRoll: Bool = false) {
        guard isReplay else { return }
        let value = min(1, max(0, fraction))
        seekReplay(to: replayStart + (replayEnd - replayStart) * value, preRoll: preRoll)
    }

    private func advanceReplay(dt: Float) {
        guard isReplay, !paused, !replayLoading,
              let archive = replayArchive, !archive.events.isEmpty else { return }
        guard replayCursor < replayEnd else {
            if replayLoop {
                seekReplay(to: replayStart, preRoll: false)
            } else if !replayFinished {
                replayFinished = true
            }
            return
        }
        if replayFinished { replayFinished = false }
        replayEmitBudget = min(1.5, replayEmitBudget + Double(dt) * 30)
        let target = min(replayEnd, replayCursor + Double(dt) * Double(replayRate) * 1000)
        var allowed = min(8, Int(replayEmitBudget))
        while replayIndex < archive.events.count,
              archive.events[replayIndex].ts <= target,
              allowed > 0 {
            playReplayEvent(archive.events[replayIndex])
            replayIndex += 1
            allowed -= 1
            replayEmitBudget -= 1
        }
        // The renderer has a fixed signal/effect budget. When history is denser
        // than that, keep the playhead honest and drop the surplus events for
        // this slice instead of building an unbounded backlog.
        while replayIndex < archive.events.count,
              archive.events[replayIndex].ts <= target {
            replayIndex += 1
        }
        replayCursor = target
        if replayCursor >= replayEnd {
            if replayLoop {
                seekReplay(to: replayStart, preRoll: false)
            } else {
                replayFinished = true
                refreshUI()
            }
        }
    }

    private func playReplayEvent(_ event: ReplayEvent) {
        guard let device = network.deviceById[event.deviceId],
              let destination = network.destinationById[event.destinationId],
              let edge = edgeByKey["\(event.deviceId)::\(event.destinationId)"] else { return }
        let query = QueryEvent(
            id: event.id,
            ts: event.ts,
            device: device,
            destination: destination,
            edge: edge,
            latency: event.latency
        )
        handleQuery(query)
        replayRecent.insert(query, at: 0)
        if replayRecent.count > 40 { replayRecent.removeLast(replayRecent.count - 40) }
    }

    private func clearReplayEffects() {
        effects.clear()
        signals.removeAll()
        deviceAppearanceLinks.removeAll()
        signalCounts.removeAll()
        localTraces.removeAll()
        ringTraces.removeAll()
        eventLabels.removeAll()
        lastImpact = nil
        hitGeometryReplayAt = nil
        for wire in wires {
            wire.setSignalActive(false)
            wire.reveal = 1
        }
        for node in nodes { node.stopRecoil() }
        for device in network.devices { device.pendingAppearance = false }
        updateLabels(force: true)
        applyVisualState()
    }

    // ── timers ───────────────────────────────────────────────────────────

    func after(_ seconds: Float, _ action: @escaping () -> Void) {
        timers.append(TimerEntry(remaining: seconds, action: action, token: timerToken))
    }

    private func updateTimers(_ dt: Float) {
        guard !timers.isEmpty else { return }
        var due: [TimerEntry] = []
        for i in timers.indices.reversed() {
            timers[i].remaining -= dt
            if timers[i].remaining <= 0 {
                due.append(timers[i])
                timers.remove(at: i)
            }
        }
        for timer in due.reversed() where timer.token == timerToken {
            timer.action()
        }
    }

    // ── frame update ─────────────────────────────────────────────────────

    func updateFrame(dt rawDt: Float, viewSize: CGSize) {
        let now = CACurrentMediaTime()
        let dt = min(0.05, max(0, rawDt))
        realTime += dt
        let simDt = paused ? 0 : dt * speed
        if !paused { elapsed += simDt }

        if viewSize.width > 10, viewSize.height > 10, viewSize != frameViewSize {
            frameViewSize = viewSize
            if !userZoomed && cameraFlight == nil {
                applyFraming()
            }
        }
        if !didFrame {
            didFrame = true
            frameViewSize = viewSize
            applyFraming()
        }

        camera.aspect = Float(frameViewSize.width / max(1, frameViewSize.height))
        trauma = max(0, trauma - dt * 1.8)
        advanceDeck(dt: paused ? 0 : dt)
        updateCamera(dt)
        // The inactive DNS instrument is frozen: its layout, effects and
        // labels are expensive and invisible at background LOD. It resumes
        // exactly where it left off when it becomes active again.
        let dnsLive = activeGlobe == .dns && !deckActive
        if dnsLive {
            updateLayout(realDt: dt)
            updateDevices(dt)
            updateNodes(dt)
            updateWires(dt)
            advanceReplay(dt: dt)
            updateHalo(dt)
            updateLocalTraces(dt)
            for i in signals.indices.reversed() {
                if !signals[i].update(dt: simDt) {
                    signals.remove(at: i)
                }
            }
            updateDeviceAppearances(simDt)
        }

        statsClock += dt
        if statsClock >= 1 {
            statsClock = 0
            updateLiveStats()
        }
        windowClock += dt
        if windowClock >= 4 {
            windowClock = 0
            _ = applyWindow(animate: true, initial: false)
            refreshUI()
        }
        // Labels track the field every frame so they do not step against a
        // 60–72 Hz globe. Per-frame SwiftUI work grows with the visible label
        // count (a full All field is several times the frame cost of one
        // selected tag), so dense sets resolve at 24 Hz and very large graphs
        // at 12 Hz; the overlay interpolates the anchor between those updates
        // on the render server.
        updateHostScene(dt: dt, viewSize: frameViewSize)
        if activeGlobe == .dns && !deckActive {
            let denseLabels = labels.labels.count > 2
            let hugeGraph = nodes.count > 200
            let labelInterval: Float = denseLabels ? (hugeGraph ? 1.0 / 12.0 : 1.0 / 24.0) : 0
            labels.cadence = TimeInterval(labelInterval)
            labels.animates = !hugeGraph
            labelResolveClock += dt
            if labelInterval <= 0 || labelResolveClock >= labelInterval {
                labelResolveClock = 0
                updateLabels(force: false)
            }
            expireEventLabels()
        } else if !labels.labels.isEmpty {
            labels.labels = []
        }
        updateTimers(simDt)
        updateAutoTour(dt)

        // Camera / post-ease constants from _tick.
        let focusDistance = max(0.001, camera.position.length)
        let wide = clamp((focusDistance - 26) / 3.5, 0, 1)
        let close = 0.55 * (1 - clamp((focusDistance - 11.5) / 14.5, 0, 1))
        let dragScale: Float = dragging ? 0.55 : 1
        let target = max(close, wide) * dragScale
        dofStrength += (target - dofStrength) * (1 - exp(-dt * 5))

        buildDrawList(simDt: simDt)
        lastRenderTime = now
    }

    private func updateCamera(_ dt: Float) {
        if deckActive { return }
        if flightDelayRemaining > 0 {
            flightDelayRemaining -= dt
            if flightDelayRemaining <= 0, let pending = pendingFlight {
                pendingFlight = nil
                startFlight(from: camera.position, to: pending.position,
                            target: pending.target, duration: pending.duration,
                            arc: pending.arc)
            }
        }
        if var flight = cameraFlight {
            flight.t = min(1, flight.t + dt / flight.duration)
            let k = easeInOutCubic(flight.t)
            orbitTarget = flight.fromTarget.lerp(flight.toTarget, k)
            if flight.arc {
                // Rotate the camera's offset around the look target instead of
                // lerping through the globe. A background body then spins into
                // view; a straight chord would dive through the field first.
                let rotation = simd_slerp(Quat(angle: 0, axis: .up), flight.rotation, k)
                let direction = simd_act(rotation, flight.fromDir).normalized
                let radius = lerp(flight.fromRadius, flight.toRadius, k)
                camera.position = orbitTarget + direction * radius
            } else {
                camera.position = flight.fromPos.lerp(flight.toPos, k)
            }
            camera.target = orbitTarget
            camera.pan = flight.fromPan + (flight.toPan - flight.fromPan) * k
            if flight.t >= 1 {
                camera.position = flight.toPos
                orbitTarget = flight.toTarget
                camera.target = orbitTarget
                camera.pan = flight.toPan
                cameraFlight = nil
            } else {
                // CameraFlight is a value type: without writing the advanced
                // copy back, `t` stayed at zero forever, which left the boot
                // flight permanently in control and blocked every later
                // orbit/zoom/auto-orbit input behind `cameraFlight == nil`.
                cameraFlight = flight
            }
            return
        }

        let autoRotate = spinEnabled && !paused && !reducedMotion && !dragging
            && !(windowMoving && !windowDragSpinsGlobe)
            && CACurrentMediaTime() > autoResumeAt
        if autoRotate {
            sphericalDelta.x -= (TAU / 60) * 0.58 * dt
        }

        var offset = camera.position - orbitTarget
        let radius = clamp(offset.length * orbitScale, minOrbitRadius, maxOrbitRadius)

        // OrbitControls with damping applies only dampingFactor of the pending
        // delta each update, then decays that delta. Auto-rotate therefore
        // lands at its documented one-revolution-per-~103s instead of being
        // amplified by the damping tail.
        let damping: Float = 0.065
        let yaw = sphericalDelta.x * damping
        let pitch = sphericalDelta.y * damping
        var up = camera.up.normalized

        // Arcball-style orbit: yaw around the camera up, then pitch around the
        // current screen-right axis. The up vector rolls with the camera, so a
        // full vertical revolution crosses the poles without a look-at flip.
        let yawQ = Quat(angle: yaw, axis: up.lengthSq > 0.001 ? up : .up)
        offset = simd_act(yawQ, offset)
        up = simd_act(yawQ, up)
        var right = offset.normalized.cross(up)
        if right.lengthSq < 0.000001 { right = camera.forward.cross(.up) }
        right = right.normalized
        let pitchQ = Quat(angle: -pitch, axis: right)
        offset = simd_act(pitchQ, offset)
        up = simd_act(pitchQ, up)
        let dir = offset.normalized
        camera.position = orbitTarget + dir * radius
        camera.target = orbitTarget
        camera.up = up.normalized
        orbitScale = 1
        sphericalDelta *= (1 - damping)
    }

    private func updateDevices(_ dt: Float) {
        for view in devices {
            view.update(dt: dt, elapsed: elapsed, camera: camera)
        }
    }

    private func updateNodes(_ dt: Float) {
        let focusDistance = camera.position.length - globeRadius * 0.7
        let labelScale = 1.6 * (0.35 + 0.65 * dofStrength)
        for node in nodes {
            let depth = camera.position.distance(to: node.basePosition)
            let far = clamp((depth - focusDistance) / max(0.001, globeRadius * 1.35), 0, 1)
            node.depthBlur = (node.selected || node.hovered) ? 0 : far * labelScale
            node.update(dt: dt, elapsed: elapsed)
        }
    }

    private func updateWires(_ dt: Float) {
        let cameraDir = camera.position.normalized
        for wire in wires {
            let facing = clamp(wire.deviceView.normal.dot(cameraDir) * 1.4 + 0.15, 0.06, 1)
            wire.setFacing(facing)
        }
        wireClock += dt
        if wireClock >= 0.06 {
            wireClock = 0
            updateWireGeometry()
        }
    }

    private func updateWireGeometry() {
        for wire in wires {
            wire.setGlobePath(from: wire.deviceView.position,
                              to: wire.nodeView.basePosition,
                              normal: wire.deviceView.normal,
                              globeRadius: globeRadius)
        }
    }

    // ── layout (AtlasGlobe._updateLayout) ────────────────────────────────

    private enum OrbSpacing {
        /// Nominal centre-to-centre clearances. These are only achievable while
        /// the population is small; inside the capped globe they shrink.
        static let device: Float = 1.25
        static let destinationBase: Float = 1.0
        static let shellInner: Float = 0.24
        static let shellOuter: Float = 0.9
        static let volumePacking: Float = 0.72
        static let surfacePacking: Float = 0.8
        static let minimumRadius: Float = 6
        /// The previous live cap was 7. A 35% increase is the largest globe we
        /// draw; after this point orbs overlap instead of growing the field.
        static let maximumRadius: Float = 7 * 1.35
    }

    private func visibleDevicesCount() -> Int {
        network.devices.reduce(0) { $0 + ($1.windowVisible ? 1 : 0) }
    }

    private func visibleDestinationsCount() -> Int {
        network.destinations.reduce(0) { $0 + ($1.windowVisible ? 1 : 0) }
    }

    /// The globe grows gently from 6 to the 35%-larger maximum as the visible
    /// population rises, then stops. It no longer expands to honour a fixed
    /// clearance; the layout spacing shrinks inside the capped globe instead.
    private func targetGlobeRadius() -> Float {
        let count = visibleDevicesCount() + visibleDestinationsCount()
        let t = smoothstep(8, 320, Float(count))
        return OrbSpacing.minimumRadius
            + (OrbSpacing.maximumRadius - OrbSpacing.minimumRadius) * t
    }

    /// Centre-to-centre spacing that the current globe can actually support.
    /// At low counts this is the authored clearance; as the population grows
    /// the value falls so the capped globe does not jitter against an
    /// impossible constraint.
    private func effectiveDeviceSpacing(radius: Float, count: Int) -> Float {
        guard count > 0 else { return OrbSpacing.device }
        let supported = 4 * radius * (OrbSpacing.surfacePacking / Float(count)).squareRoot()
        return max(0.02, min(OrbSpacing.device, supported))
    }

    private func effectiveDestinationSpacing(radius: Float, count: Int,
                                             averageVisualRadius: Float) -> Float {
        let nominal = OrbSpacing.destinationBase + averageVisualRadius * 2
        guard count > 0 else { return nominal }
        let shellFraction = OrbSpacing.shellOuter * OrbSpacing.shellOuter * OrbSpacing.shellOuter
            - OrbSpacing.shellInner * OrbSpacing.shellInner * OrbSpacing.shellInner
        let available = shellFraction * (4.0 / 3.0) * Float.pi * radius * radius * radius
            * OrbSpacing.volumePacking
        let perOrb = available / Float(count)
        let supported = 2 * Float(cbrt(Double(3 * perOrb / (4 * Float.pi))))
        return max(0.02, min(nominal, supported))
    }

    private func updateLayout(realDt: Float) {
        let dt = min(0.1, max(0, realDt))
        let target = targetGlobeRadius()
        if abs(target - lastFramingTarget) > 0.35 {
            lastFramingTarget = target
            AtlasDiagnostics.log("globe target=\(String(format: "%.2f", target)) devices=\(visibleDevicesCount()) destinations=\(visibleDestinationsCount())")
            if !userZoomed, selection == nil, cameraFlight == nil {
                applyFraming()
            }
        }
        globeRadius += (target - globeRadius) * (1 - exp(-dt * 1.35))
        stageScale = globeRadius / 6
        let R = globeRadius

        let devices = network.devices
        let visibleDevices = devices.filter(\.windowVisible)
        let destinations = network.destinations
        let visible = destinations.filter(\.windowVisible)

        let averageDestinationRadius = visible.isEmpty ? 0
            : visible.reduce(0) { $0 + $1.visualRadius } / Float(visible.count)
        let deviceSpacing = effectiveDeviceSpacing(radius: R, count: visibleDevices.count)
        let destinationSpacing = effectiveDestinationSpacing(
            radius: R, count: visible.count, averageVisualRadius: averageDestinationRadius)

        layoutTick &+= 1
        let pairBudget = visibleDevices.count * visibleDevices.count
            + visible.count * visible.count
        let relaxationInterval = pairBudget > 1_000_000 ? 8 : (pairBudget > 250_000 ? 4 : 1)
        let relaxPairs = layoutTick % relaxationInterval == 0

        let move = 1 - exp(-dt * 0.22)
        for device in visibleDevices {
            var targetDir = device.homeNormal * 2.0
            // Only pairs that have exchanged local traffic pull on each other;
            // the weight is symmetric because handleLocal indexes both
            // directions. This is the same sum the previous all-pairs scan
            // computed, without building a key per pair per frame.
            if let peers = localWeights[device.id] {
                let ordered = peers.sorted {
                    (deviceRank[$0.key] ?? Int.max) < (deviceRank[$1.key] ?? Int.max)
                }
                for (peerId, count) in ordered where peerId != device.id {
                    guard let peer = deviceById[peerId]?.deviceRef,
                          peer.windowVisible else { continue }
                    let strength = min(5, sqrt(count)) * 0.42
                    targetDir += peer.normal * strength
                }
            }
            if targetDir.lengthSq > 0.0001 {
                device.normal = (device.normal + (targetDir.normalized - device.normal) * move).normalized
            }
        }
        if relaxPairs {
            for _ in 0..<2 {
                for i in 0..<visibleDevices.count {
                    for j in (i + 1)..<visibleDevices.count {
                        let a = visibleDevices[i], b = visibleDevices[j]
                        let distance = a.normal.distance(to: b.normal) * R
                        if distance >= deviceSpacing { continue }
                        var delta = a.normal - b.normal
                        if delta.lengthSq < 1e-6 { delta = Vec3(1, 0, 0) }
                        delta = delta.normalized * (((deviceSpacing - distance) / R) * 0.5)
                        a.normal = (a.normal + delta).normalized
                        b.normal = (b.normal - delta).normalized
                    }
                }
            }
        }

        let destMove = 1 - exp(-dt * 0.2)
        let radialMove = 1 - exp(-dt * 0.3)
        for destination in visible {
            var pull = Vec3.zero
            var total: Float = 0
            var maxWeight: Float = 0
            for edge in destination.edges where edge.device.windowVisible {
                let weight = 0.2 + Float(edge.baseQueries) * 0.003 + edge.activity * 2.2
                pull += edge.device.normal * weight
                total += weight
                maxWeight = max(maxWeight, weight)
            }
            if total > 0.0001 {
                var targetDirection = pull.normalized
                targetDirection = (targetDirection + (destination.homeDirection - targetDirection) * 0.3).normalized
                destination.direction = (destination.direction
                    + (targetDirection - destination.direction) * destMove).normalized
                let dominance = max(0.2, maxWeight / total)
                let clearance = destination.visualRadius + 0.55
                let maxFraction = max(0.36, min(OrbSpacing.shellOuter, 1 - clearance / R))
                let targetFraction = max(0.34, min(maxFraction, 0.42 + dominance * 0.4))
                destination.radialFraction += (targetFraction - destination.radialFraction) * radialMove
            }
            destination.radialFraction = max(OrbSpacing.shellInner, min(OrbSpacing.shellOuter, destination.radialFraction))
        }

        if relaxPairs {
            for _ in 0..<3 {
                for i in 0..<visible.count {
                    let a = visible[i]
                    for j in (i + 1)..<visible.count {
                        let b = visible[j]
                        var pa = a.direction * (a.radialFraction * R)
                        var pb = b.direction * (b.radialFraction * R)
                        let minDist = min(a.visualRadius + b.visualRadius + OrbSpacing.destinationBase,
                                          destinationSpacing)
                        var delta = pa - pb
                        let distance = max(0.0001, delta.length)
                        if distance >= minDist { continue }
                        delta = delta.normalized * ((minDist - distance) * 0.5)
                        pa += delta
                        pb -= delta
                        let maxA = max(0.34, min(OrbSpacing.shellOuter, 1 - (a.visualRadius + 0.55) / R))
                        let maxB = max(0.34, min(OrbSpacing.shellOuter, 1 - (b.visualRadius + 0.55) / R))
                        a.radialFraction = max(0.34, min(maxA, pa.length / R))
                        b.radialFraction = max(0.34, min(maxB, pb.length / R))
                        a.direction = pa.normalized
                        b.direction = pb.normalized
                    }
                }
            }
        }

        for device in devices {
            device.surface = device.normal * R
            deviceById[device.id]?.setSurfacePosition(device.surface, device.normal)
        }
        for destination in destinations {
            let maxFraction = max(0.34, min(OrbSpacing.shellOuter, 1 - (destination.visualRadius + 0.55) / R))
            destination.radialFraction = min(destination.radialFraction, maxFraction)
            destination.radius = destination.radialFraction * R
            destination.position = destination.direction * destination.radius
            nodeByDest[destination.id]?.setBasePosition(destination.position)
        }

        updateCameraLimits()

        haloClock += realDt
        if haloClock >= 0.55 {
            haloClock = 0
            if selection?.destinationId != nil || hoveredPath != nil {
                pathHalo = nil
                haloKey = nil
                syncPathHalo()
            }
        }
    }

    // ── draw list ────────────────────────────────────────────────────────

    /// Deterministic headless stepping for snapshot / verification tools. The
    /// live timers are bypassed; the source is pumped on the same 120 ms cadence
    /// as AtlasGlobe's setInterval.
    func advanceForSnapshot(seconds: Float, step: Float = 1.0 / 60.0) {
        var remaining = seconds
        var sourceAccumulator: Float = 0
        var last = 0.0
        _ = last
        while remaining > 0.00001 {
            let dt = min(step, remaining)
            remaining -= dt
            sourceAccumulator += dt
            if sourceAccumulator >= 0.12 {
                sourceAccumulator = 0
                if !paused { source.update(realDt: 0.12) }
            }
            updateFrame(dt: dt, viewSize: frameViewSize)
        }
    }

    private func buildDrawList(simDt: Float) {
        dot.reset()
        if !dnsHasVisualData {
            // An empty globe never joins the crossfade, so it stays at the
            // background floor even while a deck is in flight.
            let detail: Float = activeGlobe == .dns && !deckActive
                ? 1 : GlobeDeckPresentation.backgroundDetail
            let startLine = dot.stageLines.count
            let startPoint = dot.stagePoints.count
            stage.update(dt: simDt, elapsed: elapsed, stageScale: stageScale,
                         detail: max(0.51, detail), into: dot)
            let alpha = 0.03 + 0.97 * smoothstep(0.28, 0.82, detail)
            for i in startLine..<dot.stageLines.count { dot.stageLines[i].color.w *= alpha }
            for i in startPoint..<dot.stagePoints.count { dot.stagePoints[i].color.w *= alpha }
            labels.labels = []
            return
        }
        let dnsDetail = deckPresentation.dnsGeometryDetail
        // Keep the stage geometry stable and fade it, so the shell does not
        // pop in at a detail threshold while the globe is coming into focus.
        let stageLineStart = dot.stageLines.count
        let stagePointStart = dot.stagePoints.count
        stage.update(dt: simDt, elapsed: elapsed, stageScale: stageScale,
                     detail: max(0.51, dnsDetail), into: dot)
        let stageAlpha = 0.03 + 0.97 * smoothstep(0.28, 0.82, dnsDetail)
        for i in stageLineStart..<dot.stageLines.count { dot.stageLines[i].color.w *= stageAlpha }
        for i in stagePointStart..<dot.stagePoints.count { dot.stagePoints[i].color.w *= stageAlpha }

        for node in nodes {
            node.appendDraw(dot, elapsed: elapsed, camera: camera, detail: dnsDetail)
        }
        let focusDepth = camera.viewDepth(of: .zero)
        for (index, device) in devices.enumerated() {
            let delta = camera.viewDepth(of: device.position) - focusDepth
            device.defocus = delta > 0 ? clamp01(delta * 0.16) : 0
            device.stagger = Float(index % 7) / 7 * 0.10
            device.appendDraw(dot, elapsed: elapsed, detail: dnsDetail)
        }
        for wire in wires where !wire.hidden {
            wire.appendDraw(dot, elapsed: elapsed, detail: dnsDetail)
        }
        let dnsLive = activeGlobe == .dns && !deckActive
        if dnsLive {
            for signal in signals {
                signal.appendDraw(dot, elapsed: elapsed)
            }

            var ctx = EffectContext(camera: camera, node: nil, radius: 0.3, point: .zero,
                                    normal: .up, elapsed: elapsed, onShake: { [weak self] amount in
                                        self?.trauma = min(1, (self?.trauma ?? 0) + amount * 0.55)
                                    }, rng: rng)
            effects.update(dt: simDt, ctx: ctx, draw: dot)
            appendHitGeometry(dot)
            _ = ctx
        }

        for trace in localTraces {
            let t = min(1, trace.age / trace.duration)
            let alpha = 1 - t
            for vertex in trace.baseTriangles {
                var v = vertex
                v.color.w *= alpha
                dot.rawTriangles.append(v)
            }
        }
        for trace in ringTraces {
            let t = min(1, trace.age / trace.duration)
            let scale = 0.9 + t * 1.3
            let orientation = simd_quatf(from: Vec3(0, 0, 1), to: trace.normal)
            let model = Mat4.compose(position: trace.center, quaternion: orientation,
                                     scale: Vec3(repeating: scale))
            dot.addMesh(.ringFull, MeshInstance(model: model,
                                                color: rgba(Palette.signalIce, trace.baseAlpha * (1 - t))))
        }
        if let halo = pathHalo {
            dot.rawTriangles.append(contentsOf: halo.wide)
            dot.rawTriangles.append(contentsOf: halo.tight)
            let t = (elapsed * 0.16).truncatingRemainder(dividingBy: 1)
            let p = halo.curve.pointAt(t)
            dot.sprites.append(.glow(p, size: 0.75,
                                     color: halo.blocked ? Palette.coral : Palette.gold,
                                     opacity: 0.55 + sin(elapsed * 3.2) * 0.18))
        }
    }

    /// Port of the lab's optional Hit geometry overlay: the blast plane, its
    /// normal and the impact centre. It is drawn from the same record the
    /// effects use, so the plane can never disagree with the blast. Shield
    /// hits are 360° and deliberately have no planar overlay.
    private func appendBackgroundShell(to draw: DrawList, color: SRGB, alpha: Float) {
        // A fuzzy ring of soft glows, not a line: the shell should read as a
        // bokeh silhouette rather than sharp geometry behind the active globe.
        let count = 56
        for i in 0..<count {
            let y = 1 - (Float(i) + 0.5) * 2 / Float(count)
            let r = sqrt(max(0, 1 - y * y))
            let a = Float(i) * 2.399963
            let p = Vec3(cos(a) * r * 6.08, y * 6.08, sin(a) * r * 6.08)
            draw.sprites.append(.glow(p, size: 3.2, color: color, opacity: 0.04 * alpha))
        }
    }

    private func appendHitGeometry(_ draw: DrawList) {
        guard showHitGeometry,
              let record = lastImpact,
              !record.blocked,
              record.impactId != "containment",
              let node = nodeByDest[record.destinationId],
              !node.destroyed else { return }
        let age = elapsed - (hitGeometryReplayAt ?? record.at)
        guard age >= 0, age < 1.9 else { return }

        let baseR = max(0.26, node.radius * 1.55)
        let size = baseR * 3.2
        let centre = node.basePosition + node.recoilOffset
        let basis = orthoBasis(record.normal)
        let fade = 1 - max(0, (age - 1.05) / (1.9 - 1.05))
        let pulse = 1 + sin(age * 5.5) * 0.012

        let cross = rgba(Palette.signal, 0.045 * fade)
        draw.addLine(centre - basis.t * (size * pulse), centre + basis.t * (size * pulse), cross)
        draw.addLine(centre - basis.b * (size * pulse), centre + basis.b * (size * pulse), cross)

        draw.addPolyline(ringPoints(center: centre, axisX: basis.t, axisY: basis.b,
                                    radius: size * 0.55 * pulse, segments: 96),
                         color: rgba(Palette.signal, 0.06 * fade))
        draw.addPolyline(ringPoints(center: centre, axisX: basis.t, axisY: basis.b,
                                    radius: size * pulse, segments: 128),
                         color: rgba(Palette.signal, 0.17 * fade))
        draw.addPolyline(ringPoints(center: centre, axisX: basis.t, axisY: basis.b,
                                    radius: node.radius * 1.02, segments: 96),
                         color: rgba(Palette.gold, 0.28 * fade))

        draw.addLine(centre - record.normal * (size * 0.18),
                     centre + record.normal * (size * pulse),
                     rgba(Palette.signalIce, 0.34 * fade))
        draw.sprites.append(.glow(centre + record.normal * (size * 0.98),
                                  size: node.radius * 0.7,
                                  color: Palette.signal,
                                  opacity: 0.55 * fade))
        draw.sprites.append(.glow(centre - record.normal * (node.radius * 0.92),
                                  size: node.radius * 1.15,
                                  color: Palette.gold,
                                  opacity: 0.55 * fade))
    }

    func makeRenderState(viewSize: CGSize) -> RenderState {
        let focusDistance = max(0.001, camera.position.length)
        // The native composer's full-resolution DOF pass removes more energy
        // from the bright-pass threshold than the web's BokehPass; the 1.5×
        // calibration restores the web's bloom envelope at the same distance.
        // Keep the bloom envelope stable through close inspection. The old
        // close-up ramp attenuated strength, shrank the radius and finally
        // disabled bloom near the camera, which made zoomed-in studies look
        // flat. DOF still eases close-up; bloom does not.
        let hostMode = displayedGlobe == .host
        let densityScale = min(1, 24.0 / Float(max(1, nodes.count)))
        let bloomStrength = (0.4 + trauma * 0.32) * 1.5 * (hostMode ? 0.18 : densityScale)
        let bloomRadius: Float = 0.5
        var shake = Vec3.zero
        if motionMode != .off {
            let amount = trauma * trauma * 0.38
            if amount > 0.0005 {
                shake = Vec3(sin(realTime * 91.7) * amount * 0.24,
                             sin(realTime * 73.3 + 1.7) * amount * 0.18,
                             sin(realTime * 113.9 + 0.4) * amount * 0.14)
            }
        }
        let p = clamp01(deckProgress)
        let deck = deckPresentation
        let dnsDetail = deck.dnsDetail
        let hostDetail = deck.hostDetail

        var dnsLayer = RenderLayer(drawList: dot, offset: .zero,
                                   stageScale: stageScale, detail: dnsDetail)
        var hostLayer = RenderLayer(drawList: hostScene.draw, offset: .zero,
                                    stageScale: 1, detail: hostDetail)
        let backgroundOffset = deckActive ? deckWorldBackground : rearOffset()
        switch deck.backgroundKind {
        case .dns: dnsLayer.offset = backgroundOffset
        case .host: hostLayer.offset = backgroundOffset
        }
        let order = GlobeDeckPresentation.layerOrder(active: activeGlobe, deckActive: deckActive,
                                                     deckTo: deckTo)
        let layers = order.map { $0 == .dns ? dnsLayer : hostLayer }

        // Camera pan to the inactive globe. The target reaches the incoming
        // body early so the chrome handoff at p=0.5 already reads as its
        // close-up; the position arcs around instead of cutting through the
        // foreground globe.
        var renderCamera = camera
        if deckActive {
            let eased = p * p * (3 - 2 * p)
            let angle = deckOrbitAngle * eased
            let direction: Vec3
            if deckOrbitStart.lengthSq > 0.0001 {
                direction = deckOrbitStart.normalized
            } else {
                direction = Vec3(0, 0, 1)
            }
            let rotated = Mat4.rotation(quaternion: Quat(angle: angle, axis: deckOrbitAxis))
                * SIMD4(direction, 1)
            let radius = deckOrbitStart.length
                + (deckOrbitRadiusEnd - deckOrbitStart.length) * eased
            let position = deckOrbitCenter + Vec3(rotated.x, rotated.y, rotated.z) * radius
            let targetT = min(1, p / 0.35)
            let targetK = targetT * targetT * (3 - 2 * targetT)
            renderCamera.position = position
            renderCamera.target = deckTargetFrom.lerp(deckTargetFrom + deckWorldBackground, targetK)
            renderCamera.pan = .zero
        }
        let focusCenter = deckActive ? deckWorldBackground : Vec3.zero
        let focus = max(4, renderCamera.position.distance(to: focusCenter) - globeRadius * 0.7)

        return RenderState(
            camera: renderCamera,
            layers: layers,
            activeLayer: layers.count - 1,
            logicalSize: viewSize,
            elapsed: elapsed,
            backdropYaw: elapsed * 0.002,
            shake: shake,
            bloomStrength: bloomStrength,
            bloomRadius: bloomRadius,
            bloomEnabled: true,
            dofFocus: focus,
            dofAperture: 0.0004 * dofStrength,
            dofMaxBlur: 0.006 * dofStrength,
            dofEnabled: false,
            focusCenter: focusCenter,
            focusRadius: globeRadius
        )
    }

    // ── queries / signals / impacts ──────────────────────────────────────

    private func selectionAllows(deviceId: String, destinationId: String) -> Bool {
        guard let selection else { return true }
        switch selection {
        case .device(let id): return deviceId == id
        case .destination(let id): return destinationId == id
        case .path(let d, let dest): return deviceId == d && destinationId == dest
        }
    }

    private func handleQuery(_ event: QueryEvent) {
        guard ready else { return }
        guard activeGlobe == .dns, !deckActive else { return }
        if let status = filter.status, event.status != status { return }
        guard selectionAllows(deviceId: event.deviceId, destinationId: event.destinationId) else { return }
        guard let node = nodeByDest[event.destinationId],
              let wire = wireByKey["\(event.deviceId)::\(event.destinationId)"] else { return }
        let destination = node.destinationRef!
        let wasHidden = !destination.windowVisible
        if node.destroyed && !wasHidden { return }
        if signals.count > 44 { return }

        // An aged-out device is not shown yet. First recompute where it belongs
        // on the shell and let the query draw a wire from that empty position
        // to the destination. The arrival callback then reveals the device with
        // one of its appearance studies.
        let deviceWasHidden = !event.device.windowVisible && !event.device.pendingAppearance
        if deviceWasHidden {
            event.device.pendingAppearance = true
            revealDeviceLocation(event.device, wire: wire, node: node)
        }
        if wasHidden {
            wire.setVisible(true)
            wire.setDim(0.55)
        }
        let key = "\(event.deviceId)::\(event.destinationId)"
        signalCounts[key, default: 0] += 1
        wire.setSignalActive(true)
        let control = wire.controlPoints
        let length = CatmullRom(points: control).length()
        let duration = max(0.38, min(1.25, 0.42 + length * 0.05))
        if deviceWasHidden {
            let link = DeviceAppearanceLink(device: event.device, wire: wire, duration: duration) { [weak self] in
                self?.finishDeviceArrival(event.device, wire: wire)
            }
            deviceAppearanceLinks.append(link)
        }
        let arrival = CatmullRom(points: control, closed: false,
                                 curveType: "centripetal", tension: 0.5)
        let signal = Signal(controlPoints: control, duration: duration,
                            seed: UInt32(truncatingIfNeeded: Int(elapsed * 1000) ^ control.count)) { [weak self, weak node, weak wire] in
            guard let self, let node, let wire else { return }
            let next = max(0, (self.signalCounts[key] ?? 1) - 1)
            if next == 0 { self.signalCounts.removeValue(forKey: key) }
            else { self.signalCounts[key] = next }
            wire.setSignalActive(next > 0)
            if wasHidden {
                if !destination.windowVisible {
                    destination.windowVisible = true
                    self.birthDestination(destination, style: destination.birthId)
                    self.refreshUI()
                }
                return
            }
            if node.destroyed { return }
            // Use the curve snapshot the packet actually travelled, exactly as
            // the lab's `snapshot.getTangentAt(1)`. The live wire tangent can
            // drift if the destination moved while the packet was in flight.
            self.registerImpact(node: node, normal: arrival.tangentAt(1), event: event)
        }
        signals.append(signal)
        deviceById[event.deviceId]?.onFire()
    }

    /// Blocked destinations own the red containment/redaction pair; allowed
    /// destinations never receive either study. This mirrors the lab's field
    /// mapping (the red orb answers with the 360° shield and is sealed with a
    /// redaction) and keeps the two tones mutually exclusive even if a source
    /// document ever carries a mismatched style id.
    private func impactStyle(for destination: Destination) -> String {
        if destination.status == .blocked { return "containment" }
        if motionMode == .calm { return "eclipse" }
        let candidate = destination.impactId
        if candidate == "containment" || !Effects.impacts.contains(where: { $0.id == candidate }) {
            return "eclipse"
        }
        return candidate
    }

    private func birthStyle(for destination: Destination, override: String? = nil) -> String {
        if destination.status == .blocked { return "redaction" }
        if let override, override != "redaction",
           Effects.births.contains(where: { $0.id == override }) {
            return override
        }
        return destination.birthId == "redaction" ? "spiral" : destination.birthId
    }

    private func registerImpact(node: NodeView, normal: Vec3, event: QueryEvent?) {
        let destination = node.destinationRef!
        let blocked = destination.status == .blocked
        let n = normal.normalized
        node.onHit(n, recoil: recoilEnabled && !blocked)
        hitCounts.impact += 1

        let style = impactStyle(for: destination)
        let meta = Effects.meta(impact: style)
        if motionMode != .off {
            if effects.countByKind("impact") < 24 {
                let R = max(0.26, node.radius * 1.55)
                var ctx = EffectContext(camera: camera, node: node, radius: R,
                                        point: node.basePosition, normal: n,
                                        elapsed: elapsed, onShake: { [weak self] amount in
                                            self?.trauma = min(1, (self?.trauma ?? 0) + amount * 0.55)
                                        }, rng: rng)
                ctx.offset = .zero
                let effect = Effects.impact(style, ctx: ctx)
                effects.add(effect, node: node, origin: node.basePosition,
                            kind: "impact")
            }
            if !blocked && motionMode == .cinematic {
                trauma = max(trauma, 0.42)
            }
        }
        lastImpact = ImpactRecord(destinationId: destination.id, blocked: blocked,
                                  at: elapsed, normal: n, point: node.basePosition,
                                  impactId: meta.id, impactName: "\(meta.key) · \(meta.name)")
        hitGeometryReplayAt = nil
        flashDestinationLabel(destination.id, duration: 1.7)
        inspectorRevision += 1
    }

    private func handleLocal(_ event: LocalTrafficEvent) {
        // The layout's pull index mirrors network.localActivity; index it even
        // when the visual flow is skipped (paused/hidden), matching the old
        // per-frame dictionary read.
        localWeights[event.source.id, default: [:]][event.target.id, default: 0] += 1
        localWeights[event.target.id, default: [:]][event.source.id, default: 0] += 1
        guard let sourceView = deviceById[event.source.id],
              let targetView = deviceById[event.target.id] else { return }
        // A local flow is still a visual claim that both orbs are on stage.
        guard sourceView.deviceRef.windowVisible,
              targetView.deviceRef.windowVisible else { return }
        if paused { return }
        if signals.count > 52 { return }
        let from = sourceView.position
        let to = targetView.position
        var points: [Vec3] = []
        for i in 0...20 {
            let t = Float(i) / 20
            let radial = from.lerp(to, t).normalized
            let lift = 0.34 + sin(Float.pi * t) * 0.62
            points.append(radial * (globeRadius + lift))
        }
        let curve = CatmullRom(points: points, closed: false, curveType: "centripetal", tension: 0.5)
        let sampled = (0...72).map { curve.pointAt(Float($0) / 72) }
        let tightPositions = GeometryKit.tube(points: sampled, radius: 0.018, tubularSegments: 72, radialSegments: 5)
        let widePositions = GeometryKit.tube(points: sampled, radius: 0.06, tubularSegments: 72, radialSegments: 5)
        let ice = Palette.signalIce
        let tight = tightPositions.map { TriangleVertex(position: SIMD4($0, 1), color: rgba(ice, 0.42)) }
        let wide = widePositions.map { TriangleVertex(position: SIMD4($0, 1), color: rgba(ice, 0.065)) }
        localTraces.append(LocalTrace(baseTriangles: tight + wide, duration: 1.8))
        for view in [sourceView, targetView] {
            ringTraces.append(RingTrace(center: view.position + view.normal * 0.035,
                                        normal: view.normal, duration: 0.9,
                                        baseAlpha: 0.46))
        }
        sourceView.onFire()
        let localCurve = CatmullRom(points: points, closed: false, curveType: "centripetal", tension: 0.5)
        let duration = max(0.62, min(1.25, 0.36 + localCurve.length() * 0.045))
        let signal = Signal(controlPoints: points, duration: duration) { [weak targetView] in
            targetView?.onFire()
        }
        signals.append(signal)
        localFlowCount += 1
    }

    private(set) var localFlowCount = 0

    // ── births / deaths / windows ────────────────────────────────────────

    private func setWireVisibility(destinationId: String, visible: Bool) {
        for wire in wires where wire.nodeView.destinationRef?.id == destinationId {
            let deviceVisible = wire.deviceView.deviceRef?.windowVisible ?? true
            let next = visible && deviceVisible
            wire.setVisible(next)
            if next { wire.setDim(1) }
        }
    }

    private func setWireVisibility(deviceId: String, visible: Bool) {
        for wire in wires where wire.deviceView.deviceRef?.id == deviceId {
            let destinationVisible = wire.nodeView.destinationRef?.windowVisible ?? true
            let next = visible && destinationVisible
            wire.setVisible(next)
            if next { wire.setDim(1) }
        }
    }

    private func pulseDeviceRing(_ view: DeviceView) {
        guard motionMode != .off, !reducedMotion else { return }
        ringTraces.append(RingTrace(center: view.position + view.normal * 0.035,
                                    normal: view.normal, duration: 0.9, baseAlpha: 0.46))
    }

    /// Place an aged-out device back on the current shell radius and rebuild
    /// the query edge from that relative location. The wire starts empty and
    /// grows as the pulse travels; the orb itself stays hidden until arrival.
    private func revealDeviceLocation(_ device: Device, wire: WireView, node: NodeView) {
        device.surface = device.normal * globeRadius
        guard let view = deviceById[device.id] else { return }
        view.setSurfacePosition(device.surface, device.normal)
        wire.setGlobePath(from: view.position, to: node.basePosition,
                          normal: view.normal, globeRadius: globeRadius)
        wire.reveal = 0
        wire.setVisible(true)
        wire.setDim(0.55)
    }

    private func updateDeviceAppearances(_ dt: Float) {
        guard !deviceAppearanceLinks.isEmpty, dt > 0 else { return }
        for index in deviceAppearanceLinks.indices.reversed() {
            var link = deviceAppearanceLinks[index]
            link.t = min(1, link.t + dt / max(0.001, link.duration))
            link.wire.reveal = link.t
            if link.t >= 1 {
                deviceAppearanceLinks.remove(at: index)
                link.wire.reveal = 1
                link.onArrive()
            } else {
                deviceAppearanceLinks[index] = link
            }
        }
    }

    private func finishDeviceArrival(_ device: Device, wire: WireView) {
        guard let view = deviceById[device.id] else { return }
        device.pendingAppearance = false
        device.windowVisible = true
        view.setSurfacePosition(device.surface, device.normal)
        let styles = DeviceView.AppearanceStyle.allCases
        let style = styles[Int(rng.next() * Float(styles.count)) % styles.count]
        view.setWindowVisible(true, style: style)
        wire.reveal = 1
        setWireVisibility(deviceId: device.id, visible: true)
        pulseDeviceRing(view)
        windowStats = network.windowStats()
        updateLabels(force: true)
        applyVisualState()
    }

    func birthDestination(_ destination: Destination, fromBoot: Bool = false, style: String? = nil,
                          forceStyle: Bool = false) {
        guard let node = nodeByDest[destination.id] else { return }
        let id = forceStyle ? (style ?? destination.birthId) : birthStyle(for: destination, override: style)
        let meta = Effects.meta(birth: id)
        effects.cancel("death:\(destination.id)")
        effects.cancel("birth:\(destination.id)")
        node.destroyed = false
        node.setPresence(0)
        setWireVisibility(destinationId: destination.id, visible: true)
        let R = max(0.26, node.radius * 1.6)
        let ctx = EffectContext(camera: camera, node: node, radius: R,
                                point: node.basePosition, normal: .up,
                                elapsed: elapsed, onShake: { [weak self] amount in
                                    self?.trauma = min(1, (self?.trauma ?? 0) + amount * 0.55)
                                }, rng: rng)
        let effect = Effects.birth(meta.id, ctx: ctx, node: node)
        effects.add(effect, node: node, origin: node.basePosition,
                    key: "birth:\(destination.id)", kind: "birth")
        hitCounts.birth += 1
        flashDestinationLabel(destination.id, duration: 2.6)
        applyVisualState()
        _ = fromBoot
    }

    func retireDestination(_ destination: Destination, style: String? = nil, restoreAfter: Float = 0) {
        guard let node = nodeByDest[destination.id], !node.destroyed else { return }
        let meta: EffectMeta
        if let style, Effects.deaths.contains(where: { $0.id == style }) {
            meta = Effects.meta(death: style)
        } else {
            // Natural window expiry is not indexed by destination any more:
            // every orb that leaves the stage rolls one of the remaining
            // disappearance studies (D1–D2), so a busy lifetime change does
            // not replay the same death in the same order.
            meta = Effects.meta(death: randomDeathStyle())
        }
        effects.cancel("birth:\(destination.id)")
        effects.cancel("impact:\(destination.id)")
        node.destroyed = true
        node.stopRecoil()
        node.setPresence(0)
        setWireVisibility(destinationId: destination.id, visible: false)
        let R = max(0.26, node.radius * 1.6)
        let ctx = EffectContext(camera: camera, node: node, radius: R,
                                point: node.basePosition, normal: .up,
                                elapsed: elapsed, onShake: { [weak self] amount in
                                    self?.trauma = min(1, (self?.trauma ?? 0) + amount * 0.55)
                                }, rng: rng)
        let effect = Effects.death(meta.id, ctx: ctx, node: node)
        effects.add(effect, node: node, origin: node.basePosition,
                    key: "death:\(destination.id)", kind: "death")
        hitCounts.death += 1
        flashDestinationLabel(destination.id, duration: 2.0)
        if restoreAfter > 0 {
            after(restoreAfter) { [weak self] in
                self?.restoreDestination(destination, birth: true)
            }
        }
        applyVisualState()
    }

    /// World-clock disappearance roll. The four studies are deliberately
    /// equiprobable and the roll goes through the scene RNG, so a deterministic
    /// snapshot seed still reproduces the same sequence of erasures.
    private func randomDeathStyle() -> String {
        let index = Int(rng.next() * Float(Effects.deaths.count)) % Effects.deaths.count
        return Effects.deaths[index].id
    }

    func restoreDestination(_ destination: Destination, birth: Bool = false) {
        guard let node = nodeByDest[destination.id] else { return }
        effects.cancel("death:\(destination.id)")
        effects.cancel("birth:\(destination.id)")
        node.destroyed = false
        node.stopRecoil()
        node.setPresence(1)
        setWireVisibility(destinationId: destination.id, visible: true)
        if birth { birthDestination(destination, style: destination.birthId) }
        applyVisualState()
    }

    @discardableResult
    private func applyWindow(animate: Bool, initial: Bool) -> Bool {
        // Replay owns presence while it runs: a body that was outside the live
        // history window is born by its first replayed query and should stay
        // on stage for the rest of the range. Returning to live re-applies the
        // live window immediately.
        if isReplay { return false }
        let now = Date().timeIntervalSince1970 * 1000
        let windowMS = Double(windowHours) * 3_600_000
        var changed = false
        var becameVisible: [Destination] = []
        var becameHidden: [Destination] = []
        var becameVisibleDevices: [Device] = []
        var becameHiddenDevices: [Device] = []
        let canAnimate = animate && !paused

        // Update both endpoint flags before any wire decision: a wire is only
        // present while its device and its destination are inside the window.
        for device in network.devices {
            if device.pendingAppearance { continue }
            let visible = now - device.lastSeen <= windowMS
            let was = device.windowVisible
            if was != visible { changed = true }
            device.windowVisible = visible
            if !visible {
                if canAnimate {
                    if was { becameHiddenDevices.append(device) }
                } else {
                    deviceById[device.id]?.setWindowVisible(false, animated: false)
                    setWireVisibility(deviceId: device.id, visible: false)
                }
            } else if !initial && !was {
                if canAnimate {
                    becameVisibleDevices.append(device)
                } else {
                    deviceById[device.id]?.setWindowVisible(true, animated: false)
                    setWireVisibility(deviceId: device.id, visible: true)
                }
            }
        }

        for destination in network.destinations {
            let visible = now - destination.lastSeen <= windowMS
            let was = destination.windowVisible
            if was != visible { changed = true }
            destination.windowVisible = visible
            guard let node = nodeByDest[destination.id] else { continue }
            if !visible {
                if canAnimate {
                    if was { becameHidden.append(destination) }
                } else {
                    node.destroyed = true
                    node.setPresence(0)
                    setWireVisibility(destinationId: destination.id, visible: false)
                }
            } else if !initial && !was {
                if canAnimate {
                    becameVisible.append(destination)
                } else {
                    node.destroyed = false
                    node.setPresence(1)
                    setWireVisibility(destinationId: destination.id, visible: true)
                }
            }
        }
        if let selection {
            let hiddenDevice = selection.deviceId
                .flatMap { network.deviceById[$0] }?.windowVisible == false
            let hiddenDestination = selection.destinationId
                .flatMap { network.destinationById[$0] }?.windowVisible == false
            if hiddenDevice || hiddenDestination { select(nil) }
        }
        if let hover {
            let hiddenDevice = hover.deviceId
                .flatMap { network.deviceById[$0] }?.windowVisible == false
            let hiddenDestination = hover.destinationId
                .flatMap { network.destinationById[$0] }?.windowVisible == false
            if hiddenDevice || hiddenDestination { setHovered(nil) }
        }
        if canAnimate {
            for (index, destination) in becameHidden.enumerated() {
                after(Float(index) * 0.06) { [weak self] in
                    guard let self, !destination.windowVisible else { return }
                    self.retireDestination(destination)
                }
            }
            for (index, destination) in becameVisible.enumerated() {
                after(Float(index) * 0.09) { [weak self] in
                    guard let self, destination.windowVisible else { return }
                    self.birthDestination(destination, style: destination.birthId)
                }
            }
        }
        for device in becameHiddenDevices {
            deviceById[device.id]?.setWindowVisible(false)
            setWireVisibility(deviceId: device.id, visible: false)
            if let view = deviceById[device.id] { pulseDeviceRing(view) }
        }
        for device in becameVisibleDevices {
            deviceById[device.id]?.setWindowVisible(true)
            setWireVisibility(deviceId: device.id, visible: true)
            if let view = deviceById[device.id] { pulseDeviceRing(view) }
        }
        network.windowHours = windowHours
        updateLabels(force: true)
        applyVisualState()
        refreshUI()
        return changed
    }

    func setWindowHours(_ hours: Float) {
        let normalized = Windows.normalize(hours)
        AtlasPreferences.windowHours = normalized
        if normalized == windowHours {
            refreshUI()
            return
        }
        windowHours = normalized
        _ = applyWindow(animate: true, initial: false)
        showToast("Orb lifetime · \(Windows.label(hours: normalized))", tone: .signal)
    }

    // ── selection / filter / labels ──────────────────────────────────────

    func select(_ next: Selection?, toggle: Bool = true) {
        if let next {
            switch next {
            case .device(let id):
                guard deviceById[id] != nil else { return }
            case .destination(let id):
                guard nodeByDest[id] != nil else { return }
            case .path(let deviceId, let destinationId):
                guard wireByKey["\(deviceId)::\(destinationId)"] != nil else { return }
            }
        }
        let resolved: Selection? = (toggle && selection == next) ? nil : next
        selection = resolved
        pushSelection(resolved)
        updateLabels(force: true)
        applyVisualState()
        if selection != nil { rightRailOpen = true }
    }

    private func pushSelection(_ next: Selection?) {
        if selectionHistory.last == next { canGoBack = selectionHistory.count > 1; return }
        selectionHistory.append(next)
        if selectionHistory.count > 40 { selectionHistory.removeFirst(selectionHistory.count - 40) }
        canGoBack = selectionHistory.count > 1
    }

    func navigateBack() {
        guard selectionHistory.count > 1 else {
            clearSelection()
            return
        }
        selectionHistory.removeLast()
        let previous = selectionHistory.last ?? nil
        selection = previous
        canGoBack = selectionHistory.count > 1
        updateLabels(force: true)
        applyVisualState()
        rightRailOpen = previous != nil || rightRailOpen
    }

    func clearSelection() {
        selection = nil
        pushSelection(nil)
        updateLabels(force: true)
        applyVisualState()
    }

    func clearEffectsForSnapshot() {
        effects.clear()
        timers.removeAll()
        signals.removeAll()
        deviceAppearanceLinks.removeAll()
        signalCounts.removeAll()
        eventLabels.removeAll()
        lastImpact = nil
        hitGeometryReplayAt = nil
        for node in nodes {
            if node.destinationRef?.windowVisible == true {
                node.destroyed = false
                node.stopRecoil()
                node.setPresence(1)
                setWireVisibility(destinationId: node.destinationRef.id, visible: true)
            }
        }
        labelMode = .off
        updateLabels(force: true)
        rebuildDrawListForSnapshot()
    }

    func rebuildDrawListForSnapshot() {
        buildDrawList(simDt: 0)
    }

    func setCameraForSnapshot(position: Vec3, target: Vec3) {
        camera.position = position
        camera.target = target
        camera.up = .up
        camera.pan = .zero
        orbitTarget = target
        cameraFlight = nil
        panDragging = false
        userZoomed = true
        settlePostForSnapshot()
        rebuildDrawListForSnapshot()
    }

    /// Snapshot-only lever for the right-drag lens shift. Pan is a signed NDC
    /// offset; +x moves right, +y moves up.
    func setPanForSnapshot(_ pan: SIMD2<Float>) {
        camera.pan = clampedPan(pan)
        rebuildDrawListForSnapshot()
    }

    func prepareForUISnapshot(size: CGSize) {
        frameViewSize = size
        camera.aspect = Float(size.width / max(1, size.height))
        if !userZoomed && cameraFlight == nil { applyFraming() }
        settlePostForSnapshot()
        // Resolve only the visible instrument's tags; the DNS resolver would
        // otherwise repopulate the hidden globe's labels in a HOST still.
        if activeGlobe == .dns && !deckActive {
            updateLabels(force: true)
        } else if activeGlobe == .host && !deckActive {
            labels.labels = []
            hostScene.resolveLabels(camera: camera, viewSize: size, labelMode: labelMode)
            hostLabels.labels = hostScene.labels
        } else {
            labels.labels = []
            hostLabels.labels = []
        }
        rebuildDrawListForSnapshot()
        refreshUI()
    }

    func settlePostForSnapshot() {
        let focusDistance = max(0.001, camera.position.length)
        let wide = clamp((focusDistance - 26) / 3.5, 0, 1)
        let close = 0.55 * (1 - clamp((focusDistance - 11.5) / 14.5, 0, 1))
        dofStrength = max(close, wide)
    }

    /// Headless checks for the shared-world deck: background depth sign,
    /// background click target, focus handoff and chrome ownership.
    func debugGlobeChecks() -> [String] {
        var failed: [String] = []
        let savedPaused = paused
        let savedLabelMode = labelMode
        paused = false
        defer {
            paused = savedPaused
            labelMode = savedLabelMode
        }
        if activeGlobe != .dns || displayedGlobe != .dns { failed.append("initial-deck") }
        let offset = rearOffset()
        let backgroundDepth = offset.dot(camera.forward)
        let activeDepth = camera.position.distance(to: orbitTarget)
        if backgroundDepth > 0, backgroundDepth < activeDepth + globeRadius + 4 {
            failed.append("background-not-behind")
        }
        debugShowHostGlobe()
        if activeGlobe != .host || displayedGlobe != .host { failed.append("host-debug-state") }
        if hostScene.snapshot.apps.isEmpty { failed.append("host-demo-empty") }
        hostScene.selection = nil
        hostScene.hover = nil
        hostScene.setDetail(1, active: true)
        labelMode = .selected
        hostScene.resolveLabels(camera: camera, viewSize: frameViewSize, labelMode: labelMode)
        if !hostScene.labels.isEmpty { failed.append("host-label-selected") }
        labelMode = .all
        hostScene.resolveLabels(camera: camera, viewSize: frameViewSize, labelMode: labelMode)
        if hostScene.labels.isEmpty { failed.append("host-label-all") }
        debugShowDeck(progress: 0.4)
        if displayedGlobe != .dns { failed.append("handoff-early") }
        debugShowDeck(progress: 0.8)
        if displayedGlobe != .host { failed.append("handoff-late") }
        debugShowHostGlobe()
        focusGlobe(.dns)
        advanceForSnapshot(seconds: 0.9)
        if displayedGlobe != .dns { failed.append("focus-handoff") }
        advanceForSnapshot(seconds: 0.9)
        if activeGlobe != .dns { failed.append("focus-complete") }
        if !hostLabels.labels.isEmpty { failed.append("hud-labels") }
        return failed
    }

    func debugCameraPanChecks() -> [String] {
        var failed: [String] = []
        let savedPaused = paused
        paused = false
        defer { paused = savedPaused }
        if activeGlobe != .dns {
            focusGlobe(.dns)
            advanceForSnapshot(seconds: 1.4)
        }
        focusGlobe(.host)
        advanceForSnapshot(seconds: 0.92)
        if displayedGlobe != .host { failed.append("pan-handoff") }
        advanceForSnapshot(seconds: 0.95)
        if activeGlobe != .host { failed.append("pan-complete") }
        if camera.position.distance(to: .zero) < 8 { failed.append("pan-camera") }
        let rear = rearOffset()
        if rear.dot(camera.forward) <= 0 { failed.append("pan-background") }
        focusGlobe(.dns)
        advanceForSnapshot(seconds: 1.8)
        if activeGlobe != .dns { failed.append("pan-return") }
        return failed
    }

    func debugPickProbe() -> (destination: Bool, device: Bool) {
        guard let node = nodes.first(where: { $0.destinationRef.windowVisible && !$0.destroyed }),
              let device = devices.first(where: { $0.canPick() }) else { return (false, false) }
        let vp = SIMD2<Float>(Float(frameViewSize.width), Float(frameViewSize.height))
        let nodePoint = camera.project(node.basePosition, viewport: vp)
        let nodeHit = pick(at: CGPoint(x: CGFloat(nodePoint.x), y: CGFloat(nodePoint.y)),
                           viewSize: frameViewSize)
        let devicePoint = camera.project(device.visualCenter, viewport: vp)
        let deviceHit = pick(at: CGPoint(x: CGFloat(devicePoint.x), y: CGFloat(devicePoint.y)),
                             viewSize: frameViewSize)
        return (nodeHit?.destinationId == node.destinationRef.id,
                deviceHit?.deviceId == device.deviceRef.id)
    }

    func debugEffectSmoke() -> [String] {
        var failed: [String] = []
        for meta in Effects.impacts {
            debugPreviewEffect(kind: "impact", style: meta.id, destinationId: nil,
                               age: 1.0 / 60.0, viewSize: frameViewSize)
            if effects.entries.isEmpty { failed.append(meta.id) }
            effects.clear()
        }
        effects.clear()
        for meta in Effects.births {
            debugPreviewEffect(kind: "birth", style: meta.id, destinationId: nil,
                               age: 1.0 / 60.0, viewSize: frameViewSize)
            if effects.entries.isEmpty { failed.append(meta.id) }
            effects.clear()
        }
        for meta in Effects.deaths {
            debugPreviewEffect(kind: "death", style: meta.id, destinationId: nil,
                               age: 1.0 / 60.0, viewSize: frameViewSize)
            if effects.entries.isEmpty { failed.append(meta.id) }
            effects.clear()
        }
        for node in nodes {
            if node.destinationRef.windowVisible {
                node.destroyed = false
                node.setPresence(1)
                setWireVisibility(destinationId: node.destinationRef.id, visible: true)
            }
        }
        return failed
    }

    /// Code-level checks for the behaviours that are easy to regress in a
    /// hand port: the red-orb exclusivity rules, the recoil sign, the
    /// disappearance roll (D1/D2 must be reachable) and the camera paths used
    /// by the study controls. The snapshot tool prints any failures.
    func debugStudyChecks() -> [String] {
        var failed: [String] = []
        let visibleBlocked = nodes.first { $0.status == .blocked && $0.destinationRef.windowVisible }
        let anyBlocked = nodes.first { $0.status == .blocked }
        if let blocked = visibleBlocked ?? anyBlocked {
            let destination = blocked.destinationRef!
            if impactStyle(for: destination) != "containment" {
                failed.append("red-impact-not-shield")
            }
            if birthStyle(for: destination, override: "spiral") != "redaction" {
                failed.append("red-birth-not-redaction")
            }
            if let edge = destination.edges.max(by: { $0.liveQueries < $1.liveQueries }),
               let wire = wireByKey["\(edge.deviceId)::\(edge.destinationId)"],
               let blockedNode = nodeByDest[destination.id],
               let sourceView = deviceById[edge.deviceId] {
                // Shield contact is -inbound; it must face the source, not the
                // back of the destination.
                let sourceDir = (sourceView.position - blockedNode.basePosition).normalized
                if (-wire.tangent).dot(sourceDir) < 0.9 {
                    failed.append("shield-direction")
                }
            }
        } else {
            failed.append("red-orb-missing")
        }

        if let allowed = nodes.first(where: { $0.status == .allowed }) {
            let destination = allowed.destinationRef!
            if impactStyle(for: destination) == "containment" {
                failed.append("allowed-contains-shield")
            }
            if birthStyle(for: destination, override: "redaction") == "redaction" {
                failed.append("allowed-uses-redaction")
            }
        } else {
            failed.append("allowed-orb-missing")
        }

        var wireDirectionOK = true
        for wire in wires {
            let expected = (wire.nodeView.basePosition - wire.deviceView.position).normalized
            if wire.tangent.dot(expected) < 0.1 {
                wireDirectionOK = false
                break
            }
        }
        if !wireDirectionOK {
            failed.append("wire-tangent-inbound")
        }
        if let wire = wires.first, let curve = wire.curve,
           let last = curve.points.last,
           curve.point(1).distance(to: last) > 0.001 {
            failed.append("curve-endpoint")
        }

        if let node = nodes.first(where: { $0.status == .allowed }) {
            let inbound = Vec3(1, 0, 0)
            node.onHit(inbound, recoil: true)
            node.update(dt: 0.02, elapsed: elapsed)
            if node.recoilOffset.dot(inbound) <= 0.0001 {
                failed.append("recoil-not-forward")
            }
            // The visible assembly must take one impulse and settle. A
            // damped sine used to swing back through the anchor, which read
            // as a bounce rather than a blast.
            var minReturn: Float = .greatestFiniteMagnitude
            for _ in 0..<45 {
                node.update(dt: 1.0 / 60.0, elapsed: elapsed)
                minReturn = min(minReturn, node.recoilOffset.dot(inbound))
            }
            if minReturn < -0.0001 {
                failed.append("recoil-bounces")
            }
            node.stopRecoil()
        }

        // The blast plane is built from an orthonormal basis whose +Z is the
        // inbound tangent. The two in-plane axes must be perpendicular to it.
        let planeNormal = Vec3(0.32, 0.77, -0.55).normalized
        let probe = ShockRing(point: .zero, normal: planeNormal, radius: 0.3)
        if abs(probe.basisT.dot(planeNormal)) > 1e-4
            || abs(probe.basisB.dot(planeNormal)) > 1e-4 {
            failed.append("shock-plane-not-perpendicular")
        }

        let rolled = Set((0..<96).map { _ in randomDeathStyle() })
        for meta in Effects.deaths where !rolled.contains(meta.id) {
            failed.append("death-roll-missing-\(meta.id)")
        }

        let savedSpin = spinEnabled
        let savedTour = autoTour
        spinEnabled = false
        autoTour = false
        let before = camera.position
        orbitStep(yaw: 0.4)
        advanceForSnapshot(seconds: 0.5)
        if camera.position.distance(to: before) < 0.05 {
            failed.append("orbit-input")
        }
        let radiusBefore = (camera.position - orbitTarget).length
        zoomBy(0.8)
        advanceForSnapshot(seconds: 0.2)
        let radiusAfter = (camera.position - orbitTarget).length
        if radiusAfter >= radiusBefore - 0.02 {
            failed.append("zoom-input")
        }
        if radiusAfter >= radiusBefore - 0.02 {
            failed.append("zoom-input")
        }
        // Auto-orbit must move the camera on its own once the boot flight is
        // finished. This is the path the web's OrbitControls.autoRotate owns.
        let savedPaused = paused
        paused = false
        spinEnabled = true
        autoResumeAt = 0
        sphericalDelta = .zero
        let autoBefore = camera.position
        advanceForSnapshot(seconds: 1.0)
        if camera.position.distance(to: autoBefore) < 0.005 {
            failed.append("auto-orbit")
        }
        spinEnabled = savedSpin
        autoTour = savedTour
        paused = savedPaused

        // Bloom must not be attenuated at close inspection. Probe the same
        // render state at a close and a wide camera distance.
        let savedPosition = camera.position
        let savedTarget = orbitTarget
        let savedTrauma = trauma
        trauma = 0
        camera.position = Vec3(0, 0, 13)
        orbitTarget = Vec3(0, 0, 0)
        camera.target = orbitTarget
        settlePostForSnapshot()
        let closeBloom = makeRenderState(viewSize: frameViewSize)
        camera.position = Vec3(0, 0, 40)
        settlePostForSnapshot()
        let farBloom = makeRenderState(viewSize: frameViewSize)
        if abs(closeBloom.bloomStrength - farBloom.bloomStrength) > 0.0001
            || !closeBloom.bloomEnabled {
            failed.append("bloom-closeup")
        }
        camera.position = savedPosition
        orbitTarget = savedTarget
        camera.target = savedTarget
        trauma = savedTrauma
        settlePostForSnapshot()
        return failed
    }

    /// Code-level checks for right-drag lens panning and local aliases. The
    /// pan must move the projection without touching the orbit target, and
    /// auto-orbit must keep turning the globe around that same target while a
    /// pan is held. Aliases must replace the raw hostname/domain by default
    /// and restore the original address when "show both" is enabled.
    func debugInteractionChecks() -> [String] {
        var failed: [String] = []

        // Pan: the globe centre must move in the viewport, and picking must
        // still line up with the shifted projection.
        cameraFlight = nil
        let savedPosition = camera.position
        let savedPan = camera.pan
        let viewport = SIMD2<Float>(Float(frameViewSize.width), Float(frameViewSize.height))
        camera.pan = .zero
        let before = camera.project(Vec3(0, 0.15, 0), viewport: viewport)
        beginPan()
        pan(dx: 120, dy: 60, viewSize: frameViewSize)
        endPan()
        let moved = camera.project(Vec3(0, 0.15, 0), viewport: viewport)
        if abs(moved.x - before.x) < 8 || abs(moved.y - before.y) < 4 {
            failed.append("pan-input")
        }
        if moved.x <= before.x || moved.y >= before.y {
            failed.append("pan-direction")
        }
        let panProbe = debugPickProbe()
        if !panProbe.destination || !panProbe.device {
            failed.append("pan-pick-alignment")
        }
        beginPan()
        pan(dx: 5000, dy: 5000, viewSize: frameViewSize)
        endPan()
        if abs(camera.pan.x - Self.panLimit) > 0.0001
            || abs(camera.pan.y - Self.panLimit) > 0.0001 {
            failed.append("pan-clamp")
        }

        // Auto-orbit with a panned globe: the camera must move, the lens shift
        // must stay put, and the globe centre must hold its screen position.
        let savedSpin = spinEnabled
        let savedPaused = paused
        let savedAutoResume = autoResumeAt
        let heldPan = camera.pan
        let heldCenter = camera.project(Vec3(0, 0.15, 0), viewport: viewport)
        let spinBefore = camera.position
        spinEnabled = true
        paused = false
        autoResumeAt = 0
        sphericalDelta = .zero
        dragging = false
        advanceForSnapshot(seconds: 1.0)
        if camera.position.distance(to: spinBefore) < 0.005 {
            failed.append("pan-auto-orbit")
        }
        if simd_distance(camera.pan, heldPan) > 1e-5 {
            failed.append("pan-auto-orbit-moved-globe")
        }
        let centerAfter = camera.project(Vec3(0, 0.15, 0), viewport: viewport)
        if heldCenter.distance(to: centerAfter) > 0.5 {
            failed.append("pan-spin-off-axis")
        }
        spinEnabled = savedSpin
        paused = savedPaused
        autoResumeAt = savedAutoResume
        camera.position = savedPosition
        camera.pan = savedPan
        camera.target = orbitTarget
        sphericalDelta = .zero
        dragging = false
        panDragging = false

        // Alias display rules. A device alias replaces the title but never the
        // IP; a destination alias still follows the "show both" preference.
        let savedDeviceAliases = deviceAliases
        let savedDestinationAliases = destinationAliases
        let savedShowBoth = showAliasWithAddress
        if let device = network.devices.first(where: { $0.name != $0.ip }) {
            setShowAliasWithAddress(false)
            setDeviceAlias("Lab device", for: device)
            if deviceDisplayName(device) != "Lab device" {
                failed.append("device-alias-title")
            }
            if deviceAddressText(device) != device.ip {
                failed.append("device-alias-keeps-ip")
            }
            setShowAliasWithAddress(true)
            if deviceAddressText(device) != device.ip {
                failed.append("device-alias-keeps-ip-show-both")
            }
            setDeviceAlias("", for: device)
            if deviceAlias(device) != nil || deviceAddressText(device) != device.ip {
                failed.append("device-alias-clear")
            }
        } else {
            failed.append("device-alias-fixture")
        }
        if let destination = network.destinations.first {
            setShowAliasWithAddress(false)
            setDestinationAlias("Lab DNS", for: destination)
            if destinationDisplayName(destination) != "Lab DNS" {
                failed.append("destination-alias-title")
            }
            if destinationOriginalText(destination) != nil {
                failed.append("destination-alias-hides-original")
            }
            setShowAliasWithAddress(true)
            if destinationOriginalText(destination) != destination.domain {
                failed.append("destination-alias-show-both")
            }
            setDestinationAlias("", for: destination)
            if destinationAlias(destination) != nil {
                failed.append("destination-alias-clear")
            }
        } else {
            failed.append("destination-alias-fixture")
        }
        deviceAliases = savedDeviceAliases
        destinationAliases = savedDestinationAliases
        showAliasWithAddress = savedShowBoth
        AtlasPreferences.deviceAliases = savedDeviceAliases
        AtlasPreferences.destinationAliases = savedDestinationAliases
        AtlasPreferences.showAliasWithAddress = savedShowBoth
        aliasesDidChange()
        return failed
    }

    /// Code-level checks for the background-device flow: every shell body must
    /// be pickable, a hovered back-side device must publish its tag, and a
    /// focus flight must orbit the globe rather than cut through it.
    func debugFocusChecks() -> [String] {
        var failed: [String] = []
        clearSelection()
        resetCamera()
        advanceForSnapshot(seconds: 1.2)

        guard let back = devices.first(where: { $0.facing < -0.2 }) else {
            return ["no-background-device"]
        }
        let id = back.deviceRef.id
        if !back.canPick() { failed.append("background-device-not-pickable") }

        // A click on a back-side body's projected centre must address that
        // body even when a foreground orb's larger hit volume covers the ray.
        let viewport = SIMD2<Float>(Float(frameViewSize.width), Float(frameViewSize.height))
        var pickedBackground = false
        for device in devices where device.facing < -0.2 {
            let projected = camera.project(device.visualCenter, viewport: viewport)
            let hit = pick(at: CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)),
                           viewSize: frameViewSize)
            if hit?.deviceId == device.deviceRef.id {
                pickedBackground = true
                break
            }
        }
        if !pickedBackground { failed.append("background-device-pick") }

        let previousHover = hover
        setHovered(.device(id))
        if !labels.labels.contains(where: { $0.id == "dev-\(id)" }) {
            failed.append("background-device-hover-label")
        }
        setHovered(previousHover)

        let start = camera.position
        // Reproduce the two clicks of a double-click: the first selects, the
        // second must not toggle the selection off before the flight starts.
        select(.device(id))
        focus(on: .device(id))
        var minRadius = Float.greatestFiniteMagnitude
        for _ in 0..<80 {
            advanceForSnapshot(seconds: 1.0 / 60.0)
            minRadius = min(minRadius, (camera.position - orbitTarget).length)
        }
        if camera.position.distance(to: start) < 1 {
            failed.append("focus-did-not-move")
        }
        if minRadius < globeRadius * 1.2 {
            failed.append("focus-cut-through-globe")
        }
        if selection?.deviceId != id {
            failed.append("focus-lost-selection")
        }
        return failed
    }

    /// Code-level checks for the history-window contract. Both endpoints use
    /// the same lastSeen rule: an old device leaves the globe and its wires,
    /// and a fresh query brings it back. Destinations keep their existing rule.
    func debugWindowChecks() -> [String] {
        var failed: [String] = []
        let savedHours = windowHours
        let savedPaused = paused
        paused = true
        let now = Date().timeIntervalSince1970 * 1000

        if Format.ago(now - 86_400_000) != "1 day ago" { failed.append("relative-day") }
        if Format.ago(now - 3 * 86_400_000) != "3 days ago" { failed.append("relative-days") }

        guard let device = network.devices.first(where: { $0.lastSeen > 0 }),
              let view = deviceById[device.id] else {
            paused = savedPaused
            return ["no-device-for-window"]
        }
        let savedLastSeen = device.lastSeen

        windowHours = 1
        device.lastSeen = now - 2 * 86_400_000
        _ = applyWindow(animate: false, initial: false)
        if device.windowVisible { failed.append("device-window-hide") }
        if view.windowVisible { failed.append("device-view-hide") }
        if view.canPick() { failed.append("device-hidden-still-pickable") }
        if wires.contains(where: { $0.deviceView.deviceRef.id == device.id && !$0.hidden }) {
            failed.append("device-hidden-wires")
        }
        if !network.devices.contains(where: { $0.windowVisible }) {
            failed.append("device-window-hid-all")
        }

        // A live query from the hidden device must not pop it in. It first
        // draws a wire from the device's relative location; when the pulse
        // arrives the device appears with a random study.
        device.lastSeen = now
        let savedRuntimePaused = paused
        let savedArrivalSourcePaused = source.paused
        source.setPaused(true)
        paused = false
        clearSelection()
        if let edge = device.edges.first,
           let wire = wires.first(where: { $0.deviceView === view && $0.edgeId == edge.id }) {
            let event = QueryEvent(id: "window-arrival-probe", ts: now, device: device,
                                   destination: edge.destination, edge: edge, latency: nil)
            handleQuery(event)
            if !device.pendingAppearance { failed.append("device-arrival-not-pending") }
            if device.windowVisible { failed.append("device-arrival-visible-too-early") }
            if view.windowVisible { failed.append("device-arrival-view-visible-too-early") }
            if wire.reveal > 0.01 { failed.append("device-arrival-wire-not-empty") }
            advanceForSnapshot(seconds: 0.12)
            if !device.pendingAppearance { failed.append("device-arrival-ended-early") }
            if view.windowVisible { failed.append("device-arrival-view-too-early") }
            if wire.reveal <= 0.01 || wire.reveal >= 1 {
                failed.append("device-arrival-wire-progress")
            }
            advanceForSnapshot(seconds: 1.4)
            if device.pendingAppearance { failed.append("device-arrival-stuck") }
            if !device.windowVisible { failed.append("device-arrival-not-visible") }
            if !view.windowVisible { failed.append("device-arrival-view-not-visible") }
            if view.appearanceStyle == nil { failed.append("device-arrival-no-study") }
            if abs(wire.reveal - 1) > 0.01 { failed.append("device-arrival-wire-incomplete") }
            if !view.canPick() { failed.append("device-arrival-not-pickable") }
        } else {
            failed.append("device-arrival-no-edge")
        }
        paused = savedRuntimePaused
        source.setPaused(savedArrivalSourcePaused)

        if let recent = network.destinationById["edge-cdn"],
           let old = network.destinationById["quad9"] {
            windowHours = 1
            _ = applyWindow(animate: false, initial: false)
            if !recent.windowVisible { failed.append("destination-recent-hidden") }
            if old.windowVisible { failed.append("destination-old-visible") }
            windowHours = Windows.stops.last?.hours ?? 168
            _ = applyWindow(animate: false, initial: false)
            if !recent.windowVisible { failed.append("destination-week-hidden") }
            if old.windowVisible { failed.append("destination-old-week-visible") }
        }

        // The fade/scale path must ease rather than pop. Freeze source traffic
        // so a random query cannot pull the device back mid-animation.
        let savedSourcePaused = source.paused
        source.setPaused(true)
        paused = false
        windowHours = 1
        device.lastSeen = now - 2 * 86_400_000
        _ = applyWindow(animate: true, initial: false)
        let hideStart = view.windowPresence
        advanceForSnapshot(seconds: 0.08)
        let hideMid = view.windowPresence
        advanceForSnapshot(seconds: 1.2)
        let hideEnd = view.windowPresence
        if hideStart < 0.99 || hideMid <= 0.01 || hideMid >= 0.99 || hideEnd > 0.01 {
            failed.append("device-window-fade")
        }

        device.lastSeen = now
        _ = applyWindow(animate: true, initial: false)
        advanceForSnapshot(seconds: 0.08)
        let showMid = view.windowPresence
        advanceForSnapshot(seconds: 1.2)
        let showEnd = view.windowPresence
        if showMid <= 0.01 || showMid >= 0.99 || showEnd < 0.99 {
            failed.append("device-window-appear")
        }
        source.setPaused(savedSourcePaused)

        device.lastSeen = savedLastSeen
        windowHours = savedHours
        _ = applyWindow(animate: false, initial: false)
        paused = savedPaused
        return failed
    }

    /// Check the live population contract: All must admit every client and
    /// domain in the snapshot; the finite choices must keep the top-N bound.
    func debugLiveChecks() -> [String] {
        var failed: [String] = []
        let now = Date().timeIntervalSince1970 * 1000
        var rows: [PiHoleQueryRow] = []
        for i in 0..<60 {
            rows.append(PiHoleQueryRow(
                id: "window-row-\(i)",
                timestamp: now - Double(i) * 1_000,
                clientIP: "10.0.0.\(i % 40)",
                clientName: "client-\(i % 40)",
                domain: "domain\(i % 30).example",
                status: "allowed",
                blocked: false,
                latencyMs: 12,
                type: "A"
            ))
        }
        let snapshot = PiHoleSnapshot(rows: rows, endpoint: "test",
                                      windowSeconds: 21_600, truncated: false,
                                      fetchedAt: Date())
        do {
            let all = try LiveNetworkBuilder.make(snapshot: snapshot, seed: seed,
                                                  population: .all)
            if all.devices.count != 40 { failed.append("live-all-devices") }
            if all.destinations.count != 30 { failed.append("live-all-destinations") }

            let focused = try LiveNetworkBuilder.make(snapshot: snapshot, seed: seed,
                                                      population: .top25)
            if focused.devices.count != 25 {
                failed.append("live-focused-devices")
            }
            if focused.destinations.count != 25 {
                failed.append("live-focused-destinations")
            }
        } catch {
            failed.append("live-builder")
        }
        return failed
    }

    /// Snapshot / verification helper: enter replay, jump to a fraction of the
    /// range, and settle a few frames so the transport and field show motion.
    @discardableResult
    func debugReplay(hours: Float = 6, progress: Double = 0.55,
                     settle: Float = 0.35) -> (events: Int, buckets: Int) {
        enterReplay(hours: hours)
        if isReplay {
            seekReplay(fraction: progress, preRoll: true)
            if settle > 0 { advanceForSnapshot(seconds: settle) }
        }
        return (replayTotal, replayBuckets.count)
    }

    /// Check the time-travel contract end to end on the demo source: archive
    /// creation, seek, advancing, pause, loop and the return to live.
    func debugReplayChecks() -> [String] {
        var failed: [String] = []
        let savedPaused = paused
        paused = false
        enterReplay(hours: 1)
        if !isReplay { failed.append("replay-enter") }
        if replayTotal == 0 { failed.append("replay-empty") }
        if replayBuckets.isEmpty { failed.append("replay-buckets") }
        if replayBuckets.reduce(0, { $0 + $1.total }) == 0 { failed.append("replay-density") }
        if replayEnd <= replayStart { failed.append("replay-range") }
        if replaySourceLabel.isEmpty { failed.append("replay-label") }
        if replayRate != 60 { failed.append("replay-auto-rate") }

        seekReplay(fraction: 0.5, preRoll: true)
        if replayTime <= replayStart || replayTime >= replayEnd {
            failed.append("replay-seek")
        }
        let before = replayCursor
        setReplayRate(600)
        advanceForSnapshot(seconds: 0.3)
        if replayCursor <= before { failed.append("replay-advance") }

        setPaused(true)
        let pausedAt = replayCursor
        advanceForSnapshot(seconds: 0.3)
        if abs(replayCursor - pausedAt) > 0.01 { failed.append("replay-pause") }
        setPaused(false)

        seekReplay(fraction: 0.995, preRoll: false)
        advanceForSnapshot(seconds: 0.5)
        if !replayFinished { failed.append("replay-finish") }

        replayLoop = true
        advanceForSnapshot(seconds: 0.3)
        if replayFinished { failed.append("replay-loop") }
        replayLoop = false

        goLive()
        if isReplay { failed.append("replay-live") }
        paused = savedPaused
        return failed
    }

    func debugPreviewEffect(kind: String, style: String, destinationId: String?,
                            age: Float, viewSize: CGSize) {
        paused = false
        let destination = destinationId.flatMap { network.destinationById[$0] }
            ?? network.destinations.sorted { $0.liveQueries > $1.liveQueries }.first
        guard let destination, let node = nodeByDest[destination.id] else { return }
        selection = .destination(destination.id)
        effects.clear()
        node.destroyed = false
        node.stopRecoil()
        node.setPresence(1)
        setWireVisibility(destinationId: destination.id, visible: true)
        switch kind {
        case "birth":
            birthDestination(destination, style: style, forceStyle: true)
        case "death":
            retireDestination(destination, style: style)
        default:
            let meta = Effects.meta(impact: style)
            registerImpactPreview(node: node, meta: meta)
        }
        // Step only the scene; the demo source is driven by its own timer and
        // must stay out of deterministic study captures.
        var remaining = max(0, age)
        while remaining > 0.00001 {
            let dt = min(1.0 / 60.0, remaining)
            updateFrame(dt: dt, viewSize: viewSize)
            remaining -= dt
        }
        paused = true
        settlePostForSnapshot()
        rebuildDrawListForSnapshot()
        updateLabels(force: true)
    }

    /// Snapshot helper: frame one destination at study distance while keeping
    /// the current viewing direction. Used for births/deaths, which do not
    /// publish an inbound hit axis.
    func debugFrameDestination(_ id: String) {
        guard let node = nodeByDest[id] else { return }
        let direction = (camera.position - node.basePosition).normalized
        let distance = max(11.5, node.radius * 13)
        var position = node.basePosition + direction * distance
        position.y = max(1.1, position.y)
        setCameraForSnapshot(position: position, target: node.basePosition)
    }

    /// Snapshot helper: frame the last hit along its inbound axis so a plane
    /// reads as a circle. Mirrors `faceHitCamera` without starting a flight.
    func debugFrameLastImpact(fromHitSide: Bool = false, fromSide: Bool = false) {
        guard let record = lastImpact,
              let node = nodeByDest[record.destinationId] else { return }
        let point = node.basePosition
        let distance = max(11.5, node.radius * 13)
        var position: Vec3
        if fromSide {
            let side = record.normal.cross(.up).normalized
            position = point + side * distance
        } else {
            position = point + record.normal * (fromHitSide ? -distance : distance)
        }
        position.y = max(1.1, position.y)
        setCameraForSnapshot(position: position, target: point)
    }

    func setHovered(_ next: Selection?) {
        guard hover != next else { return }
        hover = next
        for node in nodes {
            node.setHovered(next?.destinationId == node.destinationRef.id)
        }
        for view in devices {
            view.setHovered(next?.deviceId == view.deviceRef.id)
        }
        updateLabels(force: true)
        applyVisualState()
    }

    func setFilter(_ filter: OutcomeFilter) {
        self.filter = filter
        filterOpen = false
        updateLabels(force: true)
        applyVisualState()
        refreshFeed()
    }

    func setLabelMode(_ mode: LabelMode) {
        labelMode = mode
        AtlasPreferences.labelMode = mode
        updateLabels(force: true)
    }

    func setMotionMode(_ mode: MotionMode) {
        motionMode = mode
        AtlasPreferences.motionMode = mode
    }

    func setSpin(_ enabled: Bool) {
        spinEnabled = enabled
        AtlasPreferences.autoOrbit = enabled
        autoResumeAt = 0
    }

    func setWindowDragSpinsGlobe(_ enabled: Bool) {
        windowDragSpinsGlobe = enabled
        AtlasPreferences.windowDragSpinsGlobe = enabled
        autoResumeAt = 0
    }

    /// The window's move notifications drive this. Auto-orbit holds still while
    /// the frame is being dragged unless the optional window-drag coupling is
    /// enabled. The settle delay coalesces per-step move notifications.
    func setWindowMoving(_ moving: Bool) {
        windowMoveSettle?.cancel()
        windowMoveSettle = nil
        if moving {
            windowMoving = true
            return
        }
        let work = DispatchWorkItem { [weak self] in
            self?.windowMoving = false
            self?.windowMoveSettle = nil
        }
        windowMoveSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func setShowHitGeometry(_ enabled: Bool) {
        showHitGeometry = enabled
        AtlasPreferences.hitPlane = enabled
        if enabled { hitGeometryReplayAt = elapsed }
        showToast(enabled ? "Hit plane overlay on" : "Hit plane overlay off",
                  tone: enabled ? .signal : .gold)
    }

    func setAutoTour(_ enabled: Bool) {
        guard enabled != autoTour else { return }
        if enabled {
            guard let destination = previewDestination() else {
                showToast("Select a destination first.", tone: .gold)
                return
            }
            tourDestinationId = destination.id
            tourClock = 0
            tourPhase = 0
            tourInterval = 0.05
            autoTour = true
            showToast("Auto tour engaged · \(destinationDisplayName(destination))", tone: .gold)
        } else {
            autoTour = false
            tourDestinationId = nil
            showToast("Auto tour stopped", tone: .signal)
        }
    }

    /// Port of the lab's auto tour: alternate one emergence and one impact on
    /// the same study destination. The camera is deliberately not moved, so
    /// the user can orbit/zoom while the loop runs.
    private func updateAutoTour(_ realDt: Float) {
        guard autoTour, !paused else { return }
        tourClock += realDt
        guard tourClock >= tourInterval else { return }
        tourClock = 0
        guard let id = tourDestinationId,
              let destination = network.destinationById[id],
              destination.windowVisible else {
            setAutoTour(false)
            return
        }
        tourPhase += 1
        if tourPhase % 2 == 1 {
            tourInterval = 3.35
            birthDestination(destination, style: destination.birthId)
            let meta = Effects.meta(birth: destination.birthId)
            showToast("Auto tour · \(meta.key) \(meta.name)", tone: .signal)
        } else {
            tourInterval = 4.3
            fireStudy(at: destination)
            let meta = Effects.meta(impact: destination.impactId)
            showToast("Auto tour · \(meta.key) \(meta.name)", tone: .gold)
        }
    }

    private func fireStudy(at destination: Destination) {
        guard let node = nodeByDest[destination.id], !node.destroyed else { return }
        let busiestEdge = destination.edges.max { $0.liveQueries < $1.liveQueries }
        let wire = busiestEdge.flatMap { wireByKey["\($0.deviceId)::\($0.destinationId)"] }
        let normal = (wire?.tangent ?? node.basePosition).normalized
        registerImpact(node: node, normal: normal, event: nil)
    }

    func setRecoil(_ enabled: Bool) {
        recoilEnabled = enabled
        AtlasPreferences.recoil = enabled
        if !enabled { nodes.forEach { $0.stopRecoil() } }
    }

    func setPaused(_ paused: Bool) {
        if isReplay, !paused, replayFinished {
            seekReplay(to: replayStart, preRoll: false)
        }
        self.paused = paused
        if !isReplay { source.setPaused(paused) }
        lastSourceTime = CACurrentMediaTime()
        refreshUI()
    }

    func setSpeed(_ speed: Float) {
        self.speed = clamp(speed, 0.25, 4)
        AtlasPreferences.speed = self.speed
        source.setSpeed(self.speed)
        refreshUI()
    }

    func setRate(_ rate: Float) {
        source.setRate(rate)
        refreshUI()
    }

    func flashDestinationLabel(_ id: String, duration: Double) {
        eventLabels[id] = Date().timeIntervalSince1970 + duration
        if labelMode == .events { updateLabels(force: true) }
    }

    private func expireEventLabels() {
        guard !eventLabels.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var changed = false
        for (id, until) in eventLabels where until <= now {
            eventLabels.removeValue(forKey: id)
            changed = true
        }
        if changed { updateLabels(force: true) }
    }

    func previewMotion(_ kind: String) {
        if autoTour { setAutoTour(false) }
        if paused { setPaused(false) }
        guard let destination = previewDestination(), let node = nodeByDest[destination.id] else {
            showToast("Select a destination first.", tone: .gold)
            return
        }
        switch kind {
        case "impact":
            let allowed = destination.status == .blocked
                ? [Effects.meta(impact: "containment")]
                : Effects.impacts.filter { $0.id != "containment" }
            let meta = allowed[previewIndex.impact % allowed.count]
            previewIndex.impact += 1
            registerImpactPreview(node: node, meta: meta)
            showToast("Impact preview · \(meta.key) \(meta.name)", tone: .gold)
        case "birth":
            let pool = destination.status == .blocked
                ? [Effects.meta(birth: "redaction")]
                : Effects.births.filter { $0.id != "redaction" }
            let meta = pool[previewIndex.birth % pool.count]
            previewIndex.birth += 1
            birthDestination(destination, style: meta.id)
            showToast("Emergence preview · \(meta.key) \(meta.name)", tone: .gold)
        case "death":
            let meta = Effects.deaths[previewIndex.death % Effects.deaths.count]
            previewIndex.death += 1
            retireDestination(destination, style: meta.id, restoreAfter: meta.duration + 1.25)
            showToast("Erasure preview · \(meta.key) \(meta.name)", tone: .coral)
        default: break
        }
    }

    private func registerImpactPreview(node: NodeView, meta: EffectMeta) {
        let destination = node.destinationRef!
        // Preview the same geometry an arriving packet uses: the plane normal
        // is the wire's arrival tangent, not the destination's radial normal.
        // Falling back to the radial only keeps random/debug previews safe when
        // no wire exists; it never replaces the real inbound vector.
        let busiestEdge = destination.edges.max { $0.liveQueries < $1.liveQueries }
        let previewWire = busiestEdge.flatMap {
            wireByKey["\($0.deviceId)::\($0.destinationId)"]
        }
        let normal = (previewWire?.tangent ?? node.basePosition).normalized
        node.onHit(normal, recoil: recoilEnabled && destination.status != .blocked)
        let R = max(0.26, node.radius * 1.9)
        var ctx = EffectContext(camera: camera, node: node, radius: R,
                                point: node.basePosition, normal: normal,
                                elapsed: elapsed, onShake: { [weak self] amount in
                                    self?.trauma = min(1, (self?.trauma ?? 0) + amount * 0.55)
                                }, rng: rng)
        ctx.offset = .zero
        let effect = Effects.impact(meta.id, ctx: ctx)
        effects.add(effect, node: node, origin: node.basePosition, kind: "impact")
        lastImpact = ImpactRecord(destinationId: destination.id, blocked: destination.status == .blocked,
                                  at: elapsed, normal: normal, point: node.basePosition,
                                  impactId: meta.id, impactName: "\(meta.key) · \(meta.name)")
        hitGeometryReplayAt = nil
        flashDestinationLabel(destination.id, duration: 1.7)
    }

    private func previewDestination() -> Destination? {
        if let selection, let id = selection.destinationId { return network.destinationById[id] }
        if let hover, let id = hover.destinationId { return network.destinationById[id] }
        if let selection, let deviceId = selection.deviceId,
           let device = network.deviceById[deviceId] {
            return device.edges.sorted { $0.liveQueries > $1.liveQueries }.first?.destination
        }
        return network.destinations.sorted { $0.liveQueries > $1.liveQueries }.first
    }

    private func relatedForSelection() -> (devices: Set<String>, destinations: Set<String>, edges: Set<String>) {
        var relatedDevices = Set<String>()
        var relatedDestinations = Set<String>()
        var relatedEdges = Set<String>()
        guard let selection else { return (relatedDevices, relatedDestinations, relatedEdges) }
        switch selection {
        case .device(let id):
            guard let device = network.deviceById[id] else { break }
            relatedDevices.insert(device.id)
            for edge in device.edges {
                relatedEdges.insert(edge.id)
                relatedDestinations.insert(edge.destinationId)
            }
        case .destination(let id):
            guard let destination = network.destinationById[id] else { break }
            relatedDestinations.insert(destination.id)
            for edge in destination.edges {
                relatedEdges.insert(edge.id)
                relatedDevices.insert(edge.deviceId)
            }
        case .path(let deviceId, let destinationId):
            relatedEdges.insert("\(deviceId)::\(destinationId)")
            relatedDevices.insert(deviceId)
            relatedDestinations.insert(destinationId)
        }
        return (relatedDevices, relatedDestinations, relatedEdges)
    }

    private func applyVisualState() {
        let related = relatedForSelection()
        let hasSelection = selection != nil
        for node in nodes {
            let destination = node.destinationRef!
            let matchesFilter = filter == .all || destination.status == filter.status
            let isRelated = !hasSelection || related.destinations.contains(destination.id)
            node.setDimmed(!matchesFilter || !isRelated)
            switch selection {
            case .destination(let id): node.setSelected(id == destination.id)
            case .path(_, let id): node.setSelected(id == destination.id)
            default: node.setSelected(false)
            }
        }
        for view in devices {
            let isRelated = !hasSelection || related.devices.contains(view.deviceRef.id)
            view.setDimmed(!isRelated)
            switch selection {
            case .device(let id): view.setSelected(id == view.deviceRef.id)
            case .path(let id, _): view.setSelected(id == view.deviceRef.id)
            default: view.setSelected(false)
            }
        }
        for wire in wires {
            let edge = wire.nodeView.destinationRef!
            let matchesFilter = filter == .all || edge.status == filter.status
            let isRelated = !hasSelection || related.edges.contains(wire.edgeId)
            let isSelected = hasSelection && related.edges.contains(wire.edgeId)
            var dim: Float = 1
            if !matchesFilter { dim = 0.06 }
            else if !isRelated { dim = 0.12 }
            wire.setDim(dim)
            var highlight: Float = isSelected ? 0.75 : 0
            if !isSelected, let hover, let id = hover.deviceId, id == wire.deviceView.deviceRef.id {
                highlight = 0.35
            }
            if let hoveredPath, hoveredPath.deviceId == wire.deviceView.deviceRef.id,
               hoveredPath.destinationId == wire.nodeView.destinationRef.id {
                highlight = 0.9
            }
            wire.setHighlight(highlight)
        }
        syncPathHalo()
    }

    private func syncPathHalo() {
        var edge: Edge?
        if let selection, case .path(let deviceId, let destinationId) = selection {
            edge = network.edges.first { $0.deviceId == deviceId && $0.destinationId == destinationId }
        } else if selection == nil, let hoveredPath {
            edge = network.edges.first {
                $0.deviceId == hoveredPath.deviceId && $0.destinationId == hoveredPath.destinationId
            }
        }
        guard let edge, let wire = wireByEdge[edge.id], let curve = wire.curve,
              let node = nodeByDest[edge.destinationId], !node.destroyed else {
            pathHalo = nil
            haloKey = nil
            return
        }
        if filter != .all && edge.destination.status != filter.status {
            pathHalo = nil
            haloKey = nil
            return
        }
        if haloKey == edge.id { return }
        haloKey = edge.id
        let blocked = edge.destination.status == .blocked
        let color = blocked ? Palette.coral : Palette.gold
        let tightColor = blocked ? SRGB(hex: "ffb6a3") : SRGB(hex: "fff1c9")
        let sampled = (0...96).map { curve.pointAt(Float($0) / 96) }
        let wideVerts = GeometryKit.tube(points: sampled, radius: 0.055, tubularSegments: 96, radialSegments: 6)
            .map { TriangleVertex(position: SIMD4($0, 1), color: rgba(color, 0.09)) }
        let tightVerts = GeometryKit.tube(points: sampled, radius: 0.016, tubularSegments: 96, radialSegments: 6)
            .map { TriangleVertex(position: SIMD4($0, 1), color: rgba(tightColor, 0.72)) }
        pathHalo = PathHalo(curve: curve, wide: wideVerts, tight: tightVerts, blocked: blocked)
    }

    private func updateHalo(_ dt: Float) {
        _ = dt
    }

    private func updateLocalTraces(_ dt: Float) {
        for i in localTraces.indices.reversed() {
            localTraces[i].age += dt
            if localTraces[i].age >= localTraces[i].duration { localTraces.remove(at: i) }
        }
        for i in ringTraces.indices.reversed() {
            ringTraces[i].age += dt
            if ringTraces[i].age >= ringTraces[i].duration { ringTraces.remove(at: i) }
        }
    }

    // ── labels ───────────────────────────────────────────────────────────

    private struct LabelEntry {
        let el: AtlasLabel
        let priority: Int
        let order: Float
    }

    /// Upper bounds for the dense label modes. The demo never reaches them;
    /// the live All field would otherwise measure text for every destination
    /// and try to lay out hundreds of blurred tags in one SwiftUI pass.
    private static let maxLabelCandidates = 64
    private static let maxFieldLabels = 24

    private func updateLabels(force: Bool) {
        _ = force
        guard dnsHasVisualData else {
            labels.labels = []
            return
        }
        var destSet = Set<String>()
        var deviceSet = Set<String>()
        if labelMode != .off {
            if let selection {
                switch selection {
                case .destination(let id): destSet.insert(id)
                case .device(let id): deviceSet.insert(id)
                case .path(let d, let dest): destSet.insert(dest); deviceSet.insert(d)
                }
            }
            if let hover {
                switch hover {
                case .destination(let id): destSet.insert(id)
                case .device(let id): deviceSet.insert(id)
                case .path(let d, let dest): destSet.insert(dest); deviceSet.insert(d)
                }
            }
            if labelMode == .events {
                let now = Date().timeIntervalSince1970
                for (id, until) in eventLabels where until > now { destSet.insert(id) }
            }
            if labelMode == .all {
                // Do not construct a label (or measure its text) for every orb
                // in a live All graph. Resolve the busiest visible candidates
                // only; the overlay then keeps the highest-priority visible
                // set (24 normally, 4 above 200 destinations). On the demo
                // this changes nothing (14 destinations).
                let candidates = nodes.compactMap { node -> (NodeView, Destination)? in
                    guard let destination = node.destinationRef, destination.windowVisible else { return nil }
                    guard filter == .all || destination.status == filter.status else { return nil }
                    return (node, destination)
                }.sorted { $0.1.liveQueries > $1.1.liveQueries }
                for (_, destination) in candidates.prefix(Self.maxLabelCandidates) {
                    destSet.insert(destination.id)
                }
                for view in devices.prefix(Self.maxLabelCandidates) {
                    deviceSet.insert(view.deviceRef.id)
                }
            }
        }
        for node in nodes {
            node.setLabelVisible(destSet.contains(node.destinationRef.id))
        }
        for view in devices {
            view.setLabelVisible(deviceSet.contains(view.deviceRef.id))
        }
        resolveLabels()
    }

    private func resolveLabels() {
        let timingStart = AtlasDiagnostics.enabled ? CACurrentMediaTime() : 0
        var entries: [LabelEntry] = []
        let focusDistance = camera.position.length - globeRadius * 0.7
        let labelScale = 1.6 * (0.35 + 0.65 * dofStrength)

        for node in nodes {
            let destination = node.destinationRef!
            let visible = node.labelWanted && node.presence > 0.12 && !node.dimmed
            if visible {
                let screen = camera.project(node.labelPosition, viewport: SIMD2(Float(frameViewSize.width), Float(frameViewSize.height)))
                let depth = camera.position.distance(to: node.basePosition)
                let far = clamp((depth - focusDistance) / max(0.001, globeRadius * 1.35), 0, 1)
                let blur = (node.selected || node.hovered) ? 0 : far * labelScale
                let text = node.labelStatOverride ?? (destination.status == .blocked
                    ? "\(Format.count(destination.liveBlocked)) blocked"
                    : "\(Format.count(destination.liveQueries)) q")
                let entry = destinationLabel(node: node, destination: destination,
                                             screen: screen, blur: CGFloat(blur), latency: text)
                var priority = 10
                if node.labelWanted { priority = 40 + (destination.status == .blocked ? 6 : 0) }
                if let selection, selection.destinationId == destination.id { priority = 120 }
                if let hover, hover.destinationId == destination.id { priority = 130 }
                entries.append(LabelEntry(el: entry, priority: priority, order: Float(destination.liveQueries)))
            }
        }
        for view in devices {
            let device = view.deviceRef!
            if view.labelVisible {
                let screen = camera.project(view.labelPosition, viewport: SIMD2(Float(frameViewSize.width), Float(frameViewSize.height)))
                let entry = deviceLabel(view: view, device: device, screen: screen)
                var priority = 5
                if view.labelWanted { priority = 35 }
                if device.thisMac { priority = 94 }
                if let selection, selection.deviceId == device.id { priority = 118 }
                if let hover, hover.deviceId == device.id { priority = 128 }
                entries.append(LabelEntry(el: entry, priority: priority, order: source.getQps(device.id)))
            }
        }
        entries.sort { $0.priority == $1.priority ? $0.order > $1.order : $0.priority > $1.priority }
        var placed: [CGRect] = []
        var labels: [AtlasLabel] = []
        let fieldLimit = nodes.count > 200 ? 4 : Self.maxFieldLabels
        for entry in entries {
            let label = entry.el
            guard label.anchor.x > -200, label.anchor.x < frameViewSize.width + 200,
                  label.anchor.y > -200, label.anchor.y < frameViewSize.height + 200 else { continue }
            let rect = labelRect(label)
            var collides = false
            for other in placed where rect.intersects(other) { collides = true; break }
            if collides && entry.priority < 100 { continue }
            if !collides { placed.append(rect.insetBy(dx: -4, dy: -3)) }
            labels.append(label)
            // `.all` on a live All graph can admit hundreds of tags. Rendering
            // them all stalls SwiftUI, and they are unreadable anyway; keep the
            // highest-priority visible set (selected/hover are sorted first).
            if labels.count >= fieldLimit { break }
        }
        labelsStoreUpdate(labels)
        if timingStart > 0 {
            recordLabelTiming(CACurrentMediaTime() - timingStart)
        }
    }

    private func recordLabelTiming(_ seconds: Double) {
        labelTimingSum += seconds
        labelTimingMax = max(labelTimingMax, seconds)
        labelTimingCount += 1
        guard labelTimingCount >= 120 else { return }
        let avg = labelTimingSum / Double(labelTimingCount) * 1000
        AtlasDiagnostics.log(String(format: "labels resolve count=%d avg=%.2fms max=%.2fms",
                                    self.labels.labels.count, avg, labelTimingMax * 1000))
        labelTimingSum = 0
        labelTimingMax = 0
        labelTimingCount = 0
    }

    private func labelsStoreUpdate(_ labels: [AtlasLabel]) {
        // The resolver runs every frame now; only wake SwiftUI when the label
        // set or an anchor actually moved (e.g. paused camera).
        if self.labels.labels != labels {
            self.labels.labels = labels
        }
    }

    private func labelRect(_ label: AtlasLabel) -> CGRect {
        CGRect(x: label.anchor.x - label.size.width / 2,
               y: label.anchor.y - label.size.height - 8,
               width: label.size.width, height: label.size.height)
    }

    private func destinationLabel(node: NodeView, destination: Destination,
                                  screen: SIMD3<Float>, blur: CGFloat, latency: String) -> AtlasLabel {
        let host = destinationDisplayName(destination)
        let original = destinationOriginalText(destination)
        let detail = original.map { "\($0) · \(latency)" } ?? latency
        let cacheKey = "d:\(destination.id):\(host):\(detail):\(destination.status.rawValue)"
        let size: CGSize
        if let cached = labelSizeCache[cacheKey] {
            size = cached
        } else {
            let hostFont = NSFont.monospacedSystemFont(ofSize: 8.2, weight: .regular)
            let keyFont = NSFont.monospacedSystemFont(ofSize: 5.6, weight: .regular)
            let subFont = NSFont.monospacedSystemFont(ofSize: 6.2, weight: .regular)
            let hostWidth = ceil((host as NSString).size(withAttributes: [.font: hostFont]).width)
            let keyWidth = max(16, ceil((destination.key as NSString).size(withAttributes: [.font: keyFont]).width) + 6)
            let chipWidth: CGFloat = destination.status == .blocked ? 38 : 0
            let tagWidth = 5 + keyWidth + 6 + hostWidth + (chipWidth > 0 ? 6 + chipWidth : 0) + 7
            let metaWidth = ceil((destination.status.rawValue as NSString).size(withAttributes: [.font: subFont]).width)
            let detailWidth = ceil((detail as NSString).size(withAttributes: [.font: subFont]).width)
            let width = max(tagWidth, metaWidth + 6 + 2 + 6 + detailWidth)
            size = CGSize(width: max(52, width), height: 40)
            if labelSizeCache.count > 2048 { labelSizeCache.removeAll(keepingCapacity: true) }
            labelSizeCache[cacheKey] = size
        }
        return AtlasLabel(
            id: "dest-\(destination.id)", kind: .destination,
            anchor: CGPoint(x: CGFloat(screen.x), y: CGFloat(screen.y)),
            key: destination.key, host: host,
            badge: destination.status == .blocked ? "blocked" : nil,
            meta: destination.status.rawValue, detail: detail,
            blocked: destination.status == .blocked,
            hovered: node.hovered, selected: node.selected, blur: blur, size: size,
            accessibilityLabel: "\(host), \(destination.domain), \(destination.status.rawValue), \(detail)"
        )
    }

    private func deviceLabel(view: DeviceView, device: Device, screen: SIMD3<Float>) -> AtlasLabel {
        let rate = Format.rate(source.getQps(device.id))
        let host = deviceDisplayName(device)
        let address = deviceAddressText(device)
        let detail = "\(address) · \(rate)/s"
        let cacheKey = "v:\(device.id):\(host):\(detail)"
        let size: CGSize
        if let cached = labelSizeCache[cacheKey] {
            size = cached
        } else {
            let hostFont = NSFont.monospacedSystemFont(ofSize: 8.2, weight: .regular)
            let subFont = NSFont.monospacedSystemFont(ofSize: 6.2, weight: .regular)
            let hostWidth = ceil((host as NSString).size(withAttributes: [.font: hostFont]).width)
            let tagWidth = 5 + 12 + 6 + hostWidth + (device.thisMac ? 6 + 35 : 0) + 7
            let metaWidth = ceil(("source" as NSString).size(withAttributes: [.font: subFont]).width)
            let detailWidth = ceil((detail as NSString).size(withAttributes: [.font: subFont]).width)
            let width = max(tagWidth, metaWidth + 6 + 2 + 6 + detailWidth)
            size = CGSize(width: max(56, width), height: 40)
            if labelSizeCache.count > 2048 { labelSizeCache.removeAll(keepingCapacity: true) }
            labelSizeCache[cacheKey] = size
        }
        return AtlasLabel(
            id: "dev-\(device.id)", kind: .device,
            anchor: CGPoint(x: CGFloat(screen.x), y: CGFloat(screen.y)),
            key: "", host: host,
            badge: device.thisMac ? "this mac" : nil,
            meta: "source", detail: detail,
            blocked: false, hovered: view.hovered, selected: view.selected, blur: 0, size: size,
            accessibilityLabel: "\(host), \(device.kind), \(device.name), \(detail)"
        )
    }

    // ── aliases ──────────────────────────────────────────────────────────

    /// Aliases are keyed by the stable facts Pi-hole gives us, not by the
    /// synthetic graph ids rebuilt on every refresh: device IP and destination
    /// domain. A local alias is display data only and never reaches Pi-hole.
    private func aliasKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func normalizedAlias(_ raw: String) -> String? {
        let trimmed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(64))
    }

    func deviceAlias(_ device: Device) -> String? {
        deviceAliases[aliasKey(device.ip)]
    }

    func destinationAlias(_ destination: Destination) -> String? {
        destinationAliases[aliasKey(destination.domain)]
    }

    /// The primary card title. A local alias takes over the title so cards
    /// present the name the user chose instead of Pi-hole's raw hostname.
    func deviceDisplayName(_ device: Device) -> String {
        deviceAlias(device) ?? device.name
    }

    /// The address line under a device's title. An alias only replaces the
    /// name; the IP is the device's identity and stays visible everywhere so a
    /// renamed client can still be recognized. This is independent of the
    /// destination-only "show both" preference.
    func deviceAddressText(_ device: Device) -> String {
        device.ip
    }

    func destinationDisplayName(_ destination: Destination) -> String {
        destinationAlias(destination) ?? destination.domain
    }

    /// The original domain beside an alias. Nil when the destination has no
    /// alias (the primary title is already the domain) or when the user asked
    /// for alias-only cards.
    func destinationOriginalText(_ destination: Destination) -> String? {
        guard destinationAlias(destination) != nil else { return nil }
        return showAliasWithAddress ? destination.domain : nil
    }

    func setDeviceAlias(_ raw: String, for device: Device) {
        var next = deviceAliases
        let key = aliasKey(device.ip)
        if let value = normalizedAlias(raw) {
            next[key] = value
        } else {
            next.removeValue(forKey: key)
        }
        guard next != deviceAliases else { return }
        deviceAliases = next
        AtlasPreferences.deviceAliases = next
        aliasesDidChange()
    }

    func setDestinationAlias(_ raw: String, for destination: Destination) {
        var next = destinationAliases
        let key = aliasKey(destination.domain)
        if let value = normalizedAlias(raw) {
            next[key] = value
        } else {
            next.removeValue(forKey: key)
        }
        guard next != destinationAliases else { return }
        destinationAliases = next
        AtlasPreferences.destinationAliases = next
        aliasesDidChange()
    }

    func setShowAliasWithAddress(_ enabled: Bool) {
        guard showAliasWithAddress != enabled else { return }
        showAliasWithAddress = enabled
        AtlasPreferences.showAliasWithAddress = enabled
        aliasesDidChange()
    }

    private func aliasesDidChange() {
        labelSizeCache.removeAll(keepingCapacity: true)
        updateLabels(force: true)
        if rightRailOpen { refreshFeed() }
    }

    // ── picking ──────────────────────────────────────────────────────────

    func pick(at point: CGPoint, viewSize: CGSize) -> Selection? {
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }
        let ndc = SIMD2<Float>(Float(point.x / viewSize.width) * 2 - 1,
                               -(Float(point.y / viewSize.height) * 2 - 1))
        let ray = camera.rayDirection(ndc: ndc)
        var candidates: [(selection: Selection, center: Vec3, distance: Float)] = []
        for node in nodes where node.canPick() {
            let center = node.basePosition
            let radius = node.radius * 2.1
            if let t = raySphere(origin: camera.position, direction: ray, center: center, radius: radius) {
                candidates.append((.destination(node.destinationRef.id), center, t))
            }
        }
        for view in devices where view.canPick() {
            let center = view.visualCenter
            if let t = raySphere(origin: camera.position, direction: ray, center: center, radius: 0.9) {
                candidates.append((.device(view.deviceRef.id), center, t))
            }
        }
        guard !candidates.isEmpty else { return nil }

        // Hit volumes deliberately overreach the drawn bodies so small orbs
        // stay easy to catch, which makes ray order a poor tie-breaker: a
        // foreground body can swallow a click aimed at a background one. Rank
        // by screen distance to each projected centre instead, and use ray
        // distance only for near-exact ties. This is what makes an out-of-
        // focus device on the far shell directly addressable.
        let viewport = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
        var best: (selection: Selection, screenDistance: Float, distance: Float)?
        for candidate in candidates {
            let projected = camera.project(candidate.center, viewport: viewport)
            let dx = projected.x - Float(point.x)
            let dy = projected.y - Float(point.y)
            let screenDistance = (dx * dx + dy * dy).squareRoot()
            if best == nil
                || screenDistance < best!.screenDistance - 1.5
                || (abs(screenDistance - best!.screenDistance) <= 1.5
                    && candidate.distance < best!.distance) {
                best = (candidate.selection, screenDistance, candidate.distance)
            }
        }
        return best?.selection
    }

    private func raySphere(origin: Vec3, direction: Vec3, center: Vec3, radius: Float) -> Float? {
        let oc = origin - center
        let b = oc.dot(direction)
        let c = oc.dot(oc) - radius * radius
        let disc = b * b - c
        guard disc > 0 else { return nil }
        let sqrtD = sqrt(disc)
        let t1 = -b - sqrtD
        let t2 = -b + sqrtD
        if t1 > 0.001 { return t1 }
        if t2 > 0.001 { return t2 }
        return nil
    }

    // ── camera controls ──────────────────────────────────────────────────

    func computeFitDistance(width: CGFloat, height: CGFloat) -> Float {
        AtlasRuntime.computeFitDistance(width: width, height: height,
                                        globeRadius: max(globeRadius, targetGlobeRadius()))
    }

    static func computeFitDistance(width: CGFloat, height: CGFloat,
                                   globeRadius: Float = 6) -> Float {
        let metrics = Metrics(width: width, height: height)
        let left = metrics.railLeftWidth
        let right = metrics.railRightWidth
        let free = max(320, width - left - right - 80)
        let desired = min(free * 0.70, height * 0.55)
        let diameter = max(330, min(720, desired))
        let tanFov = tan(35 * Float.pi / 360)
        return globeRadius * Float(height) / max(0.001, Float(diameter) * tanFov)
    }

    private func currentFitDistance() -> Float {
        computeFitDistance(width: frameViewSize.width, height: frameViewSize.height)
    }

    private var minOrbitRadius: Float {
        max(11.5, globeRadius * 1.12)
    }

    private var maxOrbitRadius: Float {
        max(42, currentFitDistance() * 2.2)
    }

    /// Keep the projection and the orbit clamp in step with the computed
    /// globe size. A 13-unit test globe and a 1000-orb live globe need very
    /// different far planes and zoom-out bounds.
    private func updateCameraLimits() {
        let maxRadius = maxOrbitRadius
        let far = max(220, maxRadius * 2.2 + globeRadius * 3)
        if abs(camera.far - far) > 0.5 { camera.far = far }
    }

    private func applyFraming() {
        guard cameraFlight == nil else { return }
        fitDistance = currentFitDistance()
        let direction = (camera.position - orbitTarget).normalized
        camera.position = orbitTarget + direction * fitDistance
        camera.target = orbitTarget
        camera.pan = clampedPan(camera.pan)
        camera.aspect = Float(frameViewSize.width / max(1, frameViewSize.height))
        lastFramingTarget = targetGlobeRadius()
        updateCameraLimits()
    }

    func orbit(dx: CGFloat, dy: CGFloat, viewSize: CGSize) {
        guard cameraFlight == nil, !panDragging else { return }
        guard !windowMoving || windowDragSpinsGlobe else { return }
        cameraDragging = true
        dragging = true
        let h = max(1, Float(viewSize.height))
        sphericalDelta.x -= TAU * Float(dx) / h * 0.52
        sphericalDelta.y -= TAU * Float(dy) / h * 0.52
        autoResumeAt = CACurrentMediaTime() + 6
        lastInteraction = CACurrentMediaTime()
    }

    // ── pan (right-drag) ──────────────────────────────────────────────────

    /// The globe's lens shift is clamped so it can be moved freely around the
    /// viewport but never entirely out of view. NDC ±1 is the viewport edge;
    /// ±0.6 keeps a usable part of the globe on screen on both axes.
    private static let panLimit: Float = 0.6

    private func clampedPan(_ value: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(clamp(value.x, -Self.panLimit, Self.panLimit),
              clamp(value.y, -Self.panLimit, Self.panLimit))
    }

    func beginPan() {
        guard cameraFlight == nil else { return }
        panDragging = true
        lastInteraction = CACurrentMediaTime()
    }

    /// Right-drag translates the globe on screen. It is deliberately a lens
    /// shift rather than a camera pan: the camera keeps orbiting the same
    /// look target, so an enabled auto-orbit still spins the globe on its own
    /// axis instead of swinging it around the moved target.
    func pan(dx: CGFloat, dy: CGFloat, viewSize: CGSize) {
        guard cameraFlight == nil, panDragging else { return }
        let w = max(1, Float(viewSize.width))
        let h = max(1, Float(viewSize.height))
        camera.pan.x += Float(dx) * 2 / w
        camera.pan.y += Float(dy) * 2 / h
        camera.pan = clampedPan(camera.pan)
        lastInteraction = CACurrentMediaTime()
    }

    func endPan() {
        panDragging = false
    }

    func endDrag() {
        dragging = false
        cameraDragging = false
        autoResumeAt = CACurrentMediaTime() + 6
    }

    func zoom(_ amount: CGFloat, viewSize: CGSize) {
        guard cameraFlight == nil else { return }
        let steps = max(-60, min(60, Float(amount)))
        let factor = exp(-steps * 0.012)
        orbitScale *= min(1.35, max(0.74, factor))
        userZoomed = true
        autoResumeAt = CACurrentMediaTime() + 6
    }

    /// Explicit zoom for the study controls and keyboard shortcuts. Unlike the
    /// wheel path this is a single finished step, so the camera HUD can show a
    /// deterministic -/+ action while the live update consumes `orbitScale`.
    func zoomBy(_ factor: Float) {
        guard cameraFlight == nil else { return }
        orbitScale *= clamp(factor, 0.5, 2.0)
        userZoomed = true
        autoResumeAt = CACurrentMediaTime() + 6
    }

    /// One click of the orbit controls. The damping tail integrates the
    /// injected delta to exactly this yaw/pitch, matching a drag of the same
    /// arc without requiring a gesture.
    func orbitStep(yaw: Float, pitch: Float = 0) {
        guard cameraFlight == nil else { return }
        sphericalDelta.x -= yaw
        sphericalDelta.y -= pitch
        autoResumeAt = CACurrentMediaTime() + 6
        lastInteraction = CACurrentMediaTime()
    }

    /// The lab's Face hit: put the camera on the last inbound axis so the
    /// perpendicular blast plane reads as a circle instead of an ellipse.
    func faceHitCamera() {
        guard let record = lastImpact, let node = nodeByDest[record.destinationId] else {
            showToast("Fire once to establish a hit plane", tone: .gold)
            return
        }
        let point = node.basePosition
        let distance = max(11.5, node.radius * 13)
        var position = point + record.normal * distance
        position.y = max(1.1, position.y)
        userZoomed = true
        flyTo(position: position, target: point, duration: 1.0)
        showToast("Face hit · blast plane face-on", tone: .signal)
    }

    func flyTo(position: Vec3, target: Vec3, duration: Float, delay: Float = 0, arc: Bool = false) {
        if delay > 0 {
            pendingFlight = (position, target, duration, arc)
            flightDelayRemaining = delay
            return
        }
        startFlight(from: camera.position, to: position, target: target,
                    duration: duration, arc: arc)
    }

    private func startFlight(from: Vec3, to: Vec3, target: Vec3, duration: Float,
                             arc: Bool = false) {
        guard duration > 0 else {
            camera.position = to
            orbitTarget = target
            camera.target = target
            camera.pan = .zero
            panDragging = false
            return
        }
        let fromOffset = from - orbitTarget
        let toOffset = to - target
        let fromLength = fromOffset.length
        let toLength = toOffset.length
        let fromDir = fromLength > 1e-6 ? fromOffset / fromLength : Vec3.forward
        let toDir = toLength > 1e-6 ? toOffset / toLength : Vec3.forward
        cameraFlight = CameraFlight(
            t: 0,
            duration: duration,
            fromPos: from,
            toPos: to,
            fromTarget: orbitTarget,
            toTarget: target,
            arc: arc,
            fromRadius: max(0.001, fromLength),
            toRadius: max(0.001, toLength),
            fromDir: fromDir,
            toDir: toDir,
            rotation: Quat(from: fromDir, to: toDir),
            fromPan: camera.pan,
            toPan: .zero
        )
        cameraDragging = false
        dragging = false
        panDragging = false
    }

    /// The single action behind a double-click or an explicit "focus" button.
    /// The first click of a pair has already selected the body; selecting it
    /// again with the default toggle would deselect it, which made the camera
    /// do nothing. Focus always selects without toggling, then flies.
    func focus(on next: Selection) {
        select(next, toggle: false)
        autoResumeAt = CACurrentMediaTime() + 6
        lastInteraction = CACurrentMediaTime()
        focusSelection()
    }

    func focusSelection() {
        guard let selection else { return }
        let fit = currentFitDistance()
        var position: Vec3?
        switch selection {
        case .device(let id):
            guard let view = deviceById[id] else { return }
            guard view.deviceRef.windowVisible else {
                showToast("Outside the history window", tone: .signal)
                return
            }
            position = view.normal * (fit * 0.84) + Vec3(0, 0.8, 0)
        case .destination(let id):
            guard let node = nodeByDest[id] else { return }
            guard node.destinationRef.windowVisible else {
                showToast("Outside the history window", tone: .signal)
                return
            }
            position = node.basePosition.normalized * (fit * 0.68)
        case .path(let id, let destinationId):
            guard let view = deviceById[id] else { return }
            guard view.deviceRef.windowVisible,
                  nodeByDest[destinationId]?.destinationRef.windowVisible == true else {
                showToast("Outside the history window", tone: .signal)
                return
            }
            position = view.normal * (fit * 0.8)
        }
        guard let position else { return }
        // Focus is a rotation around the globe, never a straight dive through
        // it, so a body on the far shell spins into view.
        flyTo(position: position, target: Vec3(0, 0.15, 0),
              duration: 1.15, arc: true)
    }

    func resetCamera() {
        userZoomed = false
        camera.up = .up
        let center = Vec3(0, 0.15, 0)
        let fit = currentFitDistance()
        updateCameraLimits()
        let dir = Vec3(13.2, 9.1, 26.4).normalized
        flyTo(position: center + dir * fit, target: center, duration: 1.0)
    }

    func topCamera() {
        userZoomed = false
        camera.up = .up
        let center = Vec3(0, 0.15, 0)
        let fit = currentFitDistance()
        updateCameraLimits()
        flyTo(position: Vec3(0.01, fit * 1.08, fit * 0.035), target: center, duration: 1.1)
    }

    var orbitAutoPaused: Bool { spinEnabled }

    // ── pulse ────────────────────────────────────────────────────────────

    private var pulseHistory: [PulseBucket] = []
    private var currentPulse = PulseBucket()
    private var seededBuckets: [PulseBucket] = []
    private var pulseReady = false

    private func buildPulseIfNeeded() {
        guard !pulseReady else { return }
        pulseReady = true
        var rng = RNG(0x51a7e)
        var seeded: [PulseBucket] = []
        for i in 0..<90 {
            let wave = 1.2 + sin(Float(i) * 0.26) * 0.9 + cos(Float(i) * 0.11 + 1.2) * 0.55
            let allowed = max(0, Int((wave + rng.next() * 1.6).rounded()))
            let blocked = rng.next() < 0.17 ? 1 + Int((rng.next() * 1.1).rounded()) : 0
            seeded.append(PulseBucket(allowed: allowed, blocked: blocked))
        }
        seededBuckets = seeded
        pulseHistory = Array(seeded.prefix(89))
        currentPulse = seeded[89]
        pulseScaleMax = max(1, seeded.map(\.total).max() ?? 1)
        publishPulse()
    }

    private func bumpPulse(_ event: QueryEvent) {
        buildPulseIfNeeded()
        if event.status == .blocked { currentPulse.blocked += 1 }
        else { currentPulse.allowed += 1 }
        publishPulse()
    }

    private func commitPulseSecond() {
        buildPulseIfNeeded()
        pulseHistory.append(currentPulse)
        if pulseHistory.count >= 90 { pulseHistory.removeFirst(pulseHistory.count - 89) }
        currentPulse = PulseBucket()
        // Keep the published sequence at 90 buckets: 89 history + current.
        publishPulse()
    }

    private func publishPulse() {
        var buckets = pulseHistory
        buckets.append(currentPulse)
        if buckets.count > 90 { buckets = Array(buckets.suffix(90)) }
        // Assigning a @Published property invalidates every observer even when
        // the value is identical. refreshUI runs 2.5x/s, so compare first and
        // only wake SwiftUI when the 90-second readout actually moved.
        if pulse != buckets { pulse = buckets }
        if pulseCurrent != currentPulse { pulseCurrent = currentPulse }
        let total = buckets.reduce(0) { $0 + $1.total }
        if pulseTotal != total { pulseTotal = total }
        let scale = max(1, buckets.map(\.total).max() ?? 1)
        if pulseScaleMax != scale { pulseScaleMax = scale }
    }

    // ── UI refresh ───────────────────────────────────────────────────────

    private func refreshUI() {
        if isReplay && replayCursor != replayLastPublished {
            replayLastPublished = replayCursor
            replayTime = replayCursor
        }
        let nextTotals = network.totals
        if nextTotals != totals { totals = nextTotals }
        let nextWindowStats = network.windowStats()
        if nextWindowStats != windowStats { windowStats = nextWindowStats }
        let nextQps: Float
        if isReplay, let archive = replayArchive, archive.bucketSeconds > 0 {
            let fraction = (replayTime - archive.start) / archive.duration
            let index = min(archive.buckets.count - 1,
                            max(0, Int(fraction * Double(archive.buckets.count))))
            // A single bucket can legitimately be empty between bursts. A
            // short rolling window keeps the inspector readable while still
            // describing the archive rather than the live stream.
            let low = max(0, index - 2)
            let high = min(archive.buckets.count - 1, index + 2)
            var total = 0
            for i in low...high { total += archive.buckets[i].total }
            let span = archive.bucketSeconds * Double(high - low + 1)
            nextQps = span > 0 ? Float(total) / Float(span) : 0
        } else {
            nextQps = source.getQps()
        }
        if abs(nextQps - qps) > 0.01 { qps = nextQps }
        let nextClock = isReplay ? Format.clock(replayTime) : Format.clock()
        if nextClock != clock { clock = nextClock }
        let nextFeedCount = source.recent.count
        if nextFeedCount != feedCount { feedCount = nextFeedCount }
        let nextMotion: String
        if isReplay {
            if replayFinished {
                nextMotion = "replay complete"
            } else if paused {
                nextMotion = "replay paused"
            } else {
                nextMotion = "replay · \(Format.rate(replayRate))×"
            }
        } else {
            nextMotion = paused ? "paused" : (speed == 1 ? "streaming" : "streaming · \(Format.rate(speed))×")
        }
        if nextMotion != motionStateText { motionStateText = nextMotion }
        let nextAgo = isReplay ? "at \(Format.clock(replayTime))"
            : (source.recent.first.map { Format.ago($0.ts) } ?? "observing now")
        if nextAgo != lastEventAgo { lastEventAgo = nextAgo }
        buildPulseIfNeeded()
        publishPulse()
        if rightRailOpen { refreshFeed() }
        if let record = lastImpact,
           let node = nodeByDest[record.destinationId] {
            let telemetry = StudyTelemetry(
                host: destinationDisplayName(node.destinationRef),
                inbound: record.normal,
                axis: record.normal,
                centre: record.point,
                faceAngle: angleToView(record.normal, camera),
                blocked: record.blocked,
                impactName: record.impactName
            )
            if telemetry != studyTelemetry { studyTelemetry = telemetry }
        } else if studyTelemetry != nil {
            studyTelemetry = nil
        }
        if selection != nil { inspectorRevision += 1 }
    }

    private func refreshFeed() {
        var rows: [FeedRow] = []
        let events = isReplay ? replayRecent : source.recent
        for event in events {
            guard event.destination.windowVisible else { continue }
            if filter != .all && event.status != filter.status { continue }
            rows.append(FeedRow(
                id: event.id,
                deviceId: event.deviceId,
                destinationId: event.destinationId,
                deviceName: deviceDisplayName(event.device),
                domain: destinationDisplayName(event.destination),
                clock: Format.clock(event.ts),
                status: event.status,
                latency: event.latency,
                ts: event.ts
            ))
            if rows.count >= 14 { break }
        }
        feed = rows
    }

    private func updateLiveStats() {
        for view in devices {
            view.deviceRef.qps = source.getQps(view.deviceRef.id)
        }
        for node in nodes {
            let destination = node.destinationRef!
            let text = destination.status == .blocked
                ? "\(Format.count(destination.liveBlocked)) blocked"
                : "\(Format.count(destination.liveQueries)) q"
            node.setLabelStat(text)
        }
    }

    // ── toasts ───────────────────────────────────────────────────────────

    func showToast(_ text: String, tone: ToastMessage.Tone = .gold) {
        let message = ToastMessage(text: text, tone: tone)
        toast = message
        toastToken += 1
        let token = toastToken
        after(2.8) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.toast = nil
        }
    }

    // ── inspector data ──────────────────────────────────────────────────

    func recentEvents(deviceId: String? = nil, destinationId: String? = nil) -> [QueryEvent] {
        (isReplay ? replayRecent : source.recent).filter { event in
            event.destination.windowVisible &&
            (deviceId == nil || event.deviceId == deviceId) &&
            (destinationId == nil || event.destinationId == destinationId)
        }
    }

    func selectedEntity() -> (device: Device?, destination: Destination?, edge: Edge?)? {
        guard let selection else { return nil }
        switch selection {
        case .device(let id): return (network.deviceById[id], nil, nil)
        case .destination(let id): return (nil, network.destinationById[id], nil)
        case .path(let deviceId, let destinationId):
            let edge = network.edges.first { $0.deviceId == deviceId && $0.destinationId == destinationId }
            return (network.deviceById[deviceId], network.destinationById[destinationId], edge)
        }
    }

    func windowVisibleDestinations() -> [Destination] {
        network.destinations.filter(\.windowVisible)
    }

    func windowVisibleDevices() -> [Device] {
        network.devices.filter(\.windowVisible)
    }

    var devicePresenceText: String {
        let total = network.devices.count
        let visible = windowVisibleDevices().count
        let name = total == 1 ? "device" : "devices"
        if visible == total { return "\(Format.compact(total)) \(name)" }
        return "\(Format.compact(visible))/\(Format.compact(total)) \(name)"
    }

    var isLiveSource: Bool { source.kind == "pihole" }
    var filterStatus: DNSStatus? { filter.status }
}

extension OutcomeFilter {
    var status: DNSStatus? {
        switch self {
        case .all: return nil
        case .allowed: return .allowed
        case .blocked: return .blocked
        }
    }
}

extension DNSStatus {
    var rawValueString: String { rawValue }
}

extension NodeView {
    func setLabelStat(_ text: String) {
        // The label is rebuilt from the destination on every label pass; this
        // keeps the stat text ready for that pass.
        labelStatOverride = text
    }
}
