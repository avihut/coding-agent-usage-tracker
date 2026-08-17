import Foundation

/// `DigestQuery`'s noun handlers — one function per noun (plus the
/// noun-scoped helpers only that noun needs), split from `DigestQuery.swift`
/// along the house rule (a file over ~600 lines splits along a whole-type
/// seam): that file is the grammar core (entry point, arg parsing,
/// selectors, ranges) shared by everything below; this extension is
/// "the nouns" per the plan's own item 3. Every helper here that the core
/// file's selectors/ranges/`Outcome`/`Selection` machinery needs is
/// `internal` (no `private`) so it crosses the file boundary within the
/// module — nothing here is `public`, so the CLI target still only sees
/// `DigestQuery.run`, `.nouns`, and `.parseDuration`.
extension DigestQuery {
    // MARK: - status

    static func runStatus(parsed: ParsedArgs, digest: LiveState, now: Date, json: Bool) -> QueryOutput {
        if parsed.flags["check"] != nil {
            return QueryOutput(stdout: "", exitCode: digest.engine.stale ? exitStale : exitOK)
        }
        let engine = digest.engine
        guard let field = parsed.positionals.first else {
            guard parsed.positionals.isEmpty else { return badQuery("too many arguments") }
            // Singular no-field summaries honor the registers like the
            // plural lists do: --json prints the digest object itself;
            // --raw needs a row vocabulary or a field — never a silent
            // fall-through to the human line.
            if json { return ok(DigestQueryFormat.jsonValue(engine)) }
            if parsed.flags["raw"] != nil {
                return badQuery("raw needs a field — e.g. `status age`")
            }
            var parts = [engine.serviceName]
            if let plan = engine.planLabel { parts.append(plan) }
            parts.append("\(engine.host) pid \(engine.pid)")
            if let fetchedAt = engine.fetchedAt {
                parts.append("fetched \(UsageFormatting.duration(max(0, now.timeIntervalSince(fetchedAt)))) ago")
            }
            if let nextPollAt = engine.nextPollAt, nextPollAt > now {
                parts.append("next poll in \(UsageFormatting.duration(nextPollAt.timeIntervalSince(now)))")
            }
            if let error = engine.error { parts.append("ERROR: \(error.text)") }
            return ok(withStaleSuffix(parts.joined(separator: " · "), digest: digest))
        }
        guard parsed.positionals.count == 1 else { return badQuery("too many arguments") }
        let unix = parsed.flags["unix"] != nil
        switch field {
        case "provider": return DigestQueryFormat.textField(engine.providerID, json: json)
        case "service": return DigestQueryFormat.textField(engine.serviceName, json: json)
        case "agent": return DigestQueryFormat.textField(engine.agentName, json: json)
        case "glyph": return DigestQueryFormat.textField(engine.glyph, json: json)
        case "plan": return DigestQueryFormat.textField(engine.planLabel, json: json)
        case "plan.type": return DigestQueryFormat.textField(engine.planSubscriptionType, json: json)
        case "plan.tier": return DigestQueryFormat.textField(engine.planRateLimitTier, json: json)
        case "host": return DigestQueryFormat.textField(engine.host, json: json)
        case "pid": return DigestQueryFormat.intField(engine.pid, json: json)
        case "version": return DigestQueryFormat.textField(engine.appVersion, json: json)
        case "schema": return DigestQueryFormat.intField(digest.schemaVersion, json: json)
        case "generated": return DigestQueryFormat.dateField(engine.generatedAt, json: json, unix: unix, relative: false)
        case "fetched": return DigestQueryFormat.dateField(engine.fetchedAt, json: json, unix: unix, relative: false)
        case "age":
            // Since fetchedAt, not generatedAt — "how old is the DATA", the
            // freshness `--max-age` itself judges off generatedAt instead
            // (the digest's own publish time, not the upstream fetch).
            let age = engine.fetchedAt.map { now.timeIntervalSince($0) }
            return DigestQueryFormat.secondsField(age, json: json)
        case "next-poll": return DigestQueryFormat.dateField(engine.nextPollAt, json: json, unix: unix, relative: false)
        case "backoff": return DigestQueryFormat.dateField(engine.backoffUntil, json: json, unix: unix, relative: false)
        case "gate-floor": return DigestQueryFormat.secondsField(engine.gateFloorSeconds, json: json)
        case "stale": return DigestQueryFormat.boolField(engine.stale, json: json)
        case "local": return DigestQueryFormat.boolField(engine.isLocalProvider, json: json)
        case "pace": return DigestQueryFormat.secondsField(engine.activeIntervalSeconds, json: json)
        case "pace.multiplier": return DigestQueryFormat.intField(engine.paceMultiplier, json: json)
        case "error": return DigestQueryFormat.textField(engine.error?.text, json: json)
        case "error.code": return DigestQueryFormat.textField(engine.error?.code, json: json)
        case "error.hint": return DigestQueryFormat.textField(engine.error?.hint, json: json)
        case "error.http": return DigestQueryFormat.intField(engine.error?.httpStatus, json: json)
        case "accent": return DigestQueryFormat.textField(engine.accent.hexString, json: json)
        case "system-accent": return DigestQueryFormat.textField(engine.systemAccent?.hexString, json: json)
        case "forecast.ready": return DigestQueryFormat.boolField(engine.forecastProfile?.isReady, json: json)
        case "forecast.remaining": return DigestQueryFormat.secondsField(engine.forecastProfile?.remainingSeconds, json: json)
        case "forecast.caption": return DigestQueryFormat.textField(engine.forecastProfile?.caption, json: json)
        case "timezone": return DigestQueryFormat.textField(digest.activity.timeZone, json: json)
        default: return badQuery("status has no field '\(field)'")
        }
    }

