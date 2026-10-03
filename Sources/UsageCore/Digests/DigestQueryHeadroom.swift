import Foundation

/// `headroom` and the data-age guard (issue #8, 2026-10-03): the one question
/// a caller deciding whether it may spend on a harness needs answered from
/// the digest — given a cap, is there room on this account right now, and
/// can the number be trusted? The motivating caller is an agent-to-agent
/// delegation layer that hands a task to another harness only while that
/// harness sits under a share of its plan the CALLER chose, so the cap
/// arrives on the command line and nothing here stores a preference or
/// knows one vendor from another.
///
/// The answer is the exit code — 0 room · 24 at or over the cap · 25 under
/// it, but a forecast fails `--forecast` · 26 nothing to judge · 21 older
/// than the caller allows — and every register prints it for EVERY verdict,
/// so a refused caller can log why. FAIL CLOSED throughout: an unreported
/// percent is never room, a harness nobody meters here is never answered
/// with another harness's numbers, and a measurement with no stamp, or one
/// stamped ahead of this clock, is never fresh.
///
/// The data-age guard lives here because headroom is its first reason to
/// exist: `--max-age` judges `generatedAt`, when the engine last PUBLISHED,
/// and a local provider's digest is republished every few minutes around a
/// snapshot that can be days old — so it passed on exactly the numbers it
/// exists to refuse. `--max-data-age` judges `fetchedAt`, when the numbers
/// were MEASURED.
extension DigestQuery {
    // MARK: - The data-age guard

    /// Why the numbers can't be trusted under the guards the caller set.
    /// The limits are carried as the caller spelled them, for the line that
    /// says why.
    enum Staleness: Equatable {
        /// `--max-age`: the digest was written longer ago than allowed — the
        /// engine stopped publishing.
        case digestAge(TimeInterval, limit: String)
        /// `--max-data-age`: the numbers were measured longer ago than allowed.
        case dataAge(TimeInterval, limit: String)
        /// `--max-data-age` with no measurement stamp at all: absent is not
        /// fresh.
        case unmeasured
        /// `--max-data-age` with a stamp further ahead of this clock than
        /// `clockTolerance`: the clock was set back since, so no age can be
        /// read off it.
        case measuredAhead(TimeInterval)
    }

    /// How far ahead of `now` a measurement stamp may sit and still read as
    /// just taken. Both come off this Mac's clock, so a wider gap is the
    /// clock having been set back — and an age read across it would pass
    /// any guard, however old the numbers are.
    static let clockTolerance: TimeInterval = 60

    /// The nouns whose answer IS the measurement `fetchedAt` stamps: the
    /// meters, the plan, the spend line, the bar's segments, and the raw walk
    /// over them. Elsewhere (scanned activity, the status feed's own
    /// `checked`, a list with a stamp per row) a data age means nothing, so
    /// the flag is unknown there rather than accepted and inert.
    static let dataAgeNouns: Set<String> = ["status", "limits", "limit", "headroom", "spend", "prompt", "get"]

    /// Both freshness guards. Every duration parses before either is judged
    /// — a bad one is a bad query whatever the other would say — and
    /// `--max-age` is judged first, as it always was. `engine` is the
    /// selected account's: nil for a harness nobody meters here, which has
    /// no measurement to be fresh.
    static func staleness(
        parsed: ParsedArgs, engine: EngineStatus?, generatedAt: Date, now: Date
    ) -> Outcome<Staleness?> {
        let maxAgeText = parsed.flags["max-age"]
        let maxDataAgeText = parsed.flags["max-data-age"]
        let maxAge = maxAgeText.flatMap(parseDuration)
        let maxDataAge = maxDataAgeText.flatMap(parseDuration)
        if let maxAgeText, maxAge == nil {
            return .failure(badQuery("bad --max-age duration '\(maxAgeText)' — e.g. 90s, 5m, 2h, 7d"))
        }
        if let maxDataAgeText, maxDataAge == nil {
            return .failure(badQuery("bad --max-data-age duration '\(maxDataAgeText)' — e.g. 90s, 5m, 2h, 7d"))
        }
        if let maxAge, let maxAgeText {
            let age = now.timeIntervalSince(generatedAt)
            if age > maxAge { return .success(.digestAge(age, limit: maxAgeText)) }
        }
        guard let maxDataAge, let maxDataAgeText else { return .success(nil) }
        guard let fetchedAt = engine?.fetchedAt else { return .success(.unmeasured) }
        let age = now.timeIntervalSince(fetchedAt)
        if age < -clockTolerance { return .success(.measuredAhead(-age)) }
        if age > maxDataAge { return .success(.dataAge(age, limit: maxDataAgeText)) }
        return .success(nil)
    }

