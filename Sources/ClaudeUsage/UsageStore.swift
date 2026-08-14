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
    private(set) var activity: [DailyActivity] = []
    /// Recent per-minute, per-model transcript usage; feeds the per-meter
    /// window breakdown in the panel.
    private(set) var tokenTimeline: [TokenSlot] = []
    /// Best pricing table available (live feed, disk cache, or bundled).
    private(set) var pricing: PricingTable
    private(set) var isRefreshingPricing = false
    /// Last manual pricing-refresh failure; cleared on the next attempt.
    private(set) var pricingRefreshError: String?

    private let service: UsageService
    private let history: UsageHistory
    private let scanner: TranscriptScanner
    private let promptScanner: PromptHistoryScanner
    private let pricingService: PricingService
    private var gate = TriggerGate()
    private let scheduler = Scheduler()
    private var cadence: AdaptiveCadence
    private var ledger: RequestLedger
    private var watcher: ClaudeActivityWatcher?
    private var lastActivityScan: Date?
    private var lastPricingAttempt: Date?

    static let defaultInterval: TimeInterval = 300
    private static let intervalKey = "refreshIntervalSeconds"
    private static let ceilingKey = "apiHourlyCeiling"

    init(service: UsageService? = nil) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage"
        self.service = service ?? .standard(bundleID: bundleID)
        self.history = .standard(bundleID: bundleID)
        self.scanner = .standard(bundleID: bundleID)
        self.promptScanner = .standard()
        self.pricingService = .standard(bundleID: bundleID)
        self.pricing = pricingService.current()
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        // Stored 60s choices predate the 180s floor — clamp, don't honor.
        let interval = stored >= 60 ? max(TriggerGate.floor, stored) : Self.defaultInterval
        self.activeInterval = interval
        self.cadence = AdaptiveCadence(activeInterval: interval, now: Date())
        let storedCeiling = UserDefaults.standard.integer(forKey: Self.ceilingKey)
        self.ledger = RequestLedger(
            ceiling: storedCeiling > 0 ? storedCeiling : RequestLedger.defaultCeiling)
        self.samples = history.load()

        scheduler.onTrigger = { [weak self] reason in
            self?.refresh(reason)
        }
        scheduler.start()
        // Claude Code writing a transcript is the push signal that Claude is
        // in use. When the directory doesn't exist (Claude Code never ran on
        // this machine) the pull signal — percentages moving between polls —
        // still drives the cadence.
        watcher = ClaudeActivityWatcher(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".claude/projects")
        ) { [weak self] in
            self?.noteLocalClaudeActivity()
        }
        refresh(.launch)
        scanActivity()
    }

    func refresh(_ reason: RefreshReason) {
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
            let newState = await service.refresh()
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

    /// The FSEvents watcher saw Claude Code write a transcript: snap the
    /// cadence back to the active pace, and fetch now whenever the displayed
    /// data is older than that pace, so re-engaging always catches the meters
    /// up promptly — even when a background agent session kept the evidence
    /// warm the whole time.
    func noteLocalClaudeActivity() {
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

    /// Re-scans local transcripts + prompt history for the heatmap, at most
    /// once a minute.
    func scanActivity(force: Bool = false) {
        if !force, let last = lastActivityScan, Date().timeIntervalSince(last) < 60 { return }
        lastActivityScan = Date()
        let scanner = scanner
        let promptScanner = promptScanner
        Task.detached(priority: .utility) { [weak self] in
            let scan = scanner.scan()
            let activity = ActivityMerge.merge(
                transcripts: scan.daily, prompts: promptScanner.scan())
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
            UserDefaults.standard.set(ledger.ceiling, forKey: Self.ceilingKey)
        } else if case .live(let snapshot) = newState {
            cadence.noteSuccess(
                usageAdvanced: UsageMovement.advanced(from: previous, to: snapshot), at: now)
        }
    }

    private func scheduleNext() {
        scheduler.schedule(after: cadence.interval(now: Date()))
        nextRefreshAt = scheduler.nextFireDate
    }

    private func ensureScheduled(now: Date) {
        if let next = scheduler.nextFireDate, next > now { return }
        scheduleNext()
    }

    private func recomputePredictions(for snapshot: Snapshot) {
        let now = Date()
        var fresh: [String: UsagePrediction] = [:]
        for meter in snapshot.meters {
            if let prediction = PredictionEngine.predict(meter: meter, samples: samples, now: now) {
                fresh[meter.label] = prediction
            }
        }
        predictions = fresh
    }

    func setActiveInterval(_ interval: TimeInterval) {
        let clamped = min(max(TriggerGate.floor, interval), AdaptiveCadence.maxActiveInterval)
        activeInterval = clamped
        cadence.activeInterval = clamped
        UserDefaults.standard.set(clamped, forKey: Self.intervalKey)
        scheduleNext()
    }
}
