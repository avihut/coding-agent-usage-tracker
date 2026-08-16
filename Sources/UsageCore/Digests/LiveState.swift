import Foundation

/// The live-state digest — the engine's whole renderable state, written to
/// `live-state.json` after every landing point (fetch, scan, prediction
/// pass, pricing refresh). Consumer interfaces render it and compute
/// nothing: the Rust TUI reads ONLY this file; the menu bar app will read
/// it too when a daemon hosts the engine. docs/DAEMON.md is the design —
/// its draft spec §10 amendment is NOT in force until the daemon ships.
///
/// SyncDigest discipline applies: the schema evolves additively forever
/// (new fields only — never remove, rename, or retype), readers tolerate
/// unknown fields, and the golden fixtures in
/// Tests/UsageCoreTests/Fixtures/digest/ pin the encoded shape. The TUI's
/// serde contract tests decode the SAME fixture files, so cross-language
/// drift fails a test instead of a render. The freeze anchors at the first
/// external consumer (the TUI, v0.67.0) — until it lands, pre-consumer
/// reshaping is allowed with a deliberate golden regen; after it, never.
///
/// Absent ≠ zero, throughout: an unpriced cost is nil and an unreported
/// percent is nil — never 0. Readers mirror these as options; encoding a 0
/// where data is absent is a schema bug.
public struct LiveState: Codable, Sendable, Equatable {
    /// Bump ONLY additively. Readers must tolerate any version ≥ theirs by
    /// ignoring unknown fields.
    public static let schemaVersion = 1
    public static let fileName = "live-state.json"

    public let schemaVersion: Int
    public let engine: EngineStatus
    public let meters: [LiveMeter]
    /// The menu bar triple (S/W/scoped) — doubles as `usage-tui --status`
    /// input, colors resolved.
    public let menuBar: [SegmentStatus]
    /// Today's models, heaviest first — the dashboard's model rows.
    public let models: [ModelRow]
    public let activity: ActivityRollup

    public init(
        engine: EngineStatus, meters: [LiveMeter], menuBar: [SegmentStatus],
        models: [ModelRow], activity: ActivityRollup
    ) {
        self.schemaVersion = Self.schemaVersion
        self.engine = engine
        self.meters = meters
        self.menuBar = menuBar
        self.models = models
        self.activity = activity
    }

    /// `<App Support>/<bundleID>/live-state.json` — the bundle root, above
    /// the provider scopes: one engine, one file, whichever provider it
    /// currently meters.
    public static func fileURL(bundleID: String) -> URL {
        StorageScope.rootSupportDirectory(bundleID: bundleID).appending(path: fileName)
    }

    /// The pinned wire settings. sortedKeys makes rewrites byte-stable when
    /// nothing changed but the heartbeat; pretty printing keeps the file
    /// jq-able and diff-able for free.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Who is publishing and where the engine stands: identity, freshness,
/// scheduling, backoff, and the API budget gauge.
public struct EngineStatus: Codable, Sendable, Equatable {
    public let providerID: String
    public let serviceName: String
    public let agentName: String
    public let glyph: String
    public let accent: RGBColor
    /// The host Mac's control accent (dark-appearance sRGB), so terminal
    /// clients can tint normal-state fills the way the app's own controls
    /// are tinted. Nil from engines that predate the field — readers fall
    /// back to the provider accent.
    public let systemAccent: RGBColor?
    public let planLabel: String?
    /// The label's raw credential facts, so a client-mode app can rebuild
    /// PlanInfo verbatim. Same privacy standing as the label itself.
    public let planSubscriptionType: String?
    public let planRateLimitTier: String?
    public let appVersion: String
    public let pid: Int
    /// "app" | "daemon" — which host kind runs the engine.
    public let host: String
    public let generatedAt: Date
    public let fetchedAt: Date?
    public let nextPollAt: Date?
    public let backoffUntil: Date?
    /// True when what's rendered isn't fresh (cache-served or errored).
    public let stale: Bool
    /// Local-files provider: no network, no budget gauge; a manual refresh
    /// is a disk rescan.
    public let isLocalProvider: Bool
    /// The user's chosen active pace and the cadence's current decay
    /// multiplier (1 at pace, 2/4/8 as quiet decays it).
    public let activeIntervalSeconds: TimeInterval
    public let paceMultiplier: Int
    /// Nil for local providers — absent, not zero.
    public let apiBudgetUsed: Int?
    public let apiBudgetCeiling: Int?
    public let apiBudgetFraction: Double?
    public let gateFloorSeconds: TimeInterval
    public let error: ErrorStatus?
    /// The panel footer's enabled-credits line, when the provider sent one.
    public let spend: SpendStatus?

