import Foundation
import Observation

/// The process-level owner of metering (D3, the hybrid host): ONE lease
/// holder runs one `UsageEngine` per enrolled profile beside one
/// `ProviderServices`, folds their sections into ONE live-state.json, and
/// answers the control socket. usaged runs it headless; the app runs it
/// while no daemon does. Everything a single engine used to own that must
/// exist once per process — the publisher, the socket, the network
/// monitor, the update checker — lives here.
///
/// Profiles come from `ProfileStore` (the app's defaults domain, which the
/// daemon reads too). D9 rules run here: a reprobe every ten minutes reads
/// each profile's last session write, declares dormant ones (no engine,
/// hidden from bar and strip, an FSEvents watcher kept so the first write
/// revives it), and focus follows the newest write unless pinned — held
/// while the panel is open. The host stamps the digest's heartbeat and its
/// next-poll horizon, so an all-dormant machine never reads as a dead
/// host to a client.
@MainActor
@Observable
public final class MeteringHost {
    public struct Configuration: Sendable {
        public var bundleID: String
        public var kind: UsageEngine.Host
        public var roots: StorageScope.Roots
        /// False builds no status poller (tests, an offline host).
        public var pollsStatus: Bool
        /// The release feed to poll; nil = no update checker.
        public var updateFeedURL: URL?
        public var reprobeInterval: TimeInterval
        /// The user home "~" and discovery are judged against.
        public var userHome: URL
        /// The span the launch polls of N engines spread across.
        public var stagger: TimeInterval
        /// Where the control socket binds; nil = the broker's standard path.
        public var socketURL: URL?
        public var bindsSocket: Bool

        public init(
            bundleID: String, kind: UsageEngine.Host, roots: StorageScope.Roots = .standard,
            pollsStatus: Bool = true, updateFeedURL: URL? = nil, reprobeInterval: TimeInterval = 600,
            userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
            stagger: TimeInterval = TriggerGate.floor, socketURL: URL? = nil, bindsSocket: Bool = true
        ) {
            self.bundleID = bundleID
            self.kind = kind
            self.roots = roots
            self.pollsStatus = pollsStatus
            self.updateFeedURL = updateFeedURL
            self.reprobeInterval = reprobeInterval
            self.userHome = userHome
            self.stagger = stagger
            self.socketURL = socketURL
            self.bindsSocket = bindsSocket
        }

        /// The release feed a real host polls: both GitHub flavors, so a
        /// source checkout still learns it is behind; the drill's override
        /// both supplies the URL and forces the checker on.
        public static func updateFeedURL(defaults: UserDefaults) -> URL? {
            let channel = Distribution.channel(for: Bundle.main.bundleURL)
            let override = defaults.string(forKey: UpdateChecker.feedOverrideKey)
                .flatMap(URL.init(string:))
            return override ?? channel?.updateFeedURL
        }
    }

    public let provider: any UsageProvider
    public let services: ProviderServices
    public let configuration: Configuration

    /// Every record for this provider, the implicit default first —
    /// enrolled AND dismissed-discovery records alike (`Profile.isEnrolled`).
    public private(set) var profiles: [Profile] = []
    /// Running engines: enrolled ∧ enabled ∧ awake.
    public private(set) var engines: [String: UsageEngine] = [:]
    public private(set) var lastActivity: [String: Date] = [:]
    public private(set) var identities: [String: AccountIdentity] = [:]
    public private(set) var dormant: Set<String> = []
    public private(set) var focusedProfileID: String?
    public private(set) var pin: String?
    /// The digest as last written.
    public private(set) var digest: LiveState?
    public private(set) var appUpdate: AppUpdateCard?
    public private(set) var notices: NoticesCard?
    public private(set) var outages: [OutageSpan] = []
    /// Homes found beside the standard one that nobody decided about.
    public private(set) var discovered: [DiscoveredHome] = []

    public var serviceStatus: ServiceStatusCard? { services.serviceStatus }
    public var focusedEngine: UsageEngine? { focusedProfileID.flatMap { engines[$0] } }
    public var enrolledProfiles: [Profile] { profiles.filter(\.isEnrolled) }
    public var activeInterval: TimeInterval {
        focusedEngine?.activeInterval ?? engines.values.first?.activeInterval
            ?? UsageEngine.activeInterval(from: defaults)
    }