    // MARK: - headroom

    /// A run's verdict. The meter verdicts are ranked worst first — the
    /// order a run over several meters settles on (`binding`); `stale` is
    /// decided before any meter is looked at.
    enum HeadroomVerdict: String {
        case overCap = "over-cap"
        case forecast
        case noData = "no-data"
        case ok
        case stale

        var exitCode: Int32 {
            switch self {
            case .ok: exitOK
            case .overCap: exitOverCap
            case .forecast: exitForecast
            case .noData: exitNoData
            case .stale: exitStale
            }
        }

        /// Worst first. A known refusal outranks an unknown, so one meter
        /// over the cap is reported as that rather than as the silence of
        /// another.
        fileprivate var rank: Int {
            switch self {
            case .overCap: 0
            case .forecast: 1
            case .noData: 2
            case .ok: 3
            case .stale: -1
            }
        }
    }

    /// What one run judged, and for whom.
    struct HeadroomAnswer {
        let verdict: HeadroomVerdict
        let cap: Int
        /// The meter that decided the run, a rolled window already aged. Nil
        /// when no meter was judged: stale numbers, or none to judge.
        let meter: LiveMeter?
        let provider: String
        /// The account judged (its `ProfileKey`); nil for a harness nobody
        /// meters here.
        let account: String?
        /// The account is its harness's standard one — the line then names
        /// the harness alone.
        let standardAccount: Bool
        /// The account's engine; nil for a harness nobody meters here.
        let engine: EngineStatus?
        let staleness: Staleness?
        let now: Date

        var headroom: Int? { meter?.percent.map { cap - $0 } }
        var dataAge: TimeInterval? { engine?.fetchedAt.map { now.timeIntervalSince($0) } }
    }

    /// `--raw`'s one row, and what `--header` names its columns: the verdict,
    /// whom it judged, and the numbers that decided it. `--fields` picks any
    /// other set.
    static let headroomColumns = [
        "verdict", "provider", "account", "tag", "percent", "cap", "headroom", "resets-at",
        "forecast.verdict", "data-age",
    ]

