import Foundation
import Testing
@testable import UsageCore

@Suite("CostIndex")
struct CostIndexTests {
    static func day(_ dayOfMonth: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 8, day: dayOfMonth))!
    }

    @Test("prices each day per model, skipping models without rates")
    func build() {
        // Bundled fable-5 rates: input 1e-5, output 5e-5 per token.
        let days: [Date: DailyActivity] = [
            Self.day(1): DailyActivity(
                day: Self.day(1), tokens: 1_100_000, messages: 1,
                models: [
                    "claude-fable-5": TokenTally(input: 1_000_000, output: 100_000),
                    "mystery-model": TokenTally(input: 5_000_000),
                ]),
            Self.day(2): DailyActivity(
                day: Self.day(2), tokens: 500_000, messages: 1,
                models: ["claude-fable-5": TokenTally(input: 500_000)]),
            Self.day(3): DailyActivity(
                day: Self.day(3), tokens: 0, messages: 0, prompts: 3),
        ]
        let index = CostIndex.build(days: days, pricing: .bundled)

        // Day 1: 1M × $10/MTok + 100K × $50/MTok = $15; mystery-model skipped.
        #expect(abs(index.byDay[Self.day(1)]! - 15.0) < 0.0001)
        #expect(abs(index.byDay[Self.day(2)]! - 5.0) < 0.0001)
        #expect(index.byDay[Self.day(3)] == nil)
        #expect(abs(index.total - 20.0) < 0.0001)
        #expect(abs(index.maxByDay - 15.0) < 0.0001)
        #expect(abs(index.modelMax["claude-fable-5"]! - 15.0) < 0.0001)
        #expect(index.modelMax["mystery-model"] == nil)
    }

    @Test("nothing priced degrades to a safe empty index")
    func nothingPriced() {
        let days = [
            Self.day(1): DailyActivity(
                day: Self.day(1), tokens: 100, messages: 1,
                models: ["mystery-model": TokenTally(input: 100)]),
        ]
        let index = CostIndex.build(days: days, pricing: .bundled)

        #expect(index.byDay.isEmpty)
        #expect(index.maxByDay == 1)
        #expect(index.total == 0)
    }
}
