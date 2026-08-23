import Foundation
import Observation

/// The metering orchestrator — every consumer surface's single source of
/// truth. Every trigger funnels through `refresh(_:)`, which owns
/// single-flighting, the 60-second gate, and the 429 backoff — one gate,
/// uniformly applied (spec §9).
///
/// Core so any host process can run it: the menu bar app embeds it behind
/// the `UsageStore` façade; `usaged` runs it as the launchd engine. Hosts
/// inject their `UserDefaults` domain — the app passes `.standard`, the
/// daemon the app's suite (same cfprefsd domain, different process) — and
/// forward their platform wake signal to `noteWake()`.
@MainActor
@Observable
public final class UsageEngine {
    public enum RefreshReason: String, Sendable {
        case launch, timer, wake, networkRestored, manual, activity
    }

    /// Which kind of process hosts the engine — stamped into the published
    /// digest so consumers (and the future host broker) can tell who is
    /// running the show.
    public enum Host: String, Sendable {
        case app, daemon
    }

    public private(set) var state: DisplayState = .loading
    public private(set) var isRefreshing = false
    /// Poll interval while the agent is actively in use — the user's setting.
    /// Quiet decays the real cadence from here (see `AdaptiveCadence`).
    public private(set) var activeInterval: TimeInterval
    public private(set) var nextRefreshAt: Date?
    public private(set) var samples: [UsageSample] = []
    /// Closed limit-window outcomes, oldest first — the audit views' record
    /// of what past windows reached (kept indefinitely, tiny).
    public private(set) var windowOutcomes: [WindowOutcome] = []
    public private(set) var predictions: [String: UsagePrediction] = [:]
    /// Each meter's learned hour-of-week rhythm, rebuilt from the sample
    /// history alongside predictions. Present even before it's ready — the
    /// readiness gate lives on the profile itself.
    public private(set) var profiles: [String: WeeklyProfile] = [:]
    public private(set) var activity: [DailyActivity] = []
    /// Recent per-minute, per-model transcript usage; feeds the per-meter
    /// window breakdown in the panel.
    public private(set) var tokenTimeline: [TokenSlot] = []
    /// Per-session rollups from the last transcript scan, newest activity
    /// first; feeds the Sessions window's sidebar.
    public private(set) var sessions: [SessionSummary] = []
    /// Best pricing table available (live feed, disk cache, or bundled).
    public private(set) var pricing: PricingTable
    public private(set) var isRefreshingPricing = false
    /// Last manual pricing-refresh failure; cleared on the next attempt.
    public private(set) var pricingRefreshError: String?
    /// The provider's service health, or nil when it declares no status feed
    /// (absent is not healthy — see `ServiceStatusCard`).
    public private(set) var serviceStatus: ServiceStatusCard?
    /// This app's newest published release, or nil when no updater runs
    /// (source-managed builds check nothing — see `AppUpdateCard`).
    public private(set) var appUpdate: AppUpdateCard?

