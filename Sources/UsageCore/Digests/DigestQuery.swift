import Foundation

/// One query's answer: `stdout` never carries a trailing newline (the CLI
/// layer appends exactly one, so a caller controls line termination in a
/// single place); `note` is commentary for stderr, in the existing `note()`
/// pattern; `exitCode` is part of the API (spec: 0 ok, 13 no digest — the
/// CLI's own concern, before a `DigestQuery` call happens — 19 bad query,
/// 20 selector matched nothing, 21 stale beyond `--max-age`).
public struct QueryOutput: Sendable, Equatable {
    public let stdout: String
    public let note: String?
    public let exitCode: Int32

    public init(stdout: String, note: String? = nil, exitCode: Int32) {
        self.stdout = stdout
        self.note = note
        self.exitCode = exitCode
    }
}

/// The `usage-cli` query grammar over `live-state.json` — one flat noun
/// table, kebab-case field paths, three output registers. A pure enum of
/// static funcs (Swift 6 strict concurrency: no shared mutable state — even
/// the noun/flag vocabularies below are immutable `let` sets, not doors into
/// anything mutable) so the whole surface is headlessly testable: every
/// answer is a deterministic function of its arguments, never of the clock
/// or the filesystem (the CLI target owns both, and hands them in as `now`
/// and `digest`/`rawDigest`).
///
/// Design reference: the approved query-surface artifact the v0.81.0 plan
/// links (§§2-3 for the grammar/registers, per-noun sections for field
/// tables). Where an example there shows a style this codebase doesn't have
/// a formatter for ("2d 4h", "proj. 74% at reset"), THIS file follows the
/// house formatters (`UsageFormatting.duration`/`.money`, pre-phrased
/// captions) instead — the artifact's mockups illustrate shape, not
/// literal output.
public enum DigestQuery {
    static let exitOK: Int32 = 0
    static let exitBadQuery: Int32 = 19
    static let exitNoMatch: Int32 = 20
    static let exitStale: Int32 = 21

    /// The grammar's own noun vocabulary — `run` below validates argv's
    /// noun position against this set directly (bad-query exit for
    /// anything else); public so a caller can enumerate it without a
    /// second copy of the list.
    public static let nouns: Set<String> = [
        "status", "health", "account", "notices", "limits", "limit", "budget", "spend",
        "activity", "cost", "models", "model",
        "sessions", "session", "prompt", "get",
    ]

    /// `all`/`background`/`no-background` are M2 deep-verb flags —
    /// registered here, in the ONE shared parser, so `DeepQuery.run`
    /// doesn't duplicate a second grammar. Registration is not
    /// applicability: `rejectInapplicableFlags` below returns them to
    /// exit 19 on every noun that doesn't answer to them, exactly as an
    /// unknown flag exited before M2 — a shipped noun's grammar must not
    /// silently widen because a sibling verb learned a new flag.
    private static let booleanFlags: Set<String> = [
        "json", "raw", "iso", "unix", "relative", "no-color", "header",
        "check", "no-glyph", "tmux", "all", "background", "no-background",
        "no-scan",
    ]
    /// `digest`/`provider` are recognized-but-inert here: the CLI already
    /// consumed `--digest` to choose which file to read, and digest verbs
    /// ignore `--provider` by design (the digest is single-provider). They
    /// still have to parse cleanly or every documented invocation in the
    /// design doc would exit 19 on its own flags. `last` is the deep list
    /// verbs' count-or-duration flag (`DeepQuery.parseLast`), registered
    /// here for the same one-shared-parser reason as the booleans above.
    private static let valueFlags: Set<String> = [
        "max-age", "digest", "provider", "day", "range", "since", "limit",
        "project", "branch", "last", "fields",
    ]

