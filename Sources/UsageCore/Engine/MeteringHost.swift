import Foundation
import Observation

/// The process-level owner of metering (D3, the hybrid host): ONE lease
/// holder runs one `UsageEngine` per metered account of every metered
/// HARNESS (v0.101.0), beside one `ProviderServices` per harness, folds
/// their sections into ONE live-state.json, and answers the control socket.
/// usaged runs it headless; the app runs it while no daemon does. Everything
/// a single engine used to own that must exist once per process — the
/// publisher, the socket, the network monitor, the update checker — lives
/// here.
///
/// Harnesses come from `HarnessPresence` (present on disk, latched for the
/// process) crossed with the person's hidden set; accounts come from
/// `ProfileStore` (the app's defaults domain, which the daemon reads too).
/// Every runtime map here is keyed by `ProfileKey` — every harness's standard
/// home is `default`, so bare profile ids stopped naming one account.
///
/// D9 rules run here: a reprobe every ten minutes reads each account's
/// session-file volume over the trailing fortnight, the days it spans and
/// its last write, declares dormant ones (no engine, hidden from bar and
/// strip, an FSEvents watcher kept so the first write revives it), and focus
/// follows — the harness used on the most days, then that harness's busiest
/// account — unless pinned, with a switch held while the panel is open. The
/// host stamps the digest's heartbeat and its next-poll horizon, so an
/// all-dormant machine never reads as a dead host to a client.
@MainActor
@Observable
public final class MeteringHost {
    /// Every harness this host may meter, in the build's standard order —
    /// what presence is probed over. A one-harness host holds exactly one.
    public let providers: [any UsageProvider]
    public let configuration: Configuration
    /// One `ProviderServices` per metered harness: its pricing, its status
    /// poller, its notice ledger.
    public let serviceRegistry: ProviderServicesRegistry

    /// The metered harnesses and their accounts, rebuilt whenever the stored
    /// records, the hidden set or presence change.
    public private(set) var roster = HarnessRoster(rows: [])
    /// Harness ids found on disk — latched for the life of the process.
    public private(set) var present: Set<String> = []
    /// Harness ids the person turned off displaying. Still metered.
    public private(set) var hidden: Set<String> = []

    /// Every metered account, harness blocks in standard order — enrolled
    /// AND dismissed-discovery records alike (`Profile.isEnrolled`).
    public private(set) var profiles: [Profile] = []
    /// Running engines by `ProfileKey`: enrolled ∧ enabled ∧ awake.
    public private(set) var engines: [String: UsageEngine] = [:]
    public private(set) var lastActivity: [String: Date] = [:]
    /// Session files each account wrote inside `ProfileActivity.window`, as
    /// of the last probe — what focus follows WITHIN a harness.
    public private(set) var recentActivity: [String: Int] = [:]
    /// The days those files fall on — what ranks harnesses against each
    /// other, whose file counts don't compare.
    public private(set) var activeDays: [String: Set<Date>] = [:]
    public private(set) var identities: [String: AccountIdentity] = [:]
    public private(set) var dormant: Set<String> = []
    public private(set) var focusedProfileID: String?
    public private(set) var pin: String?
    /// The digest as last written.
    public private(set) var digest: LiveState?
    public private(set) var appUpdate: AppUpdateCard?
    public private(set) var notices: NoticesCard?
    public private(set) var outages: [OutageSpan] = []
    /// Homes found beside a harness's standard one that nobody decided
    /// about, by harness.
    public private(set) var discoveredByHarness: [String: [DiscoveredHome]] = [:]

    /// Every harness's offers in roster order — what the Accounts card lists.
    public var discovered: [DiscoveredHome] {
        roster.rows.flatMap { discoveredByHarness[$0.id] ?? [] }
    }

    /// The harness the focused account belongs to — whose vendor cards the
    /// digest's top level carries.
    public var focusedHarnessID: String {
        focusedProfileID.flatMap { roster.profile(key: $0)?.providerID }
            ?? roster.rows.first?.id ?? providers[0].id
    }

