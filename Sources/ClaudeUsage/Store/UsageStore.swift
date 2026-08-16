import AppKit
import Foundation
import Observation
import UsageCore

/// The app's single source of truth — a thin façade with two modes behind
/// one historical member surface (Observation tracks straight through the
/// computed forwards, so views and controllers never know which mode is
/// live):
///
/// - **hosting**: no daemon anywhere — the app takes the engine lease and
///   runs core `UsageEngine` in-process (the embedded fallback).
/// - **client**: `usaged` holds the engine — the app renders its digest
///   through `DigestClient` and sends commands over the control socket.
///
/// The daemon wins: a hosting app yields within ~30s of a daemon
/// announcing itself (daemon.alive marker), and a client app takes over
/// only when the digest heartbeat is stale beyond doubt AND the lease is
/// free — seeding the refresh gate from the dead host's last fetch so a
/// handover never double-polls.
@MainActor
@Observable
final class UsageStore {
    private enum Mode {
        case hosting(UsageEngine)
        case client(DigestClient)
    }

    private var mode: Mode
    @ObservationIgnored private let lease: EngineLease
    @ObservationIgnored private let bundleID: String
    @ObservationIgnored private let providerValue: any UsageProvider
    @ObservationIgnored private let serviceOverride: UsageService?
    @ObservationIgnored private var roleTimer: Timer?
    /// Stale numbers after lid-open are what make these widgets feel broken
    /// (spec §9) — refresh on wake. NSWorkspace is AppKit, so the observer
    /// lives here rather than in the engine; usaged wires IOKit's power
    /// callback to the same seam.
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    var state: DisplayState {
        switch mode {
        case .hosting(let engine): engine.state
        case .client(let client): client.state
        }
    }
    var isRefreshing: Bool {
        switch mode {
        case .hosting(let engine): engine.isRefreshing
        case .client(let client): client.isRefreshing
        }
    }
    var activeInterval: TimeInterval {
        switch mode {
        case .hosting(let engine): engine.activeInterval
        case .client(let client): client.activeInterval
        }
    }
    var nextRefreshAt: Date? {
        switch mode {
        case .hosting(let engine): engine.nextRefreshAt
        case .client(let client): client.nextRefreshAt
        }
    }
    var samples: [UsageSample] {
        switch mode {
        case .hosting(let engine): engine.samples
        case .client(let client): client.samples
        }
    }
    var windowOutcomes: [WindowOutcome] {
        switch mode {
        case .hosting(let engine): engine.windowOutcomes
        case .client(let client): client.windowOutcomes
        }
    }
    var predictions: [String: UsagePrediction] {
        switch mode {
        case .hosting(let engine): engine.predictions
        case .client(let client): client.predictions
        }
    }
    var profiles: [String: WeeklyProfile] {
        switch mode {
        case .hosting(let engine): engine.profiles
        case .client(let client): client.profiles
        }
    }
    var activity: [DailyActivity] {
        switch mode {
        case .hosting(let engine): engine.activity
        case .client(let client): client.activity
        }
    }
    var tokenTimeline: [TokenSlot] {
        switch mode {
        case .hosting(let engine): engine.tokenTimeline
        case .client(let client): client.tokenTimeline
        }
    }
    var sessions: [SessionSummary] {
        switch mode {
        case .hosting(let engine): engine.sessions
        case .client(let client): client.sessions
        }
    }
    var pricing: PricingTable {
        switch mode {
        case .hosting(let engine): engine.pricing
        case .client(let client): client.pricing
        }
    }
    var isRefreshingPricing: Bool {
        switch mode {
        case .hosting(let engine): engine.isRefreshingPricing
        case .client: false
        }
    }
    var pricingRefreshError: String? {
        switch mode {
        case .hosting(let engine): engine.pricingRefreshError
        case .client: nil
        }
    }
    var provider: any UsageProvider { providerValue }
    var localActivity: (any LocalActivitySource)? {
        switch mode {
        case .hosting(let engine): engine.localActivity
        case .client(let client): client.localActivity
        }
    }
    var isShutDown: Bool {
        switch mode {
        case .hosting(let engine): engine.isShutDown
        case .client(let client): client.isShutDown
        }
    }
    var isLocalProvider: Bool { providerValue.networkDestinations.isEmpty }
    var providesSessions: Bool { localActivity?.providesSessions ?? false }
    /// True while a daemon hosts the engine — settings can say so.
    var isDigestClient: Bool {
        if case .client = mode { return true }
        return false
    }

    /// The overall weekly meter's rhythm — the activity chart's typical-week
    /// overlay and the settings insights read this one profile.
    var weeklyProfile: WeeklyProfile? {
        guard let meters = state.snapshot?.meters else { return nil }
        let weekly = meters.first { $0.rank == 1 } ?? meters.first { $0.rank > 0 }
        return weekly.flatMap { profiles[$0.label] }
    }

    var historyFileURL: URL {
        StorageScope.supportDirectory(bundleID: bundleID, providerID: providerValue.id)
            .appending(path: "history.json")
    }

    static let defaultInterval = UsageEngine.defaultInterval
    static let warningThresholdKey = UsageEngine.warningThresholdKey
    static let criticalThresholdKey = UsageEngine.criticalThresholdKey