    // MARK: - limits / limit

    static func runLimits(parsed: ParsedArgs, digest: LiveState, json: Bool, raw: Bool) -> QueryOutput {
        guard parsed.positionals.isEmpty else {
            return badQuery("limits takes no selector — did you mean 'limit \(parsed.positionals[0])'?")
        }
        if json { return ok(DigestQueryFormat.jsonValue(digest.meters)) }
        guard !digest.meters.isEmpty else { return ok("") }
        if raw {
            let unix = parsed.flags["unix"] != nil
            let rows = digest.meters.map { meterRawRow($0, unix: unix) }
            let header = parsed.flags["header"] != nil ? meterColumns : nil
            return ok(DigestQueryFormat.tsv(rows, header: header))
        }
        let rows = digest.meters.map(meterSummaryRow)
        return ok(DigestQueryFormat.table(rows))
    }

    private static let meterColumns = ["id", "tag", "percent", "level", "resets_at"]

    private static func meterRawRow(_ meter: LiveMeter, unix: Bool) -> [String] {
        [meter.id, meter.tag, DigestQueryFormat.rawInt(meter.percent), meter.level,
         meter.resetsAt.map {
             unix ? String(Int($0.timeIntervalSince1970)) : DigestQueryFormat.iso($0)
         } ?? ""]
    }

    static func runLimit(parsed: ParsedArgs, digest: LiveState, now: Date, json: Bool) -> QueryOutput {
        var positionals = parsed.positionals
        guard !positionals.isEmpty else {
            return badQuery("limit needs a selector — an id, tag, label, 'worst', or 'next'")
        }
        let selectorToken = positionals.removeFirst()
        guard positionals.count <= 1 else { return badQuery("too many arguments") }
        let field = positionals.first

        switch selectMeter(selectorToken, in: digest.meters) {
        case .none:
            return noMatch("no meter matches '\(selectorToken)'")
        case .ambiguous(let ids):
            return badQuery("ambiguous selector '\(selectorToken)' matches: \(ids.joined(separator: ", "))")
        case .found(let meter):
            guard let field else {
                if json { return ok(DigestQueryFormat.jsonValue(meter)) }
                if parsed.flags["raw"] != nil {
                    let row = meterRawRow(meter, unix: parsed.flags["unix"] != nil)
                    return ok(DigestQueryFormat.tsv(
                        [row], header: parsed.flags["header"] != nil ? meterColumns : nil))
                }
                return ok(withStaleSuffix(meterSummaryLine(meter), digest: digest))
            }
            return meterField(
                field, meter: meter, now: now, json: json,
                unix: parsed.flags["unix"] != nil, relative: parsed.flags["relative"] != nil,
                header: parsed.flags["header"] != nil)
        }
    }