    public init(
        providerID: String, serviceName: String, agentName: String, glyph: String,
        accent: RGBColor, systemAccent: RGBColor? = nil, planLabel: String?,
        planSubscriptionType: String?,
        planRateLimitTier: String?, appVersion: String, pid: Int,
        host: String, generatedAt: Date, fetchedAt: Date?, nextPollAt: Date?,
        backoffUntil: Date?, stale: Bool, isLocalProvider: Bool,
        activeIntervalSeconds: TimeInterval, paceMultiplier: Int,
        apiBudgetUsed: Int?, apiBudgetCeiling: Int?, apiBudgetFraction: Double?,
        gateFloorSeconds: TimeInterval, error: ErrorStatus?, spend: SpendStatus?
    ) {
        self.providerID = providerID
        self.serviceName = serviceName
        self.agentName = agentName
        self.glyph = glyph
        self.accent = accent
        self.systemAccent = systemAccent
        self.planLabel = planLabel
        self.planSubscriptionType = planSubscriptionType
        self.planRateLimitTier = planRateLimitTier
        self.appVersion = appVersion
        self.pid = pid
        self.host = host
        self.generatedAt = generatedAt
        self.fetchedAt = fetchedAt
        self.nextPollAt = nextPollAt
        self.backoffUntil = backoffUntil
        self.stale = stale
        self.isLocalProvider = isLocalProvider
        self.activeIntervalSeconds = activeIntervalSeconds
        self.paceMultiplier = paceMultiplier
        self.apiBudgetUsed = apiBudgetUsed
        self.apiBudgetCeiling = apiBudgetCeiling
        self.apiBudgetFraction = apiBudgetFraction
        self.gateFloorSeconds = gateFloorSeconds
        self.error = error
        self.spend = spend
    }
}

/// Mirror of SpendLine — minor units + currency, formatting stays with the
/// reader.
public struct SpendStatus: Codable, Sendable, Equatable {
    public let usedMinor: Int
    public let limitMinor: Int?
    public let currency: String
    public let exponent: Int

    public init(usedMinor: Int, limitMinor: Int?, currency: String, exponent: Int) {
        self.usedMinor = usedMinor
        self.limitMinor = limitMinor
        self.currency = currency
        self.exponent = exponent
    }
}

/// A user-facing failure, pre-phrased by the engine's error taxonomy. The
/// `code` carries the taxonomy case name so a client-mode app can rebuild
/// the typed error; readers that only render use `text` + `hint`.
public struct ErrorStatus: Codable, Sendable, Equatable {
    public let text: String
    public let hint: String?
    public let code: String
    /// Set only for code "http".
    public let httpStatus: Int?

    public init(text: String, hint: String?, code: String, httpStatus: Int?) {
        self.text = text
        self.hint = hint
        self.code = code
        self.httpStatus = httpStatus
    }
}

/// One point on a percent-over-time line — sampled history and projected
/// trajectory share this shape.
public struct SeriesPoint: Codable, Sendable, Equatable {
    public let t: Date
    public let percent: Double

    public init(t: Date, percent: Double) {
        self.t = t
        self.percent = percent
    }
}

/// One grace-stitched activity stretch inside a meter's window.
public struct Stretch: Codable, Sendable, Equatable {
    public let start: Date
    public let end: Date
    /// Past the exhaustion crossing — the unreachable tail, rendered dead.
    public let exhausted: Bool

    public init(start: Date, end: Date, exhausted: Bool) {
        self.start = start
        self.end = end
        self.exhausted = exhausted
    }
}

/// The forecast mirror: what the prediction engine concluded, pre-phrased,
/// plus the working figures the settings pane surfaces — enough for a
/// client-mode app to rebuild the UsagePrediction verbatim.
public struct MeterForecast: Codable, Sendable, Equatable {
    public let projectedAtReset: Int?
    public let exhaustsAt: Date?
    /// "green" | "yellow" | "red".
    public let verdict: String
    /// The raw (pre-hysteresis) verdict — "pending flip" displays need it.
    public let rawVerdict: String
    /// The exhaustion-risk scale, 0…1.
    public let severity: Double
    public let ratePerHour: Double
    public let baselineRatePerHour: Double?
    public let paceFactor: Double?
    /// "recentOnly" | "windowAverage" | "weeklyProfile".
    public let basis: String
    /// "runs out in 1h 05m" — refreshed on every publish; nil while clean.
    public let caption: String?
    /// The dashed trajectory to the reset, ≤48 points.
    public let curve: [SeriesPoint]