    /// The user's warning/critical cutoffs, defaults standing in for unset.
    static func currentThresholds() -> Thresholds {
        UsageEngine.thresholds(from: .standard)
    }

    init(provider: any UsageProvider = ClaudeProvider(), service: UsageService? = nil) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage"
        self.bundleID = bundleID
        self.providerValue = provider
        self.serviceOverride = service
        self.lease = EngineLease(lockURL: EngineHostBroker.lockURL(bundleID: bundleID))

        let daemonAlive = Self.daemonMarkerAge(bundleID: bundleID)
            .map { $0 < EngineHostBroker.daemonAliveWindow } ?? false
        let role = EngineHostBroker.role(
            leaseHeldByOther: EngineLease.isHeld(at: lease.lockURL),
            daemonAlive: daemonAlive)
        if role == .host, lease.acquire() {
            mode = .hosting(
                UsageEngine(
                    provider: provider, service: service, defaults: .standard,
                    bundleID: bundleID, host: .app))
        } else {
            mode = .client(DigestClient(provider: provider, bundleID: bundleID))
            // An explicit Metering pick must reach the daemon; auto
            // converges on its own (same selection key, same signals).
            let selection = UserDefaults.standard.string(
                forKey: HarnessResolution.selectionKey)
            if let selection, selection != HarnessResolution.automatic,
               selection == provider.id {
                if case .client(let client) = mode {
                    client.requestProviderSwitch(provider.id)
                }
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if case .hosting(let engine) = self.mode { engine.noteWake() }
                // A client checks the host survived the sleep right away.
                self.evaluateRole()
            }
        }
        let timer = Timer.scheduledTimer(
            withTimeInterval: EngineHostBroker.checkInterval, repeats: true
        ) { _ in
            Task { @MainActor [weak self] in self?.evaluateRole() }
        }
        timer.tolerance = 5
        roleTimer = timer
    }

    /// Retires this store: stops whichever mode runs, releases the lease
    /// and the wake observer.
    func shutdown() {
        switch mode {
        case .hosting(let engine):
            engine.shutdown()
            lease.release()
        case .client(let client):
            client.shutdown()
        }
        roleTimer?.invalidate()
        roleTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    // MARK: - Host arbitration

    private static func daemonMarkerAge(bundleID: String) -> TimeInterval? {
        let marker = EngineHostBroker.daemonMarkerURL(bundleID: bundleID)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modified)
    }

    private func evaluateRole() {
        guard !isShutDown else { return }
        switch mode {
        case .hosting(let engine):
            let markerAge = Self.daemonMarkerAge(bundleID: bundleID)
            guard EngineHostBroker.shouldYield(daemonMarkerAge: markerAge) else { return }
            // The daemon wins: stop the embedded engine, free the lease,
            // render the daemon's digest from here on.
            engine.shutdown()
            lease.release()
            mode = .client(DigestClient(provider: providerValue, bundleID: bundleID))
        case .client(let client):
            guard let staleness = client.digestStaleness else { return }
            guard EngineHostBroker.heartbeatStale(
                generatedAt: staleness.generatedAt,
                nextPollAt: staleness.nextPollAt,
                now: Date())
            else { return }
            // The host looks dead — but a held lease is a live process, so
            // the lease decides, not the heuristic.
            guard lease.acquire() else { return }
            let seed = client.state.snapshot?.fetchedAt
            client.shutdown()
            mode = .hosting(
                UsageEngine(
                    provider: providerValue, service: serviceOverride,
                    defaults: .standard, bundleID: bundleID, host: .app,
                    gateSeed: seed))
        }
    }

    // MARK: - Forwards

    func refresh(_ reason: UsageEngine.RefreshReason) {
        switch mode {
        case .hosting(let engine): engine.refresh(reason)
        case .client(let client): client.refresh()
        }
    }

    func apiBudget(now: Date) -> (used: Int, ceiling: Int, fraction: Double) {
        switch mode {
        case .hosting(let engine): engine.apiBudget(now: now)
        case .client(let client): client.apiBudgetMirror
        }
    }

    func thresholdsChanged() {
        switch mode {
        case .hosting(let engine): engine.thresholdsChanged()
        case .client(let client): client.thresholdsChanged()
        }
    }

    func refreshPricingNow() {
        switch mode {
        case .hosting(let engine): engine.refreshPricingNow()
        case .client(let client): client.refreshPricingNow()
        }
    }

    func paceMultiplier(now: Date) -> Int {
        switch mode {
        case .hosting(let engine): engine.paceMultiplier(now: now)
        case .client(let client): client.paceMultiplierMirror
        }
    }

    func scanActivity(force: Bool = false) {
        switch mode {
        case .hosting(let engine): engine.scanActivity(force: force)
        case .client(let client): client.scanActivity(force: force)
        }
    }

    func sessionDetail(id: String) async -> SessionDetail? {
        switch mode {
        case .hosting(let engine): await engine.sessionDetail(id: id)
        case .client(let client): await client.sessionDetail(id: id)
        }
    }

    func setActiveInterval(_ interval: TimeInterval) {
        switch mode {
        case .hosting(let engine): engine.setActiveInterval(interval)
        case .client(let client): client.setActiveInterval(interval)
        }
    }
}
