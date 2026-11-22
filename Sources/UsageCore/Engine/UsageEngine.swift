import Foundation
import Observation

/// The metering orchestrator — every consumer surface's single source of
/// truth. Every trigger funnels through `refresh(_:)`, which owns
/// single-flighting, the 60-second gate, and the 429 backoff — one gate,
/// uniformly applied (spec §9).
///
/// Core so any host process can run it: the menu bar app embeds it behind
/// the `UsageStore` façade; `usaged` runs it as the launchd engine. Since
/// 0.96.0 ONE engine meters ONE profile (an agent home under a provider)
/// and `MeteringHost` runs one per enrolled profile: the vendor-level
/// pieces — pricing, status, the notice ledger — live in the shared
/// `ProviderServices`, the digest is folded by the host from the state
/// each engine hands its `publish` sink, and the host owns the lease, the
/// socket, the network monitor, and the update checker. Hosts inject
/// their `UserDefaults` domain — the app passes `.standard`, the daemon the
/// app's suite (same cfprefsd domain, different process) — and forward
/// their platform wake signal to `noteWake()`.
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
    /// What each forecast crossing would cost to cover, keyed by meter
    /// label — the dollars behind "runs out Mon 20:00 · ~$38 extra".
    /// Recomputed with the predictions themselves (the same pass, the same
    /// MainActor hop), so it can trail `tokenTimeline` by one scan the way
    /// the predictions trail it; a meter with no forecast crossing has no
    /// entry — absent, never a zero one.
    public private(set) var forecastOvershoots: [String: ForecastOvershoot] = [:]
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
    /// Best pricing table available — the provider services' table, shared
    /// by every profile of the provider.
    public var pricing: PricingTable { services.pricing }
    /// The signed-in-account presence card, rebuilt on every publish; nil
    /// when the provider declares no identity source, or before the first
    /// observation. Absent never means "no account" (spec §10 amendment
    /// 2026-08-25).
    public private(set) var accountPresence: AccountPresenceCard?
    /// The attribution timeline over the observed epochs — the sessions
    /// sidebar labels its rows against this. Nil when nothing tracks
    /// accounts.
    public var presenceTimeline: AccountTimeline? { presence?.timeline }
    /// The engine's latest publish — the host folds one per profile into
    /// the digest it writes.
    public private(set) var lastPublished: LiveState?

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
    /// The profile (account) this engine meters — `default` for the
    /// provider's standard home.
    public let profileID: String
    /// Vendor-level services shared by every profile's engine: pricing,
    /// the status poller, the notice ledger's one writer.
    public let services: ProviderServices
    /// Where each landing point's digest goes — the host folds it into
    /// live-state.json beside the other profiles' sections.
    private let publish: @MainActor (LiveState) -> Void
    /// The FSEvents push signal, forwarded to the host for focus (D9).
    public var onAgentActivity: ((Date) -> Void)?
    private let service: UsageService
    private let history: UsageHistory
    private let windowLedger: WindowLedger
    private var gate: TriggerGate
    private let scheduler = Scheduler()
    private var cadence: AdaptiveCadence
    private var ledger: RequestLedger
    private var watcher: AgentActivityWatcher?
    /// Reads "who is signed in" from the agent's own local record; nil when
    /// the provider declares none. A plain file read — never the Keychain,
    /// never the network (spec §10 amendment 2026-08-25).
    private let identitySource: (any AccountIdentitySource)?
    /// The observed-epochs presence ledger; nil exactly when
    /// `identitySource` is. Engine-confined single writer, like `history`.
    private var presence: AccountPresenceLedger?
    /// Spacing AND single-flight for transcript scans: a window-open
    /// force-scan must not overlap an FSEvents-triggered one (two concurrent
    /// scans race their MainActor assignments and can land stale-last), and
    /// a write that lands inside the spacing is owed a catch-up, never
    /// dropped.
    private var scanThrottle = ActivityScanThrottle()
    private var catchUpTask: Task<Void, Never>?
    /// True once a scan has landed `sessions` — before that, an empty index
    /// means "not looked yet", not "no such session".
    public private(set) var sessionsIndexed = false
    /// Where `activity`, `tokenTimeline` and `sessions` stand: nothing yet,
    /// the previous run's cached scan, or this run's own (2026-11-21). Nil
    /// for a harness with nothing to scan.
    public private(set) var activityStatus: ActivityStatus?
    /// Startup bookkeeping (`StartupTrace`): the first poll has landed (or the
    /// seeded gate denied it and the cache, fetched inside the floor, stands
    /// in), and how many forecast passes are still running.
    private(set) var metersSettled = false
    private var predictionsInFlight = 0
    /// Stamps each forecast pass; only the newest may land. Passes are no
    /// longer single-flight: the cached snapshot's pass at init and the
    /// launch poll's can overlap, and under load the older could finish last.
    private var predictionGeneration = 0
    /// Every first thing this engine owes a start has landed: meters, a scan
    /// (when it has traces to scan), and the forecast pass over them.
    public var startupSettled: Bool {
        metersSettled && (localActivity == nil || sessionsIndexed) && predictionsInFlight == 0
    }
    /// "claude/default" — how the startup trace names this engine.
    var traceName: String { "\(provider.id)/\(profileID)" }

    public static let defaultInterval: TimeInterval = 300
    static let intervalKey = "refreshIntervalSeconds"
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

    /// The user's active pace as stored — the host reads it for the digest
    /// before any engine exists. Stored 60s choices predate the 180s floor:
    /// clamp, don't honor.
    public static func activeInterval(from defaults: UserDefaults) -> TimeInterval {
        let stored = defaults.double(forKey: intervalKey)
        return stored >= 60 ? max(TriggerGate.floor, stored) : defaultInterval
    }

    /// `launchDelay` > 0 defers the launch poll (the host staggers its
    /// engines across the gate floor); the cached snapshot renders in the
    /// meantime. `publish` receives every landing point's digest.
    public init(
        provider: any UsageProvider,
        profileID: String,
        services: ProviderServices,
        service: UsageService? = nil,
        defaults: UserDefaults,
        bundleID: String,
        roots: StorageScope.Roots = .standard,
        host: Host,
        gateSeed: Date? = nil,
        systemAccent: RGBColor? = nil,
        launchDelay: TimeInterval = 0,
        agentCommandRunner: (any AgentCommandRunner)? = nil,
        publish: @escaping @MainActor (LiveState) -> Void
    ) {
        let support = StorageScope.supportDirectory(
            bundleID: bundleID, providerID: provider.id, profileID: profileID, roots: roots)
        let caches = StorageScope.cachesDirectory(
            bundleID: bundleID, providerID: provider.id, profileID: profileID, roots: roots)
        self.provider = provider
        self.profileID = profileID
        self.services = services
        self.publish = publish
        self.defaults = defaults
        self.hostKind = host
        self.systemAccent = systemAccent
        // A host taking over from a dead one seeds the gate with the old
        // host's last fetch (the digest's stamp) — a handover must never
        // double-poll inside the floor.
        self.gate = TriggerGate(lastAllowed: gateSeed)
        let localActivity = provider.makeLocalActivity(cacheDirectory: support)
        self.localActivity = localActivity
        self.service = service
            ?? UsageService(
                provider: provider, cache: UsageCache(directory: caches),
                probe: Self.quotaProbe(
                    provider: provider, runner: agentCommandRunner, directory: support,
                    activity: localActivity))
        self.history = UsageHistory(
            directory: support, relabel: { provider.currentMeterLabel(forStored: $0) })
        self.windowLedger = WindowLedger(directory: support)
        self.identitySource = provider.accountIdentity
        self.presence = provider.accountIdentity == nil
            ? nil : AccountPresenceLedger(directory: support)
        let interval = Self.activeInterval(from: defaults)
        self.activeInterval = interval
        self.cadence = AdaptiveCadence(activeInterval: interval, now: Date())
        self.ceilingKey = StorageScope.scopedKey(
            "apiHourlyCeiling", providerID: provider.id, profileID: profileID)
        let storedCeiling = defaults.integer(forKey: ceilingKey)
        self.ledger = RequestLedger(
            ceiling: storedCeiling > 0 ? storedCeiling : RequestLedger.defaultCeiling)
        self.samples = history.load()
        self.windowOutcomes = windowLedger.load()
        // Catch-up: grants already in the sample history that no ledger
        // recorded (the first run after the feature landed, a ledger lost).
        // Two days, matching the wake-time incident backfill's reach.
        let catchUpSince = Date().addingTimeInterval(-ProviderServices.noticeCatchUp)
        let catchUpSamples = samples
        services.notices.mutate {
            NoticeDetector.noteGrants(
                samples: catchUpSamples, since: catchUpSince, now: Date(), into: &$0,
                profileID: profileID)
        }

        scheduler.onTrigger = { [weak self] reason in
            self?.refresh(reason)
        }
        // The agent writing a transcript is the push signal that the service
        // is in use. When its directories don't exist (the agent never ran
        // on this machine) the pull signal — percentages moving between
        // polls — still drives the cadence.
        watcher = AgentActivityWatcher(
            directories: localActivity?.watchDirectories ?? []
        ) { [weak self] in
            self?.noteLocalAgentActivity()
        }
        // Who is signed in, before anything scans or publishes: the first
        // scan's attribution must run against a timeline that already
        // includes the present.
        observeAccountIdentity()
        // What is already known is shown before anything is fetched
        // (2026-11-21): the last fetch's meters from the cache, stamped with
        // THEIR fetch time — the faces say how old they are, nothing is
        // passed off as fresh. Every engine, the first one too: its launch
        // poll used to leave it a loading shell until the network answered,
        // which on a starved Mac was minutes. A seeded gate that denies the
        // launch poll (a takeover inside the floor) and a staggered engine
        // show the same snapshot until their poll lands.
        if let snapshot = self.service.cachedSnapshot(thresholds: currentThresholds()) {
            state = .live(snapshot)
            recomputePredictions(for: snapshot)
        }
        if launchDelay > 0 {
            scheduler.schedule(after: launchDelay)
            nextRefreshAt = scheduler.nextFireDate
        } else {
            refresh(.launch)
        }
        // A launch poll the seeded gate denied is settled by the cache: the
        // previous host fetched it inside the floor.
        if launchDelay <= 0, !isRefreshing { noteMetersSettled(source: "cache inside the floor") }
        activityStatus = localActivity == nil ? nil : .scanning
        warmStart()
    }

    /// The previous run's activity at once, then this run's scan: the cached
    /// pass (`LocalActivitySource.cachedScan` — the last complete scan as its
    /// cache saved it, no stat, no parse) lands as `cached`, dated by when
    /// that scan finished, and the full re-validation follows it. A full scan
    /// that lands first wins; the cached pass then has nothing to add.
    private func warmStart() {
        guard let source = localActivity else { return }
        let name = traceName
        Task.detached(priority: EngineWork.startup) { [weak self] in
            let started = Date()
            let cached = source.cachedScan(now: started)
            let merged = cached.map {
                ActivityMerge.merge(transcripts: $0.scan.daily, prompts: source.scanPromptDays())
            }
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            await MainActor.run { [weak self] in
                guard let self, !self.isShutDown else { return }
                if let cached, let merged, self.landCachedScan(cached, activity: merged) {
                    StartupTrace.shared.mark(
                        "cached activity \(name)",
                        "\(elapsed)ms, as of "
                            + cached.asOf.formatted(.iso8601.time(includingFractionalSeconds: false)))
                }
                self.scanActivity()
            }
        }
    }

    /// Shows the previous run's scan unless this run's own already landed —
    /// it never overwrites fresher data, and never counts as an index: the
    /// socket's `session` verb still waits for a real scan. True when it
    /// landed.
    @discardableResult
    func landCachedScan(_ cached: CachedScan, activity merged: [DailyActivity]) -> Bool {
        guard !isShutDown, !sessionsIndexed else { return false }
        activity = merged
        tokenTimeline = cached.scan.timeline
        sessions = cached.scan.sessions
        activityStatus = .cached(asOf: cached.asOf)
        publishState()
        return true
    }

    /// The provider's quota probe — only when it declares a command AND the
    /// host supplied a runner (spec §10 amendment 2026-11-21, second).
    nonisolated static func quotaProbe(
        provider: any UsageProvider, runner: (any AgentCommandRunner)?, directory: URL,
        activity: (any LocalActivitySource)?
    ) -> AgentQuotaProbe? {
        guard let runner, let command = provider.quotaCommand else { return nil }
        return AgentQuotaProbe(
            command: command, runner: runner,
            stateURL: directory.appending(path: AgentQuotaProbe.stateFileName),
            lastActivity: { now in activity?.lastActivity(now: now) })
    }

    /// The last fetch's snapshot from the cache, without fetching — what the
    /// host's focus rule reads for an engine that hasn't read yet, so a
    /// launch doesn't hand the lead to a harness whose last reading held no
    /// limits (`MeteringHost+Focus`).
    func cachedSnapshot() -> Snapshot? {
        service.cachedSnapshot(thresholds: currentThresholds())
    }

    /// Retires this engine: stops the scheduler's event sources and the
    /// FSEvents watcher so a replaced engine leaks nothing. An in-flight
    /// refresh may still land — the flag keeps its completion from
    /// rescheduling.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        // The open epoch's edge must not lose its last heartbeat window.
        presence?.flush()
        scheduler.stop()
        watcher = nil
        catchUpTask?.cancel()
        catchUpTask = nil
        nextRefreshAt = nil
        // Before the host releases the lease: a probe run still finishing
        // must not write under the next holder.
        service.probe?.retire()
    }

    /// A wake impulse from the host process — the app's NSWorkspace
    /// observer, the daemon's IOKit power callback. Stale numbers after
    /// lid-open are what make these widgets feel broken (spec §9). The
    /// status and history pokes are the provider services' — once per
    /// provider, not once per engine.
    public func noteWake() {
        // A lid-open is the classic moment a login changed elsewhere-in-time
        // (the user was away); look before the wake poll publishes anything.
        observeAccountIdentity()
        refresh(.wake)
    }

    /// The host's one network monitor saw the path come back.
    public func noteNetworkRestored() {
        refresh(.networkRestored)
    }

    /// Republish on the host's request — a provider-level card changed and
    /// the host wants this profile's section fresh beside it.
    public func publishNow() {
        publishState()
    }

    /// One presence observation — rides every landing point that could
    /// follow a login change: engine start, wake, each scan pass, each
    /// fetch. A transition is itself a landing point: the digest
    /// republishes immediately, so surfaces learn about a switch without
    /// waiting for usage to move. The 15s floor keeps a start+wake+scan
    /// pileup at one file read.
    private func observeAccountIdentity(now: Date = Date()) {
        guard let identitySource, var ledger = presence else { return }
        if let last = ledger.observedAt,
           now.timeIntervalSince(last) < AccountPresenceLedger.observationFloor {
            return
        }
        let changed = ledger.observe(identitySource.currentIdentity(), at: now)
        presence = ledger
        if changed { publishState(now: now) }
    }

    public func refresh(_ reason: RefreshReason) {
        guard !isShutDown else { return }
        let now = Date()
        observeAccountIdentity(now: now)
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
            // A meter reporting no window end inherits the one last seen
            // while it still lies ahead (`ResetCarry`): a mid-window grant
            // that zeroes the meter also blanks the stamp until the next
            // spend, and the window is nonetheless still running. History
            // records the API's own word below; the carry is what gets
            // rendered and forecast.
            let reported = await service.refresh(
                thresholds: currentThresholds(), manual: reason == .manual)
            // Shut down while it ran (a quota probe can take up to its 120 s
            // safety net, twice): the lease is gone or going, so nothing
            // lands — no history, ledger or notice written under the next
            // holder.
            guard !isShutDown else {
                isRefreshing = false
                return
            }
            let newState = Self.carryingResets(reported, samples: samples, now: Date())
            state = newState
            isRefreshing = false
            noteOutcome(newState, previous: previous)
            scheduleNext()
            if case .live(let snapshot) = newState, case .live(let asReported) = reported {
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
                // History keeps the API's own word — an absent stamp stays
                // absent on disk, so the carry can heal (or be revised)
                // retroactively at read time; the forecast runs on the
                // carried window it will be drawn against.
                samples = history.append(asReported, existing: samples)
                // The vendor emptying a meter inside its window is news;
                // the recent tail is enough to see the drop, the ledger's
                // tolerance keeps a re-read from filing it twice.
                let recent = samples
                services.notices.mutate {
                    NoticeDetector.noteGrants(
                        samples: recent, since: Date().addingTimeInterval(-3 * 3600),
                        now: Date(), into: &$0, profileID: profileID)
                }
                recomputePredictions(for: snapshot)
            } else if newState.asOf(at: Date()) != nil {
                // A cache served past its age horizon (offline, backing
                // off): the last live pass's forecast would otherwise ride
                // on it forever — it is only ever recomputed on `.live`.
                clearForecasts()
            }
            noteMetersSettled(source: Self.traceSource(newState))
            // The heartbeat: every completed cycle rewrites the digest, so
            // its freshness IS the engine's liveness signal.
            publishState()
            await services.refreshPricingIfStale()
        }
    }

    private func noteMetersSettled(source: String) {
        guard !metersSettled else { return }
        metersSettled = true
        StartupTrace.shared.mark("meters \(traceName)", source)
    }

    private static func traceSource(_ state: DisplayState) -> String {
        switch state {
        case .live: "fetched"
        case .cached(_, let error): "cache (\(error))"
        case .unavailable(let error): "unavailable (\(error))"
        case .loading: "loading"
        }
    }

    /// Snapshots this profile's renderable state and hands it to the host,
    /// which folds it into live-state.json. Cheap on the main actor (array
    /// mirrors and per-meter assembly over capped series); the host's
    /// publisher does the encoding and IO off-main. Provider-level cards
    /// (status, update, notices, outages) are the host's to attach.
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
            overshoots: forecastOvershoots,
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
            presence: presence.map {
                AccountPresenceInput(epochs: $0.epochs, observedAt: $0.observedAt)
            },
            activityStatus: activityStatus,
            now: now)
        accountPresence = digest.accountPresence
        lastPublished = digest
        publish(digest)
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

    /// The fetched state with `ResetCarry` applied to whichever snapshot it
    /// carries — live or cache-served alike, since a replayed body lacks the
    /// stamp for the same reason the fresh one did.
    static func carryingResets(
        _ state: DisplayState, samples: [UsageSample], now: Date
    ) -> DisplayState {
        switch state {
        case .live(let snapshot):
            .live(ResetCarry.fill(snapshot, samples: samples, now: now))
        case .cached(let snapshot, let error):
            .cached(ResetCarry.fill(snapshot, samples: samples, now: now), error: error)
        case .loading, .unavailable:
            state
        }
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

    /// The FSEvents watcher saw the agent write a transcript: snap the
    /// cadence back to the active pace, and fetch now whenever the displayed
    /// data is older than that pace, so re-engaging always catches the meters
    /// up promptly — even when a background agent session kept the evidence
    /// warm the whole time.
    func noteLocalAgentActivity() {
        let now = Date()
        onAgentActivity?(now)
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

    /// Re-scans the agent's transcripts + prompt history for the heatmap and
    /// the session index, at most once a minute — and a write that lands
    /// inside that minute gets a catch-up scan when it ends, never dropped
    /// (`ActivityScanThrottle`). A provider without local traces has nothing
    /// to scan — the activity section shows its empty state.
    public func scanActivity(force: Bool = false) {
        guard !isShutDown, localActivity != nil else { return }
        follow(scanThrottle.request(at: Date(), force: force))
    }

    private func follow(_ step: ActivityScanThrottle.Step) {
        guard !isShutDown else { return }
        switch step {
        case .scan:
            catchUpTask?.cancel()
            catchUpTask = nil
            startActivityScan()
        case .schedule(let due):
            catchUpTask?.cancel()
            let delay = max(0, due.timeIntervalSinceNow)
            catchUpTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.catchUpTask = nil
                self.follow(self.scanThrottle.catchUpDue(at: Date()))
            }
        case .nothing:
            break
        }
    }

    private func startActivityScan() {
        guard let source = localActivity else { return }
        // Observation rides the scan pass by design: the lines this scan
        // ingests are attributed against a timeline that includes right now,
        // so attribution is settled the first time it's computed.
        observeAccountIdentity()
        let started = Date()
        Task.detached(priority: EngineWork.heavy) { [weak self] in
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
                if !self.sessionsIndexed {
                    StartupTrace.shared.mark(
                        "scan \(self.traceName)",
                        "\(Int(Date().timeIntervalSince(started) * 1000))ms, "
                            + "\(scan.sessions.count) sessions")
                }
                self.sessionsIndexed = true
                self.activityStatus = .scanned(at: Date())
                self.publishState()
                self.follow(self.scanThrottle.finish(at: Date()))
            }
        }
    }

    /// One session's card and deep fields from the last scan's index — the
    /// `ControlCommand.session` answer. Every session the scan holds, not
    /// only the eight the digest publishes; priced and carded exactly as the
    /// digest's shortlist is. Nil before the first scan lands: an empty
    /// index then means "not looked yet", which no caller may read as "no
    /// such session".
    public func sessionAnswer(idPrefix: String) -> SessionAnswer? {
        guard sessionsIndexed else { return nil }
        return SessionAnswer.lookup(
            idPrefix, in: sessions, pricing: pricing, catalog: provider.modelCatalog,
            colorLedger: { ModelColorLedger.load(from: self.defaults, providerID: self.provider.id) },
            accent: RGBColor(provider.accent), timeline: presenceTimeline)
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
    /// not click-handler work. Two passes can overlap (the cached
    /// snapshot's at init, then the launch poll's), so each is stamped and
    /// a superseded one is dropped when it lands (`landPredictions`).
    private func recomputePredictions(for snapshot: Snapshot) {
        let now = Date()
        let samples = self.samples
        let previous = self.predictions
        let meters = snapshot.meters
        let readingAt = snapshot.fetchedAt
        // Read off the main actor's state here — the detached body cannot.
        let timeline = self.tokenTimeline
        let pricing = self.pricing
        let generation = beginPredictionPass()
        Task.detached(priority: EngineWork.heavy) { [weak self] in
            var profiles: [String: WeeklyProfile] = [:]
            for meter in meters {
                if let profile = WeeklyProfile.build(samples: samples, label: meter.label) {
                    profiles[meter.label] = profile
                }
            }
            // One pass, narrowest limit window first: a meter's forecast
            // reads its shorter-window siblings, so a spent 5h session
            // stops the weeklies climbing until it resets.
            // An OLD reading (`ReadingAge`) forecasts nothing at all.
            let fresh = PredictionEngine.predictAll(
                meters: meters, samples: samples, profiles: profiles,
                previous: previous, readingAt: readingAt, now: now)
            // What covering each forecast crossing would cost, priced on
            // the window's own tokens — nothing to state for a meter whose
            // forecast lands inside its limit.
            var overshoots: [String: ForecastOvershoot] = [:]
            for meter in meters {
                guard let prediction = fresh[meter.label] else { continue }
                if let overshoot = ForecastOvershoot.estimate(
                    prediction: prediction, meter: meter, samples: samples,
                    timeline: timeline, pricing: pricing, now: now) {
                    overshoots[meter.label] = overshoot
                }
            }
            await MainActor.run { [profiles, fresh, overshoots] in
                _ = self?.landPredictions(
                    generation: generation, profiles: profiles, predictions: fresh, overshoots: overshoots)
            }
        }
    }

    func beginPredictionPass() -> Int {
        predictionsInFlight += 1
        predictionGeneration += 1
        return predictionGeneration
    }

    /// Lands a forecast pass unless a newer one has begun since — the newer
    /// pass carries newer samples and will land itself. Internal for tests.
    @discardableResult
    func landPredictions(
        generation: Int, profiles: [String: WeeklyProfile], predictions: [String: UsagePrediction],
        overshoots: [String: ForecastOvershoot]
    ) -> Bool {
        predictionsInFlight -= 1
        guard generation == predictionGeneration else { return false }
        self.profiles = profiles
        self.predictions = predictions
        self.forecastOvershoots = overshoots
        StartupTrace.shared.mark("forecast \(traceName)")
        publishState()
        return true
    }

    /// Drops every forecast this engine holds — what an old reading
    /// (`ReadingAge`) leaves: nothing to project from. Profiles stay; they
    /// are the history's, not the reading's.
    /// A pass still in flight is superseded too, so nothing it computed
    /// can land afterwards.
    func clearForecasts() {
        predictionGeneration += 1
        guard !predictions.isEmpty || !forecastOvershoots.isEmpty else { return }
        predictions = [:]
        forecastOvershoots = [:]
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
