import Foundation

/// The digest's all-agents consumption (2026-11-21): tokens and list-price
/// cost summed across every account "all" counts (`ConsumptionMembership`),
/// every agent and model — the app panel's "All agents" reading, published
/// for the faces that only read the digest (the TUI, `usage-cli`). Limits
/// are never summed: two accounts are two meters, and nothing here is one.
///
/// Absent ≠ zero holds member by member: an account whose first scan hasn't
/// landed is named `scanning` and left out of every sum (the section is
/// then `partial`), never counted as nothing — and while NO member is
/// counted yet there is no total at all: `models` and `activity` are
/// absent, never a total of zero.
public struct AllAgentsState: Codable, Sendable, Equatable {
    /// Every account "all" counts, in the person's order, and how it counts.
    public let members: [AllAgentsMember]
    /// "3 agents", "2 of 3 agents", "2 accounts" — phrased once
    /// (`ConsumptionMembership.countLabel`).
    public let countLabel: String
    /// True while any member is `scanning`: the sums leave it out.
    public let partial: Bool
    /// Today's models across agents, heaviest first; every row names its
    /// `agent`. One model used from two accounts of one agent is one row.
    /// Nil while no member is counted.
    public let models: [ModelRow]?
    /// The merged activity, shaped exactly like the top level's so every
    /// face reads it with the code it already has. Its model rows carry
    /// `agent`; its hourly buckets reach back `AllAgentsDigest.hourSpanDays`.
    /// Nil while no member is counted.
    public let activity: ActivityRollup?

    public init(
        members: [AllAgentsMember], countLabel: String, partial: Bool, models: [ModelRow]?,
        activity: ActivityRollup?
    ) {
        self.members = members
        self.countLabel = countLabel
        self.partial = partial
        self.models = models
        self.activity = activity
    }
}

/// One account in the all-agents total.
public struct AllAgentsMember: Codable, Sendable, Equatable {
    public enum State: String, Sendable {
        /// Its scan landed and its traces carry tokens: in every sum.
        case counted
        /// Its engine's first scan hasn't landed yet (minutes on a large
        /// home): named, left out, the section `partial`.
        case scanning
        /// Its harness's traces carry no tokens (`UsageProvider
        /// .reportsTokens`): named, "not in the totals", prompts excluded.
        case noTokens
    }

    /// The account's `ProfileKey`.
    public let profile: String
    public let providerID: String
    /// A `State` raw value. A string on the wire so a later state is an
    /// addition a reader can skip, never a decode failure.
    public let state: String

    public init(profile: String, providerID: String, state: State) {
        self.profile = profile
        self.providerID = providerID
        self.state = state.rawValue
    }

    public var stateValue: State? { State(rawValue: state) }
}

/// What the host hands the composer of one account's landed scan — the same
/// in-memory days, minute timeline and price table the app's panel merges.
public struct SectionConsumption: Sendable, Equatable {
    public let days: [DailyActivity]
    public let timeline: [TokenSlot]
    public let pricing: PricingTable

    public init(days: [DailyActivity], timeline: [TokenSlot], pricing: PricingTable) {
        self.days = days
        self.timeline = timeline
        self.pricing = pricing
    }
}

/// Builds `LiveState.allAgents`. Pure; arithmetic over scans every account
/// already ran, through the functions the panel's merge uses
/// (`ConsumptionMerge.days`/`.pricing`) and the per-account rollup's own
/// builder (`LiveStateBuilder.activity`) — so the panel, the pane and the
/// CLI read one answer.
public enum AllAgentsDigest {
    /// How far back the section's hourly buckets reach — a SIZE cap. The
    /// per-account sections carry whatever their timeline holds (up to the
    /// scanner's 56-day retention); the total keeps the last 8 days so the
    /// file every status line decodes stays small. A drill past it says so
    /// (the TUI's day surface, `usage-cli … hours --all-agents`).
    public static let hourSpanDays = 8