    private static func meterSummaryLine(_ meter: LiveMeter) -> String {
        var parts = ["\(meter.tag)  \(meter.label) · \(DigestQueryFormat.humanPercent(meter.percent))"]
        if let caption = meter.resetCaption { parts.append(caption) }
        if let caption = meter.forecast?.caption { parts.append(caption) }
        return parts.joined(separator: " · ")
    }

    private static func meterSummaryRow(_ meter: LiveMeter) -> [String] {
        var caption = meter.resetCaption ?? ""
        if let forecastCaption = meter.forecast?.caption {
            caption = caption.isEmpty ? forecastCaption : "\(caption) · \(forecastCaption)"
        }
        return [meter.tag, meter.label, DigestQueryFormat.humanPercent(meter.percent), caption]
    }

    private static func meterField(
        _ field: String, meter: LiveMeter, now: Date, json: Bool, unix: Bool, relative: Bool, header: Bool
    ) -> QueryOutput {
        switch field {
        case "percent": return DigestQueryFormat.intField(meter.percent, json: json)
        case "left": return DigestQueryFormat.intField(meter.percent.map { 100 - $0 }, json: json)
        case "label": return DigestQueryFormat.textField(meter.label, json: json)
        case "tag": return DigestQueryFormat.textField(meter.tag, json: json)
        case "level": return DigestQueryFormat.textField(meter.level, json: json)
        case "rank": return DigestQueryFormat.intField(meter.rank, json: json)
        case "severity", "forecast.severity": return DigestQueryFormat.numberField(meter.forecast?.severity, json: json)
        case "risk": return DigestQueryFormat.hexField(meter.risk, json: json)
        case "resets-at":
            return DigestQueryFormat.dateField(
                meter.resetsAt, json: json, unix: unix, relative: relative, caption: meter.resetCaption)
        case "resets-in":
            return DigestQueryFormat.secondsField(meter.resetsAt.map { $0.timeIntervalSince(now) }, json: json)
        case "caption": return DigestQueryFormat.textField(meter.resetCaption, json: json)
        case "window": return DigestQueryFormat.secondsField(meter.limitWindow, json: json)
        case "rate-window": return DigestQueryFormat.secondsField(meter.rateWindowSeconds, json: json)
        case "forces-warning": return DigestQueryFormat.boolField(meter.forcesWarning, json: json)
        case "scoped-model": return DigestQueryFormat.textField(meter.scopedModelName, json: json)
        case "exhausted":
            // A reported percent is authoritative when present — a stale
            // forecast's past `exhaustsAt` must never override a live
            // percent that disagrees; the forecast only stands in when
            // percent itself is unreported. Absent when neither is known.
            let exhausted: Bool? = meter.percent.map { $0 >= 100 } ?? meter.forecast?.exhaustsAt.map { $0 <= now }
            return DigestQueryFormat.boolField(exhausted, json: json)
        case "forecast.projected": return DigestQueryFormat.intField(meter.forecast?.projectedAtReset, json: json)
        case "forecast.exhausts-at":
            return DigestQueryFormat.dateField(
                meter.forecast?.exhaustsAt, json: json, unix: unix, relative: relative,
                caption: meter.forecast?.caption)
        case "forecast.exhausts-in":
            return DigestQueryFormat.secondsField(meter.forecast?.exhaustsAt.map { $0.timeIntervalSince(now) }, json: json)
        case "forecast.verdict": return DigestQueryFormat.textField(meter.forecast?.verdict, json: json)
        case "forecast.raw-verdict": return DigestQueryFormat.textField(meter.forecast?.rawVerdict, json: json)
        case "forecast.rate": return DigestQueryFormat.numberField(meter.forecast?.ratePerHour, json: json)
        case "forecast.baseline": return DigestQueryFormat.numberField(meter.forecast?.baselineRatePerHour, json: json)
        case "forecast.pace": return DigestQueryFormat.numberField(meter.forecast?.paceFactor, json: json)
        case "forecast.basis": return DigestQueryFormat.textField(meter.forecast?.basis, json: json)
        case "forecast.caption": return DigestQueryFormat.textField(meter.forecast?.caption, json: json)
        case "series": return seriesOutput(meter.series, json: json, header: header)
        case "curve": return seriesOutput(meter.forecast?.curve ?? [], json: json, header: header)
        case "stretches": return stretchesOutput(meter.stretches, json: json, header: header)
        case "models": return modelSeriesOutput(meter.modelSeries, json: json, header: header)
        default: return badQuery("limit has no field '\(field)'")
        }
    }

