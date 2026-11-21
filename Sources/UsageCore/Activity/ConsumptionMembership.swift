import Foundation

/// Who "all agents" counts — one rule for every face that totals
/// consumption: the app's panel, the digest's `allAgents` section and
/// `usage-cli --all-agents`. An account is in when it is enrolled, turned
/// on and awake (the account strip's accounts) and its harness is shown.
/// Dormant accounts stay out: while the app hosts they have no engine and so
/// no activity in memory, and counting them would take a scan of their own
/// and make the total depend on which process hosts (#37, user-confirmed).
/// Whether the account also sits in the menu BAR is the bar's business
/// (`showInMenuBar`), never this rule's.
public enum ConsumptionMembership {
    /// One account as the rule sees it.
    public struct Candidate: Sendable, Equatable {
        /// The account's `ProfileKey`.
        public let key: String
        public let providerID: String
        public let enrolled: Bool
        public let enabled: Bool
        public let dormant: Bool

        public init(key: String, providerID: String, enrolled: Bool, enabled: Bool, dormant: Bool) {
            self.key = key
            self.providerID = providerID
            self.enrolled = enrolled
            self.enabled = enabled
            self.dormant = dormant
        }
    }

    /// The members, in the order given (the person's own). `shown` names the
    /// harnesses the person shows; nil means every harness is (a writer that
    /// metered one harness publishes no roster).
    public static func members(_ candidates: [Candidate], shown: Set<String>?) -> [ConsumptionMember] {
        candidates
            .filter { $0.enrolled && $0.enabled && !$0.dormant }
            .filter { shown?.contains($0.providerID) ?? true }
            .map { ConsumptionMember(agent: $0.providerID, account: $0.key) }
    }

    /// The same rule over a published digest — how `usage-cli` tells a
    /// one-account Mac (no `allAgents` section, nothing to total) from a
    /// writer that predates the section. A pre-profile digest metered
    /// exactly one account: its top level.
    public static func members(of digest: LiveState) -> [ConsumptionMember] {
        guard let profiles = digest.profiles else {
            return [ConsumptionMember(agent: digest.engine.providerID, account: Profile.defaultID)]
        }
        let candidates = profiles.map {
            Candidate(
                key: $0.id, providerID: $0.providerID, enrolled: true, enabled: $0.enabled,
                dormant: $0.dormant)
        }
        return members(candidates, shown: digest.harnesses.map { Set($0.filter(\.shown).map(\.id)) })
    }

    /// "3 agents", "2 of 3 agents" (one isn't in the sums — it reports no
    /// tokens, or hasn't been scanned yet), "2 accounts" (one agent's
    /// several). Phrased here once, so the panel, the pane and the CLI say
    /// the same words.
    public static func countLabel(_ members: [(agent: String, counted: Bool)]) -> String {
        var agents: [String] = []
        for member in members where !agents.contains(member.agent) { agents.append(member.agent) }
        guard agents.count > 1 else { return "\(members.count) accounts" }
        let counted = agents.filter { agent in
            members.contains { $0.agent == agent && $0.counted }
        }.count
        return counted == agents.count ? "\(agents.count) agents" : "\(counted) of \(agents.count) agents"
    }
}

/// How a model is painted wherever consumption is totalled. One agent in
/// scope keeps the colours its models wear everywhere; several paint each
/// model in its AGENT's accent at the family's tone, so two vendors can
/// never wear look-alikes. The slots are the agent's own ledger's; the
/// arithmetic is `ModelColorMath`'s, untouched here.
public enum ConsumptionPalette {
    public static func rgb(hueSlot: Int, shadeSlot: Int, accent: RGBColor, spansAgents: Bool) -> RGBColor {
        spansAgents
            ? ModelColorMath.agentShade(hueSlot: hueSlot, shadeSlot: shadeSlot, accent: accent)
            : ModelColorMath.rgb(hueSlot: hueSlot, shadeSlot: shadeSlot, accent: accent)
    }
}
