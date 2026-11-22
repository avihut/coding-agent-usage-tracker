import Foundation
import Testing

@testable import UsageCore

/// An OLD limits reading in the digest (`ReadingAge`, 2026-11-22): the
/// reporter's shape — Claude focused and fresh, Codex beside it on a reading
/// three and a half days old — and the third golden fixture, which the Rust
/// TUI decodes too. `UPDATE_GOLDENS=1 swift test --filter LiveState`
/// rewrites it.
@Suite("LiveState reading age")
struct LiveStateReadingAgeTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let posix = Locale(identifier: "en_US_POSIX")
    private let now = ISO8601DateFormatter().date(from: "2026-11-22T09:00:00Z")!
    /// The reporter's newest Codex reading: Wed 2026-11-18 20:13 UTC.
    private let codexReadAt = ISO8601DateFormatter().date(from: "2026-11-18T20:13:00Z")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func climbing(_ label: String, from: Int, until end: Date) -> [UsageSample] {
        (0...8).map { step in
            UsageSample(
                t: end.addingTimeInterval(Double(step - 8) * 1800),
                percents: [label: from + step * 2])
        }
    }

    /// Codex on the reporter's reading: the session window long since
    /// rolled (0%, no reset), the weekly at 75%, Pro Lite.
    private var codexMeters: [Meter] {
        [
            Meter(
                id: "0-session", label: "Session (5h)", percent: 0, resetsAt: nil,
                level: .normal, rank: 0, limitWindow: 5 * 3600),
            Meter(
                id: "1-weekly", label: "Weekly", percent: 75,
                resetsAt: date("2026-11-25T02:27:00Z"), level: .normal, rank: 1,
                limitWindow: 7 * 86400),
        ]
    }

    private var claudeMeters: [Meter] {
        [
            Meter(
                id: "five_hour", label: "Session (5h)", percent: 62,
                resetsAt: date("2026-11-22T11:00:00Z"), level: .normal, rank: 0,
                limitWindow: 5 * 3600),
        ]
    }

    /// A forecast that crosses — what the engine would still be holding for
    /// a reading that has gone old since its last pass.
    private func crossing(_ meters: [Meter], samplesUntil end: Date) -> [String: UsagePrediction] {
        var samples: [UsageSample] = []
        for meter in meters where (meter.percent ?? 0) > 0 {
            samples += climbing(meter.label, from: (meter.percent ?? 0) - 16, until: end)
        }
        return PredictionEngine.predictAll(
            meters: meters, samples: samples, profiles: [:], previous: [:], now: end)
    }

    private func section(
        provider: any UsageProvider, state: DisplayState, predictions: [String: UsagePrediction]
    ) -> LiveState {
        LiveStateBuilder.build(
            provider: provider, host: "daemon", pid: 909, appVersion: "0.104.0",
            state: state, predictions: predictions, samples: [], timeline: [], activity: [],
            pricing: provider.bundledRates, colorLedger: ModelColorLedger(),
            graceSeconds: ActivityGrace.defaultSeconds, activeInterval: 300, paceMultiplier: 1,
            nextPollAt: date("2026-11-22T09:03:00Z"), backoffUntil: nil, apiBudget: nil,
            now: now, calendar: utc, locale: posix)
    }

    private var codexSnapshot: Snapshot {
        Snapshot(
            meters: codexMeters, fetchedAt: codexReadAt,
            plan: PlanInfo(subscriptionType: "prolite", rateLimitTier: nil, displayName: "Pro Lite"))
    }

    private func codexSection() -> LiveState {
        section(
            provider: CodexProvider(), state: .live(codexSnapshot),
            predictions: crossing(codexMeters, samplesUntil: now))
    }

    private func claudeSection() -> LiveState {
        section(
            provider: ClaudeProvider(),
            state: .live(Snapshot(meters: claudeMeters, fetchedAt: date("2026-11-22T08:58:00Z"))),
            predictions: crossing(claudeMeters, samplesUntil: now))
    }

    private func buildFixture() -> LiveState {
        let claude = ClaudeProvider()
        let codex = CodexProvider()
        func account(_ providerID: String, home: String?) -> Profile {
            Profile(
                id: "default", providerID: providerID, home: home.map { URL(filePath: $0) },
                order: 0, addedAt: date("2026-09-01T09:00:00Z"))
        }
        return MeteringDigest.compose(
            harnesses: [
                HarnessSection(
                    provider: claude, recentFiles: 412, activeDays: 9,
                    serviceStatus: nil, notices: [], outages: []),
                HarnessSection(
                    provider: codex, recentFiles: 22, activeDays: 4,
                    serviceStatus: nil, notices: [], outages: nil),
            ],
            sections: [
                ProfileSection(
                    profile: account("claude", home: "/Users/t/.claude"), label: "work@example.com",
                    monogram: "W", dormant: false, lastActivityAt: date("2026-11-22T08:40:00Z"),
                    homeDisplayPath: "~/.claude", state: claudeSection()),
                ProfileSection(
                    profile: account("codex", home: nil), label: "Codex", monogram: "C",
                    dormant: false, lastActivityAt: date("2026-11-21T20:10:00Z"),
                    homeDisplayPath: nil, state: codexSection()),
            ],
            focused: "default", pinned: nil, host: "daemon", pid: 909, appVersion: "0.104.0",
            systemAccent: nil, activeInterval: 300, appUpdate: nil,
            nextReprobeAt: date("2026-11-22T09:10:00Z"), now: now, calendar: utc, locale: posix)
    }

    @Test("an old reading publishes its stamp and no forecast")
    func oldSection() throws {
        let state = codexSection()
        #expect(state.engine.asOf == codexReadAt)
        #expect(state.engine.asOfCaption == "as of Wed 20:13")
        #expect(state.engine.fetchedAt == codexReadAt)
        // `stale` keeps its own meaning: this reading wasn't cache-served.
        #expect(!state.engine.stale)
        #expect(state.engine.planLabel == "Pro Lite plan")
        for meter in state.meters {
            #expect(meter.forecast == nil)
            #expect(meter.risk == nil)
        }
        for segment in state.menuBar {
            #expect(segment.severity == nil)
            #expect(segment.risk == nil)
            #expect(segment.exhaustsAt == nil)
        }
        // Old + rolled: the rolled window still reads 0, no reset.
        let session = try #require(state.meters.first { $0.rank == 0 })
        #expect(session.percent == 0)
        #expect(session.resetsAt == nil)
        let weekly = try #require(state.meters.first { $0.rank == 1 })
        #expect(weekly.percent == 75)
        #expect(weekly.resetCaption != nil)
    }

    @Test("a fresh reading publishes no stamp and keeps its forecast")
    func freshSection() throws {
        let state = claudeSection()
        #expect(state.engine.asOf == nil)
        #expect(state.engine.asOfCaption == nil)
        let forecast = try #require(state.meters.first?.forecast)
        #expect(forecast.ratePerHour > 0)
    }

    /// A Claude cache served offline past its horizon: the engine only
    /// recomputes on `.live`, so the last pass's forecast is still held —
    /// the digest must not carry it.
    @Test("a cache served past the horizon drops the forecast it was handed")
    func cachedAndOld() {
        let fetched = now.addingTimeInterval(-(5 * 3600 + 60))
        let meters = [
            Meter(
                id: "seven_day", label: "Weekly (all)", percent: 50,
                resetsAt: now.addingTimeInterval(3 * 86400), level: .normal, rank: 1,
                limitWindow: 7 * 86400),
        ] + claudeMeters.map {
            Meter(
                id: $0.id, label: $0.label, percent: $0.percent,
                resetsAt: now.addingTimeInterval(3600), level: $0.level, rank: $0.rank,
                limitWindow: $0.limitWindow)
        }
        let held = crossing(meters, samplesUntil: fetched)
        #expect(!held.isEmpty)
        let state = section(
            provider: ClaudeProvider(),
            state: .cached(Snapshot(meters: meters, fetchedAt: fetched), error: .network),
            predictions: held)
        #expect(state.engine.stale)
        #expect(state.engine.asOf == fetched)
        #expect(state.meters.allSatisfy { $0.forecast == nil })
        // Inside the horizon the same cache keeps what it had.
        let recent = section(
            provider: ClaudeProvider(),
            state: .cached(Snapshot(meters: meters, fetchedAt: now.addingTimeInterval(-600)), error: .network),
            predictions: held)
        #expect(recent.engine.asOf == nil)
        #expect(recent.meters.contains { $0.forecast != nil })
    }

    @Test("an old account's cell takes the bar's stale treatment")
    func oldCellIsStale() throws {
        let state = buildFixture()
        let cells = try #require(state.menuBarCells)
        #expect(cells.map(\.profile) == ["default", "codex"])
        #expect(cells.map(\.stale) == [false, true])
        let codex = try #require(state.profiles?.first { $0.id == "codex" })
        #expect(codex.engine?.asOf == codexReadAt)
        // The focused (fresh) account is what the top level projects.
        #expect(state.engine.asOf == nil)
        #expect(state.viewing(profile: "codex")?.engine.asOfCaption == "as of Wed 20:13")
    }

    @Test("the day-aware stamp: today's clock, a weekday within the week, a date beyond")
    func phrasing() {
        #expect(UsageFormatting.asOfText(date("2026-11-22T02:15:00Z"), now: now, calendar: utc, locale: posix)
            == "as of 02:15")
        #expect(UsageFormatting.asOfText(codexReadAt, now: now, calendar: utc, locale: posix)
            == "as of Wed 20:13")
        #expect(UsageFormatting.asOfText(date("2026-11-10T07:05:00Z"), now: now, calendar: utc, locale: posix)
            == "as of Nov 10 07:05")
        #expect(UsageFormatting.planLabel("Pro Lite plan", asOfCaption: "as of Wed 20:13")
            == "Pro Lite plan · as of Wed 20:13")
        #expect(UsageFormatting.planLabel("Pro Lite plan", asOfCaption: nil) == "Pro Lite plan")
    }

    @Test("the old-reading golden stays decodable and equal to the crafted state")
    func golden() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1-old-reading.json")
        let state = buildFixture()
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] != nil {
            try FileManager.default.createDirectory(
                at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LiveState.encoder().encode(state).write(to: fixtureURL)
        }
        let data = try Data(contentsOf: fixtureURL)
        #expect(try LiveState.decoder().decode(LiveState.self, from: data) == state)
    }
}
