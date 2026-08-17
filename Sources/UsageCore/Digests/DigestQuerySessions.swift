import Foundation

/// The `sessions`/`session` nouns — the digest side of the two nouns that
/// have TWO possible sources. Split from `DigestQueryNouns.swift` along the
/// house rule (a file over ~600 lines splits along a whole-type seam): the
/// sessions family owns a third of that file and keeps growing, while every
/// other noun there reads one digest sub-tree and stops.
///
/// Sibling file, one seam over: `DeepQuerySessions.swift` is the SCAN side —
/// how a transcript scan becomes priced entries and which public door the CLI
/// knocks on. This file owns the grammar (selectors, filters, registers,
/// fields) for BOTH sources: a scanned entry becomes a `SessionCard` at that
/// seam, so the row builders below never fork on where a session came from.
extension DigestQuery {
    // MARK: - sessions / session

    /// `digest` is optional so `DeepQuerySessionsCLI` (no live-state file on
    /// disk) can call straight through with `nil` — every OTHER caller (the
    /// normal `DigestQuery.run` dispatch) always has one, since `LiveState`
    /// promotes into the `?` parameter for free. `scan` is the M2 addition:
    /// a LAZY, INJECTED capability, not a direct `TranscriptScanner` call —
    /// this file stays "a deterministic function of its arguments, never of
    /// the clock or the filesystem" (`DigestQuery`'s own header rule) by
    /// construction. Defaulted `nil` so `DigestQuery.run`'s existing switch
    /// (which this file doesn't own) keeps compiling unchanged, and so
    /// `DigestQuery.run` — documented as answering from live-state.json
    /// ONLY — never touches a disk scan: `sessions --all`/a shortlist-miss
    /// reached that way is a bad query / a clean no-match, never a
    /// filesystem walk. `DeepQuerySessionsCLI` is the one caller that passes
    /// a real closure.
    static func runSessionsList(
        parsed: ParsedArgs, digest: LiveState?, now: Date, calendar: Calendar, json: Bool, raw: Bool,
        scan: (() -> [DeepQuerySessions.Entry]?)? = nil
    ) -> QueryOutput {
        guard parsed.positionals.isEmpty else {
            return badQuery("sessions takes no selector — did you mean 'session \(parsed.positionals[0])'?")
        }
        // The digest shortlist doesn't record a session's kind — only the
        // scan does. A filter that can't apply must refuse, never exit 0
        // handing back the very rows it was asked to exclude.
        if parsed.flags["all"] == nil,
           parsed.flags["background"] != nil || parsed.flags["no-background"] != nil {
            return badQuery("--background/--no-background need --all — the shortlist doesn't know a session's kind")
        }
        if parsed.flags["all"] != nil {
            guard let scan else {
                return badQuery("sessions --all needs the CLI's scan capability, not available through this entry point")
            }
            guard let entries = scan() else {
                return QueryOutput(
                    stdout: "", note: "sessions --all is not wired for a non-claude provider in the CLI yet",
                    exitCode: DeepQuery.exitWrongProvider)
            }
            return sessionsAllOutput(entries: entries, parsed: parsed, now: now, calendar: calendar, json: json, raw: raw)
        }
        guard let digest else {
            // Reachable only from `DeepQuerySessionsCLI` with no digest file
            // at all and no `--all` — the shortlist has nothing to read.
            // Exit 13 mirrors UsageCLI's own "no digest" exit for every
            // other noun (DigestQuery itself defines no such constant,
            // since `DigestQuery.run`'s own entry never reaches a noun
            // handler without one already in hand).
            return QueryOutput(
                stdout: "",
                note: "no live-state digest — sessions needs one for the shortlist; add --all for the scan-backed full index",
                exitCode: 13)
        }
        switch filterSessions(digest.sessions, parsed: parsed, now: now, calendar: calendar) {
        case .failure(let output): return output
        case .success(let sessions):
            if json { return ok(DigestQueryFormat.jsonValue(sessions)) }
            guard !sessions.isEmpty else { return ok("") }
            if raw {
                let rows = sessions.map(sessionRawRow)
                return ok(DigestQueryFormat.tsv(rows, header: parsed.flags["header"] != nil ? sessionColumns : nil))
            }
            return ok(DigestQueryFormat.table(sessions.map { sessionHumanRow($0, timeZone: calendar.timeZone) }))
        }
    }

