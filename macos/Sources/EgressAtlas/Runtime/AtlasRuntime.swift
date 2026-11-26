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
    let size: CGSize
    let accessibilityLabel: String
    /// Which globe's palette the shared overlay paints with; DNS is the
    /// common case and needs no site-specific argument.
    var tone: GlobeKind = .dns
    /// Camera-relative front/back focus for the globe overlay.
    var opacity: Double = 1
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

/// A device's shell re-entry while the wire reveal catches up.
struct DeviceAppearanceLink {
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
    /// Owns the DNS scene graph, effects, clocks and per-frame draw list.
    /// Created in `init` after `super.init()` because the scene needs the
    /// runtime back-reference; the runtime owns it strongly.
    private var dns: DnsGlobeScene!
    /// Read forwarding for the probe, renderer and debug checks that inspect
    /// the DNS scene through the runtime.
    var nodes: [NodeView] { dns.nodes }
    var devices: [DeviceView] { dns.devices }
    var wires: [WireView] { dns.wires }
    private var timerToken = 0
    private var timers: [TimerEntry] = []

    // Simulation
    private(set) var camera: Camera
    var globeRadiusForRender: Float { dns.globeRadius }
    // Read and written by the scene's layout tick.
    var lastFramingTarget: Float = 6
    var elapsed: Float = 0
    private var realTime: Float = 0
    private var lastRenderTime = 0.0
    private var lastSourceTime = 0.0
    var frameViewSize = AtlasLayout.windowDefault
    private var didFrame = false
    private var windowClock: Float = 0
    private var statsClock: Float = 0
    private var labelResolveClock: Float = 0
    var dofStrength: Float = 1
    private var dragging = false
    private var windowMoving = false
    private var windowMoveSettle: DispatchWorkItem?
    private var started = false
    var ready = false
    private var lastInteraction: Double = 0
    private var sourceTimer: Timer?
    private var uiTimer: Timer?
    private var sourceRequestToken = 0
    private var liveSnapshot: PiHoleSnapshot?
    private var liveClient: PiHoleClient?
    private var activeSourcePassword: String?
    private var pulseTimer: Timer?
    private var lastPulseSecond = Int(Date().timeIntervalSince1970)
    private let replay = ReplayController()
    private var toasts: [ToastMessage] = []
    private var toastToken = 0

