import Foundation

/// One account's consumption as a merged scope reads it: its days (the
/// account's own scan, already in memory), the price table its harness
/// prices with, and whether its traces carry tokens at all.
public struct AccountConsumption: Sendable, Equatable {
    public let agent: String
    public let account: String
    public let days: [DailyActivity]
    public let pricing: PricingTable
    public let reportsTokens: Bool

    public init(
        agent: String, account: String, days: [DailyActivity], pricing: PricingTable,
        reportsTokens: Bool = true
    ) {
        self.agent = agent
        self.account = account
        self.days = days
        self.pricing = pricing
        self.reportsTokens = reportsTokens
    }

    public var member: ConsumptionMember { ConsumptionMember(agent: agent, account: account) }
}

/// A session with the account it belongs to — `SessionSummary` ids are only
/// unique within one account's scan.
public struct OwnedSession: Sendable, Equatable, Identifiable {
    public let owner: String
    public let session: SessionSummary

    public init(owner: String, session: SessionSummary) {
        self.owner = owner
        self.session = session
    }

    public var id: String { "\(owner)\(ConsumptionKey.separator)\(session.id)" }
}

/// Arithmetic over scans every account already ran: a merged scope adds no
/// scan, file or destination. Limits are never merged — only consumption.
public enum ConsumptionMerge {
    /// Every account's days summed into ONE entry per calendar day, models
    /// keyed by `ConsumptionKey`. One entry per day is the contract the
    /// period layout relies on: `HeatmapLayout.build` keeps the first entry
    /// of a day for its cells but sums every entry into its totals, so two
    /// accounts' raw days would make the bars and the headline disagree.
    ///
    /// An account whose traces carry no tokens stays out entirely — the
    /// outline names it "not in the totals", so its prompt days must not
    /// count as active days or pass for a token agent's swept transcripts.
    public static func days(_ accounts: [AccountConsumption]) -> [DailyActivity] {
        var byDay: [Date: DailyActivity] = [:]
        for account in accounts where account.reportsTokens {
            for entry in account.days {
                var merged = byDay[entry.day] ?? DailyActivity(day: entry.day, tokens: 0, messages: 0)
                merged.tokens += entry.tokens
                merged.messages += entry.messages
                merged.prompts += entry.prompts
                for (model, tally) in entry.models {
                    let key = ConsumptionKey.make(agent: account.agent, account: account.account, model: model)
                    merged.models[key, default: TokenTally()].add(tally)
                }
                byDay[entry.day] = merged
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// One table keyed like the merged days: each model priced by its own
    /// harness's table, an unpriced one left out (absent, never zero).
    public static func pricing(_ accounts: [AccountConsumption]) -> PricingTable {
        var rates: [String: ModelRates] = [:]
        var fetchedAt = Date.distantFuture
        var allLive = !accounts.isEmpty
        for account in accounts {
            fetchedAt = min(fetchedAt, account.pricing.fetchedAt)
            allLive = allLive && account.pricing.source == .live
            let models = Set(account.days.flatMap(\.models.keys))
            for model in models {
                guard let rate = account.pricing.rates(for: model) else { continue }
                rates[ConsumptionKey.make(agent: account.agent, account: account.account, model: model)] = rate
            }
        }
        return PricingTable(
            rates: rates, fetchedAt: accounts.isEmpty ? .distantPast : fetchedAt,
            source: allLive ? .live : .bundled)
    }

    /// The Sessions strip across accounts, with the shortlist's own rules:
    /// interactive rows newest first by end, capped, `hasMore` covering the
    /// cap and every hidden background run, scoped to the navigated interval
    /// when there is one. Each scan arrives end-descending (its contract), so
    /// only each account's first `limit` interactive rows can make the cut —
    /// no sort of the whole corpus on a panel redraw.
    ///
    /// `nextOwner` is the account of the newest session the strip hides —
    /// where "Show more…" should land.
    public static func sessions(
        _ owned: [(owner: String, sessions: [SessionSummary])], in interval: DateInterval?,
        limit: Int = SessionShortlist.limit
    ) -> (rows: [OwnedSession], hasMore: Bool, nextOwner: String?) {
        func inInterval(_ session: SessionSummary) -> Bool {
            guard let interval else { return true }
            return session.end >= interval.start && session.start < interval.end
        }
        func newer(_ a: OwnedSession, _ b: OwnedSession) -> Bool {
            a.session.end != b.session.end ? a.session.end > b.session.end : a.id < b.id
        }
        var candidates: [OwnedSession] = []
        var total = 0
        for entry in owned {
            let mine = entry.sessions.lazy.filter(inInterval)
            candidates += mine.filter { $0.kind == .interactive }.prefix(limit)
                .map { OwnedSession(owner: entry.owner, session: $0) }
            total += mine.count
        }
        let rows = Array(candidates.sorted(by: newer).prefix(limit))
        let shown = Set(rows.map(\.id))
        // The newest hidden one per account is its first entry not shown;
        // the newest of those across accounts.
        let hidden = owned.compactMap { entry in
            entry.sessions.lazy.filter(inInterval)
                .map { OwnedSession(owner: entry.owner, session: $0) }
                .first { !shown.contains($0.id) }
        }
        return (rows, total > rows.count, hidden.min(by: newer)?.owner)
    }
}
