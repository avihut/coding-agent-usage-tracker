import Foundation
import Testing

@testable import UsageCore

/// `DigestQuery` — the whole `usage-cli` query grammar — pinned against the
/// SAME golden fixture LiveStateTests and the Rust TUI decode
/// (Fixtures/digest/live-state-v1.json), loaded `#filePath`-relative exactly
/// as `LiveStateTests.golden()` does (NOT `Bundle.module`/`loadFixture`: the
/// digest goldens are a cross-suite, cross-language contract, not this
/// target's own resource bundle). `now` is pinned to the fixture's own
/// `engine.generatedAt` (2026-08-16T12:00:00Z) throughout, per the plan —
/// every "fetched N ago"/"next poll in N" line and every freshness check
/// below reads off that exact anchor, never `Date()`.
@Suite("DigestQuery")
struct DigestQueryTests {
    let golden: LiveState
    let goldenRaw: Data
    let now = DigestQueryTests.iso("2026-08-16T12:00:00Z")

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        goldenRaw = try Data(contentsOf: fixtureURL)
        golden = try LiveState.decoder().decode(LiveState.self, from: goldenRaw)
    }

    static func iso(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    /// Space-pads a table cell to an EXPLICIT width — used to build
    /// multi-column human-list expectations from named cell values instead
    /// of a hand-typed run of spaces, which is easy to miscount by one and
    /// then fails for the wrong reason.
    func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    /// The default call shape: golden digest/bytes, pinned now, no env.
    /// Individual tests override only what they're exercising (a custom
    /// `now` for `--max-age`, a custom `digest`/`rawDigest` for the
    /// engine-state variants the golden can't carry, `env` for NO_COLOR).
    func run(
        _ args: [String], digest: LiveState? = nil, rawDigest: Data? = nil,
        env: [String: String] = [:], now: Date? = nil
    ) -> QueryOutput {
        DigestQuery.run(
            arguments: args, digest: digest ?? golden, rawDigest: rawDigest ?? goldenRaw,
            environment: env, now: now ?? self.now)
    }
}

// MARK: - Every noun's no-field summary line

extension DigestQueryTests {
    @Test func statusSummaryLine() {
        // fetchedAt 11:58 vs pinned now 12:00 -> 2 min; nextPollAt 12:03 ->
        // 3 min; no error, not stale, on the golden fixture.
        let out = run(["status"])
        #expect(out.stdout == "Claude · Max plan · 1x · app pid 4242 · fetched 2 min ago · next poll in 3 min")
        #expect(out.exitCode == 0)
        #expect(out.note == nil)
    }

    @Test func limitsSummaryList() {
        let out = run(["limits"])
        #expect(out.stdout == "S · Session (5h) · 53% · resets in 2h\nW · Weekly (all) · —")
        #expect(out.exitCode == 0)
    }

    @Test func limitSingularSummaryAsymmetricSpacing() {
        // Deliberately DIFFERENT from the list row's " · " after the tag —
        // two literal spaces here. Do not "fix" this to match `limits`.
        let session = run(["limit", "session"])
        #expect(session.stdout == "S  Session (5h) · 53% · resets in 2h")
        let weekly = run(["limit", "weekly_all"])
        #expect(weekly.stdout == "W  Weekly (all) · —")
    }

    @Test func budgetSummaryLine() {
        let out = run(["budget"])
        #expect(out.stdout == "7 of 20 requests this hour (35%)")
        #expect(out.exitCode == 0)
    }

    @Test func spendAbsentOnGoldenIsEmptyNotAnError() {
        let out = run(["spend"])
        #expect(out.stdout == "")
        #expect(out.exitCode == 0)
        #expect(out.note == nil)
    }

    @Test func activitySummaryDefaultsToToday() {
        // todayTokens 535 (<1000, no K suffix), todayPrompts 2, todayCost
        // 0.004 -> the money formatter's own "<$0.01" rule, never $0.
        let out = run(["activity"])
        #expect(out.stdout == "today · 535 tokens · 2 prompts · <$0.01")
    }

    @Test func costSugarHasNoFieldSlot() {
        let out = run(["cost", "30d"])
        #expect(out.stdout == "$0.07")
        let raw = run(["cost", "30d", "--raw"])
        #expect(raw.stdout == "0.069")
    }

    @Test func modelsSummaryList() {
        let out = run(["models"])
        // Column widths built explicitly (13 = len("mystery-model"), 3 =
        // len("480")) rather than a hand-typed run of spaces — a miscounted
        // literal fails for the wrong reason.
        let row0 = [pad("Fable 5", 13), pad("480", 3), "<$0.01"].joined(separator: " · ")
        let row1 = [pad("mystery-model", 13), pad("55", 3), "—"].joined(separator: " · ")
        #expect(out.stdout == "\(row0)\n\(row1)")
    }

    @Test func modelSingularSummary() {
        let out = run(["model", "top"])
        #expect(out.stdout == "Fable 5 · 480 tokens · <$0.01")
    }

    @Test func sessionsSummaryList() {
        let out = run(["sessions"])
        let lines = out.stdout.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "09:00 · main main · $0.07 · 9.5K · 12❯ · Wire the digest's sessions section")
        // session-b has neither project nor branch, so its "place" cell is
        // an empty string — collapsed, not a dangling separator or a
        // fabricated placeholder. Column widths (9/5/4/3) built explicitly
        // from the two rows' own longest cells, not hand-counted spaces.
        let row1 = [
            pad("20:00", 5), pad("", 9), pad("—", 5), pad("0", 4), pad("1❯", 3), "A background run",
        ].joined(separator: " · ")
        #expect(lines[1] == row1)
    }

    @Test func sessionSingularSummary() {
        let out = run(["session", "latest"])
        #expect(
            out.stdout
                == "Wire the digest's sessions section · main main · 1 hr 30 min · 9.5K tokens · $0.07")
    }

    @Test func promptDefaultLine() {
        let out = run(["prompt"])
        let esc = "\u{1B}"
        let glyph = "\(esc)[38;2;217;119;87m✳︎\(esc)[0m"
        let percent = "\(esc)[38;2;255;156;29m53%\(esc)[0m"
        #expect(out.stdout == "\(glyph) S \(percent) W — M —")
    }
}

// MARK: - status: fields across registers, dates, absent discipline

extension DigestQueryTests {
    @Test func statusTextAndIntFields() {
        #expect(run(["status", "provider"]).stdout == "claude")
        #expect(run(["status", "provider", "--json"]).stdout == "\"claude\"")
        #expect(run(["status", "plan"]).stdout == "Max plan · 1x")
        #expect(run(["status", "plan.type"]).stdout == "max")
        #expect(run(["status", "pid"]).stdout == "4242")
        #expect(run(["status", "pid", "--json"]).stdout == "4242")
        #expect(run(["status", "host"]).stdout == "app")
        #expect(run(["status", "schema"]).stdout == "1")
        #expect(run(["status", "local"]).stdout == "false")
        #expect(run(["status", "local", "--json"]).stdout == "false")
        #expect(run(["status", "stale"]).stdout == "false")
        #expect(run(["status", "timezone"]).stdout == "GMT")
        #expect(run(["status", "accent"]).stdout == "#D97757")
        #expect(run(["status", "system-accent"]).stdout == "#007AFF")
        #expect(run(["status", "pace"]).stdout == "300")
        #expect(run(["status", "pace.multiplier"]).stdout == "1")
        #expect(run(["status", "gate-floor"]).stdout == "180")
    }

    @Test func statusErrorFieldsAbsentOnHealthyGolden() {
        #expect(run(["status", "error"]).stdout == "")
        #expect(run(["status", "error"]).exitCode == 0)
        #expect(run(["status", "error", "--json"]).stdout == "null")
        #expect(run(["status", "error.code"]).stdout == "")
        #expect(run(["status", "error.http"]).stdout == "")
        #expect(run(["status", "error.http", "--json"]).stdout == "null")
    }

    @Test func statusDateFieldsISOAndUnix() {
        let generated = run(["status", "generated"])
        #expect(generated.stdout == "2026-08-16T12:00:00Z")
        let generatedUnix = run(["status", "generated", "--unix"])
        #expect(generatedUnix.stdout == String(Int(now.timeIntervalSince1970)))
        let fetched = run(["status", "fetched"])
        #expect(fetched.stdout == "2026-08-16T11:58:00Z")
        let nextPoll = run(["status", "next-poll"])
        #expect(nextPoll.stdout == "2026-08-16T12:03:00Z")
        // backoffUntil is nil on the golden fixture — absent in every
        // register, --unix included (unix only changes a PRESENT date's
        // shape, never manufactures one).
        #expect(run(["status", "backoff"]).stdout == "")
        #expect(run(["status", "backoff", "--unix"]).stdout == "")
        #expect(run(["status", "backoff", "--json"]).stdout == "null")
        #expect(run(["status", "backoff", "--unix", "--json"]).stdout == "null")
    }

