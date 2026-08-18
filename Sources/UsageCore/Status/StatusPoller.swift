import Foundation

/// Polls one provider's status feed and hands the engine a normalized card.
///
/// Owns the moving parts the pure pieces deliberately don't: the one-shot
/// timer (rescheduled every poll, so the cadence can change between them —
/// same shape as `Scheduler`), the ETag, the last good page, and the 60-minute
/// memory of incidents that resolved (decision D4).
///
/// Two invariants worth stating, because both are easy to violate later:
/// a failed fetch NEVER becomes an incident (it ages the card and, after
/// three, turns the indicator `unknown`), and nothing here writes to disk —
/// the card reaches consumers only by being published in the digest by the
/// engine that owns this poller.
@MainActor
public final class StatusPoller {
    /// Fires whenever the card changes — the engine republishes the digest.
    public var onCard: ((ServiceStatusCard) -> Void)?

    public private(set) var card: ServiceStatusCard?
    public private(set) var cadence = StatusCadence()

    private let feed: StatuspageFeed
    private let providerID: String
    private let pageURL: String
    private var timer: Timer?
    private var etag: String?
    /// The last successfully decoded page — a 304 says "what you have is
    /// still true", so the card is rebuilt from this with a fresh `checkedAt`.
    private var lastPage: StatuspageSummary?
    private var okAt: Date?
    private var isPolling = false
    private var isStopped = false
    /// Incidents seen unresolved that have since gone — kept for an hour so
    /// the popover can say "all clear" after the loud surfaces went dark.
    private var resolvedMemory: [StatusIncident] = []

    /// How long a resolved incident stays in the popover's quiet row (D4).
    public static let resolvedMemorySpan: TimeInterval = 3600
    /// Past this, a card is old enough to distrust even if nothing failed —
    /// two healthy intervals plus slack, so a sleeping Mac's card reads stale
    /// on wake rather than confidently wrong.
    public static let staleAfter: TimeInterval = 900

    public init(feed: StatuspageFeed, providerID: String, pageURL: String) {
        self.feed = feed
        self.providerID = providerID
        self.pageURL = pageURL
    }

    /// Begins polling, starting with an immediate read.
    public func start() {
        guard !isStopped else { return }
        poll()
    }

    /// Retires the poller; a pending timer never fires again.
    public func stop() {
        isStopped = true
        timer?.invalidate()
        timer = nil
        onCard = nil
    }

    /// An out-of-band poke — wake, a panel opening on a stale card, a manual
    /// request. Honors the CDN spacing floor, so poking in a loop can't turn
    /// into a hot loop against the feed.
    public func pollNow() {
        guard !isStopped, cadence.mayPollNow(Date()) else { return }
        poll()
    }

    /// True when the card is old enough that a consumer opening a window
    /// should ask for a fresh one (decision D6's 90-second rule lives with
    /// the caller; this is the poller's own view for internal use).
    public var isCardStale: Bool {
        guard let card else { return true }
        return Date().timeIntervalSince(card.checkedAt) > Self.staleAfter
    }

    private func poll() {
        guard !isStopped, !isPolling else { return }
        isPolling = true
        let etag = etag
        Task { [weak self] in
            guard let self else { return }
            let result: Result<StatuspageFeed.Outcome, Error>
            do {
                result = .success(try await self.feed.fetchSummary(etag: etag))
            } catch {
                result = .failure(error)
            }
            self.finish(result)
        }
    }

    private func finish(_ result: Result<StatuspageFeed.Outcome, Error>) {
        isPolling = false
        guard !isStopped else { return }
        let now = Date()

        switch result {
        case .success(.fresh(let page, let newETag)):
            etag = newETag
            lastPage = page
            okAt = now
            cadence.record(
                .observed(hasIncident: Self.hasUnresolved(page)), now: now)
        case .success(.notModified):
            // The body we hold is still current; only its freshness moved.
            okAt = now
            cadence.record(
                .observed(hasIncident: lastPage.map(Self.hasUnresolved) ?? false), now: now)
        case .failure:
            cadence.record(.failed, now: now)
        }

        rebuildCard(now: now)
        scheduleNext()
    }

