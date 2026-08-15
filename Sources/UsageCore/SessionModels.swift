import Foundation

/// How a session was driven — the browser's background badge and filter read
/// this. Claude Code stamps every record with `entrypoint`; anything that
/// isn't the interactive CLI ("sdk-py" hook runs, future SDK values) is
/// background work.
public enum SessionKind: String, Sendable, Equatable {
    case interactive
    case background
}

/// One agent session as the sessions sidebar lists it. Derived fresh on every
/// transcript scan; deliberately NOT Codable — the one sanctioned persisted
/// preview lives inside the scanner's private cache types, and nothing else
/// may casually persist prompt text.
public struct SessionSummary: Sendable, Equatable, Identifiable {
    /// Provider-scoped session id (Claude: the transcript's filename UUID).
    public let id: String
    /// Resolved display title; never empty (aiTitle > first prompt > id).
    public let title: String
    public let projectPath: String?
    public let gitBranch: String?
    /// The agent's own version stamp ("2.1.231"), when recorded.
    public let agentVersion: String?
    public let kind: SessionKind
    public let start: Date
    /// Last timestamped activity — the list's sort key.
    public let end: Date
    /// Union of grace-stitched activity stretches across the main transcript
    /// and its subagents — honest working time, not wall span (a session left
    /// open overnight doesn't claim the night).
    public let activeSeconds: TimeInterval
    public let prompts: Int
    public let apiCalls: Int
    public let toolCalls: Int
    public let subagentCount: Int
    public let compactions: Int
    /// Tokens attributed per raw model id, main + subagents.
    public let models: [String: TokenTally]

    public var totalTokens: Int { models.values.reduce(0) { $0 + $1.total } }

    public init(
        id: String, title: String, projectPath: String?, gitBranch: String?,
        agentVersion: String?, kind: SessionKind, start: Date, end: Date,
        activeSeconds: TimeInterval, prompts: Int, apiCalls: Int, toolCalls: Int,
        subagentCount: Int, compactions: Int, models: [String: TokenTally]
    ) {
        self.id = id
        self.title = title
        self.projectPath = projectPath
        self.gitBranch = gitBranch
        self.agentVersion = agentVersion
        self.kind = kind
        self.start = start
        self.end = end
        self.activeSeconds = activeSeconds
        self.prompts = prompts
        self.apiCalls = apiCalls
        self.toolCalls = toolCalls
        self.subagentCount = subagentCount
        self.compactions = compactions
        self.models = models
    }
}

/// One row of the detail page's message-by-message breakdown. In-memory only.
public struct SessionEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case prompt(preview: String)
        case command(name: String)
        case compaction
        case apiCall(model: String, tally: TokenTally, toolUses: Int)
    }

    /// Ordinal in file order — also the index into `SessionLedger` entries.
    public let id: Int
    public let t: Date
    public let kind: Kind

    public init(id: Int, t: Date, kind: Kind) {
        self.id = id
        self.t = t
        self.kind = kind
    }
}

/// One session parsed in full: a refreshed summary (main file fresh, subagent
/// counters from the scan cache) plus the ordered rows. Subagent activity is
/// folded into the summary's counters, never interleaved as rows.
public struct SessionDetail: Sendable, Equatable {
    public let summary: SessionSummary
    public let rows: [SessionEvent]

    public init(summary: SessionSummary, rows: [SessionEvent]) {
        self.summary = summary
        self.rows = rows
    }
}

/// Display-only scrubbing of transcript text. The scrubbed form is the ONLY
/// shape of prompt text that ever leaves the parser — cards, detail rows, and
/// the persisted title-fallback all pass through here.
public enum PromptPreview {
    public static let maxLength = 120

    /// Strips ANSI escapes, collapses long base64-ish runs to "[data]",
    /// collapses whitespace, and caps at `maxLength`. Nil when nothing
    /// displayable survives.
    public static func scrub(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "[A-Za-z0-9+/=]{80,}", with: "[data]", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "…"
    }

    /// "<command-name>/compact</command-name>…" → "/compact"; nil when the
    /// text carries no command marker.
    public static func commandName(_ raw: String) -> String? {
        guard let open = raw.range(of: "<command-name>"),
              let close = raw.range(of: "</command-name>", range: open.upperBound..<raw.endIndex)
        else { return nil }
        let name = raw[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// Running cost down a session's detail rows. One entry PER row, index-aligned
/// with `SessionEvent.id`, so consumers subscript directly instead of searching.
/// Unpriced models contribute nil increments and are excluded from the running
/// sum — never silently $0 (the ModelBreakdownGrid rule).
public enum SessionLedger {
    public struct Entry: Sendable, Equatable {
        /// This row's cost; nil for non-call rows and unpriced models.
        public let incremental: Double?
        /// Cumulative priced cost through this row.
        public let running: Double

        public init(incremental: Double?, running: Double) {
            self.incremental = incremental
            self.running = running
        }
    }

    public static func runningCost(rows: [SessionEvent], pricing: PricingTable) -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(rows.count)
        var running = 0.0
        for row in rows {
            if case .apiCall(let model, let tally, _) = row.kind,
               let rates = pricing.rates(for: model) {
                let dollars = rates.dollars(for: tally)
                running += dollars
                entries.append(Entry(incremental: dollars, running: running))
            } else {
                entries.append(Entry(incremental: nil, running: running))
            }
        }
        return entries
    }

    /// Models that appear in call rows but have no rate — surfaced as
    /// "N unpriced" beside totals.
    public static func unpricedModels(rows: [SessionEvent], pricing: PricingTable) -> Set<String> {
        var unpriced: Set<String> = []
        for row in rows {
            if case .apiCall(let model, _, _) = row.kind, pricing.rates(for: model) == nil {
                unpriced.insert(model)
            }
        }
        return unpriced
    }
}

/// Day sections for the sessions sidebar. Pure and calendar-injected so the
/// grouping is testable (the app target has no tests).
public enum SessionDayGroup {
    public struct Group: Sendable, Equatable, Identifiable {
        public let day: Date
        public let sessions: [SessionSummary]

        public var id: Date { day }

        public init(day: Date, sessions: [SessionSummary]) {
            self.day = day
            self.sessions = sessions
        }
    }

    /// Groups by the day of each session's `end` (the sort key). Input arrives
    /// end-descending per the scan's contract; groups come out newest day
    /// first with intra-day order preserved.
    public static func build(_ sessions: [SessionSummary], calendar: Calendar) -> [Group] {
        var order: [Date] = []
        var byDay: [Date: [SessionSummary]] = [:]
        for session in sessions {
            let day = calendar.startOfDay(for: session.end)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(session)
        }
        return order.map { Group(day: $0, sessions: byDay[$0] ?? []) }
    }
}
