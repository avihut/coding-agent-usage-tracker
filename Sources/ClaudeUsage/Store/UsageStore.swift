import AppKit
import Foundation
import Observation
import UsageCore

/// The app's single source of truth — a thin façade over the core
/// `UsageEngine`, which owns refreshing, cadence, scanning, predictions,
/// and persistence. The façade keeps the store's historical member surface
/// so views and controllers stay untouched (Observation tracks straight
/// through these computed forwards into the engine's storage), and
/// contributes the one signal core can't own: AppKit's system-wake
/// notification.
@MainActor
@Observable
final class UsageStore {
    private let engine: UsageEngine
    /// Stale numbers after lid-open are what make these widgets feel broken
    /// (spec §9) — refresh on wake. NSWorkspace is AppKit, so the observer
    /// lives here rather than in the engine; usaged wires IOKit's power
    /// callback to the same `noteWake()`.
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    var state: DisplayState { engine.state }
    var isRefreshing: Bool { engine.isRefreshing }
    var activeInterval: TimeInterval { engine.activeInterval }
    var nextRefreshAt: Date? { engine.nextRefreshAt }
    var samples: [UsageSample] { engine.samples }
    var windowOutcomes: [WindowOutcome] { engine.windowOutcomes }
    var predictions: [String: UsagePrediction] { engine.predictions }
    var profiles: [String: WeeklyProfile] { engine.profiles }
    var activity: [DailyActivity] { engine.activity }
    var tokenTimeline: [TokenSlot] { engine.tokenTimeline }
    var sessions: [SessionSummary] { engine.sessions }
    var pricing: PricingTable { engine.pricing }
    var isRefreshingPricing: Bool { engine.isRefreshingPricing }
    var pricingRefreshError: String? { engine.pricingRefreshError }
    var provider: any UsageProvider { engine.provider }
    var localActivity: (any LocalActivitySource)? { engine.localActivity }
    var isShutDown: Bool { engine.isShutDown }
    var isLocalProvider: Bool { engine.isLocalProvider }
    var providesSessions: Bool { engine.providesSessions }
    var weeklyProfile: WeeklyProfile? { engine.weeklyProfile }
    var historyFileURL: URL { engine.historyFileURL }

    static let defaultInterval = UsageEngine.defaultInterval
    static let warningThresholdKey = UsageEngine.warningThresholdKey
    static let criticalThresholdKey = UsageEngine.criticalThresholdKey

    /// The user's warning/critical cutoffs, defaults standing in for unset.
    static func currentThresholds() -> Thresholds {
        UsageEngine.thresholds(from: .standard)
    }

    init(provider: any UsageProvider = ClaudeProvider(), service: UsageService? = nil) {
        engine = UsageEngine(
            provider: provider, service: service, defaults: .standard,
            bundleID: Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak engine] _ in
            MainActor.assumeIsolated {
                engine?.noteWake()
            }
        }
    }

    /// Retires this store: shuts the engine down and releases the wake
    /// observer (NotificationCenter would otherwise retain it forever).
    func shutdown() {
        engine.shutdown()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    func refresh(_ reason: UsageEngine.RefreshReason) {
        engine.refresh(reason)
    }

    func apiBudget(now: Date) -> (used: Int, ceiling: Int, fraction: Double) {
        engine.apiBudget(now: now)
    }

    func thresholdsChanged() {
        engine.thresholdsChanged()
    }

    func refreshPricingNow() {
        engine.refreshPricingNow()
    }

    func paceMultiplier(now: Date) -> Int {
        engine.paceMultiplier(now: now)
    }

    func scanActivity(force: Bool = false) {
        engine.scanActivity(force: force)
    }

    func sessionDetail(id: String) async -> SessionDetail? {
        await engine.sessionDetail(id: id)
    }

    func setActiveInterval(_ interval: TimeInterval) {
        engine.setActiveInterval(interval)
    }
}