    /// The two process-lifecycle verbs belong to whoever owns the process:
    /// usaged switches providers and exits; an app refuses both.
    @ObservationIgnored public var onSetProvider: ((String) -> ControlReply)?
    @ObservationIgnored public var onShutdown: (() -> ControlReply)?
    @ObservationIgnored public var onLog: ((String) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let serviceFactory: ((Profile) -> UsageService?)?
    @ObservationIgnored private let systemAccent: RGBColor?
    @ObservationIgnored private let gateSeeds: [String: Date]
    @ObservationIgnored private let publisher: StatePublisher
    @ObservationIgnored private var sections: [String: LiveState] = [:]
    @ObservationIgnored private var revivalWatchers: [String: AgentActivityWatcher] = [:]
    @ObservationIgnored private var socket: ControlSocket?
    @ObservationIgnored private var networkMonitor: NetworkMonitor?
    @ObservationIgnored private var reprobeTimer: Timer?
    @ObservationIgnored private var updateChecker: UpdateChecker?
    @ObservationIgnored private var focusHeld = false
    @ObservationIgnored private var nextReprobeAt: Date?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var isReprobing = false

    /// `gateSeeds` are the previous host's per-profile fetch stamps
    /// (`LiveState.gateSeeds()`), so a handover never double-polls inside
    /// the floor. `serviceFactory` injects stubbed services per profile
    /// (tests); nil builds the real pipeline against each home's own
    /// credential chain.
    public init(
        provider: any UsageProvider, defaults: UserDefaults, configuration: Configuration,
        serviceFactory: ((Profile) -> UsageService?)? = nil,
        gateSeeds: [String: Date] = [:], systemAccent: RGBColor? = nil
    ) {
        self.provider = provider
        self.defaults = defaults
        self.configuration = configuration
        self.serviceFactory = serviceFactory
        self.gateSeeds = gateSeeds
        self.systemAccent = systemAccent
        self.services = ProviderServices(
            provider: provider, bundleID: configuration.bundleID, roots: configuration.roots,
            pollsStatus: configuration.pollsStatus)
        self.publisher = StatePublisher(
            fileURL: LiveState.fileURL(bundleID: configuration.bundleID, roots: configuration.roots))
    }

    // MARK: - Lifecycle

    /// The caller holds the engine lease. Services first, then the engines
    /// (launch polls staggered across the gate floor), the socket, the
    /// network monitor, the reprobe clock, discovery, and the first digest.
    public func start() {
        guard !isStarted, !isShutDown else { return }
        isStarted = true
        services.onChange = { [weak self] in self?.republish() }
        services.start()
        if let feedURL = configuration.updateFeedURL {
            let checker = UpdateChecker(
                feed: UpdateFeed(latestReleaseURL: feedURL),
                currentVersion: AppIdentity.version, defaults: defaults)
            checker.onCard = { [weak self] card in
                guard let self, !self.isShutDown else { return }
                self.appUpdate = card
                self.republish()
            }
            updateChecker = checker
            checker.start()
        }
        loadProfiles()
        probeSynchronously(profiles.filter(\.isEnrolled))
        recomputeDormancy(now: Date())
        reconcileEngines(staggered: true)
        _ = recomputeFocus()
        if configuration.bindsSocket { startSocket() }
        let monitor = NetworkMonitor()
        monitor.onRestored = { [weak self] in
            self?.engines.values.forEach { $0.noteNetworkRestored() }
        }
        monitor.start()
        networkMonitor = monitor
        scheduleReprobe()
        discoverHomes()
        republish()
    }

    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        reprobeTimer?.invalidate()
        reprobeTimer = nil
        networkMonitor?.stop()
        networkMonitor = nil
        socket?.stop()
        socket = nil
        for engine in engines.values { engine.shutdown() }
        engines = [:]
        revivalWatchers = [:]
        updateChecker?.stop()
        updateChecker = nil
        services.stop()
    }

    /// The host process's wake impulse: every engine polls (gate-ruled),
    /// the provider's status and history read once, the release check
    /// pokes, and a reprobe follows — a lid closed for a week is exactly
    /// when dormancy and focus need re-reading.
    public func noteWake() {
        guard isStarted, !isShutDown else { return }
        for engine in engines.values { engine.noteWake() }
        services.noteWake()
        updateChecker?.pokeIfStale()
        reprobe()
    }