    /// Nil when "all" holds fewer than two accounts: one account's own
    /// section is already the total, and a single-account Mac would
    /// otherwise carry a duplicate every status-line decode pays for.
    public static func build(
        harnesses: [HarnessSection], sections: [ProfileSection], now: Date,
        calendar: Calendar = .current, cache: AllAgentsCache? = nil
    ) -> AllAgentsState? {
        guard let cache else {
            return compute(harnesses: harnesses, sections: sections, now: now, calendar: calendar)
        }
        // Each horizon cuts at `now − N days`, which crosses a midnight at a
        // local midnight except across a DST change — key on where each cut
        // falls, not only on today.
        let floors = [
            LiveStateBuilder.daysHorizon, LiveStateBuilder.modelDaysHorizon,
            Double(hourSpanDays - 1) * 86400,
        ].map { calendar.startOfDay(for: now.addingTimeInterval(-$0)) }
        let inputs = AllAgentsCache.Inputs(
            day: calendar.startOfDay(for: now), floors: floors, timeZone: calendar.timeZone.identifier,
            harnesses: harnesses.map {
                .init(id: $0.provider.id, shown: $0.shown, ledger: $0.colorLedger)
            },
            sections: sections.map {
                .init(
                    key: $0.profile.key, providerID: $0.profile.providerID,
                    enrolled: $0.profile.isEnrolled, enabled: $0.profile.enabled,
                    dormant: $0.dormant, consumption: $0.consumption)
            })
        return cache.value(for: inputs) {
            compute(harnesses: harnesses, sections: sections, now: now, calendar: calendar)
        }
    }

