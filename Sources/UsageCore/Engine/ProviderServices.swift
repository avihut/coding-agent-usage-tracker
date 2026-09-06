import Foundation
import Observation

/// The vendor-level half of metering, shared by every profile's engine
/// (D3, the hybrid host): the pricing feed, the status poller, and the
/// notice ledger's ONE writer. A second account is a second engine — it
/// is NOT a second status poll, a second pricing fetch, or a second
/// notices.json, so spec §10's destinations stay one-per-provider however
/// many homes are metered.
///
/// Every change a digest should reflect — a status card, a ledger edit
/// (from this poller or from any engine's grant detection), a pricing
/// table — fires `onChange`; the host republishes.
@MainActor
@Observable
public final class ProviderServices {
    public let provider: any UsageProvider
    /// The one writer of `<provider>/notices.json`.
    @ObservationIgnored public let notices: NoticeLedgerStore
    /// Best pricing table available (live feed, disk cache, or bundled).
    public private(set) var pricing: PricingTable
    public private(set) var isRefreshingPricing = false
    /// Last manual pricing-refresh failure; cleared on the next attempt.
    public private(set) var pricingRefreshError: String?
    /// The provider's service health, or nil when it declares no status
    /// feed (absent is not healthy — see `ServiceStatusCard`).
    public private(set) var serviceStatus: ServiceStatusCard?
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let pricingService: PricingService
    @ObservationIgnored private var statusPoller: StatusPoller?
    @ObservationIgnored private var lastPricingAttempt: Date?
    @ObservationIgnored private let pollsStatus: Bool
    @ObservationIgnored private var isStopped = false

    /// How far back a start-up or wake catch-up reaches for grants in the
    /// sample history and resolved incidents in the page's history.
    public static let noticeCatchUp: TimeInterval = 48 * 3600

    /// `pollsStatus: false` builds no poller — tests, and a host that must
    /// stay offline.
    public init(
        provider: any UsageProvider, bundleID: String, roots: StorageScope.Roots = .standard,
        pollsStatus: Bool = true
    ) {
        let directory = StorageScope.providerDirectory(
            bundleID: bundleID, providerID: provider.id, roots: roots)
        self.provider = provider
        self.notices = NoticeLedgerStore(directory: directory)
        self.pricingService = PricingService(
            cacheDirectory: directory, fallback: provider.bundledRates,
            selector: provider.pricingSelector)
        self.pricing = pricingService.current()
        self.pollsStatus = pollsStatus
        notices.onChange = { [weak self] in self?.onChange?() }
    }

    /// Whether this provider tracks status at all — the outage floor is
    /// absent (nil), not empty, when it doesn't.
    public var tracksStatus: Bool { provider.statusFeed != nil }

    public func start() {
        guard !isStopped, pollsStatus, case .statuspage(let base, let pageURL) = provider.statusFeed
        else { return }
        let poller = StatusPoller(
            feed: StatuspageFeed(base: base), providerID: provider.id,
            pageURL: pageURL.absoluteString)
        poller.onCard = { [weak self] card in
            guard let self, !self.isStopped else { return }
            self.serviceStatus = card
            // An incident opening, changing, or resolving is a notice
            // transition; the ledger reads every card. The ledger's own
            // change signal republishes; a card that changed nothing in the
            // ledger still needs the digest rewritten.
            let ledgerChanged = self.notices.mutate {
                NoticeDetector.apply(card: card, now: Date(), into: &$0)
            }
            if !ledgerChanged { self.onChange?() }
        }
        poller.onHistory = { [weak self] history in
            guard let self, !self.isStopped else { return }
            let now = Date()
            // Two days of incidents are news; the rest of the retention
            // window lands as already-dismissed facts for the charts'
            // outage floor, so a fresh ledger never floods the panel.
            self.notices.mutate {
                NoticeDetector.backfill(
                    history: history, since: now.addingTimeInterval(-Self.noticeCatchUp),
                    factsSince: now.addingTimeInterval(-OutageTimeline.retention),
                    now: now, into: &$0)
            }
        }
        statusPoller = poller
        poller.start()
    }

    public func stop() {
        isStopped = true
        statusPoller?.stop()
        statusPoller = nil
        onChange = nil
        notices.onChange = nil
    }

    /// A status card from before the lid closed is stale in exactly the
    /// way the meters are; an incident that opened and closed during the
    /// sleep is gone from the summary an hour after resolving — the
    /// history read finds it. ONCE per provider, not once per engine.
    public func noteWake() {
        statusPoller?.pollNow()
        statusPoller?.pollHistoryNow()
    }

    /// An out-of-band status read — the control socket's `refreshStatus`,
    /// which the app fires when a panel opens on an aging card. Rationed by
    /// the feed's own CDN spacing, so poking is always safe.
    public func refreshServiceStatus() {
        statusPoller?.pollNow()
    }

    /// Every incident within retention for the charts' outage floor; nil
    /// when the provider tracks no status.
    public func outageSpans(now: Date) -> [OutageSpan]? {
        tracksStatus ? OutageTimeline.spans(from: notices.notices, now: now) : nil
    }

    /// Piggybacks on usage refreshes: at most one feed fetch attempt per
    /// hour, and only while the table is older than a day (or bundled).
    /// Any engine's cycle may call it; the attempt floor is shared.
    public func refreshPricingIfStale() async {
        let now = Date()
        guard !isStopped, pricing.isStale(now: now) else { return }
        if let last = lastPricingAttempt, now.timeIntervalSince(last) < 3600 { return }
        lastPricingAttempt = now
        if let fresh = await pricingService.refreshIfStale(now: now) {
            pricing = fresh
            onChange?()
        }
    }

    /// The settings screen's refresh button — always fetches (the automatic
    /// path above stays daily). Single-flighted; failure text lands beside
    /// the button instead of in a log nobody reads.
    public func refreshPricingNow() {
        guard !isStopped, !isRefreshingPricing else { return }
        isRefreshingPricing = true
        pricingRefreshError = nil
        Task {
            do {
                pricing = try await pricingService.refreshNow()
                onChange?()
            } catch let error as PricingFeedError {
                pricingRefreshError = error.shortText
            } catch {
                pricingRefreshError = "unexpected error"
            }
            isRefreshingPricing = false
        }
    }
}
