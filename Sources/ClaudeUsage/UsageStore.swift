import Foundation
import Observation
import UsageCore

/// The app's single source of truth. Every trigger funnels through
/// `refresh(_:)`, which owns single-flighting, the 60-second gate, and the
/// 429 backoff — one gate, uniformly applied (spec §9).
@MainActor
@Observable
final class UsageStore {
    enum RefreshReason: String {
        case launch, timer, wake, networkRestored, manual, activity
    }

    private(set) var state: DisplayState = .loading
    private(set) var isRefreshing = false
    /// Poll interval while Claude is actively in use — the user's setting.
    /// Quiet decays the real cadence from here (see `AdaptiveCadence`).
    private(set) var activeInterval: TimeInterval
    private(set) var nextRefreshAt: Date?
    private(set) var samples: [UsageSample] = []
    private(set) var predictions: [String: UsagePrediction] = [:]
    /// Each meter's learned hour-of-week rhythm, rebuilt from the sample
    /// history alongside predictions. Present even before it's ready — the
    /// readiness gate lives on the profile itself.
    private(set) var profiles: [String: WeeklyProfile] = [:]
    private(set) var activity: [DailyActivity] = []
    /// Recent per-minute, per-model transcript usage; feeds the per-meter
    /// window breakdown in the panel.
    private(set) var tokenTimeline: [TokenSlot] = []
    /// Best pricing table available (live feed, disk cache, or bundled).
    private(set) var pricing: PricingTable
    private(set) var isRefreshingPricing = false
    /// Last manual pricing-refresh failure; cleared on the next attempt.
    private(set) var pricingRefreshError: String?

    /// The one metered service this instance tracks. Everything
    /// vendor-specific — endpoints, paths, names, links — flows from here.
    let provider: any UsageProvider
    /// The agent's on-disk traces, created once (scanners keep warm caches);
    /// nil when the provider's agent leaves nothing to scan.
    let localActivity: (any LocalActivitySource)?
    private let service: UsageService
    private let history: UsageHistory
    private let pricingService: PricingService
    private var gate = TriggerGate()
    private let scheduler = Scheduler()
    private var cadence: AdaptiveCadence
    private var ledger: RequestLedger
    private var watcher: AgentActivityWatcher?
    private var lastActivityScan: Date?
    private var lastPricingAttempt: Date?

    static let defaultInterval: TimeInterval = 300
    private static let intervalKey = "refreshIntervalSeconds"
    static let warningThresholdKey = "warningThresholdPercent"
    static let criticalThresholdKey = "criticalThresholdPercent"
    /// The learned endpoint budget is a fact about THIS provider's API, so
    /// its defaults key carries the provider id ("claude.apiHourlyCeiling").
    private let ceilingKey: String
    /// True once `shutdown()` ran — a retired store (the registry switched
    /// providers) must never reschedule, rescan, or render again.
    private(set) var isShutDown = false