    /// Which nouns each M2 flag is real for. Everything else gets the
    /// pre-M2 answer — `unknown flag '--x'`, exit 19 — enforced at every
    /// entry point (`run` here, `DeepQuery.run`,
    /// `DeepQuerySessionsCLI.run`), so sharing one parser never loosens a
    /// noun's own grammar. Sorted iteration keeps the reported flag
    /// deterministic when several inapplicable ones appear at once.
    private static let flagOwners: [String: Set<String>] = [
        "all": ["sessions", "session"],
        "background": ["sessions"],
        "no-background": ["sessions"],
        "last": ["windows", "history"],
        "no-scan": ["sessions", "session"],
        // A comma list is legal wherever a single field name is — and only
        // where the noun actually renders one (`multiFieldNouns`).
        "fields": multiFieldNouns,
    ]

    static func rejectInapplicableFlags(noun: String, parsed: ParsedArgs) -> QueryOutput? {
        for (flag, owners) in flagOwners.sorted(by: { $0.key < $1.key })
        where parsed.flags[flag] != nil && !owners.contains(noun) {
            return badQuery("unknown flag '--\(flag)'")
        }
        return nil
    }

    // MARK: - Entry point

    public static func run(
        arguments: [String], digest: LiveState, rawDigest: Data,
        environment: [String: String], now: Date
    ) -> QueryOutput {
        guard let noun = arguments.first else {
            return badQuery("no noun given — usage-cli <noun> [selector] [field] [flags]")
        }
        guard nouns.contains(noun) else {
            return badQuery("unknown noun '\(noun)'")
        }
        let parsed = parseArgs(Array(arguments.dropFirst()))
        if let error = parsed.error { return badQuery(error) }
        if let rejection = rejectInapplicableFlags(noun: noun, parsed: parsed) { return rejection }

        if let maxAgeText = parsed.flags["max-age"] {
            guard let maxAge = parseDuration(maxAgeText) else {
                return badQuery("bad --max-age duration '\(maxAgeText)' — e.g. 90s, 5m, 2h, 7d")
            }
            let age = now.timeIntervalSince(digest.engine.generatedAt)
            if age > maxAge {
                // No stderr note here (unlike badQuery/noMatch elsewhere):
                // a prompt recipe re-invokes this on every render (design
                // §15's starship example carries no `2>/dev/null`), and the
                // exit code alone already carries the guard's meaning —
                // the segment should just disappear, not narrate why.
                return QueryOutput(stdout: "", exitCode: exitStale)
            }
        }

        let calendar = digestCalendar(digest)
        let json = parsed.flags["json"] != nil
        let raw = parsed.flags["raw"] != nil

        switch noun {
        case "status": return runStatus(parsed: parsed, digest: digest, now: now, json: json)
        case "health": return runHealth(parsed: parsed, digest: digest, now: now, json: json)
        case "account": return runAccount(parsed: parsed, digest: digest, now: now, json: json)
        case "notices": return runNotices(parsed: parsed, digest: digest, json: json, raw: raw)
        case "limits": return runLimits(parsed: parsed, digest: digest, json: json, raw: raw)
        case "limit": return runLimit(parsed: parsed, digest: digest, now: now, json: json)
        case "budget": return runBudget(parsed: parsed, digest: digest, json: json)
        case "spend": return runSpend(parsed: parsed, digest: digest, json: json)
        case "activity":
            return runActivity(
                parsed: parsed, digest: digest, now: now, calendar: calendar, json: json, raw: raw,
                sugarCost: false)
        case "cost":
            return runActivity(
                parsed: parsed, digest: digest, now: now, calendar: calendar, json: json, raw: raw,
                sugarCost: true)
        case "models":
            return runModels(parsed: parsed, digest: digest, now: now, calendar: calendar, json: json, raw: raw)
        case "model":
            return runModel(parsed: parsed, digest: digest, now: now, calendar: calendar, json: json)
        case "sessions":
            return runSessionsList(parsed: parsed, digest: digest, now: now, calendar: calendar, json: json, raw: raw)
        case "session":
            return runSession(parsed: parsed, digest: digest, now: now, calendar: calendar, json: json)
        case "prompt": return runPrompt(parsed: parsed, digest: digest, environment: environment)
        case "get": return runGet(parsed: parsed, rawDigest: rawDigest, digest: digest, json: json)
        default: return badQuery("unknown noun '\(noun)'")
        }
    }