    /// `age` (fetchedAt-anchored) and `--max-age` (generatedAt-anchored) are
    /// two different freshness anchors by design. With `now` pinned to
    /// `generatedAt`, `age` is a nonzero 120s (fetchedAt sits 2 minutes
    /// earlier) while `--max-age`'s own internal comparison sees a 0s gap
    /// — pinning both in one test keeps a future "simplification" from
    /// silently unifying them.
    @Test func statusAgeAndMaxAgeReadDifferentAnchors() {
        let age = run(["status", "age"])
        #expect(age.stdout == "120")
        // generatedAt == now exactly -> age-vs-threshold is 0, always fresh
        // no matter how tight the bound.
        let guarded = run(["status", "--max-age", "0s"])
        #expect(guarded.exitCode == 0)
    }

    @Test func statusForecastFields() {
        #expect(run(["status", "forecast.ready"]).stdout == "false")
        #expect(run(["status", "forecast.remaining"]).stdout == "950400")
        #expect(
            run(["status", "forecast.caption"]).stdout
                == "Personalized forecast activates in 11 days — learning your weekly rhythm.")
    }

    @Test func statusUnknownFieldIsBadQuery() {
        let out = run(["status", "bogus"])
        #expect(out.stdout == "")
        #expect(out.exitCode == 19)
        #expect(out.note != nil)
    }

    @Test func statusCheckModeIsSilent() {
        let fresh = run(["status", "--check"])
        #expect(fresh.stdout == "")
        #expect(fresh.exitCode == 0)
        #expect(fresh.note == nil)
    }
}

// MARK: - limits / limit: registers, selectors, absent discipline, series

extension DigestQueryTests {
    @Test func limitsJSONIsDigestFieldNames() throws {
        // Lists' --json register uses the WIRE/digest vocabulary (camelCase
        // "resetsAt"), not the CLI's kebab-case field names — round-tripping
        // through the typed decoder is the least brittle way to pin that.
        let out = run(["limits", "--json"])
        #expect(out.stdout.contains("\"resetsAt\""))
        let data = try #require(out.stdout.data(using: .utf8))
        let decoded = try LiveState.decoder().decode([LiveMeter].self, from: data)
        #expect(decoded.count == 2)
    }

    @Test func limitsRawHeaderIsAlwaysFiveTabFields() {
        let out = run(["limits", "--raw", "--header"])
        let lines = out.stdout.components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[0] == "id\ttag\tpercent\tlevel\tresets_at")
        // Every row keeps its full column count, even with trailing empty
        // fields (weekly's percent AND resets_at both empty) — the raw
        // register never trims, unlike the human table().
        for line in lines {
            #expect(line.components(separatedBy: "\t").count == 5)
        }
        #expect(lines[2] == "weekly_all\tW\t\twarning\t")
    }

    @Test func limitsRawUnixResetsAt() {
        let out = run(["limits", "--raw", "--unix"])
        let sessionRow = out.stdout.components(separatedBy: "\n")[0]
        let expectedEpoch = String(Int(DigestQueryTests.iso("2026-08-16T14:00:00Z").timeIntervalSince1970))
        #expect(sessionRow.hasSuffix("\t\(expectedEpoch)"))
    }

    @Test func limitsTakesNoSelector() {
        let out = run(["limits", "session"])
        #expect(out.exitCode == 19)
    }

    // MARK: selectors

    @Test func meterSelectorByIdTagAndLabelSubstring() {
        #expect(run(["limit", "session", "tag"]).stdout == "S")
        #expect(run(["limit", "SESSION", "tag"]).stdout == "S")
        #expect(run(["limit", "s", "tag"]).stdout == "S")
        #expect(run(["limit", "S", "tag"]).stdout == "S")
        #expect(run(["limit", "week", "tag"]).stdout == "W")
        #expect(run(["limit", "weekly_all", "tag"]).stdout == "W")
    }

    @Test func meterSelectorWorstRanksSeverityStrictlyOverPercent() {
        // Only "session" carries a forecast (severity 0.4); "weekly_all"
        // has none at all (severity treated as -1) despite carrying no
        // percent to compare either. worst must resolve to session.
        #expect(run(["limit", "worst", "tag"]).stdout == "S")
    }

    @Test func meterSelectorNextPicksSoonestResetStamp() {
        // Only session publishes a resetsAt at all — `next` compares
        // resets-at stamps, not futureness (see `selectMeter`'s doc
        // comment); this fixture can't distinguish the two since its one
        // candidate happens to also be in the future.
        #expect(run(["limit", "next", "tag"]).stdout == "S")
    }

    @Test func meterSelectorAmbiguousExitsNineteenWithCandidates() throws {
        // Both labels contain "e" ("Session (5h)", "Weekly (all)").
        let out = run(["limit", "e"])
        #expect(out.stdout == "")
        #expect(out.exitCode == 19)
        let note = try #require(out.note)
        #expect(note.contains("session"))
        #expect(note.contains("weekly_all"))
    }

    @Test func meterSelectorNoMatchExitsTwenty() {
        let out = run(["limit", "nonexistent-meter"])
        #expect(out.stdout == "")
        #expect(out.exitCode == 20)
        #expect(out.note != nil)
    }

    // MARK: field registers

    @Test func meterFieldsHumanRawJSON() {
        #expect(run(["limit", "session", "percent"]).stdout == "53")
        #expect(run(["limit", "session", "percent", "--json"]).stdout == "53")
        #expect(run(["limit", "session", "left"]).stdout == "47")
        #expect(run(["limit", "session", "label"]).stdout == "Session (5h)")
        #expect(run(["limit", "session", "level"]).stdout == "normal")
        #expect(run(["limit", "session", "rank"]).stdout == "0")
        #expect(run(["limit", "session", "severity"]).stdout == "0.4")
        #expect(run(["limit", "session", "forecast.severity"]).stdout == "0.4")
        #expect(run(["limit", "session", "risk"]).stdout == "#FF9C1D")
        #expect(run(["limit", "session", "window"]).stdout == "18000")
        #expect(run(["limit", "session", "rate-window"]).stdout == "2700")
        #expect(run(["limit", "session", "forces-warning"]).stdout == "false")
        #expect(run(["limit", "session", "scoped-model"]).stdout == "")
        #expect(run(["limit", "session", "exhausted"]).stdout == "false")
        #expect(run(["limit", "session", "resets-in"]).stdout == "7200")
        #expect(run(["limit", "session", "forecast.projected"]).stdout == "78")
        #expect(run(["limit", "session", "forecast.verdict"]).stdout == "green")
        #expect(run(["limit", "session", "forecast.raw-verdict"]).stdout == "green")
        #expect(run(["limit", "session", "forecast.rate"]).stdout == "12")
        #expect(run(["limit", "session", "forecast.baseline"]).stdout == "6")
        #expect(run(["limit", "session", "forecast.pace"]).stdout == "1.5")
        #expect(run(["limit", "session", "forecast.basis"]).stdout == "windowAverage")
    }

    @Test func meterFieldUnknownIsBadQuery() {
        #expect(run(["limit", "session", "bogus"]).exitCode == 19)
    }

    @Test func meterTooManyArgumentsIsBadQuery() {
        #expect(run(["limit", "session", "percent", "extra"]).exitCode == 19)
    }

    // MARK: --relative (paired caption vs unpaired fallback)

    @Test func relativeSubstitutesOnlyAPairedCaption() {
        let paired = run(["limit", "session", "resets-at", "--relative"])
        #expect(paired.stdout == "resets in 2h")
        // weekly_all has no resetsAt at all -> still absent, not a
        // fabricated relative phrase.
        let unpaired = run(["limit", "weekly_all", "resets-at", "--relative"])
        #expect(unpaired.stdout == "")
        // status.generated has no paired caption anywhere in the grammar ->
        // --relative is a silent no-op, ISO stands.
        let noPairing = run(["status", "generated", "--relative"])
        #expect(noPairing.stdout == "2026-08-16T12:00:00Z")
        // --json ignores --relative even where a caption pairing exists —
        // a date field must stay a date shape for scripts.
        let jsonIgnoresRelative = run(["limit", "session", "resets-at", "--relative", "--json"])
        #expect(jsonIgnoresRelative.stdout == "\"2026-08-16T14:00:00Z\"")
    }

    // MARK: absent discipline (load-bearing)

    @Test func weeklyMeterPercentIsAbsentEverywhere() {
        let raw = run(["limit", "weekly_all", "percent"])
        #expect(raw.stdout == "")
        #expect(raw.exitCode == 0)
        let json = run(["limit", "weekly_all", "percent", "--json"])
        #expect(json.stdout == "null")
        // The human register (list row and singular summary) both print
        // the em dash, never a fabricated 0.
        #expect(run(["limits"]).stdout.contains("Weekly (all) · —"))
        #expect(run(["limit", "weekly_all"]).stdout.contains("· —"))
    }

    @Test func weeklyMeterHasNoForecastAtAllNotJustNoCaption() {
        #expect(run(["limit", "weekly_all", "forecast.severity"]).stdout == "")
        #expect(run(["limit", "weekly_all", "forecast.severity", "--json"]).stdout == "null")
        #expect(run(["limit", "weekly_all", "risk"]).stdout == "")
        #expect(run(["limit", "weekly_all", "resets-at"]).stdout == "")
        #expect(run(["limit", "weekly_all", "resets-in"]).stdout == "")
        #expect(run(["limit", "weekly_all", "resets-in", "--json"]).stdout == "null")
        #expect(run(["limit", "weekly_all", "caption"]).stdout == "")
        #expect(run(["limit", "weekly_all", "scoped-model"]).stdout == "")
        // No percent AND no forecast at all -> genuinely unknown, not a
        // fabricated false (weekly_all has neither input `exhausted` reads).
        #expect(run(["limit", "weekly_all", "exhausted"]).stdout == "")
        #expect(run(["limit", "weekly_all", "exhausted", "--json"]).stdout == "null")
    }

    /// The session meter HAS a forecast, but that forecast's own
    /// sub-fields are legitimately absent (no crossing observed) — a
    /// second, distinct absent shape from "the whole forecast is nil".
    @Test func sessionForecastSubFieldsCanBeAbsentEvenWhenForecastExists() {
        #expect(run(["limit", "session", "forecast.exhausts-at"]).stdout == "")
        #expect(run(["limit", "session", "forecast.exhausts-at", "--json"]).stdout == "null")
        #expect(run(["limit", "session", "forecast.exhausts-in"]).stdout == "")
        #expect(run(["limit", "session", "forecast.caption"]).stdout == "")
        #expect(run(["limit", "session", "forecast.caption", "--json"]).stdout == "null")
    }

    // MARK: series / curve / stretches / models — always TSV

    @Test func seriesIsAlwaysTSVRegardlessOfRawFlag() {
        let withoutRaw = run(["limit", "session", "series"])
        let withRaw = run(["limit", "session", "series", "--raw"])
        #expect(withoutRaw.stdout == withRaw.stdout)
        let rows = withoutRaw.stdout.components(separatedBy: "\n")
        #expect(rows.count == 5)
        #expect(rows[0] == "2026-08-16T09:30:00Z\t91")
        #expect(rows.last == "2026-08-16T11:58:00Z\t53")
    }

    @Test func emptySeriesIsEmptyTSVNotAnError() {
        let out = run(["limit", "weekly_all", "series"])
        #expect(out.stdout == "")
        #expect(out.exitCode == 0)
    }

    @Test func curveIsTheForecastTrajectory() {
        let out = run(["limit", "session", "curve", "--header"])
        let rows = out.stdout.components(separatedBy: "\n")
        #expect(rows[0] == "t\tpercent")
        #expect(rows[1] == "2026-08-16T12:00:00Z\t53")
        #expect(rows[2] == "2026-08-16T14:00:00Z\t78")
    }

    @Test func stretchesTSVWithHeader() {
        let out = run(["limit", "session", "stretches", "--header"])
        let rows = out.stdout.components(separatedBy: "\n")
        #expect(rows[0] == "start\tend\texhausted")
        #expect(rows[1] == "2026-08-16T10:00:00Z\t2026-08-16T10:02:00Z\tfalse")
        #expect(rows[2] == "2026-08-16T10:30:00Z\t2026-08-16T10:31:00Z\tfalse")
        #expect(rows[3] == "2026-08-16T11:30:00Z\t2026-08-16T11:31:00Z\tfalse")
    }

    @Test func modelSeriesReportsEachModelsFinalWindowShare() {
        // Hand-derived from the fixture, not from the implementation's own
        // output: the session window holds 528 Fable + 55 mystery tokens
        // (583 total) against the meter's 53% — 53×528/583 = 48 exactly,
        // 53×55/583 = 5.
        let out = run(["limit", "session", "models"])
        #expect(out.stdout == "Fable 5\t48\nmystery-model\t5")
        // The weekly meter's trailing 24h adds the 07:00 and 10:30 slots to
        // Fable (540 total): mystery = 100×55/540.
        let weekly = run(["limit", "weekly_all", "models"])
        #expect(weekly.stdout == "Fable 5\t100\nmystery-model\t10.185185185185185")
    }

    @Test func modelSeriesJSONCarriesFullCurves() throws {
        let out = run(["limit", "session", "models", "--json"])
        let data = try #require(out.stdout.data(using: .utf8))
        let decoded = try LiveState.decoder().decode([ModelSeries].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded.contains { $0.points.count > 2 })
    }
}