    /// The first metered harness — what a caller that knows of only one
    /// means by "the provider".
    public var provider: any UsageProvider { roster.rows.first?.provider ?? providers[0] }
    /// That harness's services. A reader after one particular harness's
    /// pricing or notices asks `services(forHarness:)`, which never builds
    /// (and so never starts a poller for) a harness this host isn't metering.
    public var services: ProviderServices {
        serviceRegistry[provider.id] ?? serviceRegistry.services(for: provider)
    }

    /// One metered harness's services — nil for anything this host does not
    /// meter.
    public func services(forHarness providerID: String) -> ProviderServices? {
        serviceRegistry[providerID]
    }

    public var serviceStatus: ServiceStatusCard? { serviceRegistry[focusedHarnessID]?.serviceStatus }
    public var focusedEngine: UsageEngine? { focusedProfileID.flatMap { engines[$0] } }
    public var enrolledProfiles: [Profile] { profiles.filter(\.isEnrolled) }
    public var activeInterval: TimeInterval {
        focusedEngine?.activeInterval ?? engines.values.first?.activeInterval
            ?? UsageEngine.activeInterval(from: defaults)
    }

    /// The two process-lifecycle verbs belong to whoever owns the process;
    /// an app refuses both.
    @ObservationIgnored public var onSetProvider: ((String) -> ControlReply)?
    @ObservationIgnored public var onShutdown: (() -> ControlReply)?
    @ObservationIgnored public var onLog: ((String) -> Void)?

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let serviceFactory: ((Profile) -> UsageService?)?
    @ObservationIgnored private let systemAccent: RGBColor?
    @ObservationIgnored private let gateSeeds: [String: Date]
    @ObservationIgnored private let publisher: StatePublisher
    @ObservationIgnored private var sections: [String: LiveState] = [:]
    @ObservationIgnored private var revivalWatchers: [String: AgentActivityWatcher] = [:]
    @ObservationIgnored private var socket: ControlSocket?
    @ObservationIgnored private var networkMonitor: NetworkMonitor?
    @ObservationIgnored private var reprobeTimer: Timer?
    @ObservationIgnored var updateChecker: UpdateChecker?
    @ObservationIgnored private var focusHeld = false
    @ObservationIgnored private var nextReprobeAt: Date?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored var isShutDown = false
    @ObservationIgnored private var isReprobing = false

    /// One harness, the way every host built this before several were
    /// metered at once.
    public convenience init(
        provider: any UsageProvider, defaults: UserDefaults, configuration: Configuration,
        serviceFactory: ((Profile) -> UsageService?)? = nil,
        gateSeeds: [String: Date] = [:], systemAccent: RGBColor? = nil
    ) {
        self.init(
            providers: [provider], defaults: defaults, configuration: configuration,
            serviceFactory: serviceFactory, gateSeeds: gateSeeds, systemAccent: systemAccent)
    }

