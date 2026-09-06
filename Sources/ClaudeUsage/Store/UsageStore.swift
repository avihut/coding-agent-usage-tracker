import AppKit
import Foundation
import Observation
import UsageCore

/// One profile's (account's) face — a thin façade with two modes behind
/// one historical member surface (Observation tracks straight through the
/// computed forwards, so views and controllers never know which mode is
/// live):
///
/// - **hosting**: this app holds the engine lease and runs core
///   `MeteringHost`; the face reads its own profile's engine off the host
///   (nil while the profile is dormant or disabled — nothing runs for it).
/// - **client**: `usaged` holds the engine — the face renders its profile's
///   section of the digest through `DigestClient` and sends commands over
///   the control socket.
///
/// Host arbitration — who holds the lease, when to yield, when to take
/// over — is the registry's (`ProviderRegistry`), ONCE per process; a face
/// only flips modes when told (`adopt`). Provider-level facts (status,
/// update, notices, outages) come from the host or the digest's top level;
/// the launch hatches' fakes overlay them here.
@MainActor
@Observable
final class UsageStore {
    enum Mode {
        case hosting(MeteringHost)
        case client(DigestClient)
    }

    private var mode: Mode
    @ObservationIgnored let bundleID: String
    @ObservationIgnored private let providerValue: any UsageProvider
    /// The profile this face renders.
    let profile: Profile
    /// Set by the registry from the host's (or the digest's) facts.
    var isFocused = false
    var isDormant = false
    var lastActivityAt: Date?
    /// User-chosen session names, overlaid on derived titles in `sessions`.
    /// Observable state: a rename re-renders every surface that shows the
    /// title (sidebar, shortlist, detail header) in the same tick.
    private var sessionNames: [String: String] = [:]
    private var renamesFile: SessionRenames {
        SessionRenames(directory: StorageScope.supportDirectory(
            bundleID: bundleID, providerID: providerValue.id, profileID: profile.id))
    }

    /// This profile's engine while hosting; nil in client mode and while
    /// no engine runs for the profile (dormant, disabled, reconciling).
    private var engine: UsageEngine? {
        if case .hosting(let host) = mode { return host.engines[profile.id] }
        return nil
    }

