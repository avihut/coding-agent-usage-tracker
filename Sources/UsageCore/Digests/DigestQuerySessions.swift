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
        scan: DeepQuerySessions.Scan? = nil
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
        if let rejection = rejectScanContradiction(parsed) { return rejection }
        if parsed.flags["all"] != nil {
            guard let scan else {
                return badQuery("sessions --all needs the CLI's scan capability, not available through this entry point")
            }
            let scanned: [DeepQuerySessions.Entry]?
            do {
                scanned = try scan()
            } catch {
                return error.output
            }
            guard let entries = scanned else {
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
        switch filterSessions(filtered.map(DeepQuerySessions.card), parsed: parsed, now: now, calendar: calendar) {
        case .failure(let output): return output
        case .success(let sessions):
            if json { return ok(DigestQueryFormat.jsonValue(sessions)) }
            guard !sessions.isEmpty else { return ok("") }
            if raw {
                return ok(DigestQueryFormat.tsv(
                    sessions.map(sessionRawRow), header: parsed.flags["header"] != nil ? sessionColumns : nil))
            }
            return ok(DigestQueryFormat.table(sessions.map { sessionAllHumanRow($0, timeZone: calendar.timeZone) }))
        }
    }

    /// `digest`/`scan`/`ask` optional for the same reasons as
    /// `runSessionsList`. The order (issue #24):
    ///
    /// 1. The shortlist, when a digest exists and `--all` didn't skip it —
    ///    cheap, already in memory.
    /// 2. The engine (`ask`), over the host's socket: its index holds EVERY
    ///    session its last scan saw, so a session open but idle for days —
    ///    off the shortlist for good — answers in milliseconds. Asking
    ///    parses nothing, so `--no-scan` allows it, and `--all` gets the
    ///    deep fields from it. Its answer is authoritative: a session it
    ///    doesn't hold is a miss, never a reason to scan.
    /// 3. A whole-corpus scan, only when no engine answered AND either
    ///    `--all` asked for one or no digest exists at all (the v0.83.0
    ///    no-daemon door). A miss against a digest does NOT scan any more:
    ///    once per open session per status-line tick, that escalation is
    ///    what kept 18 scans in flight on a 12-core Mac.
    ///
    /// `DigestQuery.run` (no closures) keeps its documented "live-state.json
    /// ONLY" contract: a miss there is a clean, fast exit 20. `--no-scan`
    /// forbids step 3 and contradicts `--all`, which demands it.
    static func runSession(
        parsed: ParsedArgs, digest: LiveState?, now: Date, calendar: Calendar, json: Bool,
        scan: DeepQuerySessions.Scan? = nil,
        ask: ((String) -> SessionAnswer?)? = nil
    ) -> QueryOutput {
        var positionals = parsed.positionals
        guard !positionals.isEmpty else {
            return badQuery("session needs a selector — 'latest', a shortlist index, or an id prefix")
        }
        let selectorToken = positionals.removeFirst()
        guard positionals.count <= 1 else { return badQuery("too many arguments") }
        if let rejection = rejectScanContradiction(parsed) { return rejection }
        let field = positionals.first
        let noScan = parsed.flags["no-scan"] != nil
        let all = parsed.flags["all"] != nil

        if !all, let digest {
            switch filterSessions(digest.sessions, parsed: parsed, now: now, calendar: calendar) {
            case .failure(let output): return output
            case .success(let sessions):
                switch selectSession(selectorToken, in: sessions) {
                case .found(let session):
                    return renderSession(
                        session, deep: nil, parsed: parsed, field: field, json: json,
                        stale: digest.engine.stale)
                case .ambiguous(let ids):
                    return badQuery("ambiguous selector '\(selectorToken)' matches: \(ids.joined(separator: ", "))")
                case .none:
                    break  // Shortlist miss — ask the engine below.
                }
            }
        }

        if let answer = ask?(selectorToken), let resolution = answer.resolution {
            switch resolution {
            case .found(let card, let deep):
                return renderSession(
                    card, deep: deep, parsed: parsed, field: field, json: json,
                    stale: digest?.engine.stale ?? false, source: "engine")
            case .ambiguous(let ids):
                return badQuery("ambiguous selector '\(selectorToken)' matches: \(ids.joined(separator: ", "))")
            case .none:
                return noMatch(
                    "no session matches '\(selectorToken)'\(shortlistNote(digest)) or the engine's index")
            }
        }

        if noScan {
            // Two different failures, told apart: a digest answered and had
            // no such session (20, a real no-match), versus no digest to ask
            // at all (13, the same code every other noun gives for it) — the
            // scan that would have covered both is forbidden by request.
            guard digest != nil else {
                return QueryOutput(
                    stdout: "",
                    note: "no live-state digest — --no-scan forbids the transcript scan that would have answered",
                    exitCode: 13)
            }
            return noMatch(
                "no session matches '\(selectorToken)'\(shortlistNote(digest))"
                    + " — --no-scan forbids the transcript scan")
        }
        // No engine answered. A digest on disk means a host published, so a
        // miss against it is no reason to parse every transcript.
        if !all, let digest {
            return noMatch(
                "no session matches '\(selectorToken)'\(shortlistNote(digest))"
                    + " and no engine answered — add --all to scan the transcripts")
        }
        guard let scan else {
            if all {
                return badQuery("session --all needs the CLI's scan capability, not available through this entry point")
            }
            return noMatch("no session matches '\(selectorToken)'\(shortlistNote(digest))")
        }
        let scanned: [DeepQuerySessions.Entry]?
        do {
            scanned = try scan()
        } catch {
            return error.output
        }
        guard let entries = scanned else {
            return QueryOutput(
                stdout: "", note: "session is not wired for a non-claude provider in the CLI yet",
                exitCode: DeepQuery.exitWrongProvider)
        }
        switch DeepQuerySessions.select(selectorToken, in: entries) {
        case .none:
            return noMatch(
                "no session matches '\(selectorToken)'\(shortlistNote(digest)) or the full transcript scan")
        case .ambiguous(let ids):
            return badQuery("ambiguous selector '\(selectorToken)' matches: \(ids.joined(separator: ", "))")
        case .found(let entry):
            return renderSession(
                DeepQuerySessions.card(entry), deep: entry.deepFields, parsed: parsed, field: field, json: json,
                stale: false)
        }
    }

    /// `transcript <path> [field]` — `session <id> --all`'s answer for ONE
    /// transcript named by path, parsed fresh through `parse` (the CLI
    /// injects `DeepQuerySessions.transcriptEntry`; tests inject a fixture
    /// scanner). The daemon indexes exactly one `projects` tree, so a
    /// session written under another config dir (`CLAUDE_CONFIG_DIR`) has
    /// no shortlist row and no scan to fall back to; this is the door that
    /// prices it anyway, with the same parser and the same field vocabulary
    /// (`source` reads "transcript"). A path that isn't a readable
    /// transcript, or holds no call and no prompt, is a no-match — exit 20,
    /// the selector named nothing — never a bad query: the grammar was fine.
    static func runTranscript(
        parsed: ParsedArgs, json: Bool, parse: (URL) -> DeepQuerySessions.Entry?
    ) -> QueryOutput {
        var positionals = parsed.positionals
        guard !positionals.isEmpty else {
            return badQuery("transcript needs a path — usage-cli transcript <path/to/session.jsonl> [field]")
        }
        let path = positionals.removeFirst()
        guard positionals.count <= 1 else { return badQuery("too many arguments") }
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard let entry = parse(url) else {
            return noMatch(
                "no transcript at '\(path)' — expected a Claude Code session .jsonl holding at least one prompt or API call")
        }
        return renderSession(
            DeepQuerySessions.card(entry), deep: entry.deepFields, parsed: parsed, field: positionals.first,
            json: json, stale: false, noun: "transcript", source: "transcript")
    }

    /// `--no-scan` forbids the escalation; `--all` demands it. Neither is a
    /// modifier of the other, so asking for both is a bad query rather than
    /// a precedence rule nobody would remember.
    private static func rejectScanContradiction(_ parsed: ParsedArgs) -> QueryOutput? {
        guard parsed.flags["all"] != nil, parsed.flags["no-scan"] != nil else { return nil }
        return badQuery("--no-scan and --all contradict — one forbids the transcript scan, the other demands it")
    }

    /// " in the shortlist (≤8)" — the cap comes from the DIGEST that
    /// answered, never this build's own constant (which would misreport a
    /// digest published by a different version). Silent when there's no
    /// digest, or when it predates the published cap.
    private static func shortlistNote(_ digest: LiveState?) -> String {
        guard let cap = digest?.sessionsCap else { return "" }
        return " in the shortlist (≤\(cap))"
    }

    /// The "no field" vs "named field" fork, shared by every source — the
    /// shortlist, the engine, the scan, one transcript — and the only
    /// difference between them is whether `deep` (an index's extra fields)
    /// is present. `noun`/`source` let `transcript` share this path verbatim
    /// while its errors and its `source` field name IT, not `session`.
    private static func renderSession(
        _ session: SessionCard, deep: SessionDeepFields?, parsed: ParsedArgs, field: String?, json: Bool,
        stale: Bool, noun: String = "session", source: String? = nil
    ) -> QueryOutput {
        let header = parsed.flags["header"] != nil
        func resolve(_ name: String, asJSON: Bool) -> QueryOutput {
            sessionField(
                name, session: session, deep: deep, json: asJSON, unix: parsed.flags["unix"] != nil,
                relative: parsed.flags["relative"] != nil, header: header, noun: noun, source: source)
        }
        if let output = multiFieldOutput(
            noun: noun, parsed: parsed, positionalField: field, json: json, header: header, resolve: resolve) {
            return output
        }
        guard let field else {
            if json { return ok(DigestQueryFormat.jsonValue(session)) }
            if parsed.flags["raw"] != nil {
                return ok(DigestQueryFormat.tsv([sessionRawRow(session)], header: header ? sessionColumns : nil))
            }
            let line = sessionSummaryLine(session)
            return ok(stale ? "\(line) · stale" : line)
        }
        return resolve(field, asJSON: json)
    }

    /// `end` is APPENDED, never inserted: the raw register is positional, so
    /// a new column may only ever grow off the right edge — a consumer
    /// indexing `$7` keeps reading the same fact it read before 0.84.0, and
    /// `sessions --all` (which already carried a trailing `end` of its own)
    /// comes out byte-identical, now from the card rather than a side table.
    private static let sessionColumns = [
        "id", "title", "project", "branch", "started", "active", "cost", "tokens", "prompts", "api-calls", "end",
    ]

    private static func sessionRawRow(_ session: SessionCard) -> [String] {
        [
            session.id, session.title, session.project ?? "", session.branch ?? "",
            DigestQueryFormat.iso(session.startedAt), String(Int(session.activeSeconds)),
            DigestQueryFormat.rawMoney(session.cost), String(session.tokens), String(session.prompts),
            String(session.apiCalls), session.end.map(DigestQueryFormat.iso) ?? "",
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
    private static func sessionAllHumanRow(_ session: SessionCard, timeZone: TimeZone) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let time = formatter.string(from: session.end ?? session.startedAt)
        let place = [session.project, session.branch].compactMap { $0 }.joined(separator: " ")
        return [
            time, place, DigestQueryFormat.humanMoney(session.cost), TokenFormat.compact(session.tokens),
            "\(session.prompts)❯", session.title,
        ]
    }

    /// Carries the active DURATION, house-formatted: the human register is
    /// the one place a caller shouldn't have to divide seconds itself, and
    /// this line previously omitted the number the Sessions browser leads
    /// with. `active --relative` prints the same phrase for a script.
    private static func sessionSummaryLine(_ session: SessionCard) -> String {
        var parts = [session.title]
        let place = [session.project, session.branch].compactMap { $0 }.joined(separator: " ")
        if !place.isEmpty { parts.append(place) }
        parts.append(UsageFormatting.duration(session.activeSeconds))
        parts.append("\(TokenFormat.compact(session.tokens)) tokens")
        parts.append(DigestQueryFormat.humanMoney(session.cost))
        return parts.joined(separator: " · ")
    }

    /// `deep` carries the M2 fields (kind/tool-calls/subagents/compactions/
    /// agent-version/models) — present when `session` resolved through a
    /// session index (the engine's or the scan's); nil from a shortlist hit.
    /// A deep field name stays a BAD QUERY (not absent) when `deep` is nil —
    /// the shortlist genuinely has no such field, same as before M2; once a
    /// session DID come from an index, each deep field's own VALUE follows
    /// absent discipline (a session with no recorded agent version reads
    /// absent, never an error).
    ///
    /// `end` LEFT that group in 0.84.0: the shortlist publishes it now, so
    /// the one field a liveness check needs no longer costs a full scan.
    /// `source` never belonged to it — which path answered is knowable from
    /// any of them.
    private static func sessionField(
        _ field: String, session: SessionCard, deep: SessionDeepFields?, json: Bool, unix: Bool,
        relative: Bool, header: Bool, noun: String = "session", source: String? = nil
    ) -> QueryOutput {
        switch field {
        case "id": return DigestQueryFormat.textField(session.id, json: json)
        case "title": return DigestQueryFormat.textField(session.title, json: json)
        case "project": return DigestQueryFormat.textField(session.project, json: json)
        case "branch": return DigestQueryFormat.textField(session.branch, json: json)
        case "started": return DigestQueryFormat.dateField(session.startedAt, json: json, unix: unix, relative: false)
        case "end":
            // Every index builds its card with `end`; only a pre-0.84.0
            // digest answering a shortlist hit lacks it, and prints absent,
            // honestly.
            return DigestQueryFormat.dateField(session.end, json: json, unix: unix, relative: false)
        case "source":
            return DigestQueryFormat.textField(source ?? (deep == nil ? "digest" : "scan"), json: json)
        case "active": return DigestQueryFormat.secondsField(session.activeSeconds, json: json, relative: relative)
        case "cost": return DigestQueryFormat.numberField(session.cost, json: json)
        case "tokens": return DigestQueryFormat.intField(session.tokens, json: json)
        case "prompts": return DigestQueryFormat.intField(session.prompts, json: json)
        case "api-calls": return DigestQueryFormat.intField(session.apiCalls, json: json)
        case "kind", "tool-calls", "subagents", "compactions", "agent-version", "models":
            guard let deep else {
                // Deliberately NOT "has no field": the field is real and
                // catalogued, it's the SOURCE that can't answer it. Sharing
                // the unknown-name wording sent people looking for a typo.
                return badQuery(
                    "\(noun) field '\(field)' isn't in the shortlist — add --all to resolve it past the shortlist")
            }
            return deepSessionField(field, deep: deep, json: json, header: header, noun: noun)
        default:
            return unknownField(noun: noun, field: field)
        }
    }

    private static func deepSessionField(
        _ field: String, deep: SessionDeepFields, json: Bool, header: Bool, noun: String = "session"
    ) -> QueryOutput {
        switch field {
        case "kind": return DigestQueryFormat.textField(deep.kind, json: json)
        case "tool-calls": return DigestQueryFormat.intField(deep.toolCalls, json: json)
        case "subagents": return DigestQueryFormat.intField(deep.subagents, json: json)
        case "compactions": return DigestQueryFormat.intField(deep.compactions, json: json)
        case "agent-version": return DigestQueryFormat.textField(deep.agentVersion, json: json)
        case "models": return sessionModelsOutput(deep, json: json, header: header)
        default: return unknownField(noun: noun, field: field)
        }
    }

    /// A NEW deep field, so its row shape is its own (`SessionModelCost`) —
    /// not the digest's `ModelRow`, whose `color` comes from the
    /// app-persisted color ledger. Always TSV/JSON regardless of `--raw`
    /// (the `limit … series` convention: a list-shaped field has no sensible
    /// human-table form of its own). Absent (not zero) when the session has
    /// no priced models.
    private static func sessionModelsOutput(_ deep: SessionDeepFields, json: Bool, header: Bool) -> QueryOutput {
        let rows = deep.models
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
