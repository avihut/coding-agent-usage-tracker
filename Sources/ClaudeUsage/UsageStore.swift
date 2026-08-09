import Foundation
import Observation
import UsageCore

/// The app's single source of truth. Every trigger funnels through
/// `refresh(_:)`, which owns single-flighting and the 60-second gate — one
/// gate, uniformly applied (spec §9).
@MainActor
@Observable
final class UsageStore {
    enum RefreshReason: String {
        case launch, timer, wake, networkRestored, manual
    }

    private(set) var state: DisplayState = .loading
    private(set) var isRefreshing = false
    private(set) var refreshInterval: TimeInterval
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
        self.refreshInterval = stored >= 60 ? stored : Self.defaultInterval
        self.samples = history.load()

        scheduler.onTrigger = { [weak self] reason in
            self?.refresh(reason)
        }
        scheduler.start(interval: refreshInterval)
        nextRefreshAt = scheduler.nextFireDate
        refresh(.launch)
        scanActivity()
    }

    func refresh(_ reason: RefreshReason) {
        guard !isRefreshing, gate.shouldAllow(at: Date()) else { return }
        isRefreshing = true
        Task {
            let newState = await service.refresh()
            state = newState
            isRefreshing = false
            // Any completed refresh restarts the cadence, so a manual refresh
            // pushes the next automatic one a full interval out.
            scheduler.restart(interval: refreshInterval)
            nextRefreshAt = scheduler.nextFireDate
            if case .live(let snapshot) = newState {
                samples = history.append(snapshot, existing: samples)
                recomputeBurnEstimates(for: snapshot)
            }
        }
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

    func setRefreshInterval(_ interval: TimeInterval) {
        let clamped = max(60, interval)
        refreshInterval = clamped
        UserDefaults.standard.set(clamped, forKey: Self.intervalKey)
        scheduler.restart(interval: clamped)
        nextRefreshAt = scheduler.nextFireDate
    }
}