// MARK: - budget

extension DigestQueryTests {
    @Test func budgetFields() {
        #expect(run(["budget", "used"]).stdout == "7")
        #expect(run(["budget", "ceiling"]).stdout == "20")
        #expect(run(["budget", "left"]).stdout == "13")
        #expect(run(["budget", "fraction"]).stdout == "0.35")
        #expect(run(["budget", "fraction", "--json"]).stdout == "0.35")
    }

    @Test func budgetUnknownFieldIsBadQuery() {
        #expect(run(["budget", "bogus"]).exitCode == 19)
    }

    /// Fraction-shaped fields stay a bare 0...1 decimal in raw mode — never
    /// multiplied into a 0-100 int (only schema-native Int percent fields
    /// are bare ints).
    @Test func budgetFractionIsBareDecimalNotPercent() {
        #expect(run(["budget", "fraction"]).stdout == "0.35")
    }

    /// Entirely absent for a local/no-budget provider: empty output, exit
    /// 0, for the summary line AND every individual field — never a
    /// fabricated "0 of 0".
    @Test func budgetAbsentEntirelyOnLocalProviderFixture() {
        let engine = DigestQueryTests.minimalEngine(isLocalProvider: true)
        let state = DigestQueryTests.minimalState(engine: engine)
        #expect(run(["budget"], digest: state).stdout == "")
        #expect(run(["budget"], digest: state).exitCode == 0)
        #expect(run(["budget", "used"], digest: state).stdout == "")
        #expect(run(["budget", "used"], digest: state).exitCode == 0)
        #expect(run(["budget", "fraction"], digest: state).stdout == "")
        #expect(run(["budget", "fraction", "--json"], digest: state).stdout == "null")
    }
}

// MARK: - spend (golden lacks a spend block; custom fixtures fill the gap)

extension DigestQueryTests {
    @Test func spendAbsentFieldsResolveAbsentNotBadQuery() {
        // This is the fix: previously ANY named field on a spend-less
        // digest exited 19 (indistinguishable from a typo), contradicting
        // "an absent VALUE is still success" and budget's own precedent
        // for the identical shape of gap.
        let used = run(["spend", "used"])
        #expect(used.stdout == "")
        #expect(used.exitCode == 0)
        let json = run(["spend", "used", "--json"])
        #expect(json.stdout == "null")
        #expect(run(["spend", "limit"]).exitCode == 0)
        #expect(run(["spend", "left"]).exitCode == 0)
        #expect(run(["spend", "currency"]).stdout == "")
        #expect(run(["spend", "currency"]).exitCode == 0)
    }

    @Test func spendUnknownFieldIsStillBadQueryWhenAbsent() {
        // The fix must not blur "absent value" into "any field name goes" —
        // an unrecognized field name is still exit 19, spend present or not.
        let out = run(["spend", "bogus"])
        #expect(out.stdout == "")
        #expect(out.exitCode == 19)
    }

