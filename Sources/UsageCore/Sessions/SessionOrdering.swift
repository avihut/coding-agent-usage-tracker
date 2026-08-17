import Foundation

/// The sessions sidebar's sort axes. Raw values are @AppStorage-persisted —
/// frozen, like every stored preference key.
public enum SessionSortKey: String, CaseIterable, Sendable {
    case recency
    case name
    case tokens
    case cost

    public var label: String {
        switch self {
        case .recency: "Recency"
        case .name: "Name"
        case .tokens: "Token usage"
        case .cost: "Cost"
        }
    }
}

/// Ordering and search for the sessions list. Pure and injected so it is
/// testable (the app target has no tests) and so a TUI parity pass can one
/// day reuse the exact ranking.
public enum SessionOrdering {
    /// `costOf` returns nil for a session whose cost is absent (all models
    /// unpriced — the card shows "—"); absent costs sink to the END under
    /// BOTH directions, because an unknown price is not "cheapest". Every
    /// axis breaks ties by recency (newest first) so toggling direction
    /// never shuffles equal rows arbitrarily.
    public static func sorted(
        _ sessions: [SessionSummary],
        by key: SessionSortKey,
        ascending: Bool,
        costOf: (SessionSummary) -> Double?
    ) -> [SessionSummary] {
        switch key {
        case .recency:
            let newestFirst = sessions.sorted { $0.end > $1.end }
            return ascending ? newestFirst.reversed() : newestFirst
        case .name:
            return sessions.sorted {
                let order = $0.title.localizedStandardCompare($1.title)
                guard order != .orderedSame else { return $0.end > $1.end }
                return ascending
                    ? order == .orderedAscending
                    : order == .orderedDescending
            }
        case .tokens:
            return sessions.sorted {
                guard $0.totalTokens != $1.totalTokens else { return $0.end > $1.end }
                return ascending
                    ? $0.totalTokens < $1.totalTokens
                    : $0.totalTokens > $1.totalTokens
            }
        case .cost:
            // Cost is priced per comparison input once, not per comparison —
            // it walks the session's whole model map.
            let keyed = sessions.map { (session: $0, cost: costOf($0)) }
            return keyed.sorted { a, b in
                switch (a.cost, b.cost) {
                case (nil, nil): return a.session.end > b.session.end
                case (nil, _): return false
                case (_, nil): return true
                case (let x?, let y?):
                    guard x != y else { return a.session.end > b.session.end }
                    return ascending ? x < y : x > y
                }
            }.map(\.session)
        }
    }

    /// Case-insensitive substring match over what a card can show: display
    /// title, project path, branch, and the session id. A blank query
    /// matches everything.
    public static func matches(_ session: SessionSummary, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var haystack = [session.title, session.id]
        if let path = session.projectPath { haystack.append(path) }
        if let branch = session.gitBranch { haystack.append(branch) }
        return haystack.contains {
            $0.range(of: trimmed, options: .caseInsensitive) != nil
        }
    }
}