    /// Series/curve/stretches are ALWAYS TSV — a 120-point line has no
    /// sensible "human table" and design §2 pins this shape outright
    /// (awk/gnuplot-ready), unlike the noun-level lists below which do
    /// switch between an aligned table and TSV.
    private static func seriesOutput(_ points: [SeriesPoint], json: Bool, header: Bool) -> QueryOutput {
        if json { return ok(DigestQueryFormat.jsonValue(points)) }
        let rows = points.map { [DigestQueryFormat.iso($0.t), DigestQueryFormat.rawNumber($0.percent)] }
        return ok(DigestQueryFormat.tsv(rows, header: header ? ["t", "percent"] : nil))
    }

    private static func stretchesOutput(_ stretches: [Stretch], json: Bool, header: Bool) -> QueryOutput {
        if json { return ok(DigestQueryFormat.jsonValue(stretches)) }
        let rows = stretches.map {
            [DigestQueryFormat.iso($0.start), DigestQueryFormat.iso($0.end), DigestQueryFormat.rawBool($0.exhausted)]
        }
        return ok(DigestQueryFormat.tsv(rows, header: header ? ["start", "end", "exhausted"] : nil))
    }

    /// Per-model window share: name + the curve's LAST point (its share as
    /// of `now`) — `--json` carries the full curves instead, per design.
    private static func modelSeriesOutput(_ series: [ModelSeries], json: Bool, header: Bool) -> QueryOutput {
        if json { return ok(DigestQueryFormat.jsonValue(series)) }
        let rows = series.map { curve -> [String] in
            [curve.displayName, curve.points.last.map { DigestQueryFormat.rawNumber($0.percent) } ?? ""]
        }
        return ok(DigestQueryFormat.tsv(rows, header: header ? ["name", "percent"] : nil))
    }

    // MARK: - budget

    static func runBudget(parsed: ParsedArgs, digest: LiveState, json: Bool) -> QueryOutput {
        guard parsed.positionals.count <= 1 else { return badQuery("too many arguments") }
        let engine = digest.engine
        guard let field = parsed.positionals.first else {
            // Local providers carry no budget gauge at all — absent, not a
            // fabricated "0 of 0 requests" line.
            guard let used = engine.apiBudgetUsed else { return ok(json ? "null" : "") }
            if json {
                struct Box: Encodable {
                    let used: Int
                    let ceiling: Int?
                    let left: Int?
                    let fraction: Double?
                }
                return ok(DigestQueryFormat.jsonValue(Box(
                    used: used,
                    ceiling: engine.apiBudgetCeiling,
                    left: engine.apiBudgetCeiling.map { $0 - used },
                    fraction: engine.apiBudgetFraction)))
            }
            if parsed.flags["raw"] != nil {
                return badQuery("raw needs a field — e.g. `budget left`")
            }
            var line = "\(used)"
            if let ceiling = engine.apiBudgetCeiling { line += " of \(ceiling)" }
            line += " requests this hour"
            if let fraction = engine.apiBudgetFraction { line += " (\(Int((fraction * 100).rounded()))%)" }
            return ok(withStaleSuffix(line, digest: digest))
        }
        switch field {
        case "used": return DigestQueryFormat.intField(engine.apiBudgetUsed, json: json)
        case "ceiling": return DigestQueryFormat.intField(engine.apiBudgetCeiling, json: json)
        case "left":
            let left: Int? = {
                guard let ceiling = engine.apiBudgetCeiling, let used = engine.apiBudgetUsed else { return nil }
                return ceiling - used
            }()
            return DigestQueryFormat.intField(left, json: json)
        case "fraction": return DigestQueryFormat.numberField(engine.apiBudgetFraction, json: json)
        default: return badQuery("budget has no field '\(field)'")
        }
    }