    /// Background runs included only under `--background`, excluded only
    /// under `--no-background`; both or neither lists every kind (the
    /// shortlist's own "nothing filtered" default). Reuses
    /// `filterSessions`/`sessionRawRow`/`sessionHumanRow`/`sessionColumns`
    /// UNCHANGED on `SessionCard`s built from the scan — the same columns
    /// and registers as the digest-backed list, one formatting path for both
    /// sources. `calendar` is the CALLER's — `DeepQuerySessionsCLI` builds
    /// it from the digest's own `activity.timeZone` when one exists, else
    /// the system's; never hardcoded here, so `--since` means the same thing
    /// regardless of which source answered.
    private static func sessionsAllOutput(
        entries: [DeepQuerySessions.Entry], parsed: ParsedArgs, now: Date, calendar: Calendar, json: Bool, raw: Bool
    ) -> QueryOutput {
        var filtered = entries
        if parsed.flags["background"] != nil, parsed.flags["no-background"] == nil {
            filtered = filtered.filter { $0.summary.kind == .background }
        } else if parsed.flags["no-background"] != nil, parsed.flags["background"] == nil {
            filtered = filtered.filter { $0.summary.kind == .interactive }
        }
        // `SessionCard` (the shortlist's own shape, shared here for one
        // formatting path) carries only `startedAt` — but the full index is
        // sorted by `end` (`TranscriptScanner`'s own sort key), and `end` is
        // what a scan-backed listing spanning many days needs on screen to
        // read as sorted. Captured by id before the card conversion drops it,
        // since ids are unique per entry.
        let endByID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.summary.id, $0.summary.end) })
        let cards = filtered.map(DeepQuerySessions.card)
        switch filterSessions(cards, parsed: parsed, now: now, calendar: calendar) {
        case .failure(let output): return output
        case .success(let sessions):
            if json {
                return ok(DigestQueryFormat.jsonValue(sessions.map {
                    SessionAllRow(card: $0, end: endByID[$0.id] ?? $0.startedAt)
                }))
            }
            guard !sessions.isEmpty else { return ok("") }
            if raw {
                let rows = sessions.map {
                    sessionRawRow($0) + [DigestQueryFormat.iso(endByID[$0.id] ?? $0.startedAt)]
                }
                return ok(DigestQueryFormat.tsv(
                    rows, header: parsed.flags["header"] != nil ? sessionColumns + ["end"] : nil))
            }
            return ok(DigestQueryFormat.table(sessions.map {
                sessionAllHumanRow($0, end: endByID[$0.id] ?? $0.startedAt, timeZone: calendar.timeZone)
            }))
        }
    }

    /// `--all`'s own register row: the shortlist's `SessionCard` keys plus
    /// the scan's `end` — the sort key the human table leads with must
    /// exist in raw/json too, or the registers stop presenting one fact
    /// three ways. Flat on purpose (card keys and `end` side by side),
    /// matching the TSV row's trailing `end` column.
    private struct SessionAllRow: Encodable {
        let card: SessionCard
        let end: Date

        private enum CodingKeys: String, CodingKey { case end }

        func encode(to encoder: Encoder) throws {
            try card.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(end, forKey: .end)
        }
    }

    /// `digest`/`scan` optional for the same reasons as `runSessionsList`.
    /// The shortlist is tried FIRST when a digest exists (cheap, already in
    /// memory); a shortlist MISS — never an ambiguous match, which is a real
    /// error — falls through to the scan ONLY when `scan` was actually
    /// injected; a nil digest skips the shortlist entirely and goes
    /// straight there, and `--all` skips it BY REQUEST — the escape hatch
    /// that makes the deep fields reachable for the ≤8 sessions the
    /// shortlist would otherwise always answer for. `DigestQuery.run` (no
    /// `scan` closure) therefore keeps its documented "live-state.json
    /// ONLY" contract: a miss there is a clean, fast, machine-independent
    /// exit 20 — never a disk walk.
    static func runSession(
        parsed: ParsedArgs, digest: LiveState?, now: Date, calendar: Calendar, json: Bool,
        scan: (() -> [DeepQuerySessions.Entry]?)? = nil
    ) -> QueryOutput {
        var positionals = parsed.positionals
        guard !positionals.isEmpty else {
            return badQuery("session needs a selector — 'latest', a shortlist index, or an id prefix")
        }
        let selectorToken = positionals.removeFirst()
        guard positionals.count <= 1 else { return badQuery("too many arguments") }
        let field = positionals.first
        let raw = parsed.flags["raw"] != nil
        let unix = parsed.flags["unix"] != nil
        let header = parsed.flags["header"] != nil

        if parsed.flags["all"] == nil, let digest {
            switch filterSessions(digest.sessions, parsed: parsed, now: now, calendar: calendar) {
            case .failure(let output): return output
            case .success(let sessions):
                switch selectSession(selectorToken, in: sessions) {
                case .found(let session):
                    return renderSession(
                        session, deep: nil, field: field, json: json, raw: raw, unix: unix, header: header,
                        stale: digest.engine.stale)
                case .ambiguous(let ids):
                    return badQuery("ambiguous selector '\(selectorToken)' matches: \(ids.joined(separator: ", "))")
                case .none:
                    break  // Shortlist miss — fall through to the scan below.
                }
            }
        }

        guard let scan else {
            if parsed.flags["all"] != nil {
                return badQuery("session --all needs the CLI's scan capability, not available through this entry point")
            }
            return noMatch("no session matches '\(selectorToken)' in the shortlist (≤8)")
        }
        guard let entries = scan() else {
            return QueryOutput(
                stdout: "", note: "session is not wired for a non-claude provider in the CLI yet",
                exitCode: DeepQuery.exitWrongProvider)
        }
        switch DeepQuerySessions.select(selectorToken, in: entries) {
        case .none:
            return noMatch("no session matches '\(selectorToken)' in the shortlist (≤8) or the full transcript scan")
        case .ambiguous(let ids):
            return badQuery("ambiguous selector '\(selectorToken)' matches: \(ids.joined(separator: ", "))")
        case .found(let entry):
            return renderSession(
                DeepQuerySessions.card(entry), deep: entry, field: field, json: json, raw: raw, unix: unix,
                header: header, stale: false)
        }
    }

    /// The "no field" vs "named field" fork, shared by both the shortlist
    /// hit and the scan hit — the only difference between the two sources is
    /// whether `deep` (the scan's extra fields) is present.
    private static func renderSession(
        _ session: SessionCard, deep: DeepQuerySessions.Entry?, field: String?, json: Bool, raw: Bool, unix: Bool,
        header: Bool, stale: Bool
    ) -> QueryOutput {
        guard let field else {
            if json { return ok(DigestQueryFormat.jsonValue(session)) }
            if raw {
                return ok(DigestQueryFormat.tsv([sessionRawRow(session)], header: header ? sessionColumns : nil))
            }
            let line = sessionSummaryLine(session)
            return ok(stale ? "\(line) · stale" : line)
        }
        return sessionField(field, session: session, deep: deep, json: json, unix: unix, header: header)
    }

    private static let sessionColumns = [
        "id", "title", "project", "branch", "started", "active", "cost", "tokens", "prompts", "api-calls",
    ]

    private static func sessionRawRow(_ session: SessionCard) -> [String] {
        [
            session.id, session.title, session.project ?? "", session.branch ?? "",
            DigestQueryFormat.iso(session.startedAt), String(Int(session.activeSeconds)),
            DigestQueryFormat.rawMoney(session.cost), String(session.tokens), String(session.prompts),
            String(session.apiCalls),
        ]
    }

    /// The design's own worked example: clock time, project, branch, cost,
    /// tokens, a "N❯" prompt count, then the title last (unbounded width).
    private static func sessionHumanRow(_ session: SessionCard, timeZone: TimeZone) -> [String] {
        let time = UsageFormatting.clockTime(session.startedAt, timeZone: timeZone)
        let place = [session.project, session.branch].compactMap { $0 }.joined(separator: " ")
        return [
            time, place, DigestQueryFormat.humanMoney(session.cost), TokenFormat.compact(session.tokens),
            "\(session.prompts)❯", session.title,
        ]
    }

    /// `sessions --all`'s own row: unlike the ≤8-entry shortlist (always
    /// today-recent, bare "HH:mm" reads fine), the scan-backed full index can
    /// span many days and is sorted by `end` — so the time column shows
    /// `end`, dated, matching both the sort key and the legacy dump's own
    /// "yyyy-MM-dd HH:mm" this noun replaces. Every other column is
    /// `sessionHumanRow`'s, unforked.
    private static func sessionAllHumanRow(_ session: SessionCard, end: Date, timeZone: TimeZone) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let time = formatter.string(from: end)
        let place = [session.project, session.branch].compactMap { $0 }.joined(separator: " ")
        return [
            time, place, DigestQueryFormat.humanMoney(session.cost), TokenFormat.compact(session.tokens),
            "\(session.prompts)❯", session.title,
        ]
    }

    private static func sessionSummaryLine(_ session: SessionCard) -> String {
        var parts = [session.title]
        let place = [session.project, session.branch].compactMap { $0 }.joined(separator: " ")
        if !place.isEmpty { parts.append(place) }
        parts.append("\(TokenFormat.compact(session.tokens)) tokens")
        parts.append(DigestQueryFormat.humanMoney(session.cost))
        return parts.joined(separator: " · ")
    }

    /// `deep` carries the M2 fields (end/kind/tool-calls/subagents/
    /// compactions/agent-version/models) — present only when `session`
    /// resolved through the transcript scan; nil from a shortlist hit. A
    /// deep field name stays a BAD QUERY (not absent) when `deep` is nil —
    /// the shortlist genuinely has no such field, same as before M2; once a
    /// session DID come from the scan, each deep field's own VALUE follows
    /// absent discipline (a session with no recorded agent version reads
    /// absent, never an error).
    private static func sessionField(
        _ field: String, session: SessionCard, deep: DeepQuerySessions.Entry?, json: Bool, unix: Bool, header: Bool
    ) -> QueryOutput {
        switch field {
        case "id": return DigestQueryFormat.textField(session.id, json: json)
        case "title": return DigestQueryFormat.textField(session.title, json: json)
        case "project": return DigestQueryFormat.textField(session.project, json: json)
        case "branch": return DigestQueryFormat.textField(session.branch, json: json)
        case "started": return DigestQueryFormat.dateField(session.startedAt, json: json, unix: unix, relative: false)
        case "active": return DigestQueryFormat.secondsField(session.activeSeconds, json: json)
        case "cost": return DigestQueryFormat.numberField(session.cost, json: json)
        case "tokens": return DigestQueryFormat.intField(session.tokens, json: json)
        case "prompts": return DigestQueryFormat.intField(session.prompts, json: json)
        case "api-calls": return DigestQueryFormat.intField(session.apiCalls, json: json)
        case "end", "kind", "tool-calls", "subagents", "compactions", "agent-version", "models":
            guard let deep else {
                return badQuery(
                    "session has no field '\(field)' in the shortlist — add --all to resolve through the scan")
            }
            return deepSessionField(field, deep: deep, json: json, unix: unix, header: header)
        default:
            return badQuery("session has no field '\(field)'")
        }
    }

    private static func deepSessionField(
        _ field: String, deep: DeepQuerySessions.Entry, json: Bool, unix: Bool, header: Bool
    ) -> QueryOutput {
        switch field {
        case "end": return DigestQueryFormat.dateField(deep.summary.end, json: json, unix: unix, relative: false)
        case "kind": return DigestQueryFormat.textField(deep.summary.kind.rawValue, json: json)
        case "tool-calls": return DigestQueryFormat.intField(deep.summary.toolCalls, json: json)
        case "subagents": return DigestQueryFormat.intField(deep.summary.subagentCount, json: json)
        case "compactions": return DigestQueryFormat.intField(deep.summary.compactions, json: json)
        case "agent-version": return DigestQueryFormat.textField(deep.summary.agentVersion, json: json)
        case "models": return sessionModelsOutput(deep, json: json, header: header)
        default: return badQuery("session has no field '\(field)'")
        }
    }

    /// A NEW deep field, so its row shape is its own — not the digest's
    /// `ModelRow` (that struct's `color` comes from the app-persisted color
    /// ledger, which this read-only CLI path has no business touching, spec
    /// §10). Always TSV/JSON regardless of `--raw` (the `limit … series`
    /// convention: a list-shaped field has no sensible human-table form of
    /// its own). Absent (not zero) when the session has no priced models.
    private struct SessionModelRow: Encodable {
        let id: String
        let tokens: Int
        let cost: Double?
    }

    private static func sessionModelsOutput(_ deep: DeepQuerySessions.Entry, json: Bool, header: Bool) -> QueryOutput {
        let rows = deep.summary.models.map { id, tally in
            SessionModelRow(id: id, tokens: tally.total, cost: deep.modelCosts[id])
        }.sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.id < $1.id }
        if json { return ok(DigestQueryFormat.jsonValue(rows)) }
        let tsvRows = rows.map { [$0.id, String($0.tokens), DigestQueryFormat.rawMoney($0.cost)] }
        return ok(DigestQueryFormat.tsv(tsvRows, header: header ? ["id", "tokens", "cost"] : nil))
    }

    private static func filterSessions(
        _ sessions: [SessionCard], parsed: ParsedArgs, now: Date, calendar: Calendar
    ) -> Outcome<[SessionCard]> {
        var result = sessions
        if let project = parsed.flags["project"] {
            result = result.filter { ($0.project?.lowercased()) == project.lowercased() }
        }
        if let branch = parsed.flags["branch"] {
            result = result.filter { ($0.branch?.lowercased()) == branch.lowercased() }
        }
        if let since = parsed.flags["since"] {
            guard let cutoff = resolveSince(since, now: now, calendar: calendar) else {
                return .failure(badQuery("bad --since value '\(since)' — a duration (5m/2h/7d) or yyyy-MM-dd"))
            }
            result = result.filter { $0.startedAt >= cutoff }
        }
        if let limitText = parsed.flags["limit"] {
            guard let count = Int(limitText), count >= 0 else {
                return .failure(badQuery("bad --limit value '\(limitText)'"))
            }
            result = Array(result.prefix(count))
        }
        return .success(result)
    }

    /// A literal "yyyy-MM-dd" parses at midnight in the DIGEST's own
    /// calendar (matching `resolveWindow`/`isWithinDaysHorizon`), never a
    /// hard-coded UTC — a digest published west of Greenwich would
    /// otherwise cut sessions off several hours early.
    private static func resolveSince(_ text: String, now: Date, calendar: Calendar) -> Date? {
        if let duration = parseDuration(text) { return now.addingTimeInterval(-duration) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
