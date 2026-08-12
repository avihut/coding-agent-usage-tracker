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
    private(set) var burnEstimates: [String: BurnEstimate] = [:]
    private(set) var activity: [DailyActivity] = []

    private let service: UsageService
    private let history: UsageHistory
    private let scanner: TranscriptScanner
    private let promptScanner: PromptHistoryScanner
    private var gate = TriggerGate()
    private let scheduler = Scheduler()
    private var cadence: AdaptiveCadence
    private var watcher: ClaudeActivityWatcher?
    private var lastActivityScan: Date?

    static let defaultInterval: TimeInterval = 300
    private static let intervalKey = "refreshIntervalSeconds"

    init(service: UsageService? = nil) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage"
        self.service = service ?? .standard(bundleID: bundleID)
        self.history = .standard(bundleID: bundleID)
        self.scanner = .standard(bundleID: bundleID)
        self.promptScanner = .standard()
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        let interval = stored >= 60 ? stored : Self.defaultInterval
        self.activeInterval = interval
        self.cadence = AdaptiveCadence(activeInterval: interval, now: Date())
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
        Task {
            let previous = state.snapshot
            let newState = await service.refresh()
            state = newState
            isRefreshing = false
            noteOutcome(newState, previous: previous)
            scheduleNext()
            if case .live(let snapshot) = newState {
                samples = history.append(snapshot, existing: samples)
                recomputeBurnEstimates(for: snapshot)
            }
        }
    }

    /// The FSEvents watcher saw Claude Code write a transcript: snap the
    /// cadence back to the active pace, and if polling had decayed, fetch now
    /// so the meters catch up with the re-engagement immediately.
    func noteLocalClaudeActivity() {
        let now = Date()
        let wasDecayed = cadence.multiplier(now: now) > 1
        cadence.noteActivity(at: now)
        scanActivity() // transcripts changed; the heatmap follows (1/min throttle)
        guard !cadence.isBackingOff(now: now) else { return }
        if wasDecayed {
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
            let activity = ActivityMerge.merge(
                transcripts: scanner.scan(), prompts: promptScanner.scan())
            await MainActor.run { self?.activity = activity }
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

    private func recomputeBurnEstimates(for snapshot: Snapshot) {
        let now = Date()
        var estimates: [String: BurnEstimate] = [:]
        for meter in snapshot.meters {
            guard let percent = meter.percent else { continue }
            let rate = BurnRate.ratePerHour(
                samples: samples, label: meter.label,
                window: BurnRate.window(forRank: meter.rank), now: now)
            if let estimate = BurnRate.estimate(
                percent: percent, resetsAt: meter.resetsAt, ratePerHour: rate, now: now) {
                estimates[meter.label] = estimate
            }
        }
        burnEstimates = estimates
    }

    func setActiveInterval(_ interval: TimeInterval) {
        let clamped = max(60, interval)
        activeInterval = clamped
        cadence.activeInterval = clamped
        UserDefaults.standard.set(clamped, forKey: Self.intervalKey)
        scheduleNext()
    }
}