    // MARK: - spend

    static func runSpend(parsed: ParsedArgs, digest: LiveState, json: Bool) -> QueryOutput {
        guard parsed.positionals.count <= 1 else { return badQuery("too many arguments") }
        guard let spend = digest.engine.spend else {
            // No spend line for this provider — the same "entirely absent"
            // shape `budget` uses for a local provider's missing gauge: a
            // KNOWN field still resolves (absent value, exit 0); only an
            // unrecognized field name is a bad query. Previously this
            // guard short-circuited every field to exit 19, which made an
            // absent VALUE indistinguishable from a typo — a hard-rule
            // violation caught by the test suite.
            guard let field = parsed.positionals.first else { return ok(json ? "null" : "") }
            switch field {
            case "used", "limit", "left": return DigestQueryFormat.numberField(nil, json: json)
            case "currency": return DigestQueryFormat.textField(nil, json: json)
            default: return badQuery("spend has no field '\(field)'")
            }
        }
        let scale = pow(10.0, Double(spend.exponent))
        let used = Double(spend.usedMinor) / scale
        let limit = spend.limitMinor.map { Double($0) / scale }
        guard let field = parsed.positionals.first else {
            if json { return ok(DigestQueryFormat.jsonValue(spend)) }
            if parsed.flags["raw"] != nil {
                return badQuery("raw needs a field — e.g. `spend used`")
            }
            var line = UsageFormatting.money(used)
            if let limit { line += " of \(UsageFormatting.money(limit))" }
            line += " \(spend.currency)"
            return ok(withStaleSuffix(line, digest: digest))
        }
        switch field {
        case "used": return DigestQueryFormat.numberField(used, json: json)
        case "limit": return DigestQueryFormat.numberField(limit, json: json)
        case "left": return DigestQueryFormat.numberField(limit.map { $0 - used }, json: json)
        case "currency": return DigestQueryFormat.textField(spend.currency, json: json)
        default: return badQuery("spend has no field '\(field)'")
        }
    }

    // MARK: - activity / cost