    /// `gateSeeds` are the previous host's per-account fetch stamps
    /// (`LiveState.gateSeeds()`, keyed by `ProfileKey`), so a handover never
    /// double-polls inside the floor. `serviceFactory` injects stubbed usage
    /// services per account (tests); nil builds the real pipeline against
    /// each home's own credential chain.
    public init(
        providers: [any UsageProvider], defaults: UserDefaults, configuration: Configuration,
        serviceFactory: ((Profile) -> UsageService?)? = nil,
        gateSeeds: [String: Date] = [:], systemAccent: RGBColor? = nil
    ) {
        precondition(!providers.isEmpty, "a host meters at least one harness")
        self.providers = providers
        self.defaults = defaults
        self.configuration = configuration
        self.serviceFactory = serviceFactory
        self.gateSeeds = gateSeeds
        self.systemAccent = systemAccent
        self.serviceRegistry = ProviderServicesRegistry(
            bundleID: configuration.bundleID, roots: configuration.roots,
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
        serviceRegistry.onChange = { [weak self] in self?.republish() }
        serviceRegistry.start()
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
        probePresence(stored: ProfileStore.load(from: defaults))
        loadProfiles()
        probeSynchronously(profiles.filter(\.isEnrolled))
        recomputeDormancy(now: Date())
        reconcileEngines(staggered: true)
        _ = recomputeFocus()
        dismissAnsweredOffers()
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
        serviceRegistry.stop()
    }

    /// The host process's wake impulse: every engine polls (gate-ruled),
    /// every harness's status and history read once, the release check
    /// pokes, and a reprobe follows — a lid closed for a week is exactly
    /// when presence, dormancy and focus need re-reading.
    public func noteWake() {
        guard isStarted, !isShutDown else { return }
        for engine in engines.values { engine.noteWake() }
        serviceRegistry.noteWake()
        updateChecker?.pokeIfStale()
        reprobe()
    }

    /// While the panel is open focus stays put; a switch decided meanwhile
    /// applies on release.
    public func holdFocus(_ held: Bool) {
        focusHeld = held
        if !held, recomputeFocus() { republish() }
    }

    // MARK: - Harnesses and accounts

    /// The record list, the hidden set or presence changed (Settings, a
    /// socket verb, another process): re-read them and reconcile — new
    /// engines start, removed or disabled ones stop, focus re-resolves.
    public func reloadProfiles() {
        loadProfiles()
        let unprobed = enrolledProfiles.filter {
            lastActivity[$0.key] == nil && identities[$0.key] == nil
        }
        probeSynchronously(unprobed)
        recomputeDormancy(now: Date())
        reconcileEngines()
        _ = recomputeFocus()
        dismissAnsweredOffers()
        republish()
    }

    /// Show or hide a harness. Hiding is DISPLAY ONLY (user-decided): the
    /// engines keep running, the forecasts keep learning, the rates keep
    /// listing — the bar loses its cells and focus passes it by. The last
    /// shown harness can't be hidden; there would be nothing to look at.
    @discardableResult
    public func setHarnessShown(id: String, shown: Bool) -> Bool {
        guard roster.row(id) != nil else { return false }
        guard shown || roster.canHide(id) else { return false }
        var hidden = HarnessRoster.hidden(from: defaults)
        if shown { hidden.remove(id) } else { hidden.insert(id) }
        HarnessRoster.setHidden(hidden, in: defaults)
        reloadProfiles()
        return true
    }

    /// An enrolled home answers its own offer — the row leaves the panel,
    /// whichever process enrolled it and whenever the ledger learns.
    private func dismissAnsweredOffers() {
        for row in roster.rows {
            let answered = row.profiles
                .filter(\.isEnrolled)
                .map { Notice.profileFoundID(profileID: $0.id) }
            guard !answered.isEmpty else { continue }
            serviceRegistry.services(for: row.provider).notices.mutate { ledger in
                var changed = false
                for id in answered { changed = ledger.dismiss(id: id) || changed }
                return changed
            }
        }
    }

    /// Pin the focus (nil = follow activity again). A pin is the person's
    /// own choice, so it lands even while the panel holds focus — the hold
    /// exists to keep ACTIVITY from swapping the panel out from under the
    /// pointer, never to defer a click (0.97.0, user-reported: the strip's
    /// pick reverted the moment the panel closed).
    public func setPin(_ id: String?) {
        ProfileStore.setPin(id, in: defaults)
        pin = id
        if recomputeFocus(overridingHold: true) { republish() }
    }

    public func setProfileEnabled(id: String, enabled: Bool) {
        guard let record = roster.profile(key: id) else { return }
        var stored = ProfileStore.load(from: defaults)
        if let index = stored.firstIndex(where: {
            $0.id == record.id && $0.providerID == record.providerID
        }) {
            stored[index].enabled = enabled
        } else {
            var copy = record
            copy.enabled = enabled
            stored.append(copy)
        }
        ProfileStore.save(stored, to: defaults)
        reloadProfiles()
    }

    private func probePresence(stored: [Profile]) {
        present.formUnion(HarnessPresence.probe(
            providers: providers, stored: stored, bundleID: configuration.bundleID,
            roots: configuration.roots))
    }

    private func loadProfiles() {
        let stored = ProfileStore.load(from: defaults)
        hidden = HarnessRoster.hidden(from: defaults)
        roster = HarnessRoster.build(
            providers: providers, present: present, stored: stored, hidden: hidden, now: Date())
        for row in roster.rows { serviceRegistry.services(for: row.provider) }
        profiles = roster.profiles
        pin = ProfileStore.pin(from: defaults)
    }

    /// This account's harness, as the roster holds it.
    func harnessProvider(_ providerID: String) -> any UsageProvider {
        roster.row(providerID)?.provider
            ?? providers.first { $0.id == providerID }
            ?? providers[0]
    }

    /// The harness retargeted at an account's home; a standard home keeps
    /// the host's own instance (and any injected client).
    private func provider(for profile: Profile) -> any UsageProvider {
        let base = harnessProvider(profile.providerID)
        if profile.isDefault { return base }
        return profile.home.map { base.withHome($0) } ?? base
    }

    private func profileDirectory(_ profile: Profile) -> URL {
        StorageScope.supportDirectory(
            bundleID: configuration.bundleID, providerID: profile.providerID,
            profileID: profile.id, roots: configuration.roots)
    }

    // MARK: - Engines

    private func reconcileEngines(staggered: Bool = false) {
        let wanted = enrolledProfiles.filter { $0.enabled && !dormant.contains($0.key) }
        let wantedKeys = Set(wanted.map(\.key))
        for (key, engine) in engines where !wantedKeys.contains(key) {
            engine.shutdown()
            engines[key] = nil
            sections[key] = nil
            log("stopped: \(key)")
        }
        let missing = wanted.filter { engines[$0.key] == nil }
        for (index, profile) in missing.enumerated() {
            let delay = staggered && missing.count > 1
                ? Double(index) * configuration.stagger / Double(missing.count) : 0
            startEngine(for: profile, launchDelay: delay)
        }
        for profile in enrolledProfiles {
            let key = profile.key
            let needsWatcher = profile.enabled && dormant.contains(key)
            if needsWatcher, revivalWatchers[key] == nil {
                let directories = provider(for: profile)
                    .makeLocalActivity(cacheDirectory: profileDirectory(profile))?
                    .watchDirectories ?? []
                revivalWatchers[key] = AgentActivityWatcher(directories: directories) { [weak self] in
                    self?.revive(key)
                }
            } else if !needsWatcher {
                revivalWatchers[key] = nil
            }
        }
        let known = Set(profiles.map(\.key))
        for key in revivalWatchers.keys where !known.contains(key) { revivalWatchers[key] = nil }
    }

    private func startEngine(for profile: Profile, launchDelay: TimeInterval) {
        let key = profile.key
        let engine = UsageEngine(
            provider: provider(for: profile), profileID: profile.id,
            services: serviceRegistry.services(for: harnessProvider(profile.providerID)),
            service: serviceFactory?(profile), defaults: defaults,
            bundleID: configuration.bundleID, roots: configuration.roots,
            host: configuration.kind, gateSeed: gateSeeds[key], systemAccent: systemAccent,
            launchDelay: launchDelay
        ) { [weak self] state in
            self?.sink(key, state)
        }
        engine.onAgentActivity = { [weak self] at in self?.noteActivity(key, at: at) }
        engines[key] = engine
        log("engine: \(key)" + (launchDelay > 0 ? " (first poll in \(Int(launchDelay))s)" : ""))
    }

    private func sink(_ key: String, _ state: LiveState) {
        guard !isShutDown, engines[key] != nil else { return }
        sections[key] = state
        republish()
    }

    /// An engine's FSEvents push: the newest write is focus's tie-break
    /// (the window count that decides it refreshes on the next reprobe).
    private func noteActivity(_ key: String, at: Date) {
        if let known = lastActivity[key], known > at { return }
        lastActivity[key] = at
        if recomputeFocus() { republish() }
    }

    /// A dormant account's first write in a month: its engine comes back
    /// at once, no stagger.
    private func revive(_ key: String) {
        guard !isShutDown, dormant.contains(key) else { return }
        lastActivity[key] = Date()
        dormant.remove(key)
        revivalWatchers[key] = nil
        log("revived: \(key)")
        reconcileEngines()
        _ = recomputeFocus()
        republish()
    }

    // MARK: - Focus and dormancy (D9)

    @discardableResult
    private func recomputeFocus(overridingHold: Bool = false) -> Bool {
        let candidates = roster.rows.map { row -> HarnessFocusCandidate in
            let accounts = row.profiles.filter(\.isEnrolled).map { profile in
                FocusCandidate(
                    id: profile.key, order: profile.order,
                    recentActivity: recentActivity[profile.key] ?? 0,
                    lastActivity: lastActivity[profile.key],
                    eligible: profile.enabled && !dormant.contains(profile.key),
                    shown: profile.showInMenuBar)
            }
            let days = accounts.filter(\.eligible).reduce(into: Set<Date>()) { union, account in
                union.formUnion(activeDays[account.id] ?? [])
            }
            return HarnessFocusCandidate(
                id: row.id, shown: row.shown, activeDays: days.count,
                lastActivity: accounts.compactMap(\.lastActivity).max(), accounts: accounts)
        }
        let next = HarnessFocusRule.focused(candidates, pin: pin, current: focusedProfileID)
        guard next != focusedProfileID, !focusHeld || overridingHold else { return false }
        focusedProfileID = next
        let window = Int(ProfileActivity.window / 86400)
        let files = candidates.flatMap(\.accounts)
            .map { "\($0.id) \($0.recentActivity)" }.joined(separator: ", ")
        let days = candidates.count > 1
            ? "; days in \(window)d: " + candidates.map { "\($0.id) \($0.activeDays)" }
                .joined(separator: ", ")
            : ""
        log("focus → \(next ?? "none") (files in \(window)d: \(files)\(days))")
        return true
    }

    /// A synthesized default record's enrolment stamp is "now" every time it
    /// is resolved, so it must not feed the dormancy reference — otherwise a
    /// harness nobody has touched in months would look freshly enrolled and
    /// hold a cell forever ("I've not been using Codex for months; there's
    /// no point showing it"). A STORED record's stamp is a fact and counts.
    private func recomputeDormancy(now: Date) {
        var fresh: Set<String> = []
        for profile in enrolledProfiles {
            let synthesized = profile.isDefault
                && roster.row(profile.providerID)?.synthesizedDefault == true
            guard Dormancy.isDormant(
                lastActivity: lastActivity[profile.key],
                addedAt: synthesized ? nil : profile.addedAt, now: now)
            else { continue }
            fresh.insert(profile.key)
        }
        for key in fresh.subtracting(dormant) { log("dormant: \(key)") }
        for key in dormant.subtracting(fresh) { log("awake: \(key)") }
        dormant = fresh
    }

    private func probeSynchronously(_ targets: [Profile]) {
        let now = Date()
        for profile in targets {
            apply(ProfileActivity.probe(
                provider: provider(for: profile), cacheDirectory: profileDirectory(profile), now: now),
                to: profile.key)
        }
    }

    private func apply(_ probe: ProfileProbe, to key: String) {
        if let seen = probe.lastActivityAt, lastActivity[key].map({ seen > $0 }) ?? true {
            lastActivity[key] = seen
        }
        recentActivity[key] = probe.recentFiles
        activeDays[key] = probe.activeDays
        identities[key] = probe.identity
    }

    private func scheduleReprobe() {
        let interval = configuration.reprobeInterval
        nextReprobeAt = Date().addingTimeInterval(interval)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.nextReprobeAt = Date().addingTimeInterval(interval)
                self.reprobe()
            }
        }
        timer.tolerance = min(60, interval / 10)
        reprobeTimer = timer
    }

    /// Off-main: which harnesses are on disk, and the identity records and
    /// session mtimes of every metered account. Then dormancy transitions,
    /// engine reconciliation, focus, discovery, and a republish so the
    /// digest's strip reads fresh. A harness installed since the last pass
    /// joins here — within one reprobe, with no restart.
    public func reprobe() {
        guard isStarted, !isShutDown, !isReprobing else { return }
        isReprobing = true
        let targets = enrolledProfiles.map { ($0.key, provider(for: $0), profileDirectory($0)) }
        let providers = providers
        let stored = ProfileStore.load(from: defaults)
        let configuration = configuration
        Task.detached(priority: .utility) { [weak self] in
            let now = Date()
            let seen = HarnessPresence.probe(
                providers: providers, stored: stored, bundleID: configuration.bundleID,
                roots: configuration.roots)
            let probes = targets.map { key, provider, directory in
                (key, ProfileActivity.probe(provider: provider, cacheDirectory: directory, now: now))
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReprobing = false
                guard !self.isShutDown else { return }
                for (key, probe) in probes { self.apply(probe, to: key) }
                if !seen.isSubset(of: self.present) {
                    self.present.formUnion(seen)
                    self.loadProfiles()
                    self.probeSynchronously(self.enrolledProfiles.filter {
                        self.lastActivity[$0.key] == nil && self.identities[$0.key] == nil
                    })
                    self.log("harnesses: \(self.roster.rows.map(\.id).joined(separator: ", "))")
                }
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
        let configuration = configuration
        for row in roster.rows where row.provider.supportsMultipleHomes {
            let provider = row.provider
            let known = row.profiles
            Task.detached(priority: .utility) { [weak self] in
                let found = ProfileDiscovery.discover(
                    provider: provider, known: known, bundleID: configuration.bundleID,
                    roots: configuration.roots, now: Date(), userHome: configuration.userHome)
                await MainActor.run { [weak self] in
                    guard let self, !self.isShutDown else { return }
                    self.discoveredByHarness[provider.id] = found
                    let offers = ProfileDiscovery.offers(found, providerID: provider.id, now: Date())
                    guard !offers.isEmpty else { return }
                    self.serviceRegistry.services(for: provider).notices.mutate { ledger in
                        var changed = false
                        for offer in offers { changed = ledger.record(offer) || changed }
                        return changed
                    }
                }
            }
        }
    }

    /// A dismissed offer is remembered as an ignored record: silent until
    /// the home's sign-in changes.
    func ignore(_ home: DiscoveredHome, providerID: String) {
        var stored = ProfileStore.load(from: defaults)
        guard !stored.contains(where: { $0.id == home.profileID && $0.providerID == providerID })
        else { return }
        stored.append(Profile(
            id: home.profileID, providerID: providerID, home: home.home, enabled: false,
            showInMenuBar: false, order: (stored.map(\.order).max() ?? 0) + 1, addedAt: Date(),
            ignoredIdentityKey: home.identity?.key ?? ""))
        ProfileStore.save(stored, to: defaults)
        loadProfiles()
        log("ignored: \(home.displayPath)")
    }

    // MARK: - Digest

    func republish(now: Date = Date()) {
        guard isStarted, !isShutDown else { return }
        let sectionList = enrolledProfiles.map { profile -> ProfileSection in
            let key = profile.key
            let label = ProfileFacts.label(
                profile: profile, identity: identities[key],
                fallback: harnessProvider(profile.providerID).agentName)
            return ProfileSection(
                profile: profile, label: label,
                monogram: ProfileFacts.monogram(profile: profile, label: label),
                dormant: dormant.contains(key), lastActivityAt: lastActivity[key],
                homeDisplayPath: profile.displayHome(relativeTo: configuration.userHome),
                state: engines[key] != nil ? sections[key] : nil)
        }
        let harnessList = roster.rows.map { row -> HarnessSection in
            let services = serviceRegistry.services(for: row.provider)
            let keys = row.profiles.filter(\.isEnrolled).map(\.key)
            let days = keys.reduce(into: Set<Date>()) { union, key in
                union.formUnion(activeDays[key] ?? [])
            }
            return HarnessSection(
                provider: row.provider, present: row.present, shown: row.shown,
                recentFiles: keys.compactMap { recentActivity[$0] }.reduce(0, +),
                activeDays: days.count,
                serviceStatus: services.serviceStatus, notices: services.notices.pending,
                outages: services.outageSpans(now: now))
        }
        let composed = MeteringDigest.compose(
            harnesses: harnessList, sections: sectionList, focused: focusedProfileID,
            pinned: pin, host: configuration.kind.rawValue,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            appVersion: AppIdentity.version, systemAccent: systemAccent,
            activeInterval: activeInterval, appUpdate: appUpdate,
            nextReprobeAt: nextReprobeAt, now: now)
        digest = composed
        notices = composed.notices
        outages = composed.outages ?? []
        publisher.publish(composed)
    }

    func log(_ message: String) {
        onLog?(message)
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
}