    /// The one metered service this instance tracks. Everything
    /// vendor-specific — endpoints, paths, names, links — flows from here.
    public let provider: any UsageProvider
    /// The agent's on-disk traces, created once (scanners keep warm caches);
    /// nil when the provider's agent leaves nothing to scan.
    public let localActivity: (any LocalActivitySource)?
    /// The host's settings domain — every read and write goes here, never
    /// to an implicit `.standard` (the daemon has no standard domain worth
    /// sharing with the app).
    private let defaults: UserDefaults
    private let hostKind: Host
    /// The host Mac's control accent, injected by the host process (the app
    /// converts the live NSColor; usaged maps the AppleAccentColor global
    /// through `SystemAccentPalette`) — published so terminal clients tint
    /// normal-state fills like the app's own controls. Nil = provider accent.
    private let systemAccent: RGBColor?
    /// Publishes live-state.json after every landing point — consumer
    /// interfaces (the TUI, a client-mode app) render from that file.
    private let publisher: StatePublisher
    private let service: UsageService
    private let history: UsageHistory
    private let windowLedger: WindowLedger
    private let pricingService: PricingService
    private var gate: TriggerGate
    private let scheduler = Scheduler()
    private var cadence: AdaptiveCadence
    private var ledger: RequestLedger
    private var watcher: AgentActivityWatcher?
    /// Polls the provider's status page; nil when the provider declares no
    /// feed. Its cadence is entirely its own — status has nothing to do with
    /// the usage poll's gate, backoff, or activity signal.
    private var statusPoller: StatusPoller?
    /// Checks this app's own release feed; nil for source-managed builds
    /// and bare executables (`InstallKind`). App-scoped, so it neither
    /// rides the provider seam nor cares which harness is metered.
    private var updateChecker: UpdateChecker?
    private var lastActivityScan: Date?
    /// Single-flight for transcript scans: a window-open force-scan must not
    /// overlap an FSEvents-triggered one — two concurrent scans race their
    /// MainActor assignments and can land stale-last.
    private var isScanningActivity = false
    private var lastPricingAttempt: Date?

    public static let defaultInterval: TimeInterval = 300
    private static let intervalKey = "refreshIntervalSeconds"
    public static let warningThresholdKey = "warningThresholdPercent"
    public static let criticalThresholdKey = "criticalThresholdPercent"
    /// The learned endpoint budget is a fact about THIS provider's API, so
    /// its defaults key carries the provider id ("claude.apiHourlyCeiling").
    private let ceilingKey: String
    /// True once `shutdown()` ran — a retired engine (the registry switched
    /// providers, or the app yielded to the daemon) must never reschedule,
    /// rescan, or render again.
    public private(set) var isShutDown = false
    /// A provider with no network destinations reads usage from local files:
    /// no request ledger to fill, no API budget to render, and a manual
    /// refresh is just a disk rescan the trigger gate needn't ration.
    public var isLocalProvider: Bool { provider.networkDestinations.isEmpty }
    /// Gates the Sessions window and its menu item: "none yet" is an empty
    /// state, "never" hides the feature.
    public var providesSessions: Bool { localActivity?.providesSessions ?? false }