    public init(
        projectedAtReset: Int?, exhaustsAt: Date?, verdict: String,
        rawVerdict: String, severity: Double, ratePerHour: Double,
        baselineRatePerHour: Double?, paceFactor: Double?, basis: String,
        caption: String?, curve: [SeriesPoint]
    ) {
        self.projectedAtReset = projectedAtReset
        self.exhaustsAt = exhaustsAt
        self.verdict = verdict
        self.rawVerdict = rawVerdict
        self.severity = severity
        self.ratePerHour = ratePerHour
        self.baselineRatePerHour = baselineRatePerHour
        self.paceFactor = paceFactor
        self.basis = basis
        self.caption = caption
        self.curve = curve
    }
}

/// One meter, render-ready: identity, level, resolved risk color, captions,
/// forecast, and the window-scoped chart data.
public struct LiveMeter: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// The menu-bar-style one-letter tag (S, W, or the model's initial).
    public let tag: String
    public let percent: Int?
    /// "normal" | "warning" | "critical".
    public let level: String
    /// Normalized rank semantics (0 session-style, 1 overall, 2 scoped) —
    /// with rateWindow and forcesWarning, a client can rebuild the Meter.
    public let rank: Int
    public let rateWindowSeconds: TimeInterval
    public let forcesWarning: Bool
    /// Resolved through RiskRamp; nil while the forecast is clean.
    public let risk: RGBColor?
    public let resetsAt: Date?
    public let limitWindow: TimeInterval?
    public let scopedModelName: String?
    /// "resets in 3h 20m" — refreshed on every publish.
    public let resetCaption: String?
    public let forecast: MeterForecast?
    /// The window-scoped percent line (≤120 points): in-window samples
    /// entering at height, hold-then-fall pairs at reset cliffs.
    public let series: [SeriesPoint]
    public let stretches: [Stretch]

    public init(
        id: String, label: String, tag: String, percent: Int?, level: String,
        rank: Int, rateWindowSeconds: TimeInterval, forcesWarning: Bool,
        risk: RGBColor?, resetsAt: Date?, limitWindow: TimeInterval?,
        scopedModelName: String?, resetCaption: String?, forecast: MeterForecast?,
        series: [SeriesPoint], stretches: [Stretch]
    ) {
        self.id = id
        self.label = label
        self.tag = tag
        self.percent = percent
        self.level = level
        self.rank = rank
        self.rateWindowSeconds = rateWindowSeconds
        self.forcesWarning = forcesWarning
        self.risk = risk
        self.resetsAt = resetsAt
        self.limitWindow = limitWindow
        self.scopedModelName = scopedModelName
        self.resetCaption = resetCaption
        self.forecast = forecast
        self.series = series
        self.stretches = stretches
    }
}

/// One menu bar segment with its color resolved — the status-line's input.
public struct SegmentStatus: Codable, Sendable, Equatable {
    public let tag: String
    public let percent: Int?
    /// "normal" | "warning" | "critical".
    public let level: String
    public let severity: Double?
    public let risk: RGBColor?

    public init(tag: String, percent: Int?, level: String, severity: Double?, risk: RGBColor?) {
        self.tag = tag
        self.percent = percent
        self.level = level
        self.severity = severity
        self.risk = risk
    }
}

/// One model's row: identity, its ledger color, tallies, and priced cost.
public struct ModelRow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let color: RGBColor
    public let tally: TokenTally
    /// Nil = unpriced (no rates for this model) — absent, never 0.
    public let cost: Double?

    public init(id: String, displayName: String, color: RGBColor, tally: TokenTally, cost: Double?) {
        self.id = id
        self.displayName = displayName
        self.color = color
        self.tally = tally
        self.cost = cost
    }
}

/// One local-calendar hour's usage.
public struct HourBucket: Codable, Sendable, Equatable {
    /// 0–23 in the publisher's calendar.
    public let hour: Int
    public let tokens: Int
    /// Nil when nothing in the hour was priceable.
    public let cost: Double?