    static func runActivity(
        parsed: ParsedArgs, digest: LiveState, now: Date, calendar: Calendar, json: Bool, raw: Bool,
        sugarCost: Bool
    ) -> QueryOutput {
        var positionals = parsed.positionals
        let rangeToken = positionals.isEmpty ? "today" : positionals.removeFirst()
        guard let range = parseRange(rangeToken) else {
            return badQuery("bad range '\(rangeToken)' — today, yesterday, yyyy-MM-dd, 7d, 30d, month, year, all")
        }
        if sugarCost {
            guard positionals.isEmpty else {
                return badQuery("cost takes no field — try 'activity \(rangeToken) \(positionals[0])'")
            }
        } else {
            guard positionals.count <= 1 else { return badQuery("too many arguments") }
        }
        let field = sugarCost ? nil : positionals.first

        let window = resolveWindow(range, now: now, calendar: calendar)
        if case .day = range, !isWithinDaysHorizon(window.start, now: now, calendar: calendar) {
            return noMatch("'\(rangeToken)' is outside the digest's ~12-month horizon")
        }
        if case .yesterday = range, !isWithinDaysHorizon(window.start, now: now, calendar: calendar) {
            return noMatch("'\(rangeToken)' is outside the digest's ~12-month horizon")
        }

        let tokens: Int
        let prompts: Int
        let cost: Double?
        if case .today = range {
            // Never a now-derived key into days[] — a digest generated
            // moments before local midnight would otherwise miss its own
            // dedicated today* fields for the single most common query.
            tokens = digest.activity.todayTokens
            prompts = digest.activity.todayPrompts
            cost = digest.activity.todayCost
        } else {
            let matched = digest.activity.days.filter { $0.dayKey >= window.start && $0.dayKey <= window.end }
            tokens = matched.reduce(0) { $0 + $1.tokens }
            prompts = matched.reduce(0) { $0 + $1.prompts }
            let costs = matched.compactMap(\.cost)
            cost = costs.isEmpty ? nil : costs.reduce(0, +)
        }

        if sugarCost {
            if json { return ok(DigestQueryFormat.jsonValue(cost)) }
            if raw { return ok(DigestQueryFormat.rawMoney(cost)) }
            return ok(withStaleSuffix(DigestQueryFormat.humanMoney(cost), digest: digest))
        }
        guard let field else {
            if json {
                struct Box: Encodable {
                    let tokens: Int
                    let prompts: Int
                    let cost: Double?
                }
                return ok(DigestQueryFormat.jsonValue(Box(
                    tokens: tokens, prompts: prompts, cost: cost)))
            }
            if raw {
                return badQuery("raw needs a field — e.g. `activity today tokens`")
            }
            let line = "\(range.label) · \(TokenFormat.compact(tokens)) tokens · \(prompts) prompts"
                + " · \(DigestQueryFormat.humanMoney(cost))"
            return ok(withStaleSuffix(line, digest: digest))
        }
        let header = parsed.flags["header"] != nil
        switch field {
        case "tokens": return DigestQueryFormat.intField(tokens, json: json)
        case "prompts": return DigestQueryFormat.intField(prompts, json: json)
        case "cost": return DigestQueryFormat.numberField(cost, json: json)
        case "days":
            let matched = digest.activity.days.filter { $0.dayKey >= window.start && $0.dayKey <= window.end }
            return dayRollupOutput(matched, json: json, raw: raw, header: header)
        case "hours":
            let matched = digest.activity.hourDays.filter { $0.dayKey >= window.start && $0.dayKey <= window.end }
            guard !matched.isEmpty else {
                return noMatch("no hourly data for '\(rangeToken)' — beyond the ~8-day timeline retention")
            }
            return hourBucketOutput(matched, json: json, raw: raw, header: header)
        case "models":
            let matched = digest.activity.modelDays.filter { $0.dayKey >= window.start && $0.dayKey <= window.end }
            guard !matched.isEmpty else {
                return noMatch("no per-model data for '\(rangeToken)' — beyond the ~35-day model horizon")
            }
            return modelRowsOutput(aggregateModels(matched), json: json, raw: raw, header: header)
        default: return badQuery("activity has no field '\(field)'")
        }
    }

    private static func dayRollupOutput(_ days: [DayRollup], json: Bool, raw: Bool, header: Bool) -> QueryOutput {
        if json { return ok(DigestQueryFormat.jsonValue(days)) }
        guard !days.isEmpty else { return ok("") }
        if raw {
            let rows = days.map { [$0.dayKey, String($0.tokens), String($0.prompts), DigestQueryFormat.rawMoney($0.cost)] }
            return ok(DigestQueryFormat.tsv(rows, header: header ? ["day", "tokens", "prompts", "cost"] : nil))
        }
        let rows = days.map {
            [$0.dayKey, TokenFormat.compact($0.tokens), "\($0.prompts)", DigestQueryFormat.humanMoney($0.cost)]
        }
        return ok(DigestQueryFormat.table(rows))
    }

    private static func hourBucketOutput(_ days: [DayHours], json: Bool, raw: Bool, header: Bool) -> QueryOutput {
        if json { return ok(DigestQueryFormat.jsonValue(days)) }
        if raw {
            let rows = days.flatMap { day in
                day.hours.map { [String($0.hour), String($0.tokens), DigestQueryFormat.rawMoney($0.cost)] }
            }
            return ok(DigestQueryFormat.tsv(rows, header: header ? ["hour", "tokens", "cost"] : nil))
        }
        let rows = days.flatMap { day in
            day.hours.map { [String($0.hour), TokenFormat.compact($0.tokens), DigestQueryFormat.humanMoney($0.cost)] }
        }
        return ok(DigestQueryFormat.table(rows))
    }