    /// While the panel is open focus stays put; a switch decided meanwhile
    /// applies on release.
    public func holdFocus(_ held: Bool) {
        focusHeld = held
        if !held, recomputeFocus() { republish() }
    }

    // MARK: - Profiles

    /// The profile list changed (Settings, a socket verb, another process):
    /// re-read it and reconcile — new engines start, removed or disabled
    /// ones stop, focus re-resolves.
    public func reloadProfiles() {
        loadProfiles()
        let unprobed = profiles.filter { $0.isEnrolled && lastActivity[$0.id] == nil && identities[$0.id] == nil }
        probeSynchronously(unprobed)
        recomputeDormancy(now: Date())
        reconcileEngines()
        _ = recomputeFocus()
        republish()
    }

    /// Pin the focus (nil = follow activity again).
    public func setPin(_ id: String?) {
        ProfileStore.setPin(id, in: defaults)
        pin = id
        if recomputeFocus() { republish() }
    }

    public func setProfileEnabled(id: String, enabled: Bool) {
        var stored = ProfileStore.load(from: defaults)
        if let index = stored.firstIndex(where: { $0.id == id && $0.providerID == provider.id }) {
            stored[index].enabled = enabled
        } else if let record = profiles.first(where: { $0.id == id }) {
            var copy = record
            copy.enabled = enabled
            stored.append(copy)
        } else {
            return
        }
        ProfileStore.save(stored, to: defaults)
        reloadProfiles()
    }

    private func loadProfiles() {
        profiles = ProfileStore.resolved(ProfileStore.load(from: defaults), provider: provider, now: Date())
        pin = ProfileStore.pin(from: defaults)
    }

    /// The provider retargeted at a profile's home; the default profile
    /// keeps the host's own instance (and any injected client).
    private func provider(for profile: Profile) -> any UsageProvider {
        if profile.isDefault { return provider }
        return profile.home.map { provider.withHome($0) } ?? provider
    }

    private func profileDirectory(_ profile: Profile) -> URL {
        StorageScope.supportDirectory(
            bundleID: configuration.bundleID, providerID: provider.id, profileID: profile.id,
            roots: configuration.roots)
    }

    // MARK: - Engines

    private func reconcileEngines(staggered: Bool = false) {
        let wanted = enrolledProfiles.filter { $0.enabled && !dormant.contains($0.id) }
        for (id, engine) in engines where !wanted.contains(where: { $0.id == id }) {
            engine.shutdown()
            engines[id] = nil
            sections[id] = nil
            log("stopped: \(id)")
        }
        let missing = wanted.filter { engines[$0.id] == nil }
        for (index, profile) in missing.enumerated() {
            let delay = staggered && missing.count > 1
                ? Double(index) * configuration.stagger / Double(missing.count) : 0
            startEngine(for: profile, launchDelay: delay)
        }
        for profile in enrolledProfiles {
            let needsWatcher = profile.enabled && dormant.contains(profile.id)
            if needsWatcher, revivalWatchers[profile.id] == nil {
                let directories = provider(for: profile)
                    .makeLocalActivity(cacheDirectory: profileDirectory(profile))?
                    .watchDirectories ?? []
                let id = profile.id
                revivalWatchers[id] = AgentActivityWatcher(directories: directories) { [weak self] in
                    self?.revive(id)
                }
            } else if !needsWatcher {
                revivalWatchers[profile.id] = nil
            }
        }
        let known = Set(profiles.map(\.id))
        for id in revivalWatchers.keys where !known.contains(id) { revivalWatchers[id] = nil }
    }

    private func startEngine(for profile: Profile, launchDelay: TimeInterval) {
        let id = profile.id
        let engine = UsageEngine(
            provider: provider(for: profile), profileID: id, services: services,
            service: serviceFactory?(profile), defaults: defaults,
            bundleID: configuration.bundleID, roots: configuration.roots,
            host: configuration.kind, gateSeed: gateSeeds[id], systemAccent: systemAccent,
            launchDelay: launchDelay
        ) { [weak self] state in
            self?.sink(id, state)
        }
        engine.onAgentActivity = { [weak self] at in self?.noteActivity(id, at: at) }
        engines[id] = engine
        log("engine: \(id)" + (launchDelay > 0 ? " (first poll in \(Int(launchDelay))s)" : ""))
    }

