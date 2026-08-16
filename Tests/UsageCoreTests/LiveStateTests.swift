import Foundation
import Testing

@testable import UsageCore

/// Pins the live-state digest — the TUI's whole world. The golden fixture
/// in Fixtures/digest/ is decoded by BOTH this suite and the Rust TUI's
/// serde contract tests, so a schema drift fails a test on whichever side
/// drifted, never a render. Regenerate deliberately with
/// `UPDATE_GOLDENS=1 swift test --filter LiveState` after an ADDITIVE
/// change, and re-read the diff before committing it.
@Suite("LiveState")
struct LiveStateTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let posix = Locale(identifier: "en_US_POSIX")

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// A fully-populated, deterministic engine state: one crafted pricing
    /// table (never the bundled feed — it re-vendors), two meters with a
    /// forecast, samples crossing a reset, minute slots, and three days of
    /// activity including an unpriced model.
    private func buildFixture() -> LiveState {
        let now = date("2026-08-16T12:00:00Z")
        let provider = ClaudeProvider()
        let pricing = PricingTable(
            rates: [
                "claude-fable-5": ModelRates(
                    input: 5e-6, output: 25e-6, cacheWrite: 6.25e-6,
                    cacheWrite1h: 10e-6, cacheRead: 0.5e-6, contextTokens: 1_000_000)
            ],
            fetchedAt: date("2026-08-16T00:00:00Z"), source: .live)
        let ledger = ModelColorLedger(
            hues: ["Fable": 0, "Mystery": 1],
            shades: ["Fable": ["claude-fable-5": 0], "Mystery": ["mystery-model": 0]])

        let meters = [
            Meter(
                id: "session", label: "Session (5h)", percent: 53,
                resetsAt: date("2026-08-16T14:00:00Z"), level: .normal, rank: 0,
                limitWindow: 5 * 3600),
            Meter(
                id: "weekly_all", label: "Weekly (all)", percent: nil, resetsAt: nil,
                level: .warning, rank: 1),
        ]
        let snapshot = Snapshot(
            meters: meters, fetchedAt: date("2026-08-16T11:58:00Z"),
            plan: PlanInfo(subscriptionType: "max", rateLimitTier: "default_max_1x"))
        let prediction = UsagePrediction(
            ratePerHour: 12, baselineRatePerHour: 6, paceFactor: 1.5,
            basis: .windowAverage, projectedAtReset: 78,
            exhaustsAt: nil, verdict: .green, rawVerdict: .green, severity: 0.4,
            text: "", curve: [
                UsagePrediction.Point(t: now, percent: 53),
                UsagePrediction.Point(t: date("2026-08-16T14:00:00Z"), percent: 78),
            ])
        let samples = [
            UsageSample(
                t: date("2026-08-16T09:30:00Z"), percents: ["Session (5h)": 91],
                resets: ["Session (5h)": date("2026-08-16T09:40:00Z")]),
            UsageSample(
                t: date("2026-08-16T10:00:00Z"), percents: ["Session (5h)": 12],
                resets: ["Session (5h)": date("2026-08-16T14:00:00Z")]),
            UsageSample(
                t: date("2026-08-16T11:58:00Z"), percents: ["Session (5h)": 53],
                resets: ["Session (5h)": date("2026-08-16T14:00:00Z")]),
        ]
        let timeline = [
            TokenSlot(
                t: date("2026-08-16T10:00:00Z"), model: "claude-fable-5",
                tally: TokenTally(input: 100, output: 20)),
            TokenSlot(
                t: date("2026-08-16T10:01:00Z"), model: "claude-fable-5",
                tally: TokenTally(input: 300, output: 60)),
            TokenSlot(
                t: date("2026-08-16T11:30:00Z"), model: "mystery-model",
                tally: TokenTally(input: 50, output: 5)),
        ]
        let activity = [
            DailyActivity(
                day: date("2026-08-14T00:00:00Z"), tokens: 0, messages: 0, prompts: 4),
            DailyActivity(
                day: date("2026-08-15T00:00:00Z"), tokens: 9000, messages: 12, prompts: 6,
                models: ["claude-fable-5": TokenTally(input: 8000, output: 1000)]),
            DailyActivity(
                day: date("2026-08-16T00:00:00Z"), tokens: 535, messages: 3, prompts: 2,
                models: [
                    "claude-fable-5": TokenTally(input: 400, output: 80),
                    "mystery-model": TokenTally(input: 50, output: 5),
                ]),
        ]

        return LiveStateBuilder.build(
            provider: provider,
            host: "app",
            pid: 4242,
            appVersion: "0.65.0",
            state: .live(snapshot),
            predictions: ["Session (5h)": prediction],
            samples: samples,
            timeline: timeline,
            activity: activity,
            pricing: pricing,
            colorLedger: ledger,
            graceSeconds: 900,
            nextPollAt: date("2026-08-16T12:03:00Z"),
            backoffUntil: nil,
            apiBudget: (used: 7, ceiling: 20),
            now: now,
            calendar: utc,
            locale: posix)
    }

    @Test("engine status carries identity, freshness, and the budget gauge")
    func engineStatus() {
        let state = buildFixture()
        #expect(state.schemaVersion == LiveState.schemaVersion)
        #expect(state.engine.providerID == "claude")
        #expect(state.engine.host == "app")
        #expect(state.engine.pid == 4242)
        #expect(state.engine.stale == false)
        #expect(state.engine.error == nil)
        #expect(state.engine.fetchedAt == date("2026-08-16T11:58:00Z"))
        #expect(state.engine.apiBudgetUsed == 7)
        #expect(state.engine.apiBudgetCeiling == 20)
        #expect(state.engine.gateFloorSeconds == TriggerGate.floor)
        #expect(state.engine.planLabel != nil)
    }

    @Test("meters speak the menu bar's tag vocabulary and the ramp's colors")
    func meterMapping() throws {
        let state = buildFixture()
        let session = try #require(state.meters.first { $0.id == "session" })
        #expect(session.tag == "S")
        #expect(session.level == "normal")
        #expect(session.percent == 53)
        #expect(session.resetCaption == "resets in 2h")
        // severity 0.4 resolves through the one shared ramp.
        #expect(session.risk == RiskRamp.color(severity: 0.4))
        let forecast = try #require(session.forecast)
        #expect(forecast.verdict == "green")
        #expect(forecast.projectedAtReset == 78)
        #expect(forecast.caption == nil)

        let weekly = try #require(state.meters.first { $0.id == "weekly_all" })
        #expect(weekly.tag == "W")
        #expect(weekly.level == "warning")
        // Absent ≠ zero: an unreported percent stays nil.
        #expect(weekly.percent == nil)
        #expect(weekly.risk == nil)
        #expect(weekly.forecast == nil)
    }

    @Test("the window series enters at height and falls at reset cliffs")
    func seriesAssembly() throws {
        let state = buildFixture()
        let session = try #require(state.meters.first { $0.id == "session" })
        // Window 09:00→14:00 holds the 09:30 (91%), the cliff fall to 0,
        // then 12% and 53%.
        #expect(session.series.first?.percent == 91)
        #expect(session.series.contains { $0.percent == 0 })
        #expect(session.series.last?.percent == 53)
        // One minute-gapped pair coalesces; the 11:30 slot stitches in
        // within the 900s grace? No — 89 minutes apart: two stretches.
        #expect(session.stretches.count == 2)
        #expect(session.stretches.allSatisfy { !$0.exhausted })
    }

    @Test("unpriced models keep nil costs everywhere — never zero")
    func absentCostStaysAbsent() throws {
        let state = buildFixture()
        let mystery = try #require(state.models.first { $0.id == "mystery-model" })
        #expect(mystery.cost == nil)
        let fable = try #require(state.models.first { $0.id == "claude-fable-5" })
        #expect(fable.cost != nil)
        #expect(fable.cost! > 0)
        // The prompt-only day has no priceable content at all.
        let promptOnly = try #require(state.activity.days.first { $0.dayKey == "2026-08-14" })
        #expect(promptOnly.cost == nil)
        #expect(promptOnly.tokens == 0)
        #expect(promptOnly.prompts == 4)
    }

    @Test("today rolls up hours, prompts, and priced cost in the calendar's zone")
    func todayRollup() {
        let state = buildFixture()
        // Foundation normalizes TimeZone("UTC") to the GMT identifier.
        #expect(state.activity.timeZone == "GMT")
        #expect(state.activity.todayTokens == 535)
        #expect(state.activity.todayPrompts == 2)
        #expect(state.activity.todayHours.map(\.hour) == [10, 11])
        #expect(state.activity.todayHours[0].tokens == 480)
        // The mystery-model hour carries tokens but no priceable cost.
        #expect(state.activity.todayHours[1].cost == nil)
        #expect(state.activity.modelDays.map(\.dayKey) == ["2026-08-15", "2026-08-16"])
        #expect(state.activity.days.count == 3)
    }

    @Test("menu bar segments arrive with resolved risk colors")
    func segments() {
        let state = buildFixture()
        #expect(state.menuBar.count == 3)
        #expect(state.menuBar[0].tag == "S")
        #expect(state.menuBar[0].percent == 53)
        #expect(state.menuBar[0].risk == RiskRamp.color(severity: 0.4))
        #expect(state.menuBar[1].tag == "W")
        #expect(state.menuBar[1].level == "warning")
        #expect(state.menuBar[1].risk == nil)
    }

    @Test("series thinning caps points and keeps both endpoints")
    func thinning() {
        let points = (0..<500).map {
            SeriesPoint(t: Date(timeIntervalSince1970: Double($0)), percent: Double($0))
        }
        let thinned = LiveStateBuilder.thin(points, to: 120)
        #expect(thinned.count == 120)
        #expect(thinned.first == points.first)
        #expect(thinned.last == points.last)
        #expect(LiveStateBuilder.thin(Array(points.prefix(50)), to: 120).count == 50)
    }

    @Test("digest round-trips through the pinned wire settings")
    func roundTrip() throws {
        let state = buildFixture()
        let data = try LiveState.encoder().encode(state)
        let revived = try LiveState.decoder().decode(LiveState.self, from: data)
        #expect(revived == state)
    }

    /// The cross-language contract: this file is what the Rust TUI's serde
    /// tests decode. `UPDATE_GOLDENS=1` rewrites it from the crafted state
    /// above — additive changes only, and read the diff.
    @Test("golden fixture stays decodable and equal to the crafted state")
    func golden() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        let state = buildFixture()
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] != nil {
            try FileManager.default.createDirectory(
                at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LiveState.encoder().encode(state).write(to: fixtureURL)
        }
        let data = try Data(contentsOf: fixtureURL)
        let decoded = try LiveState.decoder().decode(LiveState.self, from: data)
        #expect(decoded == state)
    }
}