    @Test func spendPresentSummaryLineAndMinorUnitConversion() {
        let engine = DigestQueryTests.minimalEngine(
            spend: SpendStatus(usedMinor: 1250, limitMinor: 5000, currency: "USD", exponent: 2))
        let state = DigestQueryTests.minimalState(engine: engine)
        let line = run(["spend"], digest: state)
        #expect(line.stdout == "$12.50 of $50.00 USD")
        #expect(run(["spend", "used"], digest: state).stdout == "12.5")
        #expect(run(["spend", "limit"], digest: state).stdout == "50")
        #expect(run(["spend", "left"], digest: state).stdout == "37.5")
        #expect(run(["spend", "currency"], digest: state).stdout == "USD")
        #expect(run(["spend", "currency", "--json"], digest: state).stdout == "\"USD\"")
    }

    @Test func spendPresentWithNoLimitOmitsTheOfClause() {
        let engine = DigestQueryTests.minimalEngine(
            spend: SpendStatus(usedMinor: 900, limitMinor: nil, currency: "USD", exponent: 2))
        let state = DigestQueryTests.minimalState(engine: engine)
        let line = run(["spend"], digest: state)
        #expect(line.stdout == "$9.00 USD")
        #expect(run(["spend", "limit"], digest: state).stdout == "")
        #expect(run(["spend", "left"], digest: state).stdout == "")
    }

    @Test func spendUnknownFieldIsBadQueryWhenPresentToo() {
        let engine = DigestQueryTests.minimalEngine(
            spend: SpendStatus(usedMinor: 900, limitMinor: nil, currency: "USD", exponent: 2))
        let state = DigestQueryTests.minimalState(engine: engine)
        #expect(run(["spend", "bogus"], digest: state).exitCode == 19)
    }
}

// MARK: - activity / cost: ranges, sums, priced-days-only cost rule

extension DigestQueryTests {
    @Test func explicitDayKeyRangeReadsThatDayOnly() {
        // The fixture's own unpriced day: tokens 0, prompts 4, cost absent
        // — never $0.
        let out = run(["activity", "2026-08-14"])
        #expect(out.stdout == "2026-08-14 · 0 tokens · 4 prompts · —")
        #expect(run(["activity", "2026-08-14", "cost"]).stdout == "")
        #expect(run(["activity", "2026-08-14", "cost", "--json"]).stdout == "null")
        #expect(run(["activity", "2026-08-14", "tokens"]).stdout == "0")
        #expect(run(["activity", "2026-08-14", "prompts"]).stdout == "4")
    }

    @Test func yesterdayResolvesToThePriorCalendarDay() {
        // Pinned "now" is 2026-08-16 -> yesterday RESOLVES to the fixture's
        // priced 2026-08-15 window (cost 0.065), but the printed range
        // LABEL is the canonicalized token "yesterday" itself, not the
        // resolved date — label and resolution are deliberately separate.
        let out = run(["activity", "yesterday"])
        #expect(out.stdout == "yesterday · 9K tokens · 6 prompts · $0.07")
        #expect(run(["activity", "2026-08-15"]).stdout == "2026-08-15 · 9K tokens · 6 prompts · $0.07")
    }

    /// Every multi-day trailing/calendar range in this fixture spans the
    /// same 3 days (14/15/16), so they all agree on the sum — the
    /// assertion that matters is that each range LABEL is the canonicalized
    /// token, and the priced-only cost rule holds identically across all of
    /// them (0.065 + 0.004, day 14 excluded because unpriced, not summed
    /// as 0).
    @Test(arguments: ["7d", "30d", "month", "year", "all"])
    func trailingAndCalendarRangesSumTheSameThreeDays(range: String) {
        let out = run(["activity", range])
        #expect(out.stdout == "\(range) · 9.5K tokens · 12 prompts · $0.07")
        let rawCost = run(["cost", range, "--raw"])
        #expect(rawCost.stdout == "0.069")
    }

    @Test func costNeverCountsAnUnpricedDayAsZero() {
        // A range whose ONLY matching day is unpriced must stay absent —
        // never $0 — exactly like the single-day case above, restated at
        // the "range" level per the milestone's explicit requirement.
        #expect(run(["activity", "2026-08-14", "cost", "--raw"]).stdout == "")
    }

    @Test func costSugarRejectsATrailingField() {
        let out = run(["cost", "30d", "tokens"])
        #expect(out.exitCode == 19)
    }

    @Test func badRangeTokenIsBadQuery() {
        #expect(run(["activity", "not-a-range"]).exitCode == 19)
    }

    @Test func dayOutsideHorizonOrInTheFutureIsNoMatch() {
        // Both a too-old date and a future date are outside the digest's
        // valid horizon for an EXPLICIT single-day range — trailing/
        // calendar ranges never do this (they just sum to less).
        #expect(run(["activity", "2020-01-01"]).exitCode == 20)
        #expect(run(["activity", "2026-08-20"]).exitCode == 20)
    }

    @Test func activityDaysField() {
        let out = run(["activity", "7d", "days", "--raw", "--header"])
        let rows = out.stdout.components(separatedBy: "\n")
        #expect(rows[0] == "day\ttokens\tprompts\tcost")
        #expect(rows[1] == "2026-08-14\t0\t4\t")
        #expect(rows[2] == "2026-08-15\t9000\t6\t0.065")
        #expect(rows[3] == "2026-08-16\t535\t2\t0.004")
    }

    @Test func activityHoursFieldAndItsHorizonExit() {
        let today = run(["activity", "today", "hours", "--raw", "--header"])
        let rows = today.stdout.components(separatedBy: "\n")
        #expect(rows[0] == "hour\ttokens\tcost")
        #expect(rows[1] == "7\t12\t0.0001")
        #expect(rows[2] == "10\t528\t0.0044")
        #expect(rows[3] == "11\t55\t")
        // The fixture's hourDays only covers 2026-08-16 — yesterday has
        // none, which is a genuine "beyond retention" no-match, not zero.
        let yesterday = run(["activity", "yesterday", "hours"])
        #expect(yesterday.exitCode == 20)
    }

    @Test func activityModelsFieldAndItsHorizonExit() {
        let out = run(["activity", "7d", "models"])
        // Fable aggregated across both modeled days: 9480 tokens ("9.5K"),
        // cost 0.065+0.004 -> "$0.07". Column widths (13/4) explicit.
        let row0 = [pad("Fable 5", 13), pad("9.5K", 4), "$0.07"].joined(separator: " · ")
        let row1 = [pad("mystery-model", 13), pad("55", 4), "—"].joined(separator: " · ")
        #expect(out.stdout == "\(row0)\n\(row1)")
        // modelDays has no entry at all for 2026-08-14 (nothing modeled
        // that day) -> exit 20, distinct from "matched but zero".
        #expect(run(["activity", "2026-08-14", "models"]).exitCode == 20)
    }

    /// 2026-08-16T03:00:00Z is 2026-08-15 20:00 in America/Los_Angeles
    /// (PDT, UTC-7) — a `digestCalendar(digest)` -> `Calendar.current`
    /// regression would silently swap every day-key comparison below for
    /// whatever zone the test host happens to run in, instead of the
    /// digest's own published `activity.timeZone`.
    @Test func activityRangesResolveInTheDigestsOwnTimeZoneNotTheHosts() {
        // Pacific/Kiritimati sits at UTC+14 — ahead of every plausible
        // host zone, so a regression to Calendar.current fails on ANY
        // machine, not only on hosts whose zone happens to differ from
        // the fixture's.
        let kiritimatiNoon = DigestQueryTests.iso("2026-08-15T22:00:00Z")
        let engine = DigestQueryTests.minimalEngine(fetchedAt: nil, nextPollAt: nil)
        let state = DigestQueryTests.minimalState(
            engine: engine, timeZone: "Pacific/Kiritimati",
            days: [
                DayRollup(dayKey: "2026-08-09", tokens: 999, prompts: 9, cost: 9.99),
                DayRollup(dayKey: "2026-08-14", tokens: 111, prompts: 1, cost: 1.11),
                DayRollup(dayKey: "2026-08-15", tokens: 222, prompts: 2, cost: 2.22),
                DayRollup(dayKey: "2026-08-16", tokens: 333, prompts: 3, cost: 3.33),
            ],
            todayTokens: 333, todayPrompts: 3, todayCost: 3.33)

        // "today" reads the dedicated today* fields directly, never a
        // now-derived day key.
        #expect(run(["activity", "today", "tokens"], digest: state, now: kiritimatiNoon).stdout == "333")

        // Local noon on 2026-08-16 in Kiritimati is still 2026-08-15 in
        // UTC and every western zone: the digest's own yesterday is
        // 08-15 (222); a host-calendar regression reads 08-14 (111).
        #expect(run(["activity", "yesterday", "tokens"], digest: state, now: kiritimatiNoon).stdout == "222")
        #expect(run(["activity", "yesterday", "cost", "--raw"], digest: state, now: kiritimatiNoon).stdout == "2.22")

        // 7d by the digest's calendar spans 08-10...08-16 (111+222+333 =
        // 666); a host-calendar window spans 08-09...08-15 and answers
        // 1332 — wrong membership at BOTH edges.
        #expect(run(["activity", "7d", "tokens"], digest: state, now: kiritimatiNoon).stdout == "666")
    }
}