    // MARK: - Argument parsing

    struct ParsedArgs {
        var positionals: [String] = []
        var flags: [String: String] = [:]
        var segments: [String] = []
        var error: String?
    }

    /// One pass, flags and positionals interspersed freely (the design's
    /// own examples put flags after every kind of positional). A flag name
    /// outside both vocabularies is a bad query — new flags are added here,
    /// never guessed at by a noun handler.
    static func parseArgs(_ args: [String]) -> ParsedArgs {
        var result = ParsedArgs()
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                result.positionals.append(token)
                index += 1
                continue
            }
            let name = String(token.dropFirst(2))
            if name == "segment" {
                guard args.indices.contains(index + 1) else {
                    result.error = "--segment needs a value"
                    return result
                }
                result.segments.append(args[index + 1])
                index += 2
                continue
            }
            if booleanFlags.contains(name) {
                result.flags[name] = ""
                index += 1
                continue
            }
            if valueFlags.contains(name) {
                guard args.indices.contains(index + 1) else {
                    result.error = "--\(name) needs a value"
                    return result
                }
                result.flags[name] = args[index + 1]
                index += 2
                continue
            }
            result.error = "unknown flag '--\(name)'"
            return result
        }
        return result
    }

    /// "90s"/"5m"/"2h"/"7d" — integer magnitude, one unit suffix ("1.5h" is
    /// NOT accepted — `Int`, not `Double`, so the parser can't silently
    /// drift from its own doc comment). Public: M2's `--last`/`--since`
    /// durations reuse this exact grammar.
    public static func parseDuration(_ text: String) -> TimeInterval? {
        guard let unit = text.last else { return nil }
        guard let magnitude = Int(text.dropLast()), magnitude >= 0 else { return nil }
        switch unit {
        case "s": return TimeInterval(magnitude)
        case "m": return TimeInterval(magnitude) * 60
        case "h": return TimeInterval(magnitude) * 3600
        case "d": return TimeInterval(magnitude) * 86400
        default: return nil
        }
    }

    private static func digestCalendar(_ digest: LiveState) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: digest.activity.timeZone) ?? TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Output helpers

    static func ok(_ stdout: String) -> QueryOutput {
        QueryOutput(stdout: stdout, exitCode: exitOK)
    }

    static func badQuery(_ note: String) -> QueryOutput {
        QueryOutput(stdout: "", note: note, exitCode: exitBadQuery)
    }

    static func noMatch(_ note: String) -> QueryOutput {
        QueryOutput(stdout: "", note: note, exitCode: exitNoMatch)
    }

    /// Single-entity human summaries (a noun+selector's own line, `prompt`)
    /// dim-suffix themselves when the engine says what's on screen isn't
    /// fresh — lists don't (a table of N rows reads as data, not a
    /// headline), and raw/json never do (scripts ask `status stale` or pass
    /// `--max-age` instead of scraping decoration).
    static func withStaleSuffix(_ line: String, digest: LiveState) -> String {
        digest.engine.stale ? "\(line) · stale" : line
    }

    // MARK: - Selectors

    enum Selection<T> {
        case found(T)
        case ambiguous([String])
        case none
    }

    /// A resolved value, or the already-built `QueryOutput` to return on
    /// failure — not `Result<T, Error>` (neither `QueryOutput` nor `String`
    /// need to conform to `Error` just to travel through a two-case switch).
    enum Outcome<T> {
        case success(T)
        case failure(QueryOutput)
    }

    /// id · tag (s/w/scoped initial) · label/scoped-model substring ·
    /// `worst` (max forecast.severity, tie → percent) · `next` (soonest
    /// resets-at STAMP — this selector has no `now` to weigh futureness
    /// against, matching the design's own "soonest reset", not a stronger
    /// "future reset" promise). Case-insensitive; exact forms short-circuit
    /// before substring ambiguity is even considered, so "session" never
    /// collides with "Session (5h)".
    static func selectMeter(_ token: String, in meters: [LiveMeter]) -> Selection<LiveMeter> {
        let needle = token.lowercased()
        if let exact = meters.first(where: { $0.id.lowercased() == needle }) { return .found(exact) }
        if let byTag = meters.first(where: { $0.tag.lowercased() == needle }) { return .found(byTag) }
        if needle == "worst" {
            guard let worst = meters.max(by: { lhs, rhs in
                let ls = lhs.forecast?.severity ?? -1, rs = rhs.forecast?.severity ?? -1
                if ls != rs { return ls < rs }
                return (lhs.percent ?? -1) < (rhs.percent ?? -1)
            }) else { return .none }
            return .found(worst)
        }
        if needle == "next" {
            let withReset = meters.filter { $0.resetsAt != nil }
            guard let soonest = withReset.min(by: { $0.resetsAt! < $1.resetsAt! }) else { return .none }
            return .found(soonest)
        }
        let candidates = meters.filter {
            $0.label.lowercased().contains(needle) || ($0.scopedModelName?.lowercased().contains(needle) ?? false)
        }
        switch candidates.count {
        case 0: return .none
        case 1: return .found(candidates[0])
        default: return .ambiguous(candidates.map(\.id))
        }
    }

    /// `latest`/`current` · a 1-based shortlist index · an id prefix.
    static func selectSession(_ token: String, in sessions: [SessionCard]) -> Selection<SessionCard> {
        let needle = token.lowercased()
        if needle == "latest" || needle == "current" {
            guard let first = sessions.first else { return .none }
            return .found(first)
        }
        if let index = Int(token), index >= 1, index <= sessions.count {
            return .found(sessions[index - 1])
        }
        let candidates = sessions.filter { $0.id.lowercased().hasPrefix(needle) }
        switch candidates.count {
        case 0: return .none
        case 1: return .found(candidates[0])
        default: return .ambiguous(candidates.map(\.id))
        }
    }

    /// id · `top` (heaviest — `models` is already heaviest-first) ·
    /// displayName substring.
    static func selectModel(_ token: String, in models: [ModelRow]) -> Selection<ModelRow> {
        let needle = token.lowercased()
        if let exact = models.first(where: { $0.id.lowercased() == needle }) { return .found(exact) }
        if needle == "top" {
            guard let first = models.first else { return .none }
            return .found(first)
        }
        let candidates = models.filter { $0.displayName.lowercased().contains(needle) }
        switch candidates.count {
        case 0: return .none
        case 1: return .found(candidates[0])
        default: return .ambiguous(candidates.map(\.id))
        }
    }

    // MARK: - Ranges

    enum ActivityRange: Equatable {
        case today
        case yesterday
        case day(String)
        case trailing(Int)
        case month
        case year
        case all

        var label: String {
            switch self {
            case .today: return "today"
            case .yesterday: return "yesterday"
            case .day(let key): return key
            case .trailing(let n): return "\(n)d"
            case .month: return "month"
            case .year: return "year"
            case .all: return "all"
            }
        }
    }

    static func parseRange(_ token: String) -> ActivityRange? {
        switch token.lowercased() {
        case "today": return .today
        case "yesterday": return .yesterday
        case "month": return .month
        case "year": return .year
        case "all": return .all
        default: break
        }
        if token.hasSuffix("d"), let n = Int(token.dropLast()), n > 0 { return .trailing(n) }
        if looksLikeDayKey(token) { return .day(token) }
        return nil
    }

    private static func looksLikeDayKey(_ text: String) -> Bool {
        guard text.count == 10 else { return false }
        let chars = Array(text)
        guard chars[4] == "-", chars[7] == "-" else { return false }
        let digits = Set("0123456789")
        for (index, char) in chars.enumerated() where index != 4 && index != 7 {
            guard digits.contains(char) else { return false }
        }
        return true
    }

    /// Day keys inclusive at both ends, compared lexicographically in the
    /// digest's own `activity.timeZone` calendar (plan §1) — never failable:
    /// a `Calendar.date(byAdding:)` miss (essentially impossible for these
    /// small Gregorian offsets) just falls back to `today` rather than
    /// threading a second failure mode through every call site.
    static func resolveWindow(_ range: ActivityRange, now: Date, calendar: Calendar) -> (start: String, end: String) {
        let dayKey = LiveStateBuilder.dayKeyFormatter(calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let todayKey = dayKey.string(from: today)
        switch range {
        case .today:
            return (todayKey, todayKey)
        case .yesterday:
            let y = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            let key = dayKey.string(from: y)
            return (key, key)
        case .day(let key):
            return (key, key)
        case .trailing(let n):
            let start = calendar.date(byAdding: .day, value: -(n - 1), to: today) ?? today
            return (dayKey.string(from: start), todayKey)
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: today)
            let start = calendar.date(from: DateComponents(year: comps.year, month: comps.month, day: 1)) ?? today
            return (dayKey.string(from: start), todayKey)
        case .year:
            let comps = calendar.dateComponents([.year], from: today)
            let start = calendar.date(from: DateComponents(year: comps.year, month: 1, day: 1)) ?? today
            return (dayKey.string(from: start), todayKey)
        case .all:
            // Lexicographic sentinels: every real "yyyy-MM-dd" key sorts
            // strictly between these, so the plain string range-check below
            // just works without a separate "unbounded" branch everywhere.
            return ("0000-00-00", "9999-99-99")
        }
    }

    /// The horizon check is for a CONCRETE single day only (today/yesterday
    /// trivially pass; an explicit date might not) — trailing/calendar
    /// ranges are always valid windows that may simply sum to nothing.
    static func isWithinDaysHorizon(_ dayKey: String, now: Date, calendar: Calendar) -> Bool {
        let formatter = LiveStateBuilder.dayKeyFormatter(calendar: calendar)
        guard let date = formatter.date(from: dayKey) else { return false }
        if date > calendar.startOfDay(for: now) { return false }
        let floor = calendar.startOfDay(for: now.addingTimeInterval(-LiveStateBuilder.daysHorizon))
        return date >= floor
    }

    /// Per-model totals across several `ModelDayRollup`s — the SAME shape
    /// `activity <range> models` and `model[s] --range` both need, so it
    /// lives once. Cost sums only the days that priced this model; a model
    /// unpriced on every matched day stays absent, never $0.
    static func aggregateModels(_ modelDays: [ModelDayRollup]) -> [ModelRow] {
        var tallies: [String: TokenTally] = [:]
        var costs: [String: [Double]] = [:]
        var identity: [String: (displayName: String, color: RGBColor)] = [:]
        for day in modelDays {
            for row in day.models {
                tallies[row.id, default: TokenTally()].add(row.tally)
                if let cost = row.cost { costs[row.id, default: []].append(cost) }
                identity[row.id] = (row.displayName, row.color)
            }
        }
        return tallies.compactMap { id, tally -> ModelRow? in
            guard let identity = identity[id] else { return nil }
            let priced = costs[id] ?? []
            return ModelRow(
                id: id, displayName: identity.displayName, color: identity.color, tally: tally,
                cost: priced.isEmpty ? nil : priced.reduce(0, +))
        }.sorted { $0.tally.total != $1.tally.total ? $0.tally.total > $1.tally.total : $0.id < $1.id }
    }

}