    private static func hasUnresolved(_ page: StatuspageSummary) -> Bool {
        (page.incidents ?? []).contains(where: StatuspageAdapter.isUnresolved)
    }

    /// Rebuilds the published card from the last good page plus the current
    /// freshness verdict. Called after every poll, success or not — a failure
    /// changes only staleness and (past the threshold) the indicator.
    private func rebuildCard(now: Date) {
        let stale = cadence.isUnknown
            || okAt.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true

        guard let page = lastPage else {
            // Nothing has ever landed. Say so honestly rather than inventing
            // a green card: absent knowledge is `unknown`, never "fine".
            guard cadence.failures > 0 else { return }
            publish(ServiceStatusCard(
                providerID: providerID,
                pageName: providerID,
                pageURL: pageURL,
                indicator: ServiceStatusCard.Indicator.unknown.rawValue,
                descriptionText: "",
                checkedAt: now,
                okAt: nil,
                stale: true,
                components: [],
                incidents: []))
            return
        }

        var fresh = StatuspageAdapter.card(
            from: page, providerID: providerID, pageURL: pageURL,
            checkedAt: now, okAt: okAt, stale: stale)
        rememberResolved(from: fresh, now: now)
        fresh = StatuspageAdapter.card(
            from: page, providerID: providerID, pageURL: pageURL,
            checkedAt: now, okAt: okAt, stale: stale,
            recentlyResolved: resolvedMemory)

        // A feed we can no longer reach stops claiming to know the state —
        // but only past the failure threshold, and never by inventing an
        // incident: `unknown` is grey and quiet (D3).
        if cadence.isUnknown {
            fresh = ServiceStatusCard(
                providerID: fresh.providerID, pageName: fresh.pageName,
                pageURL: fresh.pageURL,
                indicator: ServiceStatusCard.Indicator.unknown.rawValue,
                descriptionText: fresh.descriptionText,
                checkedAt: fresh.checkedAt, okAt: fresh.okAt, stale: true,
                components: fresh.components, incidents: fresh.incidents,
                recentlyResolved: fresh.recentlyResolved,
                maintenances: fresh.maintenances)
        }
        publish(fresh)
    }

    /// Moves incidents that have left the unresolved list into the hour-long
    /// resolved memory, and expires old ones out of it.
    private func rememberResolved(from fresh: ServiceStatusCard, now: Date) {
        let stillOpen = Set(fresh.incidents.map(\.id))
        if let previous = card {
            for incident in previous.incidents where !stillOpen.contains(incident.id) {
                guard !resolvedMemory.contains(where: { $0.id == incident.id }) else { continue }
                resolvedMemory.append(StatusIncident(
                    id: incident.id, name: incident.name, impact: incident.impact,
                    phase: "resolved", startedAt: incident.startedAt,
                    lastUpdateAt: incident.lastUpdateAt, lastMessage: incident.lastMessage,
                    url: incident.url, componentNames: incident.componentNames,
                    resolvedAt: now))
            }
        }
        resolvedMemory.removeAll { incident in
            stillOpen.contains(incident.id)
                || (incident.resolvedAt.map {
                    now.timeIntervalSince($0) > Self.resolvedMemorySpan
                } ?? true)
        }
        resolvedMemory.sort { ($0.resolvedAt ?? .distantPast) > ($1.resolvedAt ?? .distantPast) }
    }

    private func publish(_ fresh: ServiceStatusCard) {
        guard fresh != card else { return }
        card = fresh
        onCard?(fresh)
    }

    private func scheduleNext() {
        guard !isStopped else { return }
        timer?.invalidate()
        let delay = cadence.nextDelay()
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // A background poller: generous tolerance lets macOS coalesce the
        // wakeup with whatever else it was going to wake for.
        timer.tolerance = min(max(5, delay * 0.1), delay / 2)
        self.timer = timer
    }
}