    private static func modelRowsOutput(_ models: [ModelRow], json: Bool, raw: Bool, header: Bool) -> QueryOutput {
        if json { return ok(DigestQueryFormat.jsonValue(models)) }
        guard !models.isEmpty else { return ok("") }
        if raw {
            let rows = models.map { [$0.id, $0.displayName, String($0.tally.total), DigestQueryFormat.rawMoney($0.cost)] }
            return ok(DigestQueryFormat.tsv(rows, header: header ? ["id", "name", "tokens", "cost"] : nil))
        }
        let rows = models.map {
            [$0.displayName, TokenFormat.compact($0.tally.total), DigestQueryFormat.humanMoney($0.cost)]
        }
        return ok(DigestQueryFormat.table(rows))
    }

    // MARK: - models / model

    static func runModels(
        parsed: ParsedArgs, digest: LiveState, now: Date, calendar: Calendar, json: Bool, raw: Bool
    ) -> QueryOutput {
        guard parsed.positionals.isEmpty else {
            return badQuery("models takes no selector — did you mean 'model \(parsed.positionals[0])'?")
        }
        switch resolveModelScope(parsed: parsed, digest: digest, now: now, calendar: calendar) {
        case .failure(let output): return output
        case .success(let models):
            return modelRowsOutput(models, json: json, raw: raw, header: parsed.flags["header"] != nil)
        }
    }

    static func runModel(
        parsed: ParsedArgs, digest: LiveState, now: Date, calendar: Calendar, json: Bool
    ) -> QueryOutput {
        var positionals = parsed.positionals
        guard !positionals.isEmpty else { return badQuery("model needs a selector — an id, name, or 'top'") }
        let selectorToken = positionals.removeFirst()
        guard positionals.count <= 1 else { return badQuery("too many arguments") }
        let field = positionals.first

        switch resolveModelScope(parsed: parsed, digest: digest, now: now, calendar: calendar) {
        case .failure(let output): return output
        case .success(let models):
            switch selectModel(selectorToken, in: models) {
            case .none: return noMatch("no model matches '\(selectorToken)'")
            case .ambiguous(let ids):
                return badQuery("ambiguous selector '\(selectorToken)' matches: \(ids.joined(separator: ", "))")
            case .found(let model):
                guard let field else {
                    if json { return ok(DigestQueryFormat.jsonValue(model)) }
                    if parsed.flags["raw"] != nil {
                        return modelRowsOutput(
                            [model], json: false, raw: true,
                            header: parsed.flags["header"] != nil)
                    }
                    let line = "\(model.displayName) · \(TokenFormat.compact(model.tally.total)) tokens"
                        + " · \(DigestQueryFormat.humanMoney(model.cost))"
                    return ok(withStaleSuffix(line, digest: digest))
                }
                let scopeTotal = models.reduce(0) { $0 + $1.tally.total }
                return modelField(field, model: model, scopeTotal: scopeTotal, json: json)
            }
        }
    }

    /// `--day`/`--range` re-scope the WHOLE noun through `modelDays` before
    /// any selector runs — `models`/`model` share this, matching the design
    /// doc's shared field-table section for both.
    private static func resolveModelScope(
        parsed: ParsedArgs, digest: LiveState, now: Date, calendar: Calendar
    ) -> Outcome<[ModelRow]> {
        if let dayText = parsed.flags["day"] {
            guard let match = digest.activity.modelDays.first(where: { $0.dayKey == dayText }) else {
                return .failure(noMatch("no per-model data for '\(dayText)' — beyond the ~35-day model horizon, or nothing logged that day"))
            }
            return .success(match.models)
        }
        if let rangeText = parsed.flags["range"] {
            guard rangeText == "7d" || rangeText == "30d", let range = parseRange(rangeText) else {
                return .failure(badQuery("--range wants 7d or 30d"))
            }
            let window = resolveWindow(range, now: now, calendar: calendar)
            let matched = digest.activity.modelDays.filter { $0.dayKey >= window.start && $0.dayKey <= window.end }
            guard !matched.isEmpty else {
                return .failure(noMatch("no per-model data in the last \(rangeText) — beyond the ~35-day model horizon"))
            }
            return .success(aggregateModels(matched))
        }
        return .success(digest.models)
    }