    public init(hour: Int, tokens: Int, cost: Double?) {
        self.hour = hour
        self.tokens = tokens
        self.cost = cost
    }
}

/// One day's totals — the heatmap cell, portable.
public struct DayRollup: Codable, Sendable, Equatable {
    /// "yyyy-MM-dd" in the publisher's calendar.
    public let dayKey: String
    public let tokens: Int
    public let prompts: Int
    /// Nil when nothing that day was priceable.
    public let cost: Double?

    public init(dayKey: String, tokens: Int, prompts: Int, cost: Double?) {
        self.dayKey = dayKey
        self.tokens = tokens
        self.prompts = prompts
        self.cost = cost
    }
}

/// One day's per-model tallies — the day drill's table.
public struct ModelDayRollup: Codable, Sendable, Equatable {
    public let dayKey: String
    /// Heaviest first.
    public let models: [ModelRow]

    public init(dayKey: String, models: [ModelRow]) {
        self.dayKey = dayKey
        self.models = models
    }
}

/// One day's hourly buckets — bars for recent drills.
public struct DayHours: Codable, Sendable, Equatable {
    public let dayKey: String
    /// Non-empty hours only, ascending.
    public let hours: [HourBucket]

    public init(dayKey: String, hours: [HourBucket]) {
        self.dayKey = dayKey
        self.hours = hours
    }
}

/// The activity section: today in hours, the trailing year in days, recent
/// days per model and per hour. Horizons are the app's own retention facts —
/// beyond each, drills degrade to what exists, labeled.
public struct ActivityRollup: Codable, Sendable, Equatable {
    /// The publisher's calendar time zone — day keys and hours are local.
    public let timeZone: String
    /// Today's non-empty hours, ascending.
    public let todayHours: [HourBucket]
    public let todayTokens: Int
    public let todayPrompts: Int
    /// Nil when nothing today was priceable.
    public let todayCost: Double?
    /// Trailing ~12 months, ascending dayKey.
    public let days: [DayRollup]
    /// Per-model day tallies for the trailing ~35 days (the 30D drill
    /// horizon), ascending dayKey.
    public let modelDays: [ModelDayRollup]
    /// Hourly buckets for days inside timeline retention (~8 days),
    /// ascending dayKey.
    public let hourDays: [DayHours]

    public init(
        timeZone: String, todayHours: [HourBucket], todayTokens: Int,
        todayPrompts: Int, todayCost: Double?, days: [DayRollup],
        modelDays: [ModelDayRollup], hourDays: [DayHours]
    ) {
        self.timeZone = timeZone
        self.todayHours = todayHours
        self.todayTokens = todayTokens
        self.todayPrompts = todayPrompts
        self.todayCost = todayCost
        self.days = days
        self.modelDays = modelDays
        self.hourDays = hourDays
    }
}

/// Pure engine-state → digest mapping. No IO, no clocks of its own — the
/// publisher supplies `now`; tests supply everything.
public enum LiveStateBuilder {
    /// How far back each activity horizon reaches.
    public static let daysHorizon: TimeInterval = 366 * 86400
    public static let modelDaysHorizon: TimeInterval = 35 * 86400
    public static let seriesCap = 120
    public static let curveCap = 48