    init(provider: any UsageProvider = ClaudeProvider(), service: UsageService? = nil) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage"
        let support = StorageScope.supportDirectory(bundleID: bundleID, providerID: provider.id)
        let caches = StorageScope.cachesDirectory(bundleID: bundleID, providerID: provider.id)
        self.provider = provider
        self.localActivity = provider.makeLocalActivity(cacheDirectory: support)
        self.service = service
            ?? UsageService(provider: provider, cache: UsageCache(directory: caches))
        self.history = UsageHistory(directory: support)
        self.pricingService = PricingService(
            cacheDirectory: support, fallback: provider.bundledRates)
        self.pricing = pricingService.current()
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        // Stored 60s choices predate the 180s floor — clamp, don't honor.
        let interval = stored >= 60 ? max(TriggerGate.floor, stored) : Self.defaultInterval
        self.activeInterval = interval
        self.cadence = AdaptiveCadence(activeInterval: interval, now: Date())
        self.ceilingKey = StorageScope.scopedKey("apiHourlyCeiling", providerID: provider.id)
        let storedCeiling = UserDefaults.standard.integer(forKey: ceilingKey)
        self.ledger = RequestLedger(
            ceiling: storedCeiling > 0 ? storedCeiling : RequestLedger.defaultCeiling)
        self.samples = history.load()

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
        refresh(.launch)
        scanActivity()
    }

    /// Retires this store: stops the scheduler's event sources and the
    /// FSEvents watcher so a replaced provider's store leaks nothing. An
    /// in-flight refresh may still land — the flag keeps its completion
    /// from rescheduling.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        scheduler.stop()
        watcher = nil
        nextRefreshAt = nil
    }

    func refresh(_ reason: RefreshReason) {
        guard !isShutDown else { return }
        let now = Date()
        // Automatic triggers sit out an active 429 backoff. A human clicking
        // refresh may try early — another 429 just extends the backoff.
        if reason != .manual, cadence.isBackingOff(now: now) {
            ensureScheduled(now: now)
            return
        }
        guard !isRefreshing, gate.shouldAllow(at: now) else {
            // Scheduling is one-shot: a denied trigger must still leave a
            // live timer behind, or the cadence dies here.
            ensureScheduled(now: now)
            return
        }
        isRefreshing = true
        ledger.recordRequest(at: now)
        Task {
            let previous = state.snapshot
            let newState = await service.refresh(thresholds: Self.currentThresholds())
            state = newState
            isRefreshing = false
            noteOutcome(newState, previous: previous)
            scheduleNext()
            if case .live(let snapshot) = newState {
                samples = history.append(snapshot, existing: samples)
                recomputePredictions(for: snapshot)
            }
            await refreshPricingIfNeeded()
        }
    }

    /// How close the last hour of requests is to the endpoint's estimated
    /// budget — the honesty gauge behind "refresh all you want".
    func apiBudget(now: Date) -> (used: Int, ceiling: Int, fraction: Double) {
        (ledger.used(at: now), ledger.ceiling, ledger.pressure(at: now))
    }

    /// The user's warning/critical cutoffs, defaults standing in for unset.
    static func currentThresholds() -> Thresholds {
        let defaults = UserDefaults.standard
        let warning = defaults.integer(forKey: warningThresholdKey)
        let critical = defaults.integer(forKey: criticalThresholdKey)
        return Thresholds(
            warningPercent: warning > 0 ? warning : Thresholds.standard.warningPercent,
            criticalPercent: critical > 0 ? critical : Thresholds.standard.criticalPercent)
    }

    /// Re-classifies what's on screen right after a threshold edit — the
    /// next poll would agree anyway; this makes the settings slider live.
    func thresholdsChanged() {
        let thresholds = Self.currentThresholds()
        switch state {
        case .live(let snapshot):
            state = .live(snapshot.rebuilt(thresholds: thresholds))
        case .cached(let snapshot, let error):
            state = .cached(snapshot.rebuilt(thresholds: thresholds), error: error)
        case .loading, .unavailable:
            break
        }
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
        }
    }

    /// The settings screen's refresh button — always fetches (the automatic
    /// path above stays daily). Single-flighted; failure text lands beside
    /// the button instead of in a log nobody reads.
    func refreshPricingNow() {
        guard !isRefreshingPricing else { return }
        isRefreshingPricing = true
        pricingRefreshError = nil
        Task {
            do {
                pricing = try await pricingService.refreshNow()
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
    func paceMultiplier(now: Date) -> Int {
        cadence.isBackingOff(now: now) ? 1 : cadence.multiplier(now: now)
    }

    /// Re-scans the agent's transcripts + prompt history for the heatmap,
    /// at most once a minute. A provider without local traces has nothing
    /// to scan — the activity section shows its empty state.
    func scanActivity(force: Bool = false) {
        guard !isShutDown, let source = localActivity else { return }
        if !force, let last = lastActivityScan, Date().timeIntervalSince(last) < 60 { return }
        lastActivityScan = Date()
        Task.detached(priority: .utility) { [weak self] in
            let scan = source.scanTranscripts(now: Date())
            let activity = ActivityMerge.merge(
                transcripts: scan.daily, prompts: source.scanPromptDays())
            await MainActor.run {
                self?.activity = activity
                self?.tokenTimeline = scan.timeline
                // Seed the persistent model-color ledger in overall usage
                // order, so first-ever assignment doesn't depend on which
                // chart happens to render first.
                var totals: [String: Int] = [:]
                for day in activity {
                    for (model, tally) in day.models {
                        totals[model, default: 0] += tally.total
                    }
                }
                _ = ModelPalette.assignment(
                    for: totals.sorted { $0.value > $1.value }.map(\.key))
            }
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
            UserDefaults.standard.set(ledger.ceiling, forKey: ceilingKey)
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
            }
        }
    }

    /// The overall weekly meter's rhythm — the activity chart's typical-week
    /// overlay and the settings insights read this one profile.
    var weeklyProfile: WeeklyProfile? {
        guard let meters = state.snapshot?.meters else { return nil }
        let weekly = meters.first { $0.rank == 1 } ?? meters.first { $0.rank > 0 }
        return weekly.flatMap { profiles[$0.label] }
    }

    /// Where the sample history lives on disk — the settings readout stats it.
    var historyFileURL: URL { history.fileURL }

    func setActiveInterval(_ interval: TimeInterval) {
        let clamped = min(max(TriggerGate.floor, interval), AdaptiveCadence.maxActiveInterval)
        activeInterval = clamped
        cadence.activeInterval = clamped
        UserDefaults.standard.set(clamped, forKey: Self.intervalKey)
        scheduleNext()
    }
}
