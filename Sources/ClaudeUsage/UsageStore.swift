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

    private let service: UsageService
    private var gate = TriggerGate()
    private let scheduler = Scheduler()

    static let defaultInterval: TimeInterval = 300
    private static let intervalKey = "refreshIntervalSeconds"

    init(service: UsageService? = nil) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage"
        self.service = service ?? .standard(bundleID: bundleID)
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        self.refreshInterval = stored >= 60 ? stored : Self.defaultInterval

        scheduler.onTrigger = { [weak self] reason in
            self?.refresh(reason)
        }
        scheduler.start(interval: refreshInterval)
        refresh(.launch)
    }

    func refresh(_ reason: RefreshReason) {
        guard !isRefreshing, gate.shouldAllow(at: Date()) else { return }
        isRefreshing = true
        Task {
            state = await service.refresh()
            isRefreshing = false
        }
    }

    func setRefreshInterval(_ interval: TimeInterval) {
        let clamped = max(60, interval)
        refreshInterval = clamped
        UserDefaults.standard.set(clamped, forKey: Self.intervalKey)
        scheduler.restart(interval: clamped)
    }
}
