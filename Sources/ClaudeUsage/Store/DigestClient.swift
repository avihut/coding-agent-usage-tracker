import Foundation
import Observation
import UsageCore

/// The app's client mode: renders a daemon-hosted engine. State arrives
/// through live-state.json (rebuilt into the same core types the views
/// already consume); commands go back over the control socket. Everything
/// this class touches on disk it touches READ-ONLY — the digest, the
/// sample history, the window ledger, the pricing cache, and the
/// transcript trees (scans never persist their parse cache) — the lease
/// holder stays the sole writer.
@MainActor
@Observable
final class DigestClient {
    private(set) var state: DisplayState = .loading
    private(set) var predictions: [String: UsagePrediction] = [:]
    private(set) var samples: [UsageSample] = []
    private(set) var windowOutcomes: [WindowOutcome] = []
    private(set) var profiles: [String: WeeklyProfile] = [:]
    private(set) var activity: [DailyActivity] = []
    private(set) var tokenTimeline: [TokenSlot] = []
    private(set) var sessions: [SessionSummary] = []
    private(set) var pricing: PricingTable
    /// The host engine's status card, mirrored from the digest. Nil when the
    /// host publishes none — absent is not healthy.
    private(set) var serviceStatus: ServiceStatusCard?
    /// The host engine's release card, mirrored from the digest. Nil when
    /// the host runs no updater — absent is never "up to date".
    private(set) var appUpdate: AppUpdateCard?
    /// Optimistic: set when this process asks for a refresh, cleared when
    /// the next digest heartbeat lands.
    private(set) var isRefreshing = false
    private(set) var activeInterval: TimeInterval = UsageEngine.defaultInterval
    private(set) var nextRefreshAt: Date?
    private(set) var digestGeneratedAt: Date?
    /// The digest's engine facts the façade forwards verbatim.
    private(set) var paceMultiplierMirror = 1
    private(set) var apiBudgetMirror: (used: Int, ceiling: Int, fraction: Double) =
        (0, RequestLedger.defaultCeiling, 0)

    let provider: any UsageProvider
    let localActivity: (any LocalActivitySource)?
    private(set) var isShutDown = false

    private let bundleID: String
    private let digestURL: URL
    private let socketURL: URL
    private let history: UsageHistory
    private let windowLedger: WindowLedger
    private let pricingService: PricingService
    private var watchTimer: Timer?
    private var lastDigestModified: Date?
    private var lastScan: Date?
    private var isScanning = false

    init(provider: any UsageProvider, bundleID: String) {
        self.provider = provider
        self.bundleID = bundleID
        self.digestURL = LiveState.fileURL(bundleID: bundleID)
        self.socketURL = EngineHostBroker.socketURL(bundleID: bundleID)
        let support = StorageScope.supportDirectory(
            bundleID: bundleID, providerID: provider.id)
        self.localActivity = provider.makeLocalActivity(cacheDirectory: support)
        self.history = UsageHistory(directory: support)
        self.windowLedger = WindowLedger(directory: support)
        self.pricingService = PricingService(
            cacheDirectory: support, fallback: provider.bundledRates,
            selector: provider.pricingSelector)
        self.pricing = pricingService.current()

        reloadDigest()
        reloadArtifacts()
        scanActivity(force: true)
        // A 2s stat is the reload signal — cheaper and simpler than
        // re-arming a DispatchSource across the publisher's atomic renames.
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 0.5
        watchTimer = timer
    }

    /// The digest heartbeat's age — the façade's takeover check reads it.
    var digestStaleness: (generatedAt: Date, nextPollAt: Date?)? {
        digestGeneratedAt.map { ($0, nextRefreshAt) }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        watchTimer?.invalidate()
        watchTimer = nil
    }

    // MARK: - Commands (socket)

    func refresh() {
        isRefreshing = true
        send(.refresh)
    }

    func setActiveInterval(_ interval: TimeInterval) {
        activeInterval = interval  // optimistic; the next digest confirms
        send(.setInterval(seconds: interval))
    }

    func thresholdsChanged() {
        send(.settingsChanged)
    }

    func refreshPricingNow() {
        send(.refreshPricing)
    }

    func requestProviderSwitch(_ id: String) {
        send(.setProvider(id: id))
    }

    /// Asks the host for a fresher status card (decision D6). Only when one
    /// exists and has aged: a host publishing no card has nothing to refresh,
    /// and one just polled would answer with the same bytes.
    func pokeServiceStatusIfAging() {
        guard UsageStore.cardIsAging(serviceStatus) else { return }
        send(.refreshStatus)
    }

    /// Asks the host to check the release feed now (Settings' "Check Now").
    func requestUpdateCheck() {
        send(.checkUpdates)
    }

    private func send(_ command: ControlCommand) {
        let socketURL = socketURL
        Task.detached(priority: .utility) {
            _ = ControlSocket.send(command, to: socketURL)
        }
    }

    // MARK: - Local read-only work