    /// `headroom [<meter>] --cap <percent> [--forecast yellow|red]
    /// [--max-data-age <dur>]` for the account `run` selected. Order is part
    /// of the contract: a bad query (19) before anything is read; the
    /// freshness guards (21) before any number is judged — an untrusted
    /// number is never reported as over or under; nothing to judge (26)
    /// before the selector, which uses `limit`'s grammar (20 no match, 19
    /// ambiguous); then the meters.
    static func runHeadroom(
        parsed: ParsedArgs, view: ProfileView, digest: LiveState, now: Date, json: Bool, raw: Bool
    ) -> QueryOutput {
        guard let capText = parsed.flags["cap"] else {
            return badQuery("headroom needs --cap <percent> — a whole number from 0 to 100")
        }
        guard let cap = Int(capText), (0...100).contains(cap) else {
            return badQuery("bad --cap '\(capText)' — a whole number from 0 to 100")
        }
        var forecastPasses: Set<String>?
        if let level = parsed.flags["forecast"] {
            switch level {
            case "red": forecastPasses = ["green", "yellow"]
            case "yellow": forecastPasses = ["green"]
            default: return badQuery("bad --forecast '\(level)' — yellow or red")
            }
        }
        guard parsed.positionals.count <= 1 else {
            return badQuery("too many arguments — headroom takes one meter selector; name fields with --fields")
        }
        let asked = parsed.flags["provider"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if asked?.isEmpty == true { return badQuery("--provider needs a harness id") }

        // Whose numbers. The selector lets a `--provider` nobody meters fall
        // through to the focus, so that a verb's own gate speaks for it —
        // this is headroom's: such a harness has nothing to judge, and the
        // focused harness's numbers never stand in for it. The harness is
        // the one the view's engine MEASURED, which a writer from before
        // profiles states where the selector can only assume.
        let measured = digest.engine.providerID
        let metered = asked.map { $0 == measured } ?? true
        let engine = metered ? digest.engine : nil
        func answer(
            _ verdict: HeadroomVerdict, meter: LiveMeter? = nil, staleness: Staleness? = nil
        ) -> HeadroomAnswer {
            HeadroomAnswer(
                verdict: verdict, cap: cap, meter: meter, provider: asked ?? measured,
                account: metered ? view.id : nil,
                standardAccount: !metered || view.accountID == Profile.defaultID, engine: engine,
                staleness: staleness, now: now)
        }
        func output(_ answer: HeadroomAnswer) -> QueryOutput {
            headroomOutput(answer, parsed: parsed, json: json, raw: raw)
        }

        switch staleness(parsed: parsed, engine: engine, generatedAt: digest.engine.generatedAt, now: now) {
        case .failure(let refusal): return refusal
        case .success(let reason?): return output(answer(.stale, staleness: reason))
        case .success(nil): break
        }

        let meters = metered ? digest.meters.map { rolled($0, now: now) } : []
        var judged = meters
        if let token = parsed.positionals.first, !meters.isEmpty {
            switch selectMeter(token, in: meters) {
            case .none:
                return noMatch("no meter matches '\(token)'")
            case .ambiguous(let ids):
                return badQuery("ambiguous selector '\(token)' matches: \(ids.joined(separator: ", "))")
            case .found(let meter):
                judged = [meter]
            }
        }
        guard let decided = binding(judged, cap: cap, forecastPasses: forecastPasses) else {
            return output(answer(.noData))
        }
        return output(answer(decided.verdict, meter: decided.meter))
    }

    /// One meter against the cap and, when `--forecast` asked, against the
    /// forecast verdicts that pass. An unreported percent is never room. A
    /// meter with no forecast passes the forecast gate — it projects nothing
    /// (right after a reset there are too few samples to fit a rate) and the
    /// cap still binds — while a verdict this build doesn't know fails it.
    static func judge(_ meter: LiveMeter, cap: Int, forecastPasses: Set<String>?) -> HeadroomVerdict {
        guard let percent = meter.percent else { return .noData }
        if percent >= cap { return .overCap }
        if let forecastPasses, let verdict = meter.forecast?.verdict, !forecastPasses.contains(verdict) {
            return .forecast
        }
        return .ok
    }

    /// The meter that decides a run over several: the worst verdict among
    /// them, and inside one verdict the least headroom — crossing ANY limit
    /// is what cuts the user off, so the closest one binds. A tie on percent
    /// goes to the riskier forecast, then to the digest's own order.
    ///
    /// The forecast gate therefore refuses on any judged meter, not only the
    /// closest: a weekly limit on course to run out binds even while the
    /// session limit sits nearer the cap, and the run reports the meter that
    /// failed. Nil for no meters at all.
    static func binding(
        _ meters: [LiveMeter], cap: Int, forecastPasses: Set<String>?
    ) -> (meter: LiveMeter, verdict: HeadroomVerdict)? {
        let judged = meters.enumerated().map { index, meter in
            (index: index, meter: meter, verdict: judge(meter, cap: cap, forecastPasses: forecastPasses))
        }
        let worst = judged.min { lhs, rhs in
            if lhs.verdict.rank != rhs.verdict.rank { return lhs.verdict.rank < rhs.verdict.rank }
            let lhsPercent = lhs.meter.percent ?? -1, rhsPercent = rhs.meter.percent ?? -1
            if lhsPercent != rhsPercent { return lhsPercent > rhsPercent }
            let lhsSeverity = lhs.meter.forecast?.severity ?? -1, rhsSeverity = rhs.meter.forecast?.severity ?? -1
            if lhsSeverity != rhsSeverity { return lhsSeverity > rhsSeverity }
            return lhs.index < rhs.index
        }
        return worst.map { ($0.meter, $0.verdict) }
    }

    /// A window whose reset already passed has rolled over since the digest
    /// was written: what it recorded describes a window that is over, so it
    /// judges as 0% with no reset and no forecast — the engine's own aging
    /// rule for a local snapshot (docs/HARNESSES.md), applied at the moment
    /// of asking rather than at the last publish. A spent window's red
    /// forecast must not refuse the fresh one.
    static func rolled(_ meter: LiveMeter, now: Date) -> LiveMeter {
        guard let resetsAt = meter.resetsAt, resetsAt < now else { return meter }
        return LiveMeter(
            id: meter.id, label: meter.label, tag: meter.tag, percent: 0, level: "normal",
            rank: meter.rank, rateWindowSeconds: meter.rateWindowSeconds,
            forcesWarning: meter.forcesWarning, risk: nil, resetsAt: nil,
            limitWindow: meter.limitWindow, scopedModelName: meter.scopedModelName,
            resetCaption: nil, forecast: nil, series: meter.series, stretches: meter.stretches,
            modelSeries: meter.modelSeries)
    }

    // MARK: - Registers

    /// Every register carries the verdict's exit code — the gate's answer is
    /// the status in all of them, so a `--fields` row (which `multiFieldOutput`
    /// stamps 0) is re-stamped, while its own refusals stand.
    private static func headroomOutput(
        _ answer: HeadroomAnswer, parsed: ParsedArgs, json: Bool, raw: Bool
    ) -> QueryOutput {
        let unix = parsed.flags["unix"] != nil
        let relative = parsed.flags["relative"] != nil
        func resolve(_ field: String, asJSON: Bool) -> QueryOutput {
            headroomField(field, answer: answer, json: asJSON, unix: unix, relative: relative)
        }
        let code = answer.verdict.exitCode
        if let output = multiFieldOutput(
            noun: "headroom", parsed: parsed, positionalField: nil, json: json,
            header: parsed.flags["header"] != nil, resolve: resolve)
        {
            return output.exitCode == exitOK ? QueryOutput(stdout: output.stdout, exitCode: code) : output
        }
        if json {
            return QueryOutput(stdout: DigestQueryFormat.jsonValue(HeadroomJSON(answer)), exitCode: code)
        }
        if raw {
            let row = headroomColumns.map { resolve($0, asJSON: false).stdout }
            let header = parsed.flags["header"] != nil ? headroomColumns : nil
            return QueryOutput(stdout: DigestQueryFormat.tsv([row], header: header), exitCode: code)
        }
        return QueryOutput(stdout: headroomLine(answer), exitCode: code)
    }

    private static func headroomField(
        _ field: String, answer: HeadroomAnswer, json: Bool, unix: Bool, relative: Bool
    ) -> QueryOutput {
        let meter = answer.meter
        let engine = answer.engine
        switch field {
        case "verdict": return DigestQueryFormat.textField(answer.verdict.rawValue, json: json)
        case "cap": return DigestQueryFormat.intField(answer.cap, json: json)
        case "percent": return DigestQueryFormat.intField(meter?.percent, json: json)
        case "headroom": return DigestQueryFormat.intField(answer.headroom, json: json)
        case "label": return DigestQueryFormat.textField(meter?.label, json: json)
        case "tag": return DigestQueryFormat.textField(meter?.tag, json: json)
        case "resets-at":
            return DigestQueryFormat.dateField(
                meter?.resetsAt, json: json, unix: unix, relative: relative, caption: meter?.resetCaption)
        case "resets-in":
            return DigestQueryFormat.secondsField(
                meter?.resetsAt.map { $0.timeIntervalSince(answer.now) }, json: json, relative: relative)
        case "forecast.verdict": return DigestQueryFormat.textField(meter?.forecast?.verdict, json: json)
        case "forecast.projected": return DigestQueryFormat.intField(meter?.forecast?.projectedAtReset, json: json)
        case "forecast.exhausts-at":
            return DigestQueryFormat.dateField(
                meter?.forecast?.exhaustsAt, json: json, unix: unix, relative: relative,
                caption: meter?.forecast?.caption)
        case "fetched-at":
            return DigestQueryFormat.dateField(engine?.fetchedAt, json: json, unix: unix, relative: false)
        case "data-age": return DigestQueryFormat.secondsField(answer.dataAge, json: json, relative: relative)
        case "plan": return DigestQueryFormat.textField(engine?.planLabel, json: json)
        case "plan-type": return DigestQueryFormat.textField(engine?.planSubscriptionType, json: json)
        case "provider": return DigestQueryFormat.textField(answer.provider, json: json)
        case "account": return DigestQueryFormat.textField(answer.account, json: json)
        default: return unknownField(noun: "headroom", field: field)
        }
    }

    /// "codex · W 35% of cap 80% · 45 pts left · resets in 5 days 22 hr ·
    /// forecast red — runs out Tue 18:21": the house captions verbatim, never
    /// re-phrased here. A stale run says why, and judges nothing.
    private static func headroomLine(_ answer: HeadroomAnswer) -> String {
        var subject = answer.provider
        if !answer.standardAccount, let account = answer.account { subject += " (\(account))" }
        if answer.verdict == .stale {
            return "\(subject) · stale — \(staleReason(answer.staleness))"
        }
        guard let meter = answer.meter else {
            let why = answer.engine == nil ? "not metered here" : "no meters"
            return "\(subject) · \(why) — nothing to judge"
        }
        guard let percent = meter.percent else {
            return "\(subject) · \(meter.tag) — of cap \(answer.cap)% · no percent reported — nothing to judge"
        }
        var parts = [subject, "\(meter.tag) \(percent)% of cap \(answer.cap)%"]
        let room = answer.cap - percent
        switch room {
        case 0: parts.append("at the cap")
        case 1: parts.append("1 pt left")
        case -1: parts.append("1 pt over")
        case ..<0: parts.append("\(-room) pts over")
        default: parts.append("\(room) pts left")
        }
        if let caption = meter.resetCaption { parts.append(caption) }
        if let forecast = meter.forecast, forecast.verdict != "green" {
            parts.append(forecast.caption.map { "forecast \(forecast.verdict) — \($0)" } ?? "forecast \(forecast.verdict)")
        }
        return parts.joined(separator: " · ")
    }

    private static func staleReason(_ staleness: Staleness?) -> String {
        switch staleness {
        case .digestAge(let age, let limit)?:
            "the digest was written \(UsageFormatting.duration(age)) ago, past --max-age \(limit)"
        case .dataAge(let age, let limit)?:
            "measured \(UsageFormatting.duration(age)) ago, past --max-data-age \(limit)"
        case .unmeasured?:
            "no measurement time to judge its age by"
        case .measuredAhead(let lead)?:
            "measured \(UsageFormatting.duration(lead)) ahead of this clock, so its age can't be judged"
        case nil:
            "older than allowed"
        }
    }

    /// `--json`'s object: ONE shape for every verdict — each key present,
    /// null when absent (absent ≠ zero), so a caller logging a refusal reads
    /// the same keys it reads on a pass. Encoded by hand, never synthesized:
    /// a synthesized encoder drops nil keys, and this object is a contract.
    private struct HeadroomJSON: Encodable {
        let answer: HeadroomAnswer

        init(_ answer: HeadroomAnswer) { self.answer = answer }

        private enum CodingKeys: String, CodingKey {
            case verdict, cap, percent, headroom, label, tag, resetsAt, resetsIn, forecast, fetchedAt, dataAge
            case plan, planType, provider, account
        }

        private enum ForecastKeys: String, CodingKey {
            case verdict, projected, exhaustsAt
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let meter = answer.meter
            try container.encode(answer.verdict.rawValue, forKey: .verdict)
            try container.encode(answer.cap, forKey: .cap)
            try container.encode(meter?.percent, forKey: .percent)
            try container.encode(answer.headroom, forKey: .headroom)
            try container.encode(meter?.label, forKey: .label)
            try container.encode(meter?.tag, forKey: .tag)
            try container.encode(meter?.resetsAt, forKey: .resetsAt)
            try container.encode(meter?.resetsAt.map { Int($0.timeIntervalSince(answer.now)) }, forKey: .resetsIn)
            if let forecast = meter?.forecast {
                var nested = container.nestedContainer(keyedBy: ForecastKeys.self, forKey: .forecast)
                try nested.encode(forecast.verdict, forKey: .verdict)
                try nested.encode(forecast.projectedAtReset, forKey: .projected)
                try nested.encode(forecast.exhaustsAt, forKey: .exhaustsAt)
            } else {
                try container.encodeNil(forKey: .forecast)
            }
            try container.encode(answer.engine?.fetchedAt, forKey: .fetchedAt)
            try container.encode(answer.dataAge.map { Int($0) }, forKey: .dataAge)
            try container.encode(answer.engine?.planLabel, forKey: .plan)
            try container.encode(answer.engine?.planSubscriptionType, forKey: .planType)
            try container.encode(answer.provider, forKey: .provider)
            try container.encode(answer.account, forKey: .account)
        }
    }
}
