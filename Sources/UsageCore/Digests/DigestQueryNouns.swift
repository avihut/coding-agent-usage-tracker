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
///
/// Two nouns are NOT here: `sessions`/`session` live in
/// `DigestQuerySessions.swift`, the same split one seam further (they own a
/// third of this file and, alone among the nouns, answer from two sources).
extension DigestQuery {
    // MARK: - status

    static func runStatus(parsed: ParsedArgs, digest: LiveState, now: Date, json: Bool) -> QueryOutput {
        if parsed.flags["check"] != nil {
            return QueryOutput(stdout: "", exitCode: digest.engine.stale ? exitStale : exitOK)
        }
        let engine = digest.engine
        let unix = parsed.flags["unix"] != nil
        let relative = parsed.flags["relative"] != nil
        func resolve(_ field: String, asJSON: Bool) -> QueryOutput {
            statusField(field, digest: digest, now: now, json: asJSON, unix: unix, relative: relative)
        }
        if let output = multiFieldOutput(
            noun: "status", parsed: parsed, positionalField: parsed.positionals.first, json: json,
            header: parsed.flags["header"] != nil, resolve: resolve) {
            return output
        }
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
        return resolve(field, asJSON: json)
    }

    private static func statusField(
        _ field: String, digest: LiveState, now: Date, json: Bool, unix: Bool, relative: Bool
    ) -> QueryOutput {
        let engine = digest.engine
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
        case "sessions-cap":
            // The WRITER's cap, straight off the digest — never this build's
            // own `LiveStateBuilder.sessionsCap`, which would report the
            // reader's truncation rule for somebody else's list. Absent from
            // a digest published before 0.84.0, and honestly so: the answer
            // is unknown, not 8.
            return DigestQueryFormat.intField(digest.sessionsCap, json: json)
        case "generated": return DigestQueryFormat.dateField(engine.generatedAt, json: json, unix: unix, relative: false)
        case "fetched": return DigestQueryFormat.dateField(engine.fetchedAt, json: json, unix: unix, relative: false)
        case "age":
            // Since fetchedAt, not generatedAt — "how old is the DATA", the
            // freshness `--max-age` itself judges off generatedAt instead
            // (the digest's own publish time, not the upstream fetch).
            let age = engine.fetchedAt.map { now.timeIntervalSince($0) }
            return DigestQueryFormat.secondsField(age, json: json, relative: relative)
        case "next-poll": return DigestQueryFormat.dateField(engine.nextPollAt, json: json, unix: unix, relative: false)
        case "backoff": return DigestQueryFormat.dateField(engine.backoffUntil, json: json, unix: unix, relative: false)
        case "gate-floor": return DigestQueryFormat.secondsField(engine.gateFloorSeconds, json: json, relative: relative)
        case "stale": return DigestQueryFormat.boolField(engine.stale, json: json)
        case "local": return DigestQueryFormat.boolField(engine.isLocalProvider, json: json)
        case "pace": return DigestQueryFormat.secondsField(engine.activeIntervalSeconds, json: json, relative: relative)
        case "pace.multiplier": return DigestQueryFormat.intField(engine.paceMultiplier, json: json)
        case "error": return DigestQueryFormat.textField(engine.error?.text, json: json)
        case "error.code": return DigestQueryFormat.textField(engine.error?.code, json: json)
        case "error.hint": return DigestQueryFormat.textField(engine.error?.hint, json: json)
        case "error.http": return DigestQueryFormat.intField(engine.error?.httpStatus, json: json)
        case "accent": return DigestQueryFormat.textField(engine.accent.hexString, json: json)
        case "system-accent": return DigestQueryFormat.textField(engine.systemAccent?.hexString, json: json)
        case "forecast.ready": return DigestQueryFormat.boolField(engine.forecastProfile?.isReady, json: json)
        case "forecast.remaining":
            return DigestQueryFormat.secondsField(
                engine.forecastProfile?.remainingSeconds, json: json, relative: relative)
        case "forecast.caption": return DigestQueryFormat.textField(engine.forecastProfile?.caption, json: json)
        case "timezone": return DigestQueryFormat.textField(digest.activity.timeZone, json: json)
        default: return unknownField(noun: "status", field: field)
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
            func resolve(_ name: String, asJSON: Bool) -> QueryOutput {
                meterField(
                    name, meter: meter, now: now, json: asJSON,
                    unix: parsed.flags["unix"] != nil, relative: parsed.flags["relative"] != nil,
                    header: parsed.flags["header"] != nil)
            }
            if let output = multiFieldOutput(
                noun: "limit", parsed: parsed, positionalField: field, json: json,
                header: parsed.flags["header"] != nil, resolve: resolve) {
                return output
            }
            guard let field else {
                if json { return ok(DigestQueryFormat.jsonValue(meter)) }
                if parsed.flags["raw"] != nil {
                    let row = meterRawRow(meter, unix: parsed.flags["unix"] != nil)
                    return ok(DigestQueryFormat.tsv(
                        [row], header: parsed.flags["header"] != nil ? meterColumns : nil))
                }
                return ok(withStaleSuffix(meterSummaryLine(meter), digest: digest))
            }
            return resolve(field, asJSON: json)
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
            return DigestQueryFormat.secondsField(
                meter.resetsAt.map { $0.timeIntervalSince(now) }, json: json, relative: relative)
        case "caption": return DigestQueryFormat.textField(meter.resetCaption, json: json)
        case "window": return DigestQueryFormat.secondsField(meter.limitWindow, json: json, relative: relative)
        case "rate-window":
            return DigestQueryFormat.secondsField(meter.rateWindowSeconds, json: json, relative: relative)
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
            return DigestQueryFormat.secondsField(
                meter.forecast?.exhaustsAt.map { $0.timeIntervalSince(now) }, json: json, relative: relative)
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
        default: return unknownField(noun: "limit", field: field)
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
        func resolve(_ name: String, asJSON: Bool) -> QueryOutput {
            budgetField(name, engine: engine, json: asJSON)
        }
        if let output = multiFieldOutput(
            noun: "budget", parsed: parsed, positionalField: parsed.positionals.first, json: json,
            header: parsed.flags["header"] != nil, resolve: resolve) {
            return output
        }
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
        return resolve(field, asJSON: json)
    }