    public init(
        provider: any UsageProvider = ClaudeProvider(),
        service: UsageService? = nil,
        defaults: UserDefaults = .standard,
        bundleID: String? = nil,
        host: Host = .app,
        gateSeed: Date? = nil,
        systemAccent: RGBColor? = nil
    ) {
        let bundleID = bundleID ?? Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage"
        let support = StorageScope.supportDirectory(bundleID: bundleID, providerID: provider.id)
        let caches = StorageScope.cachesDirectory(bundleID: bundleID, providerID: provider.id)
        self.provider = provider
        self.defaults = defaults
        self.hostKind = host
        self.systemAccent = systemAccent
        // A host taking over from a dead one seeds the gate with the old
        // host's last fetch (the digest's stamp) — a handover must never
        // double-poll inside the floor.
        self.gate = TriggerGate(lastAllowed: gateSeed)
        self.publisher = StatePublisher(fileURL: LiveState.fileURL(bundleID: bundleID))
        self.localActivity = provider.makeLocalActivity(cacheDirectory: support)
        self.service = service
            ?? UsageService(provider: provider, cache: UsageCache(directory: caches))
        self.history = UsageHistory(directory: support)
        self.windowLedger = WindowLedger(directory: support)
        self.pricingService = PricingService(
            cacheDirectory: support, fallback: provider.bundledRates,
            selector: provider.pricingSelector)
        self.pricing = pricingService.current()
        let stored = defaults.double(forKey: Self.intervalKey)
        // Stored 60s choices predate the 180s floor — clamp, don't honor.
        let interval = stored >= 60 ? max(TriggerGate.floor, stored) : Self.defaultInterval
        self.activeInterval = interval
        self.cadence = AdaptiveCadence(activeInterval: interval, now: Date())
        self.ceilingKey = StorageScope.scopedKey("apiHourlyCeiling", providerID: provider.id)
        let storedCeiling = defaults.integer(forKey: ceilingKey)
        self.ledger = RequestLedger(
            ceiling: storedCeiling > 0 ? storedCeiling : RequestLedger.defaultCeiling)
        self.samples = history.load()
        self.windowOutcomes = windowLedger.load()

        scheduler.onTrigger = { [weak self] reason in
            self?.refresh(reason)
        }
        scheduler.start()
        // The agent writing a transcript is the push signal that the service
        // is in use. When its directories don't exist (the agent never ran
        // on this machine) the pull signal — percentages moving between
        // polls — still drives the cadence.
        watcher = AgentActivityWatcher(
            directories: localActivity?.watchDirectories ?? []
        ) { [weak self] in
            self?.noteLocalAgentActivity()
        }
        if case .statuspage(let base, let pageURL) = provider.statusFeed {
            let poller = StatusPoller(
                feed: StatuspageFeed(base: base), providerID: provider.id,
                pageURL: pageURL.absoluteString)
            poller.onCard = { [weak self] card in
                guard let self, !self.isShutDown else { return }
                self.serviceStatus = card
                // A card change is a landing point like any other — consumers
                // learn about an incident from the digest, not from polling.
                self.publishState()
            }
            statusPoller = poller
            poller.start()
        }
        let installKind = InstallKind.detect(bundleURL: Bundle.main.bundleURL)
        let feedOverride = defaults.string(forKey: UpdateChecker.feedOverrideKey)
            .flatMap(URL.init(string:))
        if installKind == .standaloneApp || feedOverride != nil {
            let checker = UpdateChecker(
                feed: UpdateFeed(
                    latestReleaseURL: feedOverride
                        ?? UpdateFeed.latestURL(repository: AppIdentity.repository)),
                currentVersion: AppIdentity.version, defaults: defaults)
            checker.onCard = { [weak self] card in
                guard let self, !self.isShutDown else { return }
                self.appUpdate = card
                self.publishState()
            }
            updateChecker = checker
            checker.start()
        }
        refresh(.launch)
        // A seeded gate can deny that launch poll (the previous host
        // fetched moments ago — a takeover inside the floor; isRefreshing
        // stays false on the denied path). The cache holds that same
        // fetch: present it as live rather than a loading shell — the
        // already-scheduled poll replaces it soon enough.
        if !isRefreshing, case .loading = state,
           let snapshot = self.service.cachedSnapshot(thresholds: currentThresholds()) {
            state = .live(snapshot)
            recomputePredictions(for: snapshot)
        }
        scanActivity()
    }

