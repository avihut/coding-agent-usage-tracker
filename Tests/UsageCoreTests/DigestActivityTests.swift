import Foundation
import Testing

@testable import UsageCore

/// A demo face's activity, rebuilt from the golden's rollups (2026-08-14:
/// prompts only; 2026-08-15: one model tallied; 2026-08-16: today).
@Suite("Digest activity")
struct DigestActivityTests {
    let golden: LiveState
    let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }()

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        golden = try LiveState.decoder().decode(
            LiveState.self, from: Data(contentsOf: fixtureURL))
    }

    @Test("every rolled-up day lands on its own calendar day, with its model tallies")
    func dailyFromRollup() throws {
        let days = DigestActivity.daily(from: golden.activity, calendar: utc)
        #expect(days.map(\.day) == [
            DigestQueryTests.iso("2026-08-14T00:00:00Z"),
            DigestQueryTests.iso("2026-08-15T00:00:00Z"),
            DigestQueryTests.iso("2026-08-16T00:00:00Z"),
        ])
        let tallied = try #require(days.first { !$0.models.isEmpty })
        #expect(tallied.models.keys.sorted() == ["claude-fable-5"])
        // The contract DailyActivity states: `models` sums to `tokens`.
        #expect(tallied.tokens == tallied.models.values.reduce(0) { $0 + $1.total })
    }

    @Test("a prompt-only day keeps its prompts and no tokens — absent is not invented")
    func promptOnlyDay() throws {
        let day = try #require(DigestActivity.daily(from: golden.activity, calendar: utc).first)
        #expect(day.prompts == 4)
        #expect(day.tokens == 0)
        #expect(day.models.isEmpty)
    }

    @Test("a day key that names no date is skipped, never guessed")
    func malformedDayKey() {
        let rollup = ActivityRollup(
            timeZone: "GMT", todayHours: [], todayTokens: 0, todayPrompts: 0, todayCost: nil,
            days: [
                DayRollup(dayKey: "not-a-day", tokens: 5, prompts: 1, cost: nil),
                DayRollup(dayKey: "2026-08-16", tokens: 7, prompts: 1, cost: nil),
            ],
            modelDays: [], hourDays: [])
        let days = DigestActivity.daily(from: rollup, calendar: utc)
        #expect(days.map(\.tokens) == [7])
    }

    @Test("a session card becomes a summary whose tokens ride the heaviest model")
    func sessionsFromCards() throws {
        let sessions = DigestActivity.sessions(from: golden.sessions, models: golden.models)
        #expect(sessions.map(\.id) == golden.sessions.map(\.id))
        let first = try #require(sessions.first)
        let card = try #require(golden.sessions.first)
        #expect(first.title == card.title)
        #expect(first.end == card.end)
        let heaviest = try #require(golden.models.max { $0.tally.total < $1.tally.total })
        #expect(Array(first.models.keys) == [heaviest.id])
        // Rounded per class, so within a token of the card's total per class.
        #expect(abs(first.totalTokens - card.tokens) <= 5)
        // A card with no tokens names no model rather than a zero tally.
        let empty = try #require(sessions.first { $0.id == "session-b" })
        #expect(empty.models.isEmpty)
    }
}