    private static func compute(
        harnesses: [HarnessSection], sections: [ProfileSection], now: Date, calendar: Calendar
    ) -> AllAgentsState? {
        let shown = Set(harnesses.filter(\.shown).map(\.provider.id))
        let candidates = sections.map {
            ConsumptionMembership.Candidate(
                key: $0.profile.key, providerID: $0.profile.providerID,
                enrolled: $0.profile.isEnrolled, enabled: $0.profile.enabled, dormant: $0.dormant)
        }
        let memberList = ConsumptionMembership.members(candidates, shown: shown)
        guard memberList.count > 1 else { return nil }

        let harnessByID = Dictionary(
            harnesses.map { ($0.provider.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sectionByKey = Dictionary(
            sections.map { ($0.profile.key, $0) }, uniquingKeysWith: { first, _ in first })

        var members: [AllAgentsMember] = []
        var accounts: [AccountConsumption] = []
        var timeline: [TokenSlot] = []
        let hourFloor = calendar.startOfDay(
            for: now.addingTimeInterval(-Double(hourSpanDays - 1) * 86400))
        for member in memberList {
            let reportsTokens = harnessByID[member.agent]?.provider.reportsTokens ?? true
            guard reportsTokens else {
                members.append(AllAgentsMember(profile: member.account, providerID: member.agent, state: .noTokens))
                continue
            }
            guard let consumption = sectionByKey[member.account]?.consumption else {
                members.append(AllAgentsMember(profile: member.account, providerID: member.agent, state: .scanning))
                continue
            }
            members.append(AllAgentsMember(profile: member.account, providerID: member.agent, state: .counted))
            accounts.append(AccountConsumption(
                agent: member.agent, account: member.account, days: consumption.days,
                pricing: consumption.pricing))
            for slot in consumption.timeline where slot.t >= hourFloor {
                timeline.append(TokenSlot(
                    t: slot.t,
                    model: ConsumptionKey.make(agent: member.agent, account: member.account, model: slot.model),
                    tally: slot.tally))
            }
        }

        let countLabel = ConsumptionMembership.countLabel(
            members.map { ($0.providerID, $0.stateValue == .counted) })
        let partial = members.contains { $0.stateValue == .scanning }
        // Nobody counted yet: no total, rather than a total of zero.
        guard !accounts.isEmpty else {
            return AllAgentsState(
                members: members, countLabel: countLabel, partial: partial, models: nil,
                activity: nil)
        }
        let pricing = ConsumptionMerge.pricing(accounts)
        let spansAgents = Set(memberList.map(\.agent)).count > 1
        let rows = rowBuilder(harnesses: harnessByID, pricing: pricing, spansAgents: spansAgents)
        let (models, activity) = LiveStateBuilder.activity(
            ConsumptionMerge.days(accounts), timeline: timeline, pricing: pricing, now: now,
            calendar: calendar, rows: rows)
        return AllAgentsState(
            members: members, countLabel: countLabel, partial: partial, models: models,
            activity: activity)
    }

    /// Composite-keyed tallies (`agent␟account␟model`) → one row per agent +
    /// model, accounts of one agent summed. A row's cost is the sum of what
    /// its harness prices, nil when it prices none of it — absent, never 0.
    /// Names come from the agent's own catalog, colours from its own ledger
    /// by its own catalog's family (the engine seeds the ledger that way; a
    /// lookup by any other family reading would miss and paint slot 0).
    static func rowBuilder(
        harnesses: [String: HarnessSection], pricing: PricingTable, spansAgents: Bool
    ) -> ([String: TokenTally]) -> [ModelRow] {
        { tallies in
            struct Sum {
                var tally = TokenTally()
                var cost = 0.0
                var priced = false
            }
            var sums: [String: [String: Sum]] = [:]
            for (key, tally) in tallies {
                guard let parts = ConsumptionKey.split(key) else { continue }
                var sum = sums[parts.agent]?[parts.model] ?? Sum()
                sum.tally.add(tally)
                if let rates = pricing.rates(for: key) {
                    sum.cost += rates.dollars(for: tally)
                    sum.priced = true
                }
                sums[parts.agent, default: [:]][parts.model] = sum
            }
            var rows: [ModelRow] = []
            for (agent, models) in sums {
                let harness = harnesses[agent]
                let catalog = harness?.provider.modelCatalog
                let accent = harness.map { RGBColor($0.provider.accent) } ?? RGBColor(red: 0.5, green: 0.5, blue: 0.5)
                for (model, sum) in models {
                    let slots = harness?.colorLedger.slots(
                        for: model, family: catalog?.familyName(model) ?? model) ?? (hue: 0, shade: 0)
                    rows.append(ModelRow(
                        id: model, displayName: catalog?.displayName(model) ?? model,
                        // The dark variant, as every digest colour is
                        // (`LiveStateBuilder`): terminals draw on dark.
                        color: ConsumptionPalette.rgb(
                            hueSlot: slots.hue, shadeSlot: slots.shade, accent: accent,
                            spansAgents: spansAgents, on: .dark),
                        tally: sum.tally, cost: sum.priced ? sum.cost : nil, agent: agent))
                }
            }
            return rows.sorted { a, b in
                if a.tally.total != b.tally.total { return a.tally.total > b.tally.total }
                if a.agent != b.agent { return (a.agent ?? "") < (b.agent ?? "") }
                return a.id < b.id
            }
        }
    }
}

/// The host's memo of the last all-agents section. The composer runs on
/// every landing point of every engine — heartbeats included — while the
/// section only changes when a scan, a price table, a ledger, membership or
/// the calendar day does. Arrays compare by buffer identity first, so an
/// unchanged scan costs a pointer check. Held and used on the host's actor
/// only.
public final class AllAgentsCache {
    struct Inputs: Equatable {
        struct Harness: Equatable {
            let id: String
            let shown: Bool
            let ledger: ModelColorLedger
        }

        struct Section: Equatable {
            let key: String
            let providerID: String
            let enrolled: Bool
            let enabled: Bool
            let dormant: Bool
            let consumption: SectionConsumption?
        }

        /// "Today" turns over at a local midnight; each horizon's first day
        /// when its cut crosses one (`floors`).
        let day: Date
        let floors: [Date]
        let timeZone: String
        let harnesses: [Harness]
        let sections: [Section]
    }

    private var last: (inputs: Inputs, value: AllAgentsState?)?

    public init() {}

    func value(for inputs: Inputs, build: () -> AllAgentsState?) -> AllAgentsState? {
        if let last, last.inputs == inputs {
            // Content-equal but perhaps fresh buffers: keep the new ones, so
            // the next compare is identity-fast.
            self.last = (inputs, last.value)
            return last.value
        }
        let value = build()
        last = (inputs, value)
        return value
    }
}