    private static func modelField(_ field: String, model: ModelRow, scopeTotal: Int, json: Bool) -> QueryOutput {
        switch field {
        case "name": return DigestQueryFormat.textField(model.displayName, json: json)
        case "id": return DigestQueryFormat.textField(model.id, json: json)
        case "color": return DigestQueryFormat.hexField(model.color, json: json)
        case "cost": return DigestQueryFormat.numberField(model.cost, json: json)
        case "share":
            let share: Double? = scopeTotal > 0 ? Double(model.tally.total) / Double(scopeTotal) : nil
            return DigestQueryFormat.numberField(share, json: json)
        case "tokens": return DigestQueryFormat.intField(model.tally.total, json: json)
        case "tokens.input": return DigestQueryFormat.intField(model.tally.input, json: json)
        case "tokens.output": return DigestQueryFormat.intField(model.tally.output, json: json)
        case "tokens.cache-read": return DigestQueryFormat.intField(model.tally.cacheRead, json: json)
        case "tokens.cache-write": return DigestQueryFormat.intField(model.tally.cacheCreation, json: json)
        case "tokens.cache-write-1h": return DigestQueryFormat.intField(model.tally.cacheCreation1h, json: json)
        case "tokens.uncached-input": return DigestQueryFormat.intField(model.tally.uncachedInput, json: json)
        case "tokens.input-side": return DigestQueryFormat.intField(model.tally.inputSide, json: json)
        case "tokens.cached-share": return DigestQueryFormat.numberField(model.tally.cachedShare, json: json)
        default: return badQuery("model has no field '\(field)'")
        }
    }

    // MARK: - sessions / session

    static func runSessionsList(
        parsed: ParsedArgs, digest: LiveState, now: Date, calendar: Calendar, json: Bool, raw: Bool
    ) -> QueryOutput {
        guard parsed.positionals.isEmpty else {
            return badQuery("sessions takes no selector — did you mean 'session \(parsed.positionals[0])'?")
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

    static func runSession(
        parsed: ParsedArgs, digest: LiveState, now: Date, calendar: Calendar, json: Bool
    ) -> QueryOutput {
        var positionals = parsed.positionals
        guard !positionals.isEmpty else {
            return badQuery("session needs a selector — 'latest', a shortlist index, or an id prefix")
        }
        let selectorToken = positionals.removeFirst()
        guard positionals.count <= 1 else { return badQuery("too many arguments") }
        let field = positionals.first

        switch filterSessions(digest.sessions, parsed: parsed, now: now, calendar: calendar) {
        case .failure(let output): return output
        case .success(let sessions):
            switch selectSession(selectorToken, in: sessions) {
            case .none:
                return noMatch("no session matches '\(selectorToken)' in the shortlist (≤8) — try --all (M2) for the full index")
            case .ambiguous(let ids):
                return badQuery("ambiguous selector '\(selectorToken)' matches: \(ids.joined(separator: ", "))")
            case .found(let session):
                guard let field else {
                    if json { return ok(DigestQueryFormat.jsonValue(session)) }
                    if parsed.flags["raw"] != nil {
                        return ok(DigestQueryFormat.tsv(
                            [sessionRawRow(session)],
                            header: parsed.flags["header"] != nil ? sessionColumns : nil))
                    }
                    let line = sessionSummaryLine(session)
                    return ok(withStaleSuffix(line, digest: digest))
                }
                return sessionField(field, session: session, json: json, unix: parsed.flags["unix"] != nil)
            }
        }
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

    private static func sessionSummaryLine(_ session: SessionCard) -> String {
        var parts = [session.title]
        let place = [session.project, session.branch].compactMap { $0 }.joined(separator: " ")
        if !place.isEmpty { parts.append(place) }
        parts.append("\(TokenFormat.compact(session.tokens)) tokens")
        parts.append(DigestQueryFormat.humanMoney(session.cost))
        return parts.joined(separator: " · ")
    }

    private static func sessionField(_ field: String, session: SessionCard, json: Bool, unix: Bool) -> QueryOutput {
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
        default:
            return badQuery("session has no field '\(field)' in the shortlist — deep fields (end/kind/tool-calls/…) need --all (M2)")
        }
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