    private func sink(_ id: String, _ state: LiveState) {
        guard !isShutDown, engines[id] != nil else { return }
        sections[id] = state
        republish()
    }

    /// An engine's FSEvents push: the newest write moves focus.
    private func noteActivity(_ id: String, at: Date) {
        if let known = lastActivity[id], known > at { return }
        lastActivity[id] = at
        if recomputeFocus() { republish() }
    }

    /// A dormant profile's first write in a month: its engine comes back
    /// at once, no stagger.
    private func revive(_ id: String) {
        guard !isShutDown, dormant.contains(id) else { return }
        lastActivity[id] = Date()
        dormant.remove(id)
        revivalWatchers[id] = nil
        log("revived: \(id)")
        reconcileEngines()
        _ = recomputeFocus()
        republish()
    }

    // MARK: - Focus and dormancy (D9)

    @discardableResult
    private func recomputeFocus() -> Bool {
        let candidates = enrolledProfiles.map { profile in
            FocusCandidate(
                id: profile.id, order: profile.order, lastActivity: lastActivity[profile.id],
                eligible: profile.enabled && !dormant.contains(profile.id),
                shown: profile.showInMenuBar)
        }
        let next = FocusRule.focused(candidates, pin: pin)
        guard next != focusedProfileID, !focusHeld else { return false }
        focusedProfileID = next
        log("focus → \(next ?? "none")")
        return true
    }

    private func recomputeDormancy(now: Date) {
        var fresh: Set<String> = []
        for profile in enrolledProfiles
        where Dormancy.isDormant(lastActivity: lastActivity[profile.id], addedAt: profile.addedAt, now: now) {
            fresh.insert(profile.id)
        }
        for id in fresh.subtracting(dormant) { log("dormant: \(id)") }
        for id in dormant.subtracting(fresh) { log("awake: \(id)") }
        dormant = fresh
    }

    private func probeSynchronously(_ targets: [Profile]) {
        let now = Date()
        for profile in targets {
            apply(ProfileActivity.probe(
                provider: provider(for: profile), cacheDirectory: profileDirectory(profile), now: now),
                to: profile.id)
        }
    }

    private func apply(_ probe: ProfileProbe, to id: String) {
        if let seen = probe.lastActivityAt, lastActivity[id].map({ seen > $0 }) ?? true {
            lastActivity[id] = seen
        }
        identities[id] = probe.identity
    }