// MARK: - models / model: selectors, --day / --range rescoping

extension DigestQueryTests {
    @Test func modelsTakesNoSelector() {
        #expect(run(["models", "top"]).exitCode == 19)
    }

    @Test func modelSelectorByIdTopAndSubstring() {
        #expect(run(["model", "claude-fable-5", "id"]).stdout == "claude-fable-5")
        #expect(run(["model", "top", "id"]).stdout == "claude-fable-5")
        #expect(run(["model", "fable", "id"]).stdout == "claude-fable-5")
        #expect(run(["model", "MYSTERY", "id"]).stdout == "mystery-model")
    }

    @Test func modelSelectorAmbiguousAndNoMatch() {
        // Both display names contain "e".
        let ambiguous = run(["model", "e"])
        #expect(ambiguous.exitCode == 19)
        #expect(run(["model", "does-not-exist"]).exitCode == 20)
    }

    @Test func modelFieldsHumanRawJSON() {
        #expect(run(["model", "top", "name"]).stdout == "Fable 5")
        #expect(run(["model", "top", "color"]).stdout == "#D97757")
        #expect(run(["model", "top", "cost"]).stdout == "0.004")
        #expect(run(["model", "top", "tokens"]).stdout == "480")
        #expect(run(["model", "top", "tokens.input"]).stdout == "400")
        #expect(run(["model", "top", "tokens.output"]).stdout == "80")
        #expect(run(["model", "top", "tokens.cache-read"]).stdout == "0")
        #expect(run(["model", "top", "tokens.cache-write"]).stdout == "0")
        #expect(run(["model", "top", "tokens.cache-write-1h"]).stdout == "0")
        #expect(run(["model", "top", "tokens.uncached-input"]).stdout == "400")
        #expect(run(["model", "top", "tokens.input-side"]).stdout == "400")
        #expect(run(["model", "top", "tokens.cached-share"]).stdout == "0")
        // Today's scope total is 480 + 55 = 535.
        #expect(run(["model", "top", "share"]).stdout == DigestQueryFormat.jsonValue(480.0 / 535.0))
    }

    @Test func modelUnpricedCostIsAbsentNotZero() {
        #expect(run(["model", "mystery-model", "cost"]).stdout == "")
        #expect(run(["model", "mystery-model", "cost", "--json"]).stdout == "null")
        #expect(run(["models"]).stdout.contains("mystery-model · 55  · —"))
    }

    @Test func modelUnknownFieldIsBadQuery() {
        #expect(run(["model", "top", "bogus"]).exitCode == 19)
    }

    @Test func modelDayRescopeSelectsThatDaysModels() {
        // 2026-08-15 only modeled Fable (9000 tokens, cost 0.065) — a
        // different scope than "today"'s default.
        let out = run(["model", "top", "tokens", "--day", "2026-08-15"])
        #expect(out.stdout == "9000")
        #expect(run(["model", "top", "cost", "--day", "2026-08-15"]).stdout == "0.065")
    }

    @Test func modelDayRescopeNoMatchIsTwenty() {
        // 2026-08-14 exists in days[] but modeled nothing -> absent from
        // modelDays entirely, a real no-match rather than an empty list.
        #expect(run(["models", "--day", "2026-08-14"]).exitCode == 20)
    }

    @Test func modelRangeRescopeAggregatesAcrossDays() {
        let out = run(["models", "--range", "7d"])
        // Fable across both modeled days: (8000+400) in, (1000+80) out —
        // the SAME aggregate `activity 7d models` sums (shared
        // `aggregateModels` helper), so it must render byte-identical.
        let row0 = [pad("Fable 5", 13), pad("9.5K", 4), "$0.07"].joined(separator: " · ")
        let row1 = [pad("mystery-model", 13), pad("55", 4), "—"].joined(separator: " · ")
        #expect(out.stdout == "\(row0)\n\(row1)")
        #expect(out.stdout == run(["activity", "7d", "models"]).stdout)
        #expect(run(["model", "top", "tokens", "--range", "7d"]).stdout == "9480")
    }

    @Test func modelRangeRejectsAnythingButSevenOrThirtyDays() {
        #expect(run(["models", "--range", "14d"]).exitCode == 19)
        #expect(run(["models", "--range", "month"]).exitCode == 19)
    }
}

// MARK: - sessions / session: shortlist selectors, filters, raw columns

extension DigestQueryTests {
    @Test func sessionsTakesNoSelector() {
        #expect(run(["sessions", "latest"]).exitCode == 19)
    }

    @Test func sessionsRawColumnsExactShapeAndOrder() {
        let out = run(["sessions", "--raw", "--header"])
        let rows = out.stdout.components(separatedBy: "\n")
        // `end` is the 0.84.0 addition and sits LAST: the raw register is
        // positional, so every column a consumer already indexes keeps its
        // place and a new one may only grow off the right edge.
        #expect(rows[0] == "id\ttitle\tproject\tbranch\tstarted\tactive\tcost\ttokens\tprompts\tapi-calls\tend")
        let sessionA = rows[1].components(separatedBy: "\t")
        #expect(sessionA[0] == "session-a")
        #expect(sessionA[4] == "2026-08-16T09:00:00Z")
        #expect(sessionA[5] == "5400")
        #expect(sessionA[6] == "0.069")
        #expect(sessionA[10] == "2026-08-16T11:30:00Z")
        let sessionB = rows[2].components(separatedBy: "\t")
        #expect(sessionB[2] == "")
        #expect(sessionB[3] == "")
        #expect(sessionB[6] == "")
        #expect(sessionB.count == 11)
    }

    @Test func sessionsJSONIsDigestFieldNames() throws {
        let out = run(["sessions", "--json"])
        #expect(out.stdout.contains("\"apiCalls\""))
        let data = try #require(out.stdout.data(using: .utf8))
        let decoded = try LiveState.decoder().decode([SessionCard].self, from: data)
        #expect(decoded.count == 2)
    }

    @Test func sessionSelectorLatestIndexAndIdPrefix() {
        #expect(run(["session", "latest", "id"]).stdout == "session-a")
        #expect(run(["session", "current", "id"]).stdout == "session-a")
        #expect(run(["session", "1", "id"]).stdout == "session-a")
        #expect(run(["session", "2", "id"]).stdout == "session-b")
        #expect(run(["session", "session-a", "id"]).stdout == "session-a")
    }

    @Test func sessionSelectorAmbiguousPrefixAndNoMatch() {
        // Both ids share the "session-" prefix.
        let ambiguous = run(["session", "session-"])
        #expect(ambiguous.exitCode == 19)
        #expect(run(["session", "3"]).exitCode == 20)
        #expect(run(["session", "nope"]).exitCode == 20)
    }

    @Test func sessionFieldsAndDeepFieldRejection() {
        #expect(run(["session", "latest", "project"]).stdout == "main")
        #expect(run(["session", "latest", "branch"]).stdout == "main")
        #expect(run(["session", "latest", "active"]).stdout == "5400")
        #expect(run(["session", "latest", "api-calls"]).stdout == "40")
        // `end` and `source` answer straight from the shortlist: the first
        // is what a liveness check reads, the second is which path answered.
        #expect(run(["session", "latest", "end"]).stdout == "2026-08-16T11:30:00Z")
        #expect(run(["session", "latest", "source"]).stdout == "digest")
        // A deep field (only reachable via --all in M2) is a bad query, not
        // an absent value — the shortlist genuinely doesn't carry it.
        let deep = run(["session", "latest", "kind"])
        #expect(deep.exitCode == 19)
    }

    @Test func sessionWithNoProjectOrBranchOmitsThePlaceClauseInSummary() {
        let out = run(["session", "2"])
        #expect(out.stdout == "A background run · 30 min · 0 tokens · —")
    }