    /// Same 60s throttle as the engine's scan, force included — but never
    /// persisting the parse cache, and never seeding the color ledger
    /// (that is the engine's job).
    func scanActivity(force: Bool = false) {
        guard !isShutDown, !isScanning, let source = localActivity else { return }
        if !force, let last = lastScan, Date().timeIntervalSince(last) < 60 { return }
        lastScan = Date()
        isScanning = true
        Task.detached(priority: .utility) { [weak self] in
            let scan = source.scanTranscriptsReadOnly(now: Date())
            let activity = ActivityMerge.merge(
                transcripts: scan.daily, prompts: source.scanPromptDays())
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activity = activity
                self.tokenTimeline = scan.timeline
                self.sessions = scan.sessions
                self.isScanning = false
            }
        }
    }

    func sessionDetail(id: String) async -> SessionDetail? {
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

    // MARK: - Digest intake

    private func tick() {
        guard !isShutDown else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: digestURL.path),
              let modified = attributes[.modificationDate] as? Date
        else { return }
        if let lastDigestModified, modified <= lastDigestModified { return }
        lastDigestModified = modified
        reloadDigest()
        reloadArtifacts()
        // The digest changing usually means the engine scanned or fetched;
        // follow with our own read-only scan (throttled).
        scanActivity()
    }

    private func reloadDigest() {
        guard let data = try? Data(contentsOf: digestURL),
              let digest = try? LiveState.decoder().decode(LiveState.self, from: data)
        else { return }
        apply(digest)
    }

    private func apply(_ digest: LiveState) {
        digestGeneratedAt = digest.engine.generatedAt
        serviceStatus = digest.serviceStatus
        appUpdate = digest.appUpdate
        nextRefreshAt = digest.engine.nextPollAt
        activeInterval = digest.engine.activeIntervalSeconds
        paceMultiplierMirror = digest.engine.paceMultiplier
        if let used = digest.engine.apiBudgetUsed,
           let ceiling = digest.engine.apiBudgetCeiling {
            apiBudgetMirror = (used, ceiling, digest.engine.apiBudgetFraction ?? 0)
        }
        isRefreshing = false

        let meters = digest.meters.map { mirror in
            Meter(
                id: mirror.id, label: mirror.label, percent: mirror.percent,
                resetsAt: mirror.resetsAt, level: Self.level(mirror.level),
                rank: mirror.rank, limitWindow: mirror.limitWindow,
                rateWindow: mirror.rateWindowSeconds,
                forcesWarning: mirror.forcesWarning,
                scopedModelName: mirror.scopedModelName)
        }
        var rebuilt: [String: UsagePrediction] = [:]
        for mirror in digest.meters {
            guard let forecast = mirror.forecast else { continue }
            rebuilt[mirror.label] = UsagePrediction(
                ratePerHour: forecast.ratePerHour,
                baselineRatePerHour: forecast.baselineRatePerHour,
                paceFactor: forecast.paceFactor,
                basis: Self.basis(forecast.basis),
                projectedAtReset: forecast.projectedAtReset,
                exhaustsAt: forecast.exhaustsAt,
                verdict: Self.verdict(forecast.verdict),
                rawVerdict: Self.verdict(forecast.rawVerdict),
                severity: forecast.severity,
                text: forecast.caption ?? "",
                curve: forecast.curve.map {
                    UsagePrediction.Point(t: $0.t, percent: $0.percent)
                })
        }
        predictions = rebuilt

        if let fetchedAt = digest.engine.fetchedAt {
            let plan: PlanInfo? =
                digest.engine.planSubscriptionType == nil
                    && digest.engine.planRateLimitTier == nil
                ? nil
                : PlanInfo(
                    subscriptionType: digest.engine.planSubscriptionType,
                    rateLimitTier: digest.engine.planRateLimitTier)
            let snapshot = Snapshot(
                meters: meters,
                spendLine: digest.engine.spend.map {
                    SpendLine(
                        usedMinor: $0.usedMinor, limitMinor: $0.limitMinor,
                        currency: $0.currency, exponent: $0.exponent)
                },
                fetchedAt: fetchedAt,
                plan: plan)
            if digest.engine.stale {
                state = .cached(snapshot, error: Self.error(digest.engine.error))
            } else {
                state = .live(snapshot)
            }
        } else if let error = digest.engine.error {
            state = .unavailable(Self.error(error))
        } else {
            state = .loading
        }
    }

    /// Samples, outcomes, and the pricing cache change only when the engine
    /// writes them — the digest heartbeat is the reload signal.
    private func reloadArtifacts() {
        samples = history.load()
        windowOutcomes = windowLedger.load()
        pricing = pricingService.current()
        recomputeProfiles()
    }

    /// Profiles are pure functions of the samples — recomputed locally, the
    /// same off-main hop the engine makes.
    private func recomputeProfiles() {
        guard let meters = state.snapshot?.meters else { return }
        let samples = samples
        let labels = meters.map(\.label)
        Task.detached(priority: .utility) { [weak self] in
            var fresh: [String: WeeklyProfile] = [:]
            for label in labels {
                if let profile = WeeklyProfile.build(samples: samples, label: label) {
                    fresh[label] = profile
                }
            }
            await MainActor.run { [weak self] in
                self?.profiles = fresh
            }
        }
    }

    // MARK: - Digest vocabulary → core types

    private static func level(_ name: String) -> DisplayLevel {
        switch name {
        case "warning": .warning
        case "critical": .critical
        default: .normal
        }
    }

    private static func verdict(_ name: String) -> UsagePrediction.Verdict {
        switch name {
        case "yellow": .yellow
        case "red": .red
        default: .green
        }
    }

    private static func basis(_ name: String) -> UsagePrediction.Basis {
        switch name {
        case "windowAverage": .windowAverage
        case "weeklyProfile": .weeklyProfile
        default: .recentOnly
        }
    }

    private static func error(_ status: ErrorStatus?) -> UsageError {
        guard let status else { return .network }
        switch status.code {
        case "noCredentials": return .noCredentials
        case "keychainDenied": return .keychainDenied
        case "credentialsUnreadable": return .credentialsUnreadable
        case "signInExpired": return .signInExpired
        case "rateLimited": return .rateLimited(retryAfter: nil)
        case "http": return .http(status.httpStatus ?? 0)
        case "schema": return .schema
        case "noLocalData": return .noLocalData
        default: return .network
        }
    }
}