    // Orbit / camera
    var cameraFlight: CameraFlight?
    private var orbitTarget = Vec3(0, 0.15, 0)
    private var sphericalDelta = SIMD2<Float>(0, 0)
    private var orbitScale: Float = 1
    private var autoResumeAt: Double = 0
    var userZoomed = false
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
    @Published private(set) var hostAppAliases: [String: String]
    @Published private(set) var hostDestinationAliases: [String: String]
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
    /// True while the deterministic HOST sample is driving both the HOST
    /// globe and its chrome (demo source, not the live socket monitor).
    @Published private(set) var hostDemoActive = false
    /// UI-facing scope cache. The sampler queue can be busy inside nettop for
    /// hundreds of milliseconds, so views must never wait on it just to read
    /// a scope set.
    @Published private(set) var hostScopes: Set<HostScope> = [.internet, .lan, .vpn]
    let hostScene: HostGlobeScene
    private let host: HostInstrument
    /// Headless tools opt back into the offline demo graph; the shipping app
    /// shows an empty DNS globe until a live Pi-hole is connected.
    private let allowsDemoGeometry = !AtlasPreferences.persists
    private var demoPreview = false
    private var hostDemoTimer: Timer?
    private var latestLiveHostSnapshot: HostSnapshot?
    var dnsHasVisualData: Bool { isLiveSource || allowsDemoGeometry || demoPreview }
    private var deckTo: GlobeKind = .dns
    private var deckProgress: Float = 0
    private var deckDuration: Float = 1.45
    var deckActive = false
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
        host = HostInstrument()
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
        let restoredHostAppAliases = AtlasPreferences.hostAppAliases
        let restoredHostDestinationAliases = AtlasPreferences.hostDestinationAliases
        hostAppAliases = restoredHostAppAliases
        hostDestinationAliases = restoredHostDestinationAliases
        let restoredShowAliasWithAddress = AtlasPreferences.showAliasWithAddress ?? false
        showAliasWithAddress = restoredShowAliasWithAddress
        scene.setHostAliases(apps: restoredHostAppAliases,
                             destinations: restoredHostDestinationAliases,
                             showBoth: restoredShowAliasWithAddress)
        motionMode = AtlasPreferences.motionMode ?? (reducedMotion ? .calm : .cinematic)
        labelMode = AtlasPreferences.labelMode ?? .selected
        let restoredRecoil = AtlasPreferences.recoil ?? true
        recoilEnabled = restoredRecoil
        scene.setRecoilEnabled(restoredRecoil)
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
        dns = DnsGlobeScene(runtime: self)
        configureReplay()
        configureHostInstrument()
        dns.buildScene()
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
        hostDemoTimer?.invalidate()
        sourceTimer?.invalidate()
        uiTimer?.invalidate()
        pulseTimer?.invalidate()
        windowMoveSettle?.cancel()
    }

    // ── replay wiring ────────────────────────────────────────────────────

    /// The controller owns the engine; these closures are the only surface it
    /// has back into the scene/source/UI. Every one captures `self` weakly so
    /// the runtime → controller ownership stays acyclic.
    private func configureReplay() {
        replay.onPresentationChange = { [weak self] presentation in
            self?.applyReplayPresentation(presentation)
        }
        replay.attach(ReplayController.Services(
            nowMS: { Date().timeIntervalSince1970 * 1000 },
            isReady: { [weak self] in self?.ready ?? false },
            archiveSource: { [weak self] start, end in
                guard let self else { return .unavailable }
                if let live = self.source as? PiHoleSource {
                    return .pihole { try await live.loadReplay(from: start, until: end) }
                }
                if let demo = self.source as? LiveSource {
                    return .demo(demo.makeReplay(from: start, until: end))
                }
                return .unavailable
            },
            resolveEvent: { [weak self] event in
                guard let self,
                      let device = self.network.deviceById[event.deviceId],
                      let destination = self.network.destinationById[event.destinationId],
                      let edge = self.dns.edgeByKey["\(event.deviceId)::\(event.destinationId)"] else {
                    return nil
                }
                return QueryEvent(id: event.id, ts: event.ts, device: device,
                                  destination: destination, edge: edge, latency: event.latency)
            },
            playEvent: { [weak self] event in self?.handleQuery(event) },
            clearEffects: { [weak self] in self?.clearReplayEffects() },
            applyLiveWindow: { [weak self] in _ = self?.applyWindow(animate: false, initial: false) },
            isPaused: { [weak self] in self?.paused ?? false },
            setPausedFlag: { [weak self] value in self?.paused = value },
            resumePlayback: { [weak self] in self?.setPaused(false) },
            closeJump: { [weak self] in self?.replayJumpOpen = false },
            isLoopEnabled: { [weak self] in self?.replayLoop ?? false },
            setSourcePaused: { [weak self] value in self?.source.setPaused(value) },
            noteSourceResumed: { [weak self] in self?.lastSourceTime = CACurrentMediaTime() },
            refreshUI: { [weak self] in self?.refreshUI() },
            showToast: { [weak self] text, tone in self?.showToast(text, tone: tone) }
        ))
    }

    /// Copy the controller snapshot into the `@Published` replay fields SwiftUI
    /// already observes. Compare first so a cursor-only refresh does not
    /// invalidate the whole transport.
    private func applyReplayPresentation(_ presentation: ReplayPresentation) {
        if replayRangeHours != presentation.rangeHours { replayRangeHours = presentation.rangeHours }
        if replayStart != presentation.start { replayStart = presentation.start }
        if replayEnd != presentation.end { replayEnd = presentation.end }
        if replayTime != presentation.time { replayTime = presentation.time }
        if replayRate != presentation.rate { replayRate = presentation.rate }
        if replayBuckets != presentation.buckets { replayBuckets = presentation.buckets }
        if replayMaxBucket != presentation.maxBucket { replayMaxBucket = presentation.maxBucket }
        if replayTotal != presentation.total { replayTotal = presentation.total }
        if replayScanned != presentation.scanned { replayScanned = presentation.scanned }
        if replaySkipped != presentation.skipped { replaySkipped = presentation.skipped }
        if replaySampled != presentation.sampled { replaySampled = presentation.sampled }
        if replaySourceLabel != presentation.sourceLabel { replaySourceLabel = presentation.sourceLabel }
        if replayLoading != presentation.loading { replayLoading = presentation.loading }
        if replayFinished != presentation.finished { replayFinished = presentation.finished }
        let nextMode: AtlasMode = presentation.active ? .replay : .live
        if mode != nextMode { mode = nextMode }
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
        dns.reset()
        timers.removeAll()
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
        replayJumpOpen = false
        replay.reset()
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
        dns.buildScene()
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
                    self.stopHostDemo()
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
        startHostDemo()
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

    private func configureBoot() {
        let visible = network.destinations.filter(\.windowVisible)
        if reducedMotion {
            for destination in visible {
                dns.nodeByDest[destination.id]?.setPresence(1)
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
        lastFramingTarget = dns.targetGlobeRadius()
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

    var deckPresentation: GlobeDeckPresentation {
        GlobeDeckPresentation(activeGlobe: activeGlobe, deckActive: deckActive,
                              deckTo: deckTo, progress: deckProgress)
    }

    /// Bridge the instrument's main-queue callbacks into published state. The
    /// instrument owns monitoring; the runtime owns what the UI observes.
    private func configureHostInstrument() {
        host.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            self.latestLiveHostSnapshot = snapshot
            guard !self.hostDemoActive else { return }
            self.applyHostSnapshot(snapshot)
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

    func setHostScope(_ scope: HostScope, enabled: Bool) {
        var next = hostScopes
        if enabled { next.insert(scope) } else { next.remove(scope) }
        if next.isEmpty { next.insert(.internet) }
        guard next != hostScopes else { return }
        hostScopes = next
        host.setScopes(next)
    }

    func setHostScopes(_ scopes: Set<HostScope>) {
        let next = scopes.isEmpty ? [.internet] : scopes
        guard next != hostScopes else { return }
        hostScopes = next
        host.setScopes(next)
    }

    private func applyHostSnapshot(_ snapshot: HostSnapshot) {
        hostSnapshot = snapshot
        hostAvailable = snapshot.available
        hostNote = snapshot.note
        hostScene.apply(snapshot)
        inspectorRevision += 1
    }

    /// Demo mode fills the HOST globe with the same deterministic fixture
    /// used by headless review. The live monitor keeps sampling in the
    /// background; its snapshots are held until demo mode ends.
    private func startHostDemo() {
        hostDemoActive = true
        hostAvailable = true
        hostDomainStatus = nil
        hostNote = "Deterministic sample traffic"
        applyHostSnapshot(HostDemo.snapshot(includeLocal: false))
        hostDemoTimer?.invalidate()
        hostDemoTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.hostDemoActive, !self.hostPaused else { return }
            self.applyHostSnapshot(HostDemo.snapshot(includeLocal: false))
        }
    }

    private func stopHostDemo() {
        guard hostDemoActive else { return }
        hostDemoActive = false
        hostDemoTimer?.invalidate()
        hostDemoTimer = nil
        if let snapshot = latestLiveHostSnapshot {
            applyHostSnapshot(snapshot)
        } else {
            applyHostSnapshot(.empty)
        }
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
        let radius = CGFloat(dns.globeRadius * Float(viewSize.height)
            / (2 * tan(camera.fov * .pi / 360)) / max(0.001, depth))
        return (kind, CGPoint(x: CGFloat(center.x), y: CGFloat(center.y)), radius)
    }

    private func hitsInactiveGlobe(point: CGPoint, viewSize: CGSize) -> Bool {
        let viewport = SIMD2<Float>(Float(viewSize.width), Float(viewSize.height))
        let activeCenter = camera.project(.zero, viewport: viewport)
        let activeRadius = dns.globeRadius * Float(viewSize.height)
            / (2 * tan(camera.fov * .pi / 360)) / max(0.001, camera.position.length)
        let dActive = hypot(activeCenter.x - Float(point.x), activeCenter.y - Float(point.y))
        if dActive < activeRadius * 0.96 { return false }

        let offset = rearOffset()
        let center = camera.project(offset, viewport: viewport)
        let depth = camera.position.distance(to: offset)
        let radius = dns.globeRadius * Float(viewSize.height)
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
        // Orbit the camera 180° around the clicked globe's far side. The
        // active globe never moves, so it becomes the background instead of
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

    private func retargetSettingsTab(for kind: GlobeKind) {
        guard settingsOpen else { return }
        if kind == .host {
            if settingsTab == .source || settingsTab == .motion { settingsTab = .host }
        } else if settingsTab == .host {
            settingsTab = .source
        }
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
        // a clamped offset would pull the background forward instead of
        // letting the orbit pass behind the camera.
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
            retargetSettingsTab(for: deckTo)
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
        retargetSettingsTab(for: deckTo)
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
    func debugHostArrival(_ domainID: String) {
        _ = hostScene.debugTriggerArrival(domainID: domainID)
    }

    func debugHostRetire(_ domainID: String) {
        _ = hostScene.debugRetireDomain(domainID)
    }

    func debugHostStyle(_ id: String?) {
        hostScene.debugSetMotionStyle(id)
    }

    func debugHostAppImpact(_ appID: String) {
        _ = hostScene.debugTriggerAppImpact(appID: appID)
    }

    func debugHostRetireApp(_ appID: String) {
        _ = hostScene.debugRetireApp(appID)
    }

    func debugShowHostGlobe(includeLocal: Bool = false, prime: Bool = true) {
        let snapshot = HostDemo.snapshot(includeLocal: includeLocal)
        hostSnapshot = snapshot
        hostScene.apply(snapshot)
        if prime { hostScene.primeForSnapshot() }
        activeGlobe = .host
        displayedGlobe = .host
        deckActive = false
        selection = nil
        hostSelection = nil
        labels.labels = []
        retargetSettingsTab(for: .host)
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
        // Pause freezes the host field, not the camera. Passing zero keeps
        // birth/retirement studies and comets on their last frame until the
        // monitor resumes.
        hostScene.update(dt: hostPaused ? 0 : dt, camera: camera)
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

    // The engine lives in `ReplayController`. These entry points stay on the
    // runtime so the UI and tools keep their existing call sites.
    func enterReplay(hours: Float = ReplayRange.defaultChoice.hours, at anchorMS: Double? = nil) {
        replay.enterReplay(hours: hours, at: anchorMS)
    }

    func goLive() {
        replay.goLive()
    }

    func setReplayRate(_ rate: Float) {
        replay.setRate(rate)
    }

    func setReplayRange(_ range: ReplayRange) {
        replay.setRange(range)
    }

    func seekReplay(to timeMS: Double, preRoll: Bool = true) {
        replay.seekReplay(to: timeMS, preRoll: preRoll)
    }

    func seekReplay(fraction: Double, preRoll: Bool = false) {
        replay.seekReplay(fraction: fraction, preRoll: preRoll)
    }


    private func clearReplayEffects() {
        dns.clearReplayEffects()
    }

    // ── timers ───────────────────────────────────────────────────────────

    func after(_ seconds: Float, _ action: @escaping () -> Void) {
        timers.append(TimerEntry(remaining: seconds, action: action, token: timerToken))
    }

    func clearTimers() {
        timers.removeAll()
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
        dns.trauma = max(0, dns.trauma - dt * 1.8)
        advanceDeck(dt: paused ? 0 : dt)
        updateCamera(dt)
        // The inactive DNS instrument is frozen: its layout, effects and
        // labels are expensive and invisible at background LOD. It resumes
        // exactly where it left off when it becomes active again.
        let dnsLive = activeGlobe == .dns && !deckActive
        if dnsLive {
            dns.updateLayout(realDt: dt)
            dns.updateDevices(dt)
            dns.updateNodes(dt)
            dns.updateWires(dt)
            replay.advance(dt: dt)
            dns.updateHalo(dt)
            dns.updateLocalTraces(dt)
            for i in dns.signals.indices.reversed() {
                if !dns.signals[i].update(dt: simDt) {
                    dns.signals.remove(at: i)
                }
            }
            dns.updateDeviceAppearances(simDt)
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
            dns.expireEventLabels()
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

        dns.buildDrawList(simDt: simDt)
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

    func makeRenderState(viewSize: CGSize) -> RenderState {
        let focusDistance = max(0.001, camera.position.length)
        // The 1.5× calibration keeps the bloom envelope stable through close
        // inspection. DOF eases close-up; bloom does not.
        let hostMode = displayedGlobe == .host
        let densityScale = min(1, 24.0 / Float(max(1, nodes.count)))
        let bloomStrength = (0.4 + dns.trauma * 0.32) * 1.5 * (hostMode ? 0.18 : densityScale)
        let bloomRadius: Float = 0.5
        var shake = Vec3.zero
        if motionMode != .off {
            let amount = dns.trauma * dns.trauma * 0.38
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

        var dnsLayer = RenderLayer(drawList: dns.dot, offset: .zero,
                                   stageScale: dns.stageScale, detail: dnsDetail)
        var hostLayer = RenderLayer(drawList: hostScene.draw, offset: .zero,
                                    stageScale: 1, detail: hostDetail)
        // Impact trauma shakes the active globe only. The layer offset is
        // subtracted from the camera before the shake is added, so adding the
        // shake here cancels it for the inactive globe.
        let backgroundOffset = (deckActive ? deckWorldBackground : rearOffset())
            + (deckActive ? .zero : shake)
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
        let focus = max(4, renderCamera.position.distance(to: focusCenter) - dns.globeRadius * 0.7)

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
            focusRadius: dns.globeRadius
        )
    }


    // ── scene entry points ───────────────────────────────────────────────

    func handleQuery(_ event: QueryEvent) { dns.handleQuery(event) }
    func handleLocal(_ event: LocalTrafficEvent) { dns.handleLocal(event) }
    func updateLabels(force: Bool) { dns.updateLabels(force: force) }
    func applyVisualState() { dns.applyVisualState() }
    func impactStyle(for destination: Destination) -> String { dns.impactStyle(for: destination) }
    func birthStyle(for destination: Destination, override: String? = nil) -> String {
        dns.birthStyle(for: destination, override: override)
    }
    func randomDeathStyle() -> String { dns.randomDeathStyle() }
    func setWireVisibility(destinationId: String, visible: Bool) {
        dns.setWireVisibility(destinationId: destinationId, visible: visible)
    }
    func setWireVisibility(deviceId: String, visible: Bool) {
        dns.setWireVisibility(deviceId: deviceId, visible: visible)
    }


    // ── presence ─────────────────────────────────────────────────────────

    func birthDestination(_ destination: Destination, fromBoot: Bool = false, style: String? = nil,
                          forceStyle: Bool = false) {
        dns.birthDestination(destination, fromBoot: fromBoot, style: style, forceStyle: forceStyle)
    }

    func retireDestination(_ destination: Destination, style: String? = nil, restoreAfter: Float = 0) {
        dns.retireDestination(destination, style: style, restoreAfter: restoreAfter)
    }

    func restoreDestination(_ destination: Destination, birth: Bool = false) {
        dns.restoreDestination(destination, birth: birth)
    }

    @discardableResult
    func applyWindow(animate: Bool, initial: Bool) -> Bool {
        dns.applyWindow(animate: animate, initial: initial)
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
                guard dns.deviceById[id] != nil else { return }
            case .destination(let id):
                guard dns.nodeByDest[id] != nil else { return }
            case .path(let deviceId, let destinationId):
                guard dns.wireByKey["\(deviceId)::\(destinationId)"] != nil else { return }
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
        dns.clearEffectsForSnapshot()
        hostScene.clearEffectsForSnapshot()
    }

    func rebuildDrawListForSnapshot() {
        dns.rebuildDrawListForSnapshot()
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
        if backgroundDepth > 0, backgroundDepth < activeDepth + dns.globeRadius + 4 {
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
            if dns.effects.entries.isEmpty { failed.append(meta.id) }
            dns.effects.clear()
        }
        dns.effects.clear()
        for meta in Effects.births {
            debugPreviewEffect(kind: "birth", style: meta.id, destinationId: nil,
                               age: 1.0 / 60.0, viewSize: frameViewSize)
            if dns.effects.entries.isEmpty { failed.append(meta.id) }
            dns.effects.clear()
        }
        for meta in Effects.deaths {
            debugPreviewEffect(kind: "death", style: meta.id, destinationId: nil,
                               age: 1.0 / 60.0, viewSize: frameViewSize)
            if dns.effects.entries.isEmpty { failed.append(meta.id) }
            dns.effects.clear()
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
               let wire = dns.wireByKey["\(edge.deviceId)::\(edge.destinationId)"],
               let blockedNode = dns.nodeByDest[destination.id],
               let sourceView = dns.deviceById[edge.deviceId] {
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
            // damped sine would swing back through the anchor, which reads
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
        // finished.
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
        let savedTrauma = dns.trauma
        dns.trauma = 0
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
        dns.trauma = savedTrauma
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

        // Active-globe impact shake must not shake the inactive layer.
        let savedTrauma = dns.trauma
        let savedMotionMode = motionMode
        motionMode = .cinematic
        dns.trauma = 0
        let stillState = makeRenderState(viewSize: frameViewSize)
        dns.trauma = 1
        let shakenState = makeRenderState(viewSize: frameViewSize)
        if stillState.layers.count >= 2, shakenState.layers.count >= 2 {
            let stillOffset = stillState.layers[0].offset
            let shakenOffset = shakenState.layers[0].offset
            if simd_distance(stillOffset, shakenOffset) < 0.0001 {
                failed.append("background-shake-cancel")
            }
            if shakenState.layers[1].offset.length > 0.0001 {
                failed.append("active-layer-shifted")
            }
        } else {
            failed.append("background-shake-layers")
        }
        dns.trauma = savedTrauma
        motionMode = savedMotionMode

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
        // HOST aliases are their own keyspace: app ids for shell bodies and
        // domain/IP:port names for interior destinations.
        let savedHostAppAliases = hostAppAliases
        let savedHostDestinationAliases = hostDestinationAliases
        let hostFixture = HostDemo.snapshot(includeLocal: true)
        if let app = hostFixture.apps.first, let domain = hostFixture.domains.first {
            setShowAliasWithAddress(false)
            setHostAppAlias("Lab app", for: app)
            if hostAppDisplayName(app) != "Lab app" {
                failed.append("host-app-alias-title")
            }
            setHostDestinationAlias("Lab destination", for: domain)
            if hostDestinationDisplayName(domain) != "Lab destination" {
                failed.append("host-destination-alias-title")
            }
            if hostDestinationOriginalText(domain) != nil {
                failed.append("host-destination-alias-hides-original")
            }
            setShowAliasWithAddress(true)
            if hostDestinationOriginalText(domain) != domain.name {
                failed.append("host-destination-alias-show-both")
            }
            setHostAppAlias("", for: app)
            setHostDestinationAlias("", for: domain)
            if hostAppAlias(app) != nil || hostDestinationAlias(domain) != nil {
                failed.append("host-alias-clear")
            }
        } else {
            failed.append("host-alias-fixture")
        }
        hostAppAliases = savedHostAppAliases
        hostDestinationAliases = savedHostDestinationAliases
        hostScene.setHostAliases(apps: savedHostAppAliases,
                                 destinations: savedHostDestinationAliases,
                                 showBoth: savedShowBoth)
        AtlasPreferences.hostAppAliases = savedHostAppAliases
        AtlasPreferences.hostDestinationAliases = savedHostDestinationAliases

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
        let backLabelOpacity = labels.labels.first(where: { $0.id == "dev-\(id)" })?.opacity
        if let front = devices.first(where: { $0.facing > 0.2 && $0.deviceRef.id != id }) {
            setHovered(.device(front.deviceRef.id))
            let frontLabelOpacity = labels.labels.first(where: {
                $0.id == "dev-\(front.deviceRef.id)"
            })?.opacity
            if let backLabelOpacity, let frontLabelOpacity {
                if !(backLabelOpacity < frontLabelOpacity - 0.02) {
                    failed.append("dns-focus-back-label")
                }
                if frontLabelOpacity < 0.9 { failed.append("dns-focus-front-label") }
                if backLabelOpacity > 0.8 { failed.append("dns-focus-back-label-too-bright") }
            } else {
                failed.append("dns-focus-label-missing")
            }
        } else {
            failed.append("dns-focus-front-fixture")
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
        if minRadius < dns.globeRadius * 1.2 {
            failed.append("focus-cut-through-globe")
        }
        if selection?.deviceId != id {
            failed.append("focus-lost-selection")
        }
        return failed
    }

    /// Demo mode must populate both globes: deterministic DNS devices and
    /// host apps/domains, not an empty HOST field.
    func debugDemoHostChecks() -> [String] {
        var failed: [String] = []
        if network.devices.isEmpty || network.destinations.isEmpty {
            failed.append("demo-dns-empty")
        }
        let saved = hostSnapshot
        startHostDemo()
        if !hostDemoActive { failed.append("demo-host-flag") }
        if hostSnapshot.apps.count < 5 { failed.append("demo-host-apps") }
        if hostSnapshot.domains.count < 5 { failed.append("demo-host-domains") }
        if hostScene.snapshot.apps.count != hostSnapshot.apps.count {
            failed.append("demo-host-scene-apps")
        }
        if !hostScene.appNodes.isEmpty && hostScene.domainNodes.isEmpty {
            failed.append("demo-host-scene-domains")
        }
        stopHostDemo()
        if hostDemoActive { failed.append("demo-host-stop") }
        applyHostSnapshot(saved)
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
              let view = dns.deviceById[device.id] else {
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
        let before = replay.cursor
        setReplayRate(600)
        advanceForSnapshot(seconds: 0.3)
        if replay.cursor <= before { failed.append("replay-advance") }

        setPaused(true)
        let pausedAt = replay.cursor
        advanceForSnapshot(seconds: 0.3)
        if abs(replay.cursor - pausedAt) > 0.01 { failed.append("replay-pause") }
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

    /// Deterministic headless dump used by verification. It reports
    /// simulation state, not wall-clock text.
    func debugSceneProbe() -> String {
        func vector(_ value: Vec3) -> String {
            String(format: "%.5f,%.5f,%.5f", value.x, value.y, value.z)
        }
        func point(_ value: CGPoint) -> String {
            String(format: "%.3f,%.3f", value.x, value.y)
        }
        func selectionText(_ value: Selection?) -> String {
            switch value {
            case .device(let id): return "device:\(id)"
            case .destination(let id): return "destination:\(id)"
            case .path(let device, let destination): return "path:\(device):\(destination)"
            case nil: return "none"
            }
        }
        var lines: [String] = []
        lines.append("network devices=\(network.devices.count) destinations=\(network.destinations.count) edges=\(network.edges.count)")
        lines.append("camera pos=\(vector(camera.position)) target=\(vector(camera.target)) up=\(vector(camera.up)) pan=\(String(format: "%.5f,%.5f", camera.pan.x, camera.pan.y)) fov=\(String(format: "%.3f", camera.fov))")
        lines.append("sim elapsed=\(String(format: "%.5f", elapsed)) real=\(String(format: "%.5f", realTime)) radius=\(String(format: "%.5f", dns.globeRadius)) trauma=\(String(format: "%.5f", dns.trauma)) dof=\(String(format: "%.5f", dofStrength))")
        lines.append("ui filter=\(filter.rawValue) labels=\(labelMode.rawValue) window=\(String(format: "%.4f", windowHours)) paused=\(paused) mode=\(mode == .replay ? "replay" : "live") selection=\(selectionText(selection)) hover=\(selectionText(hover))")
        lines.append("stats totals=\(totals.queries),\(totals.blocked) window=\(windowStats.devices),\(windowStats.destinations),\(windowStats.allowed),\(windowStats.blockedDestinations) qps=\(String(format: "%.5f", qps)) feed=\(feed.count)/\(feedCount) pulse=\(pulseCurrent.allowed),\(pulseCurrent.blocked)")

        let state = makeRenderState(viewSize: frameViewSize)
        let draw = state.drawList
        let meshCounts = draw.meshBatches.map { "\($0.count)" }.joined(separator: ",")
        lines.append("draw lines=\(draw.lines.count) stageLines=\(draw.stageLines.count) points=\(draw.points.count) stagePoints=\(draw.stagePoints.count) ambient=\(draw.ambientPoints.count) sprites=\(draw.sprites.count) mesh=\(meshCounts) rings=\(draw.nodeRings.count) shocks=\(draw.shocks.count) planets=\(draw.planets.count) atmo=\(draw.planetAtmospheres.count) shells=\(draw.shockShells.count) shields=\(draw.shields.count) scans=\(draw.scans.count) discs=\(draw.discs.count) jets=\(draw.jets.count) atmospheres=\(draw.atmospheres.count)")
        lines.append("render bloom=\(String(format: "%.5f", state.bloomStrength)) shake=\(vector(state.shake)) dofFocus=\(String(format: "%.5f", state.dofFocus)) dofEnabled=\(state.dofEnabled) focusCenter=\(vector(state.focusCenter)) layers=\(state.layers.map { "\(vector($0.offset)):\(String(format: "%.5f", $0.detail))" }.joined(separator: "|"))")

        for node in nodes.sorted(by: { $0.id < $1.id }) {
            guard let destination = node.destinationRef else { continue }
            lines.append("node \(node.id) pos=\(vector(node.basePosition)) label=\(vector(node.labelPosition)) presence=\(String(format: "%.5f", node.presence)) wanted=\(node.labelWanted) visible=\(destination.windowVisible) status=\(destination.status.rawValue) q=\(destination.liveQueries) blocked=\(destination.liveBlocked) selected=\(node.selected) hovered=\(node.hovered) destroyed=\(node.destroyed)")
        }
        for device in devices.sorted(by: { $0.spec.id < $1.spec.id }) {
            guard let model = device.deviceRef else { continue }
            lines.append("device \(device.spec.id) pos=\(vector(device.position)) normal=\(vector(device.normal)) label=\(vector(device.labelPosition)) visible=\(device.windowVisible) presence=\(String(format: "%.5f", device.windowPresence)) display=\(String(format: "%.5f", device.displayVisibility)) pending=\(model.pendingAppearance) selected=\(device.selected) hovered=\(device.hovered)")
        }
        for wire in wires.sorted(by: { $0.edgeId < $1.edgeId }) {
            lines.append("wire \(wire.edgeId) hidden=\(wire.hidden) dim=\(String(format: "%.5f", wire.dim)) reveal=\(String(format: "%.5f", wire.reveal)) signal=\(wire.signalActive) highlight=\(String(format: "%.5f", wire.highlight)) control=\(wire.controlPoints.count) end=\(vector(wire.end)) tangent=\(vector(wire.tangent))")
        }
        for label in labels.labels.sorted(by: { $0.id < $1.id }) {
            lines.append("label \(label.id) kind=\(label.kind == .device ? "device" : "destination") tone=\(label.tone.rawValue) anchor=\(point(label.anchor)) size=\(String(format: "%.2f,%.2f", label.size.width, label.size.height)) selected=\(label.selected) hovered=\(label.hovered)")
        }
        lines.append("replay active=\(isReplay) progress=\(String(format: "%.6f", replayProgress)) total=\(replayTotal) buckets=\(replayBuckets.count) rate=\(String(format: "%.3f", replayRate)) finished=\(replayFinished) loading=\(replayLoading) feed=\(feed.count) recent=\(replay.recent.count)")
        return lines.joined(separator: "\n") + "\n"
    }


    func debugPreviewEffect(kind: String, style: String, destinationId: String?,
                            age: Float, viewSize: CGSize) {
        dns.debugPreviewEffect(kind: kind, style: style, destinationId: destinationId,
                               age: age, viewSize: viewSize)
    }

    /// Snapshot helper: frame one destination at study distance while keeping
    /// the current viewing direction. Used for births/deaths, which do not
    /// publish an inbound hit axis.
    func debugFrameDestination(_ id: String) {
        guard let node = dns.nodeByDest[id] else { return }
        let direction = (camera.position - node.basePosition).normalized
        let distance = max(11.5, node.radius * 13)
        var position = node.basePosition + direction * distance
        position.y = max(1.1, position.y)
        setCameraForSnapshot(position: position, target: node.basePosition)
    }

    /// Snapshot helper: frame the last hit along its inbound axis so a plane
    /// reads as a circle. Mirrors `faceHitCamera` without starting a flight.
    func debugFrameLastImpact(fromHitSide: Bool = false, fromSide: Bool = false) {
        guard let record = dns.lastImpact,
              let node = dns.nodeByDest[record.destinationId] else { return }
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
        if enabled { dns.hitGeometryReplayAt = elapsed }
        showToast(enabled ? "Hit plane overlay on" : "Hit plane overlay off",
                  tone: enabled ? .signal : .gold)
    }

    func setAutoTour(_ enabled: Bool) {
        guard enabled != autoTour else { return }
        if enabled {
            guard let destination = dns.previewDestination() else {
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
        guard let node = dns.nodeByDest[destination.id], !node.destroyed else { return }
        let busiestEdge = destination.edges.max { $0.liveQueries < $1.liveQueries }
        let wire = busiestEdge.flatMap { dns.wireByKey["\($0.deviceId)::\($0.destinationId)"] }
        let normal = (wire?.tangent ?? node.basePosition).normalized
        dns.registerImpact(node: node, normal: normal, event: nil)
    }

    func setRecoil(_ enabled: Bool) {
        recoilEnabled = enabled
        AtlasPreferences.recoil = enabled
        hostScene.setRecoilEnabled(enabled)
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
        dns.flashDestinationLabel(id, duration: duration)
    }


    func previewMotion(_ kind: String) {
        dns.previewMotion(kind)
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

    func hostAppAlias(_ app: HostAppStat) -> String? {
        hostAppAliases[aliasKey(app.id)]
    }

    func hostAppDisplayName(_ app: HostAppStat) -> String {
        hostAppAlias(app) ?? app.name
    }

    func hostAppDisplayName(appID: String) -> String {
        guard let app = hostSnapshot.apps.first(where: { $0.id == appID }) else {
            return hostAppAliases[aliasKey(appID)] ?? "App"
        }
        return hostAppDisplayName(app)
    }

    func hostDestinationAlias(_ domain: HostDomainStat) -> String? {
        hostDestinationAliases[aliasKey(domain.name)]
    }

    func hostDestinationAlias(name: String) -> String? {
        hostDestinationAliases[aliasKey(name)]
    }

    func hostDestinationDisplayName(_ domain: HostDomainStat) -> String {
        hostDestinationAlias(domain) ?? domain.name
    }

    func hostDestinationDisplayName(name: String) -> String {
        hostDestinationAlias(name: name) ?? name
    }

    /// Original domain or IP:port beside a host alias, following the same
    /// show-both preference as DNS destinations.
    func hostDestinationOriginalText(_ domain: HostDomainStat) -> String? {
        guard hostDestinationAlias(domain) != nil, showAliasWithAddress else { return nil }
        return domain.name
    }

    func hostEndpointDisplayName(_ endpoint: HostEndpointStat) -> String {
        let raw = endpoint.domain ?? "\(endpoint.remoteHost):\(endpoint.remotePort)"
        return hostDestinationAliases[aliasKey(raw)] ?? endpoint.displayName
    }

    func setHostAppAlias(_ raw: String, for app: HostAppStat) {
        var next = hostAppAliases
        let key = aliasKey(app.id)
        if let value = normalizedAlias(raw) {
            next[key] = value
        } else {
            next.removeValue(forKey: key)
        }
        guard next != hostAppAliases else { return }
        hostAppAliases = next
        AtlasPreferences.hostAppAliases = next
        hostAliasesDidChange()
    }

    func setHostDestinationAlias(_ raw: String, for domain: HostDomainStat) {
        var next = hostDestinationAliases
        let key = aliasKey(domain.name)
        if let value = normalizedAlias(raw) {
            next[key] = value
        } else {
            next.removeValue(forKey: key)
        }
        guard next != hostDestinationAliases else { return }
        hostDestinationAliases = next
        AtlasPreferences.hostDestinationAliases = next
        hostAliasesDidChange()
    }

    private func hostAliasesDidChange() {
        hostScene.setHostAliases(apps: hostAppAliases,
                                 destinations: hostDestinationAliases,
                                 showBoth: showAliasWithAddress)
    }

    func setShowAliasWithAddress(_ enabled: Bool) {
        guard showAliasWithAddress != enabled else { return }
        showAliasWithAddress = enabled
        AtlasPreferences.showAliasWithAddress = enabled
        hostScene.setHostAliases(apps: hostAppAliases,
                                 destinations: hostDestinationAliases,
                                 showBoth: enabled)
        aliasesDidChange()
    }

    private func aliasesDidChange() {
        dns.invalidateLabelSizes()
        updateLabels(force: true)
        if rightRailOpen { refreshFeed() }
    }


    // ── picking ──────────────────────────────────────────────────────────

    func pick(at point: CGPoint, viewSize: CGSize) -> Selection? {
        dns.pick(at: point, viewSize: viewSize)
    }

    // ── camera controls ──────────────────────────────────────────────────

    func computeFitDistance(width: CGFloat, height: CGFloat) -> Float {
        AtlasRuntime.computeFitDistance(width: width, height: height,
                                        globeRadius: max(dns.globeRadius, dns.targetGlobeRadius()))
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
        max(11.5, dns.globeRadius * 1.12)
    }

    private var maxOrbitRadius: Float {
        max(42, currentFitDistance() * 2.2)
    }

    /// Keep the projection and the orbit clamp in step with the computed
    /// globe size. A 13-unit test globe and a 1000-orb live globe need very
    /// different far planes and zoom-out bounds.
    func updateCameraLimits() {
        let maxRadius = maxOrbitRadius
        let far = max(220, maxRadius * 2.2 + dns.globeRadius * 3)
        if abs(camera.far - far) > 0.5 { camera.far = far }
    }

    func applyFraming() {
        guard cameraFlight == nil else { return }
        fitDistance = currentFitDistance()
        let direction = (camera.position - orbitTarget).normalized
        camera.position = orbitTarget + direction * fitDistance
        camera.target = orbitTarget
        camera.pan = clampedPan(camera.pan)
        camera.aspect = Float(frameViewSize.width / max(1, frameViewSize.height))
        lastFramingTarget = dns.targetGlobeRadius()
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
        guard let record = dns.lastImpact, let node = dns.nodeByDest[record.destinationId] else {
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
            guard let view = dns.deviceById[id] else { return }
            guard view.deviceRef.windowVisible else {
                showToast("Outside the history window", tone: .signal)
                return
            }
            position = view.normal * (fit * 0.84) + Vec3(0, 0.8, 0)
        case .destination(let id):
            guard let node = dns.nodeByDest[id] else { return }
            guard node.destinationRef.windowVisible else {
                showToast("Outside the history window", tone: .signal)
                return
            }
            position = node.basePosition.normalized * (fit * 0.68)
        case .path(let id, let destinationId):
            guard let view = dns.deviceById[id] else { return }
            guard view.deviceRef.windowVisible,
                  dns.nodeByDest[destinationId]?.destinationRef.windowVisible == true else {
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

    func refreshUI() {
        replay.syncPublishedTime()
        let nextTotals = network.totals
        if nextTotals != totals { totals = nextTotals }
        let nextWindowStats = network.windowStats()
        if nextWindowStats != windowStats { windowStats = nextWindowStats }
        let nextQps = replay.currentQps() ?? source.getQps()
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
        if let record = dns.lastImpact,
           let node = dns.nodeByDest[record.destinationId] {
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
        let events = isReplay ? replay.recent : source.recent
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
        (isReplay ? replay.recent : source.recent).filter { event in
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