    @Test func sessionsFilters() {
        #expect(run(["sessions", "--project", "main", "--raw"]).stdout.contains("session-a"))
        #expect(run(["sessions", "--project", "nonexistent-project", "--raw"]).stdout == "")
        #expect(run(["sessions", "--branch", "main", "--raw"]).stdout.contains("session-a"))
        // Asserted by IDENTITY (starts with the newest, excludes the
        // second) rather than by row count — a row count of 1 is also what
        // a `--limit` that silently ignored its value would produce here,
        // since the shortlist only holds two sessions to begin with.
        let limited = run(["sessions", "--limit", "1", "--raw"]).stdout
        #expect(limited.hasPrefix("session-a"))
        #expect(!limited.contains("session-b"))
        // --since filters on startedAt: session-a started 08-16T09:00 (on
        // or after the cutoff), session-b started 08-15T20:00 (before it).
        #expect(run(["sessions", "--since", "2026-08-16", "--raw"]).stdout.contains("session-a"))
        #expect(!run(["sessions", "--since", "2026-08-16", "--raw"]).stdout.contains("session-b"))
    }

    @Test func sessionsBadFilterValuesAreBadQuery() {
        #expect(run(["sessions", "--since", "not-a-date-or-duration"]).exitCode == 19)
        #expect(run(["sessions", "--limit", "not-a-number"]).exitCode == 19)
    }

    /// A literal "yyyy-MM-dd" `--since` cutoff parses at midnight in the
    /// DIGEST's own time zone, not a hard-coded UTC.
    @Test func sessionsSinceDayKeyParsesInTheDigestsOwnTimeZone() {
        let engine = DigestQueryTests.minimalEngine(fetchedAt: nil, nextPollAt: nil)
        let session = SessionCard(
            id: "s1", title: "t", project: nil, branch: nil,
            startedAt: DigestQueryTests.iso("2026-08-15T06:00:00Z"),
            end: DigestQueryTests.iso("2026-08-15T06:30:00Z"),
            activeSeconds: 60, cost: nil, tokens: 0, prompts: 0, apiCalls: 0, modelColors: [])
        let state = DigestQueryTests.minimalState(
            engine: engine, sessions: [session], timeZone: "America/Los_Angeles")
        // "2026-08-15" parses as LA-local midnight (2026-08-15T07:00:00Z)
        // — the session's 06:00Z start sits BEFORE that cutoff and is
        // excluded. A hard-coded-UTC parse would put the cutoff at
        // 2026-08-15T00:00:00Z instead and wrongly include it.
        let out = run(["sessions", "--since", "2026-08-15", "--raw"], digest: state)
        #expect(out.stdout == "")
        #expect(out.exitCode == 0)
    }
}

// MARK: - prompt: color registers, --tmux, --segment, --no-glyph, stale, --json

extension DigestQueryTests {
    @Test func promptNoColorFlagStripsColor() {
        #expect(run(["prompt", "--no-color"]).stdout == "✳︎ S 53% W — M —")
    }

    @Test func promptNoColorEnvStripsColor() {
        #expect(run(["prompt"], env: ["NO_COLOR": "1"]).stdout == "✳︎ S 53% W — M —")
    }

    @Test func promptRawFlagAlsoStripsColor() {
        #expect(run(["prompt", "--raw"]).stdout == "✳︎ S 53% W — M —")
    }

    @Test func promptTmuxMarkup() {
        let out = run(["prompt", "--tmux"])
        #expect(out.stdout == "#[fg=#D97757]✳︎#[default] S #[fg=#FF9C1D]53%#[default] W — M —")
    }

    @Test func promptSegmentFilterReordersToRequestedOrder() {
        let out = run(["prompt", "--no-color", "--segment", "w", "--segment", "s"])
        #expect(out.stdout == "✳︎ W — S 53%")
    }

    /// An unmatched tag is a selector matching nothing — the same exit
    /// every other missed selector uses, not a silent empty segment list.
    @Test func promptSegmentTagWithNoMatchIsNoMatch() {
        let out = run(["prompt", "--segment", "zz"])
        #expect(out.stdout == "")
        #expect(out.exitCode == 20)
        #expect(out.note != nil)
    }

    @Test func promptNoGlyphDropsLeadingGlyphAndSpace() {
        #expect(run(["prompt", "--no-color", "--no-glyph"]).stdout == "S 53% W — M —")
    }

    @Test func promptStaleMarkerAllThreeModes() {
        let engine = DigestQueryTests.minimalEngine(stale: true)
        let state = DigestQueryTests.minimalState(
            engine: engine,
            menuBar: [SegmentStatus(tag: "S", percent: 10, level: "normal", severity: nil, risk: nil)])
        #expect(run(["prompt", "--no-color"], digest: state).stdout == "✳︎ S 10% stale")
        let ansi = run(["prompt"], digest: state)
        #expect(ansi.stdout.hasSuffix(" \u{1B}[2mstale\u{1B}[0m"))
        let tmux = run(["prompt", "--tmux"], digest: state)
        #expect(tmux.stdout.hasSuffix(" #[dim]stale#[default]"))
    }

    @Test func promptTakesNoPositionalArguments() {
        #expect(run(["prompt", "bogus"]).exitCode == 19)
    }

    @Test func promptJSONShapeAndNoGlyphKeyOmission() throws {
        let out = run(["prompt", "--json"])
        let data = try #require(out.stdout.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["glyph"] as? String == "✳︎")
        #expect(object["stale"] as? Bool == false)
        #expect((object["segments"] as? [Any])?.count == 3)

        // --no-glyph: `glyph` is a Swift Optional<String> encoded through
        // the standard synthesized Encodable, which OMITS a nil key
        // entirely (encodeIfPresent) rather than writing "null" — verified
        // directly against JSONEncoder, not assumed from the implementation
        // notes' own hedged phrasing ("...actually glyph key present as
        // null...", which this test shows is not what actually happens).
        let noGlyphOut = run(["prompt", "--no-glyph", "--json"])
        let noGlyphData = try #require(noGlyphOut.stdout.data(using: .utf8))
        let noGlyphObject = try #require(JSONSerialization.jsonObject(with: noGlyphData) as? [String: Any])
        #expect(noGlyphObject.keys.contains("glyph") == false)
    }
}

// MARK: - get: raw-JSON path walking

extension DigestQueryTests {
    @Test func getDottedPathScalar() {
        let out = run(["get", "engine.planLabel"])
        #expect(out.stdout == "Max plan · 1x")
        // Bare, not JSON-quoted, when --json is absent.
        #expect(!out.stdout.hasPrefix("\""))
    }

    @Test func getNumericArrayIndex() {
        // meters[0] is "session" in raw file order.
        #expect(run(["get", "meters.0.id"]).stdout == "session")
        #expect(run(["get", "meters.1.id"]).stdout == "weekly_all")
        #expect(run(["get", "meters.2.id"]).stdout == "")
        #expect(run(["get", "meters.2.id", "--json"]).stdout == "null")
    }

    @Test func getMeterSelectorSugarMatchesLimitsOwnResolver() {
        #expect(run(["get", "meters[session].id"]).stdout == "session")
        #expect(run(["get", "meters[week].id"]).stdout == "weekly_all")
        #expect(run(["get", "meters[worst].id"]).stdout == "session")
    }

    @Test func getMeterSelectorSugarReusesRealSelectorErrors() {
        let ambiguous = run(["get", "meters[e].id"])
        #expect(ambiguous.exitCode == 19)
        let noMatch = run(["get", "meters[nonexistent].id"])
        #expect(noMatch.exitCode == 20)
    }

    @Test func getAndLimitAgreeByteForByteOnTheSameNumber() {
        // The load-bearing cross-check: a value read two different ways
        // must be byte-identical, since both route through the same
        // canonical number formatter.
        let viaLimit = run(["limit", "session", "forecast.severity"])
        let viaGet = run(["get", "meters[session].forecast.severity"])
        #expect(viaLimit.stdout == viaGet.stdout)
        #expect(viaLimit.stdout == "0.4")

        // Fable's plateau after the 10:01 slot: 53×480/583 of the meter's
        // percent — hand-derived, not read back from the implementation.
        let viaLimitCurvePoint = run(["get", "meters[session].modelSeries.0.points.10.percent"])
        #expect(viaLimitCurvePoint.stdout == "43.63636363636364")

        let viaCost = run(["cost", "30d", "--raw"])
        let viaGetCost = run(["get", "activity.days.1.cost"])
        #expect(viaGetCost.stdout == "0.065")
        #expect(viaCost.stdout == "0.069")
    }

    @Test func getMissingKeyIsAbsentNotAnError() {
        // A key that has never existed on any schema version.
        #expect(run(["get", "engine.totallyUnknownField"]).stdout == "")
        #expect(run(["get", "engine.totallyUnknownField"]).exitCode == 0)
        #expect(run(["get", "engine.totallyUnknownField", "--json"]).stdout == "null")
        // Traversal into a scalar is equally absent, not a crash.
        #expect(run(["get", "engine.providerID.nested"]).stdout == "")
    }