    var state: DisplayState {
        switch mode {
        case .hosting: engine?.state ?? .loading
        case .client(let client): client.state
        }
    }
    var isRefreshing: Bool {
        switch mode {
        case .hosting: engine?.isRefreshing ?? false
        case .client(let client): client.isRefreshing
        }
    }
    var activeInterval: TimeInterval {
        switch mode {
        case .hosting(let host): host.activeInterval
        case .client(let client): client.activeInterval
        }
    }
    var nextRefreshAt: Date? {
        switch mode {
        case .hosting: engine?.nextRefreshAt
        case .client(let client): client.nextRefreshAt
        }
    }
    var samples: [UsageSample] {
        switch mode {
        case .hosting: engine?.samples ?? []
        case .client(let client): client.samples
        }
    }
    var windowOutcomes: [WindowOutcome] {
        switch mode {
        case .hosting: engine?.windowOutcomes ?? []
        case .client(let client): client.windowOutcomes
        }
    }
    /// Provider incidents within retention — the charts' outage floor.
    /// Empty when the provider declares no status feed or the daemon
    /// predates the field; the fake (`--fake-notices`) wins so the floor can
    /// be verified against the same synthetic incidents as the section.
    var outages: [OutageSpan] {
        if let fakeOutages { return fakeOutages }
        switch mode {
        case .hosting(let host): return host.outages
        case .client(let client): return client.outages
        }
    }
    private var fakeOutages: [OutageSpan]?
    var predictions: [String: UsagePrediction] {
        switch mode {
        case .hosting: engine?.predictions ?? [:]
        case .client(let client): client.predictions
        }
    }
    var profiles: [String: WeeklyProfile] {
        switch mode {
        case .hosting: engine?.profiles ?? [:]
        case .client(let client): client.profiles
        }
    }
    var activity: [DailyActivity] {
        switch mode {
        case .hosting: engine?.activity ?? []
        case .client(let client): client.activity
        }
    }
    var tokenTimeline: [TokenSlot] {
        switch mode {
        case .hosting: engine?.tokenTimeline ?? []
        case .client(let client): client.tokenTimeline
        }
    }
    var sessions: [SessionSummary] {
        guard !sessionNames.isEmpty else { return rawSessions }
        return rawSessions.map { session in
            sessionNames[session.id].map(session.renamed) ?? session
        }
    }
    /// The scan's own summaries, derived titles intact.
    private var rawSessions: [SessionSummary] {
        switch mode {
        case .hosting: engine?.sessions ?? []
        case .client(let client): client.sessions
        }
    }
    var pricing: PricingTable {
        switch mode {
        case .hosting(let host): host.services.pricing
        case .client(let client): client.pricing
        }
    }
    var isRefreshingPricing: Bool {
        switch mode {
        case .hosting(let host): host.services.isRefreshingPricing
        case .client: false
        }
    }
    var pricingRefreshError: String? {
        switch mode {
        case .hosting(let host): host.services.pricingRefreshError
        case .client: nil
        }
    }
    /// The provider's service health, or nil when nothing tracks it (no
    /// declared feed, or a daemon too old to publish one). Nil renders as
    /// NOTHING — absent is not healthy.
    var serviceStatus: ServiceStatusCard? {
        if let fakeServiceStatus { return fakeServiceStatus }
        switch mode {
        case .hosting(let host): return host.serviceStatus
        case .client(let client): return client.serviceStatus
        }
    }
    /// Set only by the `--fake-status` launch hatch: the status surfaces
    /// can't be verified by waiting for a real outage, and synthetic AX
    /// clicks can't reach a popover. Nil in every ordinary run.
    private var fakeServiceStatus: ServiceStatusCard?
    /// Pending notifications, phrased by the writer, or nil when the host
    /// publishes none (a daemon before 0.93.0). Nil renders as NOTHING —
    /// and so does an empty card; the section exists only while something
    /// is pending.
    var notices: NoticesCard? {
        if let fakeNotices { return fakeNotices }
        switch mode {
        case .hosting(let host): return host.notices
        case .client(let client): return client.notices
        }
    }
    /// Set only by the `--fake-notices` launch hatch: a vendor reset and
    /// an overnight outage can't be scheduled, so the section, the menu
    /// bar dot and the × get a synthetic card. Dismissals edit the fake in
    /// place so the click path can be verified end to end. Nil in every
    /// ordinary run.
    private var fakeNotices: NoticesCard?
    /// The app's newest published release, or nil when the install belongs
    /// to no feed-polling channel (bare executables, a store install) or
    /// the daemon predates the card. Nil renders as NOTHING — absent is
    /// never "up to date".
    var appUpdate: AppUpdateCard? {
        if let fakeAppUpdate { return fakeAppUpdate }
        switch mode {
        case .hosting(let host): return host.appUpdate
        case .client(let client): return client.appUpdate
        }
    }
    /// Set only by the `--fake-update` launch hatch — the chip, menu item,
    /// and Settings card can't be verified against a release that doesn't
    /// exist yet. Nil in every ordinary run.
    private var fakeAppUpdate: AppUpdateCard?
    /// Which account is signed in and how usage splits across observed
    /// accounts, or nil when nothing tracks accounts (no identity source
    /// declared, or a daemon too old to publish the card). Nil renders as
    /// NOTHING — absent is never "no account".
    var accountPresence: AccountPresenceCard? {
        if let fakeAccountPresence { return fakeAccountPresence }
        switch mode {
        case .hosting: return engine?.accountPresence
        case .client(let client): return client.accountPresence
        }
    }
    /// Set only by the `--fake-accounts` launch hatch: the two-line status
    /// row and the sessions column auto-show only once a SECOND identity
    /// has been observed — which a single-account machine can't produce on
    /// demand. Nil in every ordinary run.
    private var fakeAccountPresence: AccountPresenceCard?
    /// The distribution channel this install belongs to — decides whether
    /// the update surfaces offer the one-click swap or manual guidance. An
    /// install's channel can't change mid-run, so it's frozen at init.
    var distribution: (any DistributionChannel)? {
        fakeDistribution ?? realDistribution
    }
    private let realDistribution = Distribution.channel(for: Bundle.main.bundleURL)
    /// Set only by the `--fake-channel` launch hatch — one machine is only
    /// ever one flavor, so the other flavor's presentation needs forcing to
    /// be click-verified. Nil in every ordinary run.
    private var fakeDistribution: (any DistributionChannel)?
    /// Whether update UI may offer the one-click install here. The updater
    /// drill's feed override forces this true (its staged bundle sits
    /// inside the checkout by construction); the fake channel wins over
    /// everything, being the point of the hatch.
    var updateCanSelfInstall: Bool {
        if let fakeDistribution { return fakeDistribution.canSelfInstall }
        return Distribution.allowsSelfInstall(bundleURL: Bundle.main.bundleURL)
    }

