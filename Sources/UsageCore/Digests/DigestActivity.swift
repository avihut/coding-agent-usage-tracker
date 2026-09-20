import Foundation

/// A face's activity — heatmap days and the session shortlist — rebuilt from
/// a digest's own rollups instead of a transcript scan.
///
/// A client face normally scans the agent's transcripts itself (read-only):
/// the digest carries rollups, not the per-day model tallies and session
/// records the panel draws from. The `--demo-digest` hatch has no transcripts
/// it is allowed to read — the point of it is that nothing on this Mac shows
/// up in the picture — so its faces take what the digest does say. That is
/// less than a scan yields (no minute timeline, no per-session model split),
/// and only ever as much as a synthetic digest chose to publish.
public enum DigestActivity {
    /// One `DailyActivity` per rolled-up day. Day keys name LOCAL calendar
    /// days, so they are resolved in `calendar` — the heatmap buckets by the
    /// same one. A key that names no date is skipped, never guessed.
    public static func daily(
        from rollup: ActivityRollup, calendar: Calendar = .current
    ) -> [DailyActivity] {
        let tallies = Dictionary(
            rollup.modelDays.map { ($0.dayKey, $0.models) }, uniquingKeysWith: { first, _ in first })
        return rollup.days.compactMap { day in
            let parts = day.dayKey.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(
                      from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { return nil }
            let models = Dictionary(
                (tallies[day.dayKey] ?? []).map { ($0.id, $0.tally) },
                uniquingKeysWith: { first, _ in first })
            // `models` sums to `tokens` by DailyActivity's own contract; a
            // day the digest tallies per model takes that sum, so rounding
            // in the rollup can't open a gap between the two.
            let tokens = models.isEmpty ? day.tokens : models.values.reduce(0) { $0 + $1.total }
            return DailyActivity(
                day: date, tokens: tokens, messages: 0, prompts: day.prompts, models: models)
        }
    }

    /// The shortlist's cards as session summaries. A card names no models,
    /// so its tokens go to the digest's heaviest one, split across the token
    /// classes the way that model's own tally is — enough for a cost and a
    /// model dot, and nothing a drill-down could be built on.
    public static func sessions(from cards: [SessionCard], models: [ModelRow]) -> [SessionSummary] {
        let heaviest = models.max { $0.tally.total < $1.tally.total }
        return cards.map { card in
            var split: [String: TokenTally] = [:]
            if let heaviest, heaviest.tally.total > 0, card.tokens > 0 {
                let scale = Double(card.tokens) / Double(heaviest.tally.total)
                func part(_ value: Int) -> Int { Int((Double(value) * scale).rounded()) }
                split[heaviest.id] = TokenTally(
                    input: part(heaviest.tally.input), output: part(heaviest.tally.output),
                    cacheCreation: part(heaviest.tally.cacheCreation),
                    cacheRead: part(heaviest.tally.cacheRead),
                    cacheCreation1h: part(heaviest.tally.cacheCreation1h))
            }
            return SessionSummary(
                id: card.id, title: card.title, projectPath: card.project, gitBranch: card.branch,
                agentVersion: nil, kind: .interactive, start: card.startedAt,
                end: card.end ?? card.startedAt.addingTimeInterval(card.activeSeconds),
                activeSeconds: card.activeSeconds, prompts: card.prompts, apiCalls: card.apiCalls,
                toolCalls: 0, subagentCount: 0, compactions: 0, models: split)
        }
    }
}