    /// Injects a key into a MUTATED COPY of the golden bytes that exists
    /// nowhere on the `LiveState` struct — proving `get` walks the raw JSON
    /// independently of the typed schema (forward-compatible with a field
    /// that ships tomorrow). The typed `digest:` passed alongside is the
    /// UNMODIFIED decode, so this can't accidentally pass by reading the
    /// typed struct instead.
    @Test func getReachesAFieldThatDoesNotExistOnTheTypedSchema() throws {
        var root = try #require(
            try JSONSerialization.jsonObject(with: goldenRaw) as? [String: Any])
        var engine = try #require(root["engine"] as? [String: Any])
        engine["futureFieldFromTomorrowsSchema"] = "not on LiveState at all"
        root["engine"] = engine
        let mutated = try JSONSerialization.data(withJSONObject: root)

        let out = run(["get", "engine.futureFieldFromTomorrowsSchema"], rawDigest: mutated)
        #expect(out.stdout == "not on LiveState at all")
    }

    @Test func getObjectPrintsCompactByDefaultAndPrettyWithJSON() throws {
        let compact = run(["get", "meters[session].forecast"])
        #expect(!compact.stdout.contains("\n"))
        #expect(!compact.stdout.contains(" : "))
        #expect(compact.stdout.contains("\"severity\":0.4"))

        let pretty = run(["get", "meters[session].forecast", "--json"])
        #expect(pretty.stdout.contains("\n"))
        #expect(pretty.stdout.contains(" : "))
        #expect(pretty.stdout.contains("\"severity\" : 0.4"))

        // Both parse to the same structure — a real decode failure here
        // must fail the test, not silently vanish into a vacuous nil==nil.
        let compactObject = try #require(
            try JSONSerialization.jsonObject(with: Data(compact.stdout.utf8)) as? [String: Any])
        let prettyObject = try #require(
            try JSONSerialization.jsonObject(with: Data(pretty.stdout.utf8)) as? [String: Any])
        #expect(compactObject.count == prettyObject.count)
        #expect(compactObject["severity"] as? Double == 0.4)
    }

    @Test func getArrayLengthMatchesMenuBarCount() throws {
        let out = run(["get", "menuBar", "--json"])
        let array = try #require(
            try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [Any])
        #expect(array.count == 3)
    }

    @Test func getRequiresExactlyOnePath() {
        #expect(run(["get"]).exitCode == 19)
        #expect(run(["get", "a", "b"]).exitCode == 19)
    }
}

// MARK: - --max-age / duration parsing

extension DigestQueryTests {
    @Test func durationParserAcceptsIntegerMagnitudes() {
        #expect(DigestQuery.parseDuration("90s") == 90)
        #expect(DigestQuery.parseDuration("5m") == 300)
        #expect(DigestQuery.parseDuration("2h") == 7200)
        #expect(DigestQuery.parseDuration("7d") == 604800)
        #expect(DigestQuery.parseDuration("0s") == 0)
    }

    @Test func durationParserRejectsFractionalAndGarbage() {
        // A regression guard: this used to silently accept "1.5h".
        #expect(DigestQuery.parseDuration("1.5h") == nil)
        #expect(DigestQuery.parseDuration("abc") == nil)
        #expect(DigestQuery.parseDuration("") == nil)
        #expect(DigestQuery.parseDuration("5") == nil)
        #expect(DigestQuery.parseDuration("-5m") == nil)
    }

    @Test func maxAgeFreshPasses() {
        // now == generatedAt exactly -> age 0, well inside any bound.
        let out = run(["status", "--max-age", "5m"])
        #expect(out.exitCode == 0)
        #expect(out.stdout != "")
    }

    @Test func maxAgeStaleExitsTwentyOneWithEmptyStdout() {
        let laterNow = golden.engine.generatedAt.addingTimeInterval(90)
        let out = run(["status", "--max-age", "60s"], now: laterNow)
        #expect(out.stdout == "")
        #expect(out.exitCode == 21)
        // No stderr note on this path — a prompt recipe re-invokes this on
        // every render, and the exit code alone already carries the
        // guard's meaning (design §15).
        #expect(out.note == nil)
    }

    /// `--max-age` is checked once, in `run`, before dispatch to any noun
    /// handler — a bogus selector under a stale digest must still report
    /// staleness (21), not the selector's own no-match (20).
    @Test func maxAgeStaleTakesPriorityOverASelectorThatWouldOtherwiseFail() {
        let laterNow = golden.engine.generatedAt.addingTimeInterval(90)
        let staleGuarded = run(["limit", "bogus-selector-that-matches-nothing", "--max-age", "60s"], now: laterNow)
        #expect(staleGuarded.exitCode == 21)
        #expect(staleGuarded.stdout == "")
    }

    @Test func maxAgeBadDurationIsBadQuery() {
        let out = run(["status", "--max-age", "not-a-duration"])
        #expect(out.exitCode == 19)
    }
}

// MARK: - grammar-level errors independent of any noun

extension DigestQueryTests {
    @Test func noArgumentsIsBadQuery() {
        #expect(run([]).exitCode == 19)
    }

    @Test func unknownNounIsBadQuery() {
        #expect(run(["bogusnoun"]).exitCode == 19)
    }

    @Test func unknownFlagIsBadQuery() {
        #expect(run(["status", "--bogus-flag"]).exitCode == 19)
    }

    @Test func valueFlagMissingItsValueIsBadQuery() {
        #expect(run(["status", "--max-age"]).exitCode == 19)
    }

    @Test func segmentFlagMissingItsValueIsBadQuery() {
        #expect(run(["prompt", "--segment"]).exitCode == 19)
    }

    @Test func everyExitZeroCarriesNoStderrNote() {
        // stdout is data, stderr is commentary — a success path must never
        // leave commentary sitting in `note` for a caller to accidentally
        // interleave.
        #expect(run(["status"]).note == nil)
        #expect(run(["limits"]).note == nil)
        #expect(run(["limit", "session"]).note == nil)
    }
}

// MARK: - engine-state variants the golden fixture cannot carry

extension DigestQueryTests {
    @Test func errorSegmentAppearsInStatusLine() {
        let engine = DigestQueryTests.minimalEngine(
            error: ErrorStatus(
                text: "Sign-in expired — open Claude Code", hint: "Open Claude Code once.",
                code: "signInExpired", httpStatus: nil))
        let state = DigestQueryTests.minimalState(engine: engine)
        let out = run(["status"], digest: state)
        #expect(out.stdout.hasSuffix("ERROR: Sign-in expired — open Claude Code"))
        #expect(run(["status", "error"], digest: state).stdout == "Sign-in expired — open Claude Code")
        #expect(run(["status", "error.code"], digest: state).stdout == "signInExpired")
        #expect(run(["status", "error.hint"], digest: state).stdout == "Open Claude Code once.")
        #expect(run(["status", "error.http"], digest: state).stdout == "")
    }

    @Test func httpErrorCarriesItsStatusCode() {
        let engine = DigestQueryTests.minimalEngine(
            error: ErrorStatus(text: "Usage endpoint returned HTTP 500", hint: nil, code: "http", httpStatus: 500))
        let state = DigestQueryTests.minimalState(engine: engine)
        #expect(run(["status", "error.http"], digest: state).stdout == "500")
    }

    @Test func staleMarkerAppendsToEverySingleEntitySummaryLine() {
        let engine = DigestQueryTests.minimalEngine(stale: true)
        let meter = LiveMeter(
            id: "session", label: "Session (5h)", tag: "S", percent: 10, level: "normal",
            rank: 0, rateWindowSeconds: 2700, forcesWarning: false, risk: nil, resetsAt: nil,
            limitWindow: nil, scopedModelName: nil, resetCaption: nil, forecast: nil,
            series: [], stretches: [])
        let state = DigestQueryTests.minimalState(engine: engine, meters: [meter])
        #expect(run(["status"], digest: state).stdout.hasSuffix("· stale"))
        #expect(run(["limit", "session"], digest: state).stdout.hasSuffix("· stale"))
        // Lists never carry the stale suffix — a table of N rows reads as
        // data, not a single headline.
        #expect(!run(["limits"], digest: state).stdout.contains("stale"))
    }