    public static func build(
        provider: any UsageProvider,
        host: String,
        pid: Int,
        appVersion: String,
        state: DisplayState,
        predictions: [String: UsagePrediction],
        samples: [UsageSample],
        timeline: [TokenSlot],
        activity: [DailyActivity],
        pricing: PricingTable,
        colorLedger: ModelColorLedger,
        graceSeconds: TimeInterval,
        activeInterval: TimeInterval,
        paceMultiplier: Int,
        nextPollAt: Date?,
        backoffUntil: Date?,
        apiBudget: (used: Int, ceiling: Int, fraction: Double)?,
        systemAccent: RGBColor? = nil,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> LiveState {
        let snapshot = state.snapshot
        let accent = RGBColor(provider.accent)
        let catalog = provider.modelCatalog

        func modelRow(_ id: String, tally: TokenTally) -> ModelRow {
            let family = catalog.familyName(id)
            let slots = colorLedger.slots(for: id, family: family) ?? (hue: 0, shade: 0)
            let rates = pricing.rates(for: id)
            return ModelRow(
                id: id,
                displayName: catalog.displayName(id),
                color: ModelColorMath.rgb(
                    hueSlot: slots.hue, shadeSlot: slots.shade, accent: accent),
                tally: tally,
                cost: rates.map { $0.dollars(for: tally) })
        }

        func rows(_ models: [String: TokenTally]) -> [ModelRow] {
            models.map { modelRow($0.key, tally: $0.value) }
                .sorted {
                    $0.tally.total != $1.tally.total
                        ? $0.tally.total > $1.tally.total : $0.id < $1.id
                }
        }

        let engine = EngineStatus(
            providerID: provider.id,
            serviceName: provider.serviceName,
            agentName: provider.agentName,
            glyph: provider.menuBarGlyph,
            accent: accent,
            systemAccent: systemAccent,
            planLabel: snapshot?.plan?.displayLabel,
            planSubscriptionType: snapshot?.plan?.subscriptionType,
            planRateLimitTier: snapshot?.plan?.rateLimitTier,
            appVersion: appVersion,
            pid: pid,
            host: host,
            generatedAt: now,
            fetchedAt: snapshot?.fetchedAt,
            nextPollAt: nextPollAt,
            backoffUntil: backoffUntil,
            stale: state.isStale,
            isLocalProvider: provider.networkDestinations.isEmpty,
            activeIntervalSeconds: activeInterval,
            paceMultiplier: paceMultiplier,
            apiBudgetUsed: apiBudget?.used,
            apiBudgetCeiling: apiBudget?.ceiling,
            apiBudgetFraction: apiBudget?.fraction,
            gateFloorSeconds: TriggerGate.floor,
            error: state.error.map {
                let code = errorCode($0)
                return ErrorStatus(
                    text: $0.shortText(agent: provider.agentName),
                    hint: $0.hint(agent: provider.agentName),
                    code: code.name, httpStatus: code.httpStatus)
            },
            spend: snapshot?.spendLine.map {
                SpendStatus(
                    usedMinor: $0.usedMinor, limitMinor: $0.limitMinor,
                    currency: $0.currency, exponent: $0.exponent)
            })

        let meters = (snapshot?.meters ?? []).map { meter in
            liveMeter(
                meter, prediction: predictions[meter.label], samples: samples,
                timeline: timeline, catalog: catalog, graceSeconds: graceSeconds,
                now: now, timeZone: calendar.timeZone, locale: locale)
        }

        let segments = snapshot.map {
            UsageFormatting.menuBarSegments(from: $0.meters, predictions: predictions)
        } ?? []
        let menuBar = segments.map {
            SegmentStatus(
                tag: $0.tag, percent: $0.percent, level: levelName($0.level),
                severity: $0.severity,
                risk: $0.severity.flatMap { RiskRamp.color(severity: $0) })
        }

        let today = calendar.startOfDay(for: now)
        let todayEntry = activity.first { calendar.startOfDay(for: $0.day) == today }
        let models = rows(todayEntry?.models ?? [:])

        let dayKey = dayKeyFormatter(calendar: calendar)
        let daysFloor = now.addingTimeInterval(-Self.daysHorizon)
        let days = activity
            .filter { $0.day >= daysFloor }
            .map { day in
                let priced = day.models.compactMap { id, tally in
                    pricing.rates(for: id).map { $0.dollars(for: tally) }
                }
                return DayRollup(
                    dayKey: dayKey.string(from: day.day),
                    tokens: day.tokens,
                    prompts: day.prompts,
                    cost: priced.isEmpty ? nil : priced.reduce(0, +))
            }
            .sorted { $0.dayKey < $1.dayKey }

        let modelDaysFloor = now.addingTimeInterval(-Self.modelDaysHorizon)
        let modelDays = activity
            .filter { $0.day >= modelDaysFloor && !$0.models.isEmpty }
            .map { ModelDayRollup(dayKey: dayKey.string(from: $0.day), models: rows($0.models)) }
            .sorted { $0.dayKey < $1.dayKey }

        let hourDays = Self.hourDays(
            timeline: timeline, pricing: pricing, calendar: calendar, dayKey: dayKey)
        let todayHours = hourDays.last?.dayKey == dayKey.string(from: today)
            ? hourDays.last!.hours : []

        let activityRollup = ActivityRollup(
            timeZone: calendar.timeZone.identifier,
            todayHours: todayHours,
            todayTokens: todayEntry?.tokens ?? 0,
            todayPrompts: todayEntry?.prompts ?? 0,
            todayCost: todayEntry.flatMap { entry in
                let priced = entry.models.compactMap { id, tally in
                    pricing.rates(for: id).map { $0.dollars(for: tally) }
                }
                return priced.isEmpty ? nil : priced.reduce(0, +)
            },
            days: days,
            modelDays: modelDays,
            hourDays: hourDays)

        return LiveState(
            engine: engine, meters: meters, menuBar: menuBar, models: models,
            activity: activityRollup)
    }

    // MARK: - Meters

    private static func liveMeter(
        _ meter: Meter, prediction: UsagePrediction?, samples: [UsageSample],
        timeline: [TokenSlot], catalog: ModelCatalog, graceSeconds: TimeInterval,
        now: Date, timeZone: TimeZone, locale: Locale
    ) -> LiveMeter {
        // The popover's Window span when the meter knows its bounds, a
        // trailing span otherwise.
        let domain: DateInterval
        if let resetsAt = meter.resetsAt, let window = meter.limitWindow, resetsAt > now {
            domain = DateInterval(start: resetsAt.addingTimeInterval(-window), end: resetsAt)
        } else {
            let span = meter.limitWindow ?? 24 * 3600
            domain = DateInterval(start: now.addingTimeInterval(-span), end: now)
        }

        let audit = AuditWindow.build(
            domain: domain, meterLabel: meter.label,
            window: meter.limitWindow ?? 24 * 3600,
            samples: samples, sessions: [], outcomes: [], now: now)
        let series = thin(
            audit.percent.map { SeriesPoint(t: $0.t, percent: Double($0.percent)) },
            to: Self.seriesCap)

        let forecast = prediction.map { prediction in
            MeterForecast(
                projectedAtReset: prediction.projectedAtReset,
                exhaustsAt: prediction.exhaustsAt,
                verdict: verdictName(prediction.verdict),
                rawVerdict: verdictName(prediction.rawVerdict),
                severity: prediction.severity,
                ratePerHour: prediction.ratePerHour,
                baselineRatePerHour: prediction.baselineRatePerHour,
                paceFactor: prediction.paceFactor,
                basis: basisName(prediction.basis),
                caption: UsageFormatting.forecastCaption(
                    percent: meter.percent, exhaustsAt: prediction.exhaustsAt,
                    now: now, timeZone: timeZone, locale: locale),
                curve: thin(
                    prediction.curve.map { SeriesPoint(t: $0.t, percent: $0.percent) },
                    to: Self.curveCap))
        }

        return LiveMeter(
            id: meter.id,
            label: meter.label,
            tag: tag(for: meter),
            percent: meter.percent,
            level: levelName(meter.level),
            rank: meter.rank,
            rateWindowSeconds: meter.rateWindow,
            forcesWarning: meter.forcesWarning,
            risk: RiskRamp.color(severity: prediction?.severity ?? 0),
            resetsAt: meter.resetsAt,
            limitWindow: meter.limitWindow,
            scopedModelName: meter.scopedModelName,
            resetCaption: meter.resetsAt.map {
                UsageFormatting.resetText($0, now: now, timeZone: timeZone, locale: locale)
            },
            forecast: forecast,
            series: series,
            stretches: stretches(
                in: domain, meter: meter, timeline: timeline, catalog: catalog,
                graceSeconds: graceSeconds, exhaustsAt: prediction?.exhaustsAt, now: now))
    }

    /// The strip under the popover chart: minute slots (scoped meters keep
    /// only their own model's) coalesced into runs, idle gaps within the
    /// grace stitched shut, the tail past an already-crossed exhaustion
    /// flagged unreachable.
    private static func stretches(
        in domain: DateInterval, meter: Meter, timeline: [TokenSlot],
        catalog: ModelCatalog, graceSeconds: TimeInterval, exhaustsAt: Date?,
        now: Date
    ) -> [Stretch] {
        let needle = meter.scopedModelName?.lowercased()
        let times = Set(
            timeline
                .filter { slot in
                    guard domain.contains(slot.t) else { return false }
                    guard let needle else { return true }
                    return catalog.displayName(slot.model).lowercased().contains(needle)
                }
                .map(\.t)
        ).sorted()
        guard !times.isEmpty else { return [] }

        var runs: [DateInterval] = []
        var runStart = times[0]
        var runEnd = times[0].addingTimeInterval(60)
        for t in times.dropFirst() {
            if t <= runEnd {
                runEnd = t.addingTimeInterval(60)
            } else {
                runs.append(DateInterval(start: runStart, end: runEnd))
                runStart = t
                runEnd = t.addingTimeInterval(60)
            }
        }
        runs.append(DateInterval(start: runStart, end: runEnd))

        let stitched = ActivityGrace.stitch(runs, grace: graceSeconds)
        guard let exhaustsAt, exhaustsAt <= now else {
            return stitched.map { Stretch(start: $0.start, end: $0.end, exhausted: false) }
        }
        var flagged: [Stretch] = []
        for run in stitched {
            if run.end <= exhaustsAt {
                flagged.append(Stretch(start: run.start, end: run.end, exhausted: false))
            } else if run.start >= exhaustsAt {
                flagged.append(Stretch(start: run.start, end: run.end, exhausted: true))
            } else {
                flagged.append(Stretch(start: run.start, end: exhaustsAt, exhausted: false))
                flagged.append(Stretch(start: exhaustsAt, end: run.end, exhausted: true))
            }
        }
        return flagged
    }

    // MARK: - Activity

    private static func hourDays(
        timeline: [TokenSlot], pricing: PricingTable, calendar: Calendar,
        dayKey: DateFormatter
    ) -> [DayHours] {
        struct Bucket {
            var tokens = 0
            var pricedCost = 0.0
            var anyPriced = false
        }
        var buckets: [Date: [Int: Bucket]] = [:]
        for slot in timeline {
            let day = calendar.startOfDay(for: slot.t)
            let hour = calendar.component(.hour, from: slot.t)
            var bucket = buckets[day]?[hour] ?? Bucket()
            bucket.tokens += slot.tally.total
            if let rates = pricing.rates(for: slot.model) {
                bucket.pricedCost += rates.dollars(for: slot.tally)
                bucket.anyPriced = true
            }
            buckets[day, default: [:]][hour] = bucket
        }
        return buckets
            .map { day, hours in
                DayHours(
                    dayKey: dayKey.string(from: day),
                    hours: hours
                        .map { hour, bucket in
                            HourBucket(
                                hour: hour, tokens: bucket.tokens,
                                cost: bucket.anyPriced ? bucket.pricedCost : nil)
                        }
                        .sorted { $0.hour < $1.hour })
            }
            .sorted { $0.dayKey < $1.dayKey }
    }

    // MARK: - Shared vocabulary

    static func levelName(_ level: DisplayLevel) -> String {
        switch level {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }

    static func verdictName(_ verdict: UsagePrediction.Verdict) -> String {
        switch verdict {
        case .green: "green"
        case .yellow: "yellow"
        case .red: "red"
        }
    }

    static func basisName(_ basis: UsagePrediction.Basis) -> String {
        switch basis {
        case .recentOnly: "recentOnly"
        case .windowAverage: "windowAverage"
        case .weeklyProfile: "weeklyProfile"
        }
    }

    static func errorCode(_ error: UsageError) -> (name: String, httpStatus: Int?) {
        switch error {
        case .noCredentials: ("noCredentials", nil)
        case .keychainDenied: ("keychainDenied", nil)
        case .credentialsUnreadable: ("credentialsUnreadable", nil)
        case .signInExpired: ("signInExpired", nil)
        case .rateLimited: ("rateLimited", nil)
        case .http(let status): ("http", status)
        case .network: ("network", nil)
        case .schema: ("schema", nil)
        case .noLocalData: ("noLocalData", nil)
        }
    }

    /// Rank vocabulary as the menu bar speaks it: S, W, or the scoped
    /// model's initial.
    static func tag(for meter: Meter) -> String {
        switch meter.rank {
        case 0: "S"
        case 1: "W"
        default: UsageFormatting.scopedTag(for: meter)
        }
    }

    /// Every k-th point, endpoints kept — enough for a terminal cell grid.
    static func thin(_ points: [SeriesPoint], to cap: Int) -> [SeriesPoint] {
        guard points.count > cap, cap >= 2 else { return points }
        let stride = Double(points.count - 1) / Double(cap - 1)
        return (0..<cap).map { points[Int((Double($0) * stride).rounded())] }
    }

    static func dayKeyFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