    var provider: any UsageProvider { providerValue }
    var localActivity: (any LocalActivitySource)? {
        switch mode {
        case .hosting: engine?.localActivity
        case .client(let client): client.localActivity
        }
    }
    var isShutDown: Bool {
        switch mode {
        case .hosting: engine?.isShutDown ?? true
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
        StorageScope.supportDirectory(
            bundleID: bundleID, providerID: providerValue.id, profileID: profile.id
        ).appending(path: "history.json")
    }

    static let defaultInterval = UsageEngine.defaultInterval
    static let warningThresholdKey = UsageEngine.warningThresholdKey
    static let criticalThresholdKey = UsageEngine.criticalThresholdKey

    /// The user's warning/critical cutoffs, defaults standing in for unset.
    static func currentThresholds() -> Thresholds {
        UsageEngine.thresholds(from: .standard)
    }

    /// The scan's title for a session — what clearing a custom name
    /// reverts to.
    func derivedTitle(for id: String) -> String? {
        rawSessions.first { $0.id == id }?.title
    }

    func customSessionName(for id: String) -> String? {
        sessionNames[id]
    }

    /// Sets (or, for an empty/derived-equal name, clears) a session's
    /// custom display name. A failed save keeps the name for this run —
    /// the file lives in the app's own support dir, so failure means the
    /// disk has bigger problems than a lost rename.
    func renameSession(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == derivedTitle(for: id) {
            sessionNames.removeValue(forKey: id)
        } else {
            sessionNames[id] = trimmed
        }
        try? renamesFile.save(sessionNames)
    }

    init(profile: Profile, provider: any UsageProvider, bundleID: String, mode: Mode) {
        self.profile = profile
        self.providerValue = provider
        self.bundleID = bundleID
        self.mode = mode
        sessionNames = renamesFile.load()
    }

    /// A face over a digest that never changes — the launch hatches'
    /// synthetic profile.
    convenience init(profile: Profile, provider: any UsageProvider, bundleID: String, fixed: LiveState) {
        self.init(
            profile: profile, provider: provider, bundleID: bundleID,
            mode: .client(DigestClient(
                profileID: profile.id, provider: provider, feed: DigestFeed(fixed: fixed),
                bundleID: bundleID)))
    }

    /// The registry flips every face in one turn when the process's role
    /// changes. A retired client is shut down; a host's engines are the
    /// host's to retire.
    func adopt(_ newMode: Mode) {
        if case .client(let client) = mode { client.shutdown() }
        mode = newMode
    }

    /// Retires this face. Engines belong to the host; only a client-mode
    /// reader is this face's own.
    func shutdown() {
        if case .client(let client) = mode { client.shutdown() }
    }

    // MARK: - Forwards

    func refresh(_ reason: UsageEngine.RefreshReason) {
        switch mode {
        case .hosting: engine?.refresh(reason)
        case .client(let client): client.refresh()
        }
    }

    func apiBudget(now: Date) -> (used: Int, ceiling: Int, fraction: Double) {
        switch mode {
        case .hosting: engine?.apiBudget(now: now) ?? (0, RequestLedger.defaultCeiling, 0)
        case .client(let client): client.apiBudgetMirror
        }
    }

    func thresholdsChanged() {
        switch mode {
        case .hosting(let host): host.thresholdsChanged()
        case .client(let client): client.thresholdsChanged()
        }
    }

    func refreshPricingNow() {
        switch mode {
        case .hosting(let host): host.refreshPricingNow()
        case .client(let client): client.refreshPricingNow()
        }
    }

    func paceMultiplier(now: Date) -> Int {
        switch mode {
        case .hosting: engine?.paceMultiplier(now: now) ?? 1
        case .client(let client): client.paceMultiplierMirror
        }
    }

    func scanActivity(force: Bool = false) {
        switch mode {
        case .hosting: engine?.scanActivity(force: force)
        case .client(let client): client.scanActivity(force: force)
        }
    }

    func sessionDetail(id: String) async -> SessionDetail? {
        switch mode {
        case .hosting: await engine?.sessionDetail(id: id)
        case .client(let client): await client.sessionDetail(id: id)
        }
    }

    /// The pace is one setting for every profile's engine.
    func setActiveInterval(_ interval: TimeInterval) {
        switch mode {
        case .hosting(let host): host.setActiveInterval(interval)
        case .client(let client): client.setActiveInterval(interval)
        }
    }

    /// Asks for a fresher status card when the one on hand is aging — fired
    /// as the panel opens (decision D6). Cheap and fire-and-forget: the
    /// host rations it against the feed's own cache window, and a daemon
    /// too old to know the verb just refuses the command.
    func pokeServiceStatus() {
        guard fakeServiceStatus == nil else { return }
        switch mode {
        case .hosting(let host):
            guard Self.cardIsAging(serviceStatus) else { return }
            host.refreshServiceStatus()
        case .client(let client):
            client.pokeServiceStatusIfAging()
        }
    }

    /// The card is old enough that a window opening on it should ask for a
    /// fresh one. A nil card is NOT aging: nothing tracks status here.
    static func cardIsAging(_ card: ServiceStatusCard?, now: Date = Date()) -> Bool {
        guard let card else { return false }
        return now.timeIntervalSince(card.checkedAt) > 90
    }

    /// Installs a synthetic card for the `--fake-status` hatch, so every
    /// status surface can be clicked through without waiting for a real
    /// outage. Never called in an ordinary launch.
    func installFakeServiceStatus(_ card: ServiceStatusCard?) {
        fakeServiceStatus = card
    }

    /// Installs a synthetic notices card for the `--fake-notices` hatch,
    /// and the same incidents as outage spans for the charts' floor.
    func installFakeNotices(_ card: NoticesCard?, outages: [OutageSpan]? = nil) {
        fakeNotices = card
        fakeOutages = outages
    }

    // MARK: - Notices

    /// A face rendered these notices while pending — the panel opened on
    /// them, the hover popover showed. Seen is not dismissed (the dot
    /// stays); it decides how an ongoing notice's epilogue reads.
    func markNoticesSeen(_ ids: [String]) {
        guard !ids.isEmpty, fakeNotices == nil else { return }
        switch mode {
        case .hosting(let host): host.markNoticesSeen(ids)
        case .client(let client): client.markNoticesSeen(ids)
        }
    }

    /// The ×. The host refuses an ongoing notice; the fake drops the row
    /// so the hatch's click path reads like the real one.
    func dismissNotice(id: String) {
        if let fake = fakeNotices {
            fakeNotices = Self.dropping(fake) { $0.id == id && $0.dismissable }
            return
        }
        switch mode {
        case .hosting(let host): host.dismissNotice(id: id)
        case .client(let client): client.dismissNotice(id: id)
        }
    }

    func dismissAllNotices() {
        if let fake = fakeNotices {
            fakeNotices = Self.dropping(fake) { $0.dismissable }
            return
        }
        switch mode {
        case .hosting(let host): host.dismissAllNotices()
        case .client(let client): client.dismissAllNotices()
        }
    }

    /// The fake card minus the matching rows, its indicator recomputed by
    /// the digest's own rule.
    private static func dropping(
        _ card: NoticesCard, where gone: (NoticeCard) -> Bool
    ) -> NoticesCard {
        let items = card.items.filter { !gone($0) }
        return NoticesCard(
            indicator: items.contains { !$0.ownsMenuBarSurface },
            pendingCount: items.count, items: items)
    }

    /// Installs a synthetic release card for the `--fake-update` hatch.
    func installFakeAppUpdate(_ card: AppUpdateCard?) {
        fakeAppUpdate = card
    }

    /// Installs a synthetic distribution channel for the `--fake-channel`
    /// hatch, forcing the other flavor's update presentation.
    func installFakeDistribution(_ channel: (any DistributionChannel)?) {
        fakeDistribution = channel
    }

    /// Installs a synthetic presence card for the `--fake-accounts` hatch,
    /// so the multi-account surfaces can be clicked through on a machine
    /// that has only ever seen one account.
    func installFakeAccountPresence(_ card: AccountPresenceCard?) {
        fakeAccountPresence = card
    }

    /// A session row's chronological account labels, computed against the
    /// live attribution timeline (hosting) or the digest's reconstructed
    /// one (client). Nil = nothing tracks accounts; rows then show nothing.
    /// Callers gate on `accountPresence?.distinctAccounts` — one account
    /// ever means the labels would all read the same and say nothing.
    func sessionAccountLabels(_ session: SessionSummary) -> [String]? {
        let timeline: AccountTimeline?
        if let fakeAccountPresence {
            // The hatch has no epochs behind it; fabricate the label rule's
            // input from the card it installed, like the client path does.
            timeline = fakeTimeline(fakeAccountPresence)
        } else {
            switch mode {
            case .hosting: timeline = engine?.presenceTimeline
            case .client(let client): timeline = client.presenceTimeline
            }
        }
        guard let timeline else { return nil }
        return LiveStateBuilder.sessionAccountLabels(session, timeline: timeline)
    }

    private func fakeTimeline(_ card: AccountPresenceCard) -> AccountTimeline {
        AccountTimeline(epochs: card.epochs.map { epoch in
            AccountEpoch(
                account: AccountIdentity(
                    accountUuid: epoch.label, organizationUuid: "",
                    email: epoch.label),
                firstObservedAt: epoch.firstObservedAt,
                lastObservedAt: epoch.lastObservedAt,
                closedAt: epoch.closed ? epoch.lastObservedAt : nil)
        })
    }

    /// A user-asked release check — Settings' "Check Now". A hosting app
    /// checks directly; a client asks the daemon over the socket (an old
    /// daemon just refuses the verb, and the button's caption stays honest
    /// because the card's `checkedAt` won't move).
    func checkForUpdates() {
        guard fakeAppUpdate == nil else { return }
        switch mode {
        case .hosting(let host): host.checkForUpdates()
        case .client(let client): client.requestUpdateCheck()
        }
    }
}
