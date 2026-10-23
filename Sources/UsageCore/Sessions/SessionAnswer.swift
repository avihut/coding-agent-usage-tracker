import Foundation

/// One model's share of a session — the `session … models` field's row.
public struct SessionModelCost: Codable, Sendable, Equatable {
    public let id: String
    public let tokens: Int
    /// Nil = the model is unpriced — absent, never $0.
    public let cost: Double?

    public init(id: String, tokens: Int, cost: Double?) {
        self.id = id
        self.tokens = tokens
        self.cost = cost
    }

    private enum CodingKeys: String, CodingKey {
        case id, tokens, cost
    }
}

/// What a session index knows past the shortlist card: the `session` deep
/// fields. Built from a scanned `SessionSummary` in exactly one place, so a
/// scan hit, the engine's answer and `transcript <path>` print the same
/// values through the same formatter.
public struct SessionDeepFields: Codable, Sendable, Equatable {
    /// `SessionKind`'s raw value — carried as text so a kind added later
    /// still crosses the wire to an older reader.
    public let kind: String
    public let toolCalls: Int
    public let subagents: Int
    public let compactions: Int
    public let agentVersion: String?
    /// Heaviest first, ties by id — the order the `models` field prints.
    public let models: [SessionModelCost]

    init(summary: SessionSummary, modelCosts: [String: Double]) {
        kind = summary.kind.rawValue
        toolCalls = summary.toolCalls
        subagents = summary.subagentCount
        compactions = summary.compactions
        agentVersion = summary.agentVersion
        models = summary.models
            .map { SessionModelCost(id: $0.key, tokens: $0.value.total, cost: modelCosts[$0.key]) }
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.id < $1.id }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, toolCalls, subagents, compactions, agentVersion, models
    }
}

/// The engine's answer to one `ControlCommand.session` lookup, read from
/// the index its last transcript scan built — EVERY session that scan
/// holds, not only the eight the digest publishes (issue #24: a session
/// open but idle for days never returns to the shortlist, and answering
/// it by re-scanning the corpus per caller is what pinned 12 cores).
///
/// Carries only what the digest's sessions section already carries under
/// spec §10's 2026-08-17 re-amendment — the card, whose `project` is a
/// folder name and never a path — plus the scan's counts and model ids.
/// Nothing here is persisted; it crosses the same 0600 socket and is gone.
public struct SessionAnswer: Codable, Sendable, Equatable {
    /// The most ids an ambiguous prefix lists — enough to pick from, and a
    /// bound that keeps the reply far inside the socket's 64 KB line.
    public static let matchCap = 50

    /// The ids the prefix matched, newest activity first, at most
    /// `matchCap`: empty is a real "no such session", one is a hit, more
    /// is ambiguous.
    public let matches: [String]
    /// Present exactly when `matches` holds one id.
    public let card: SessionCard?
    public let deep: SessionDeepFields?

    public init(matches: [String], card: SessionCard?, deep: SessionDeepFields?) {
        self.matches = matches
        self.card = card
        self.deep = deep
    }

    public enum Resolution: Equatable, Sendable {
        case found(SessionCard, SessionDeepFields)
        case ambiguous([String])
        case none
    }

    /// Nil for a shape no engine sends (one match without its card) — the
    /// caller treats it as no answer, never as a hit.
    public var resolution: Resolution? {
        switch matches.count {
        case 0: return Resolution.none
        case 1:
            guard let card, let deep, card.id == matches[0] else { return nil }
            return .found(card, deep)
        default: return .ambiguous(matches)
        }
    }

    /// The lookup itself, pure: `id` is a case-insensitive prefix, the same
    /// rule `DeepQuerySessions.select` applies to a scan. The card is built
    /// by the digest's own `sessionCards` — one conversion, one place the
    /// cwd is cut to its folder name — and the ledger is read only on a hit.
    static func lookup(
        _ id: String, in sessions: [SessionSummary], pricing: PricingTable, catalog: ModelCatalog,
        colorLedger: () -> ModelColorLedger, accent: RGBColor, timeline: AccountTimeline?
    ) -> SessionAnswer {
        let needle = id.lowercased()
        let hits = sessions.filter { $0.id.lowercased().hasPrefix(needle) }
        guard hits.count == 1, let hit = hits.first else {
            return SessionAnswer(
                matches: hits.sorted { $0.end > $1.end }.prefix(matchCap).map(\.id), card: nil, deep: nil)
        }
        let card = LiveStateBuilder.sessionCards(
            [hit], pricing: pricing, catalog: catalog, colorLedger: colorLedger(), accent: accent,
            timeline: timeline)[0]
        let entry = DeepQuerySessions.entry(hit, pricing: pricing)
        return SessionAnswer(
            matches: [hit.id], card: card,
            deep: SessionDeepFields(summary: hit, modelCosts: entry.modelCosts))
    }

    private enum CodingKeys: String, CodingKey {
        case matches, card, deep
    }
}