    private static func budgetField(_ field: String, engine: EngineStatus, json: Bool) -> QueryOutput {
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
        default: return unknownField(noun: "budget", field: field)
        }
    }

    // MARK: - spend

    static func runSpend(parsed: ParsedArgs, digest: LiveState, json: Bool) -> QueryOutput {
        guard parsed.positionals.count <= 1 else { return badQuery("too many arguments") }
        let spend = digest.engine.spend
        func resolve(_ name: String, asJSON: Bool) -> QueryOutput {
            spendField(name, spend: spend, json: asJSON)
        }
        if let output = multiFieldOutput(
            noun: "spend", parsed: parsed, positionalField: parsed.positionals.first, json: json,
            header: parsed.flags["header"] != nil, resolve: resolve) {
            return output
        }
        guard let field = parsed.positionals.first else {
            guard let spend else { return ok(json ? "null" : "") }
            if json { return ok(DigestQueryFormat.jsonValue(spend)) }
            if parsed.flags["raw"] != nil {
                return badQuery("raw needs a field — e.g. `spend used`")
            }
            let scale = pow(10.0, Double(spend.exponent))
            var line = UsageFormatting.money(Double(spend.usedMinor) / scale)
            if let limitMinor = spend.limitMinor {
                line += " of \(UsageFormatting.money(Double(limitMinor) / scale))"
            }
            line += " \(spend.currency)"
            return ok(withStaleSuffix(line, digest: digest))
        }
        return resolve(field, asJSON: json)
    }

    /// `spend` is optional here on purpose: no spend line for this provider
    /// is the same "entirely absent" shape `budget` uses for a local
    /// provider's missing gauge — a KNOWN field still resolves (absent
    /// value, exit 0); only an unrecognized name is a bad query. An earlier
    /// guard short-circuited every field to exit 19 instead, which made an
    /// absent VALUE indistinguishable from a typo.
    private static func spendField(_ field: String, spend: SpendStatus?, json: Bool) -> QueryOutput {
        var used: Double?
        var limit: Double?
        if let spend {
            let scale = pow(10.0, Double(spend.exponent))
            used = Double(spend.usedMinor) / scale
            limit = spend.limitMinor.map { Double($0) / scale }
        }
        switch field {
        case "used": return DigestQueryFormat.numberField(used, json: json)
        case "limit": return DigestQueryFormat.numberField(limit, json: json)
        case "left":
            return DigestQueryFormat.numberField(limit.flatMap { total in used.map { total - $0 } }, json: json)
        case "currency": return DigestQueryFormat.textField(spend?.currency, json: json)
        default: return unknownField(noun: "spend", field: field)
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
        let header = parsed.flags["header"] != nil
        func resolve(_ name: String, asJSON: Bool) -> QueryOutput {
            switch name {
            case "tokens": return DigestQueryFormat.intField(tokens, json: asJSON)
            case "prompts": return DigestQueryFormat.intField(prompts, json: asJSON)
            case "cost": return DigestQueryFormat.numberField(cost, json: asJSON)
            case "days":
                let matched = digest.activity.days.filter { $0.dayKey >= window.start && $0.dayKey <= window.end }
                return dayRollupOutput(matched, json: asJSON, raw: raw, header: header)
            case "hours":
                let matched = digest.activity.hourDays.filter { $0.dayKey >= window.start && $0.dayKey <= window.end }
                guard !matched.isEmpty else {
                    return noMatch("no hourly data for '\(rangeToken)' — beyond the ~8-day timeline retention")
                }
                return hourBucketOutput(matched, json: asJSON, raw: raw, header: header)
            case "models":
                let matched = digest.activity.modelDays.filter { $0.dayKey >= window.start && $0.dayKey <= window.end }
                guard !matched.isEmpty else {
                    return noMatch("no per-model data for '\(rangeToken)' — beyond the ~35-day model horizon")
                }
                return modelRowsOutput(aggregateModels(matched), json: asJSON, raw: raw, header: header)
            default: return unknownField(noun: "activity", field: name)
            }
        }
        if let output = multiFieldOutput(
            noun: "activity", parsed: parsed, positionalField: field, json: json, header: header,
            resolve: resolve) {
            return output
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
        return resolve(field, asJSON: json)
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
                let scopeTotal = models.reduce(0) { $0 + $1.tally.total }
                func resolve(_ name: String, asJSON: Bool) -> QueryOutput {
                    modelField(name, model: model, scopeTotal: scopeTotal, json: asJSON)
                }
                if let output = multiFieldOutput(
                    noun: "model", parsed: parsed, positionalField: field, json: json,
                    header: parsed.flags["header"] != nil, resolve: resolve) {
                    return output
                }
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
                return resolve(field, asJSON: json)
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
        default: return unknownField(noun: "model", field: field)
        }
    }
}