    /// Retires this engine: stops the scheduler's event sources and the
    /// FSEvents watcher so a replaced engine leaks nothing. An in-flight
    /// refresh may still land — the flag keeps its completion from
    /// rescheduling.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        scheduler.stop()
        watcher = nil
        statusPoller?.stop()
        statusPoller = nil
        updateChecker?.stop()
        updateChecker = nil
        nextRefreshAt = nil
    }

    /// A wake impulse from the host process — the app's NSWorkspace
    /// observer, the daemon's IOKit power callback. Stale numbers after
    /// lid-open are what make these widgets feel broken (spec §9) — and a
    /// status card from before the lid closed is stale in exactly the same
    /// way, so both refresh here.
    public func noteWake() {
        refresh(.wake)
        statusPoller?.pollNow()
        updateChecker?.pokeIfStale()
    }

    /// An out-of-band status read — the control socket's `refreshStatus`,
    /// which the app fires when a panel opens on an aging card. Rationed by
    /// the feed's own CDN spacing, so poking is always safe.
    public func refreshServiceStatus() {
        statusPoller?.pollNow()
    }

    /// A user-asked release check — Settings' "Check Now", the control
    /// socket's `checkUpdates`. Floor-gated in the checker, so clicking in
    /// a loop can't turn into a hot loop against GitHub.
    public func checkForUpdates() {
        updateChecker?.checkNow()
    }

    public func refresh(_ reason: RefreshReason) {
        guard !isShutDown else { return }
        let now = Date()
        // Automatic triggers sit out an active 429 backoff. A human clicking
        // refresh may try early — another 429 just extends the backoff.
        if reason != .manual, cadence.isBackingOff(now: now) {
            ensureScheduled(now: now)
            return
        }
        let bypassGate = reason == .manual && isLocalProvider
        guard !isRefreshing, bypassGate || gate.shouldAllow(at: now) else {
            // Scheduling is one-shot: a denied trigger must still leave a
            // live timer behind, or the cadence dies here.
            ensureScheduled(now: now)
            return
        }
        isRefreshing = true
        if !isLocalProvider {
            ledger.recordRequest(at: now)
        }
        Task {
            let previous = state.snapshot
            let newState = await service.refresh(thresholds: currentThresholds())
            state = newState
            isRefreshing = false
            noteOutcome(newState, previous: previous)
            scheduleNext()
            if case .live(let snapshot) = newState {
                // Close-out first, against the samples as they stood while
                // the old window ran; the roll is detected by comparing the
                // last snapshot (live or cached — both are observations)
                // with this one.
                if let previousMeters = previous?.meters {
                    let closed = WindowLedger.closedWindows(
                        previous: previousMeters, current: snapshot.meters,
                        samples: samples, now: Date())
                    if !closed.isEmpty {
                        windowOutcomes = windowLedger.record(
                            closed, existing: windowOutcomes)
                    }
                }
                samples = history.append(snapshot, existing: samples)
                recomputePredictions(for: snapshot)
            }
            // The heartbeat: every completed cycle rewrites the digest, so
            // its freshness IS the engine's liveness signal.
            publishState()
            await refreshPricingIfNeeded()
        }
    }

    /// Snapshots the whole renderable state into live-state.json. Cheap on
    /// the main actor (array mirrors and per-meter assembly over capped
    /// series); encoding and IO happen on the publisher's own queue.
    private func publishState(now: Date = Date()) {
        guard !isShutDown else { return }
        let grace = defaults.object(forKey: ActivityGrace.storageKey) == nil
            ? ActivityGrace.defaultSeconds
            : defaults.double(forKey: ActivityGrace.storageKey)
        let digest = LiveStateBuilder.build(
            provider: provider,
            host: hostKind.rawValue,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            appVersion: AppIdentity.version,
            state: state,
            predictions: predictions,
            weeklyProfile: weeklyProfile,
            samples: samples,
            timeline: tokenTimeline,
            activity: activity,
            sessions: sessions,
            pricing: pricing,
            colorLedger: ModelColorLedger.load(from: defaults, providerID: provider.id),
            graceSeconds: grace,
            activeInterval: activeInterval,
            paceMultiplier: paceMultiplier(now: now),
            nextPollAt: nextRefreshAt,
            backoffUntil: cadence.backoffUntil,
            apiBudget: isLocalProvider ? nil : apiBudget(now: now),
            systemAccent: systemAccent,
            serviceStatus: serviceStatus,
            appUpdate: appUpdate,
            now: now)
        publisher.publish(digest)
    }

    /// How close the last hour of requests is to the endpoint's estimated
    /// budget — the honesty gauge behind "refresh all you want".
    public func apiBudget(now: Date) -> (used: Int, ceiling: Int, fraction: Double) {
        (ledger.used(at: now), ledger.ceiling, ledger.pressure(at: now))
    }

    /// The user's warning/critical cutoffs read from a settings domain,
    /// defaults standing in for unset.
    public static func thresholds(from defaults: UserDefaults) -> Thresholds {
        let warning = defaults.integer(forKey: warningThresholdKey)
        let critical = defaults.integer(forKey: criticalThresholdKey)
        return Thresholds(
            warningPercent: warning > 0 ? warning : Thresholds.standard.warningPercent,
            criticalPercent: critical > 0 ? critical : Thresholds.standard.criticalPercent)
    }

    private func currentThresholds() -> Thresholds {
        Self.thresholds(from: defaults)
    }

    /// Re-classifies what's on screen right after a threshold edit — the
    /// next poll would agree anyway; this makes the settings slider live.
    public func thresholdsChanged() {
        let thresholds = currentThresholds()
        switch state {
        case .live(let snapshot):
            state = .live(snapshot.rebuilt(thresholds: thresholds))
        case .cached(let snapshot, let error):
            state = .cached(snapshot.rebuilt(thresholds: thresholds), error: error)
        case .loading, .unavailable:
            break
        }
        publishState()
    }

    /// Piggybacks on usage refreshes: at most one feed fetch attempt per
    /// hour, and only while the table is older than a day (or bundled).
    private func refreshPricingIfNeeded() async {
        let now = Date()
        guard pricing.isStale(now: now) else { return }
        if let last = lastPricingAttempt, now.timeIntervalSince(last) < 3600 { return }
        lastPricingAttempt = now
        if let fresh = await pricingService.refreshIfStale(now: now) {
            pricing = fresh
            publishState()
        }
    }

    /// The settings screen's refresh button — always fetches (the automatic
    /// path above stays daily). Single-flighted; failure text lands beside
    /// the button instead of in a log nobody reads.
    public func refreshPricingNow() {
        guard !isRefreshingPricing else { return }
        isRefreshingPricing = true
        pricingRefreshError = nil
        Task {
            do {
                pricing = try await pricingService.refreshNow()
                publishState()
            } catch let error as PricingFeedError {
                pricingRefreshError = error.shortText
            } catch {
                pricingRefreshError = "unexpected error"
            }
            isRefreshingPricing = false
        }
    }

    /// The FSEvents watcher saw the agent write a transcript: snap the
    /// cadence back to the active pace, and fetch now whenever the displayed
    /// data is older than that pace, so re-engaging always catches the meters
    /// up promptly — even when a background agent session kept the evidence
    /// warm the whole time.
    func noteLocalAgentActivity() {
        let now = Date()
        cadence.noteActivity(at: now)
        scanActivity() // transcripts changed; the heatmap follows (1/min throttle)
        guard !cadence.isBackingOff(now: now) else { return }
        let dataAge = state.snapshot.map { now.timeIntervalSince($0.fetchedAt) }
        if cadence.shouldPollOnActivity(dataAge: dataAge, now: now) {
            refresh(.activity)
        }
        // Whether or not that ran (it may be gate-denied), align the pending
        // fire with the now-active pace; a completed refresh reschedules again.
        if let next = scheduler.nextFireDate,
           next.timeIntervalSince(now) > cadence.interval(now: now) + 1 {
            scheduleNext()
        }
    }

    /// 1 at the user-chosen pace; 2/4/8 once quiet has decayed the cadence.
    public func paceMultiplier(now: Date) -> Int {
        cadence.isBackingOff(now: now) ? 1 : cadence.multiplier(now: now)
    }

    /// Re-scans the agent's transcripts + prompt history for the heatmap,
    /// at most once a minute. A provider without local traces has nothing
    /// to scan — the activity section shows its empty state.
    public func scanActivity(force: Bool = false) {
        guard !isShutDown, !isScanningActivity, let source = localActivity else { return }
        if !force, let last = lastActivityScan, Date().timeIntervalSince(last) < 60 { return }
        lastActivityScan = Date()
        isScanningActivity = true
        Task.detached(priority: .utility) { [weak self] in
            let scan = source.scanTranscripts(now: Date())
            let activity = ActivityMerge.merge(
                transcripts: scan.daily, prompts: source.scanPromptDays())
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activity = activity
                self.tokenTimeline = scan.timeline
                // Seed the persistent model-color ledger in overall usage
                // order, so first-ever assignment doesn't depend on which
                // chart happens to render first.
                var totals: [String: Int] = [:]
                for day in activity {
                    for (model, tally) in day.models {
                        totals[model, default: 0] += tally.total
                    }
                }
                ModelColorLedger.grow(
                    totals.sorted { $0.value > $1.value }.map(\.key)
                        .map { ($0, self.provider.modelCatalog.familyName($0)) },
                    defaults: self.defaults, providerID: self.provider.id)
                // After the seed, so no render observes sessions first.
                self.sessions = scan.sessions
                self.isScanningActivity = false
                self.publishState()
            }
        }
    }

    /// Parses one session in full, off-main. Cancellation propagates into
    /// the parse (SwiftUI cancels its `.task` on selection change — rapid
    /// sidebar clicking must not stack concurrent multi-MB parses).
    public func sessionDetail(id: String) async -> SessionDetail? {
        guard !isShutDown, let source = localActivity, source.providesSessions
        else { return nil }
        let work = Task.detached(priority: .userInitiated) {
            source.sessionDetail(id: id)
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Feeds the poll result into the cadence: success heals any backoff and
    /// rising percentages count as activity; a 429 starts/extends the backoff.
    /// Other failures leave the cadence alone — transport errors already get
    /// one retry in the service, and network-restore triggers a fresh poll.
    private func noteOutcome(_ newState: DisplayState, previous: Snapshot?) {
        let now = Date()
        if case .rateLimited(let retryAfter) = newState.error {
            cadence.noteRateLimited(retryAfter: retryAfter, at: now)
            // The 429 just showed us the window's real budget — remember it.
            ledger.noteRateLimited(at: now)
            defaults.set(ledger.ceiling, forKey: ceilingKey)
        } else if case .live(let snapshot) = newState {
            cadence.noteSuccess(
                usageAdvanced: UsageMovement.advanced(from: previous, to: snapshot), at: now)
        }
    }

    private func scheduleNext() {
        guard !isShutDown else { return }
        scheduler.schedule(after: cadence.interval(now: Date()))
        nextRefreshAt = scheduler.nextFireDate
    }

    private func ensureScheduled(now: Date) {
        if let next = scheduler.nextFireDate, next > now { return }
        scheduleNext()
    }

    /// Rebuilds profiles and predictions off-main: walking two months of
    /// samples per meter is a few tens of milliseconds — background work,
    /// not click-handler work. Refreshes are single-flighted, so runs
    /// can't interleave.
    private func recomputePredictions(for snapshot: Snapshot) {
        let now = Date()
        let samples = self.samples
        let previous = self.predictions
        let meters = snapshot.meters
        Task.detached(priority: .utility) { [weak self] in
            var profiles: [String: WeeklyProfile] = [:]
            var fresh: [String: UsagePrediction] = [:]
            for meter in meters {
                let profile = WeeklyProfile.build(samples: samples, label: meter.label)
                if let profile { profiles[meter.label] = profile }
                if let prediction = PredictionEngine.predict(
                    meter: meter, samples: samples, profile: profile,
                    previous: previous[meter.label], now: now) {
                    fresh[meter.label] = prediction
                }
            }
            await MainActor.run { [profiles, fresh] in
                guard let self else { return }
                self.profiles = profiles
                self.predictions = fresh
                self.publishState()
            }
        }
    }

    /// The overall weekly meter's rhythm — the activity chart's typical-week
    /// overlay and the settings insights read this one profile.
    public var weeklyProfile: WeeklyProfile? {
        guard let meters = state.snapshot?.meters else { return nil }
        let weekly = meters.first { $0.rank == 1 } ?? meters.first { $0.rank > 0 }
        return weekly.flatMap { profiles[$0.label] }
    }

    /// Where the sample history lives on disk — the settings readout stats it.
    public var historyFileURL: URL { history.fileURL }

    public func setActiveInterval(_ interval: TimeInterval) {
        let clamped = min(max(TriggerGate.floor, interval), AdaptiveCadence.maxActiveInterval)
        activeInterval = clamped
        cadence.activeInterval = clamped
        defaults.set(clamped, forKey: Self.intervalKey)
        scheduleNext()
        publishState()
    }
}