    @Test func staleFlagDoesNotDecorateRawOrJSON() {
        let engine = DigestQueryTests.minimalEngine(stale: true)
        let state = DigestQueryTests.minimalState(engine: engine)
        #expect(run(["status", "stale"], digest: state).stdout == "true")
        // The summary line's OWN stale suffix is human-only; a named field
        // (raw/json) never gets the decoration either.
        #expect(!run(["status", "provider"], digest: state).stdout.contains("stale"))
    }

    @Test func statusCheckReflectsStaleFlag() {
        let engine = DigestQueryTests.minimalEngine(stale: true)
        let state = DigestQueryTests.minimalState(engine: engine)
        let out = run(["status", "--check"], digest: state)
        #expect(out.stdout == "")
        #expect(out.exitCode == 21)
    }

    @Test func backoffUntilField() {
        let backoff = DigestQueryTests.iso("2026-08-16T12:10:00Z")
        let engine = DigestQueryTests.minimalEngine(backoffUntil: backoff)
        let state = DigestQueryTests.minimalState(engine: engine)
        #expect(run(["status", "backoff"], digest: state).stdout == "2026-08-16T12:10:00Z")
        #expect(run(["status", "backoff", "--unix"], digest: state).stdout == String(Int(backoff.timeIntervalSince1970)))
    }

    @Test func nextPollInThePastIsOmittedFromStatusLine() {
        // The design's own noted gotcha: a nextPollAt at or before `now`
        // must NOT print "next poll in 0s" or a negative duration.
        let enginePast = DigestQueryTests.minimalEngine(
            fetchedAt: nil, nextPollAt: now.addingTimeInterval(-30))
        let statePast = DigestQueryTests.minimalState(engine: enginePast)
        #expect(!run(["status"], digest: statePast).stdout.contains("next poll"))

        let engineNoPoll = DigestQueryTests.minimalEngine(fetchedAt: nil, nextPollAt: nil)
        let stateNoPoll = DigestQueryTests.minimalState(engine: engineNoPoll)
        #expect(!run(["status"], digest: stateNoPoll).stdout.contains("next poll"))
    }

    @Test func fetchedAtOmittedWhenNil() {
        let engine = DigestQueryTests.minimalEngine(fetchedAt: nil, nextPollAt: nil)
        let state = DigestQueryTests.minimalState(engine: engine)
        let out = run(["status"], digest: state)
        // "host pid N" is unconditional (never optional data), so only the
        // "fetched" clause itself must disappear — not the whole line.
        #expect(!out.stdout.contains("fetched"))
        #expect(out.stdout == "Claude · daemon pid 9999")
    }
}

// MARK: - minimal fixture builders

extension DigestQueryTests {
    /// A minimal, otherwise-healthy `EngineStatus` for the narrow states the
    /// golden fixture can't carry (spend, error, backoff, stale) — built
    /// directly through the public struct initializers exactly as
    /// `LiveStateTests.buildFixture` builds ITS state, just skipping
    /// `LiveStateBuilder`'s full provider/pricing/prediction pipeline since
    /// these tests only exercise `DigestQuery`'s reading of the final typed
    /// shape, never the pipeline that produces it.
    static func minimalEngine(
        spend: SpendStatus? = nil, error: ErrorStatus? = nil, stale: Bool = false,
        backoffUntil: Date? = nil, fetchedAt: Date? = DigestQueryTests.iso("2026-08-16T11:58:00Z"),
        nextPollAt: Date? = nil, isLocalProvider: Bool = false
    ) -> EngineStatus {
        EngineStatus(
            providerID: "claude", serviceName: "Claude", agentName: "Claude Code", glyph: "✳︎",
            accent: RGBColor(red: 0.851, green: 0.467, blue: 0.341), systemAccent: nil,
            planLabel: nil, planSubscriptionType: nil, planRateLimitTier: nil,
            appVersion: "0.81.0", pid: 9999, host: "daemon",
            generatedAt: DigestQueryTests.iso("2026-08-16T12:00:00Z"), fetchedAt: fetchedAt,
            nextPollAt: nextPollAt, backoffUntil: backoffUntil, stale: stale,
            isLocalProvider: isLocalProvider, activeIntervalSeconds: 300, paceMultiplier: 1,
            apiBudgetUsed: nil, apiBudgetCeiling: nil, apiBudgetFraction: nil,
            gateFloorSeconds: 180, error: error, spend: spend, forecastProfile: nil)
    }

    static func minimalState(
        engine: EngineStatus, meters: [LiveMeter] = [], menuBar: [SegmentStatus] = [],
        models: [ModelRow] = [], sessions: [SessionCard] = [], timeZone: String = "UTC",
        days: [DayRollup] = [], todayTokens: Int = 0, todayPrompts: Int = 0, todayCost: Double? = nil
    ) -> LiveState {
        LiveState(
            engine: engine, meters: meters, menuBar: menuBar, models: models,
            activity: ActivityRollup(
                timeZone: timeZone, todayHours: [], todayTokens: todayTokens,
                todayPrompts: todayPrompts, todayCost: todayCost,
                days: days, modelDays: [], hourDays: []),
            sessions: sessions)
    }
}

// MARK: - Singular no-field summaries honor the registers (v0.81.0 verify
// finding: `--json`/`--raw` were silently discarded on every singular
// entity while the plurals honored them)

extension DigestQueryTests {
    @Test func singularEntitySummariesHonorJSON() throws {
        let meter = try LiveState.decoder().decode(
            LiveMeter.self, from: Data(run(["limit", "session", "--json"]).stdout.utf8))
        #expect(meter.id == "session")
        #expect(meter.percent == 53)

        let card = try LiveState.decoder().decode(
            SessionCard.self, from: Data(run(["session", "latest", "--json"]).stdout.utf8))
        #expect(card.id == "session-a")

        let row = try LiveState.decoder().decode(
            ModelRow.self, from: Data(run(["model", "top", "--json"]).stdout.utf8))
        #expect(row.id == "claude-fable-5")

        let engine = try LiveState.decoder().decode(
            EngineStatus.self, from: Data(run(["status", "--json"]).stdout.utf8))
        #expect(engine.providerID == "claude")
    }

    @Test func singularEntitySummariesHonorRaw() {
        let meterRow = run(["limit", "session", "--raw"])
        #expect(meterRow.exitCode == 0)
        #expect(meterRow.stdout.hasPrefix("session\tS\t53\t"))

        let sessionRow = run(["session", "latest", "--raw"])
        #expect(sessionRow.exitCode == 0)
        #expect(sessionRow.stdout.contains("session-a") && sessionRow.stdout.contains("\t"))

        let modelRow = run(["model", "top", "--raw"])
        #expect(modelRow.exitCode == 0)
        #expect(modelRow.stdout.hasPrefix("claude-fable-5\t"))
    }

    @Test func nonEntitySummariesGuideRawToAField() {
        // No row vocabulary exists for these — a guiding bad-query beats
        // both a silent human line and an invented schema.
        #expect(run(["status", "--raw"]).exitCode == 19)
        #expect(run(["budget", "--raw"]).exitCode == 19)
        #expect(run(["activity", "--raw"]).exitCode == 19)
        #expect(run(["spend", "--raw"], digest: spendState()).exitCode == 19)
    }

    @Test func nonEntitySummariesHonorJSON() throws {
        struct BudgetBox: Decodable {
            let used: Int
            let ceiling: Int?
            let left: Int?
        }
        let budget = try LiveState.decoder().decode(
            BudgetBox.self, from: Data(run(["budget", "--json"]).stdout.utf8))
        #expect(budget.used == 7)
        #expect(budget.ceiling == 20)
        #expect(budget.left == 13)

        struct ActivityBox: Decodable {
            let tokens: Int
            let prompts: Int
            let cost: Double?
        }
        let today = try LiveState.decoder().decode(
            ActivityBox.self, from: Data(run(["activity", "today", "--json"]).stdout.utf8))
        #expect(today.tokens == golden.activity.todayTokens)

        let spend = try LiveState.decoder().decode(
            SpendStatus.self, from: Data(run(["spend", "--json"], digest: spendState()).stdout.utf8))
        #expect(spend.usedMinor == 1234)

        // Absent spend under --json is null — absent, never {} or a
        // fabricated zero line.
        #expect(run(["spend", "--json"]).stdout == "null")
    }

    private func spendState() -> LiveState {
        let engine = DigestQueryTests.minimalEngine(
            spend: SpendStatus(usedMinor: 1234, limitMinor: 2500, currency: "USD", exponent: 2),
            fetchedAt: nil, nextPollAt: nil)
        return DigestQueryTests.minimalState(engine: engine)
    }
}