    private func scheduleReprobe() {
        let interval = configuration.reprobeInterval
        nextReprobeAt = Date().addingTimeInterval(interval)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.nextReprobeAt = Date().addingTimeInterval(interval)
                self.reprobe()
            }
        }
        timer.tolerance = min(60, interval / 10)
        reprobeTimer = timer
    }

    /// Off-main: the identity records and session mtimes of every enrolled
    /// profile. Then dormancy transitions, engine reconciliation, focus,
    /// discovery, and a republish so the digest's strip reads fresh.
    public func reprobe() {
        guard isStarted, !isShutDown, !isReprobing else { return }
        isReprobing = true
        let targets = enrolledProfiles.map { ($0.id, provider(for: $0), profileDirectory($0)) }
        Task.detached(priority: .utility) { [weak self] in
            let now = Date()
            let probes = targets.map { id, provider, directory in
                (id, ProfileActivity.probe(provider: provider, cacheDirectory: directory, now: now))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReprobing = false
                guard !self.isShutDown else { return }
                for (id, probe) in probes { self.apply(probe, to: id) }
                self.recomputeDormancy(now: Date())
                self.reconcileEngines()
                _ = self.recomputeFocus()
                self.discoverHomes()
                self.republish()
            }
        }
    }

    // MARK: - Discovery (D2)

    private func discoverHomes() {
        guard provider.supportsMultipleHomes else { return }
        let provider = provider
        let known = profiles
        let configuration = configuration
        Task.detached(priority: .utility) { [weak self] in
            let found = ProfileDiscovery.discover(
                provider: provider, known: known, bundleID: configuration.bundleID,
                roots: configuration.roots, now: Date(), userHome: configuration.userHome)
            await MainActor.run { [weak self] in
                guard let self, !self.isShutDown else { return }
                self.discovered = found
                let offers = ProfileDiscovery.offers(found, providerID: provider.id, now: Date())
                guard !offers.isEmpty else { return }
                self.services.notices.mutate { ledger in
                    var changed = false
                    for offer in offers { changed = ledger.record(offer) || changed }
                    return changed
                }
            }
        }
    }

    /// A dismissed offer is remembered as an ignored record: silent until
    /// the home's sign-in changes.
    private func ignore(_ home: DiscoveredHome) {
        var stored = ProfileStore.load(from: defaults)
        guard !stored.contains(where: { $0.id == home.profileID && $0.providerID == provider.id })
        else { return }
        stored.append(Profile(
            id: home.profileID, providerID: provider.id, home: home.home, enabled: false,
            showInMenuBar: false, order: (stored.map(\.order).max() ?? 0) + 1, addedAt: Date(),
            ignoredIdentityKey: home.identity?.key ?? ""))
        ProfileStore.save(stored, to: defaults)
        loadProfiles()
        log("ignored: \(home.displayPath)")
    }

    // MARK: - Digest

    private func republish(now: Date = Date()) {
        guard isStarted, !isShutDown else { return }
        let sectionList = enrolledProfiles.map { profile -> ProfileSection in
            let id = profile.id
            let label = ProfileFacts.label(profile: profile, identity: identities[id])
            return ProfileSection(
                profile: profile, label: label,
                monogram: ProfileFacts.monogram(profile: profile, label: label),
                dormant: dormant.contains(id), lastActivityAt: lastActivity[id],
                homeDisplayPath: profile.displayHome(relativeTo: configuration.userHome),
                state: engines[id] != nil ? sections[id] : nil)
        }
        let composed = MeteringDigest.compose(
            sections: sectionList, focused: focusedProfileID, provider: provider,
            host: configuration.kind.rawValue,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            appVersion: AppIdentity.version, systemAccent: systemAccent,
            activeInterval: activeInterval,
            serviceStatus: services.serviceStatus, appUpdate: appUpdate,
            notices: services.notices.pending, outages: services.outageSpans(now: now),
            nextReprobeAt: nextReprobeAt, now: now)
        digest = composed
        notices = composed.notices
        outages = composed.outages ?? []
        publisher.publish(composed)
    }

    // MARK: - Faces

    public func refresh(_ reason: UsageEngine.RefreshReason, profile: String? = nil) {
        (profile.flatMap { engines[$0] } ?? focusedEngine)?.refresh(reason)
    }

    public func thresholdsChanged() {
        for engine in engines.values { engine.thresholdsChanged() }
        if engines.isEmpty { republish() }
    }

    public func setActiveInterval(_ interval: TimeInterval) {
        for engine in engines.values { engine.setActiveInterval(interval) }
        if engines.isEmpty {
            let clamped = min(max(TriggerGate.floor, interval), AdaptiveCadence.maxActiveInterval)
            defaults.set(clamped, forKey: UsageEngine.intervalKey)
            republish()
        }
    }

    public func scanActivity(force: Bool = false) {
        for engine in engines.values { engine.scanActivity(force: force) }
    }

    public func sessionDetail(id: String, profile: String? = nil) async -> SessionDetail? {
        guard let engine = profile.flatMap({ engines[$0] }) ?? focusedEngine else { return nil }
        return await engine.sessionDetail(id: id)
    }

    public func refreshPricingNow() { services.refreshPricingNow() }
    public func refreshServiceStatus() { services.refreshServiceStatus() }
    public func checkForUpdates() { updateChecker?.checkNow() }

    /// A face rendered these pending notices. Seen is not dismissed.
    public func markNoticesSeen(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        services.notices.mutate { $0.markSeen(ids: ids) }
    }

    /// The person's ×. Refused for an ongoing notice. Dismissing a
    /// discovered home's offer also ignores that home (D2).
    @discardableResult
    public func dismissNotice(id: String) -> Bool {
        if let home = discovered.first(where: { Notice.profileFoundID(profileID: $0.profileID) == id }) {
            ignore(home)
        }
        return services.notices.mutate { $0.dismiss(id: id) }
    }

    public func dismissAllNotices() {
        for home in discovered
        where services.notices.notices.contains(where: {
            $0.id == Notice.profileFoundID(profileID: home.profileID) && $0.isPending
        }) {
            ignore(home)
        }
        services.notices.mutate { $0.dismissAll() }
    }

    public var statusSummary: String {
        "\(configuration.kind.rawValue) pid \(ProcessInfo.processInfo.processIdentifier), "
            + "provider \(provider.id), v\(AppIdentity.version), "
            + "profiles \(enrolledProfiles.count) (focus \(focusedProfileID ?? "none"), "
            + "dormant \(dormant.count))"
    }

    // MARK: - Control socket

    private func startSocket() {
        let url = configuration.socketURL
            ?? EngineHostBroker.socketURL(bundleID: configuration.bundleID, roots: configuration.roots)
        let socket = ControlSocket(socketURL: url) { [weak self] command in
            await self?.handle(command) ?? ControlReply(ok: false, message: "host gone")
        }
        do {
            try socket.start()
            self.socket = socket
        } catch {
            log("control socket failed to bind: \(error)")
        }
    }

    /// Every verb both hosts answer alike; the two process-lifecycle verbs
    /// go to the owner's closures and are refused when none is installed.
    public func handle(_ command: ControlCommand) async -> ControlReply {
        guard !isShutDown else { return ControlReply(ok: false, message: "host shut down") }
        switch command {
        case .status:
            return ControlReply(ok: true, message: statusSummary)
        case .refresh:
            guard let engine = focusedEngine else {
                return ControlReply(ok: false, message: "no engine for the focused profile")
            }
            engine.refresh(.manual)
            return ControlReply(ok: true, message: "refresh requested (gate may coalesce)")
        case .refreshProfile(let id):
            guard let engine = engines[id] else {
                return ControlReply(ok: false, message: "no engine for profile \(id)")
            }
            engine.refresh(.manual)
            return ControlReply(ok: true, message: "refresh requested for \(id) (gate may coalesce)")
        case .setInterval(let seconds):
            setActiveInterval(seconds)
            return ControlReply(ok: true, message: "interval \(Int(activeInterval))s")
        case .setProvider(let id):
            return onSetProvider?(id)
                ?? ControlReply(ok: false, message: "not while the app hosts — use the app's Metering menu")
        case .settingsChanged:
            thresholdsChanged()
            return ControlReply(ok: true)
        case .refreshPricing:
            refreshPricingNow()
            return ControlReply(ok: true)
        case .scanNow:
            scanActivity(force: true)
            return ControlReply(ok: true)
        case .refreshStatus:
            refreshServiceStatus()
            return ControlReply(ok: true)
        case .checkUpdates:
            checkForUpdates()
            return ControlReply(ok: true)
        case .markNoticesSeen(let ids):
            markNoticesSeen(ids)
            return ControlReply(ok: true)
        case .dismissNotice(let id):
            let ok = dismissNotice(id: id)
            return ControlReply(ok: ok, message: ok ? nil : "not dismissable")
        case .dismissAllNotices:
            dismissAllNotices()
            return ControlReply(ok: true)
        case .focusProfile(let id):
            if let id, !profiles.contains(where: { $0.id == id && $0.isEnrolled }) {
                return ControlReply(ok: false, message: "no such profile \(id)")
            }
            setPin(id)
            return ControlReply(ok: true, message: "focus \(id ?? "follows activity")")
        case .setProfileEnabled(let id, let enabled):
            guard profiles.contains(where: { $0.id == id && $0.isEnrolled }) else {
                return ControlReply(ok: false, message: "no such profile \(id)")
            }
            setProfileEnabled(id: id, enabled: enabled)
            return ControlReply(ok: true, message: "\(id) \(enabled ? "enabled" : "disabled")")
        case .profilesChanged:
            reloadProfiles()
            return ControlReply(ok: true, message: "profiles \(enrolledProfiles.count)")
        case .shutdown:
            return onShutdown?()
                ?? ControlReply(ok: false, message: "not while the app hosts — use the app's Metering menu")
        }
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}
