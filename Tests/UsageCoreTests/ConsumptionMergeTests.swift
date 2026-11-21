import Foundation
import Testing
@testable import UsageCore

@Suite("Consumption merge")
struct ConsumptionMergeTests {
    static func day(_ dayOfMonth: Int) -> Date {
        HeatmapLayoutTests.day(2026, 8, dayOfMonth)
    }

    static let unpriced = PricingTable(rates: [:], fetchedAt: .distantPast, source: .bundled)

    static func account(
        _ agent: String, _ account: String, pricing: PricingTable = .bundled,
        reportsTokens: Bool = true, _ days: [DailyActivity]
    ) -> AccountConsumption {
        AccountConsumption(
            agent: agent, account: account, days: days, pricing: pricing, reportsTokens: reportsTokens)
    }

    static func entry(_ dayOfMonth: Int, prompts: Int = 0, _ models: [String: Int]) -> DailyActivity {
        let tallies = models.mapValues { TokenTally(input: $0) }
        return DailyActivity(
            day: day(dayOfMonth), tokens: models.values.reduce(0, +), messages: models.count,
            prompts: prompts, models: tallies)
    }

    @Test("two accounts' same day becomes ONE entry whose sums agree with the layout's totals")
    func oneEntryPerDay() {
        let merged = ConsumptionMerge.days([
            Self.account("claude", "default", [Self.entry(5, prompts: 2, ["claude-fable-5": 100])]),
            Self.account("codex", "codex", [Self.entry(5, ["gpt-5.2-codex": 40]), Self.entry(6, ["gpt-5.2-codex": 7])]),
        ])
        #expect(merged.map(\.day) == [Self.day(5), Self.day(6)])
        #expect(merged[0].tokens == 140)
        #expect(merged[0].prompts == 2)
        #expect(merged[0].messages == 2)
        // The layout keeps one entry per day for its cells and sums every
        // entry for its totals — with merged days the two agree.
        let layout = HeatmapLayoutTests.build(merged, dayCount: 7)
        #expect(layout.byDay[Self.day(5)]?.tokens == 140)
        #expect(layout.totalTokens == 147)
    }

    @Test("the same raw model id under two agents stays two keys")
    func noCollision() {
        let merged = ConsumptionMerge.days([
            Self.account("claude", "default", [Self.entry(5, ["unknown": 10])]),
            Self.account("codex", "codex", [Self.entry(5, ["unknown": 3])]),
        ])
        let keys = merged[0].models.keys.sorted()
        #expect(keys.count == 2)
        #expect(keys.allSatisfy { ConsumptionKey.model(of: $0) == "unknown" })
        #expect(merged[0].models[ConsumptionKey.make(agent: "codex", account: "codex", model: "unknown")]?.input == 3)
    }

    @Test("each model is priced by its own harness's table; unpriced stays absent")
    func compositePricing() {
        let table = ConsumptionMerge.pricing([
            Self.account("claude", "default", [Self.entry(5, ["claude-fable-5": 100])]),
            Self.account("codex", "codex", pricing: Self.unpriced, [Self.entry(5, ["gpt-5.2-codex": 40])]),
        ])
        let fable = ConsumptionKey.make(agent: "claude", account: "default", model: "claude-fable-5")
        let codex = ConsumptionKey.make(agent: "codex", account: "codex", model: "gpt-5.2-codex")
        #expect(table.rates(for: fable) == PricingTable.bundled.rates(for: "claude-fable-5"))
        #expect(table.rates(for: codex) == nil)
        // CostIndex over merged days then values exactly the priced model.
        let merged = ConsumptionMerge.days([
            Self.account("claude", "default", [Self.entry(5, ["claude-fable-5": 1_000_000])]),
            Self.account("codex", "codex", pricing: Self.unpriced, [Self.entry(5, ["gpt-5.2-codex": 40])]),
        ])
        let index = CostIndex.build(days: Dictionary(uniqueKeysWithValues: merged.map { ($0.day, $0) }), pricing: table)
        let expected = PricingTable.bundled.rates(for: "claude-fable-5")!.dollars(for: TokenTally(input: 1_000_000))
        #expect(abs(index.total - expected) < 1e-9)
    }

    @Test("merged sessions are newest first across accounts, keep their owner, and follow the interval")
    func sessions() {
        let s = SessionDayGroupTests.summary
        let claude = [s("c2", "2026-08-05T18:00:00.000Z", .interactive), s("c1", "2026-08-03T10:00:00.000Z", .interactive)]
        let codex = [s("x1", "2026-08-04T12:00:00.000Z", .interactive), s("bg", "2026-08-05T20:00:00.000Z", .background)]
        let all = ConsumptionMerge.sessions([("default", claude), ("codex", codex)], in: nil)
        #expect(all.rows.map(\.session.id) == ["c2", "x1", "c1"])
        #expect(all.rows.map(\.owner) == ["default", "codex", "default"])
        #expect(all.hasMore) // the background run is hidden
        let interval = DateInterval(start: Self.day(4), end: Self.day(5))
        let scoped = ConsumptionMerge.sessions([("default", claude), ("codex", codex)], in: interval)
        #expect(scoped.rows.map(\.session.id) == ["x1"])
        #expect(!scoped.hasMore)
    }

    @Test("an agent that reports no tokens adds no days: its prompts are not active days")
    func promptOnlyAddsNothing() {
        let merged = ConsumptionMerge.days([
            Self.account("claude", "default", [Self.entry(5, ["claude-fable-5": 100])]),
            Self.account("gemini", "gemini", reportsTokens: false,
                         [DailyActivity(day: Self.day(6), tokens: 0, messages: 0, prompts: 40)]),
        ])
        #expect(merged.map(\.day) == [Self.day(5)])
        #expect(merged[0].prompts == 0)
    }

    @Test("Show more lands on the account of the newest hidden session")
    func nextOwner() {
        let s = SessionDayGroupTests.summary
        let claude = [s("c3", "2026-08-05T18:00:00.000Z", .interactive), s("c2", "2026-08-05T09:00:00.000Z", .interactive),
                      s("c1", "2026-08-01T10:00:00.000Z", .interactive)]
        let codex = [s("x2", "2026-08-05T12:00:00.000Z", .interactive), s("x1", "2026-08-04T12:00:00.000Z", .interactive)]
        let merged = ConsumptionMerge.sessions([("default", claude), ("codex", codex)], in: nil)
        #expect(merged.rows.map(\.session.id) == ["c3", "x2", "c2"])
        #expect(merged.hasMore)
        #expect(merged.nextOwner == "codex") // x1 (Aug 4) is newer than c1 (Aug 1)
        let all = ConsumptionMerge.sessions([("default", Array(claude.prefix(1))), ("codex", Array(codex.prefix(1)))], in: nil)
        #expect(!all.hasMore)
        #expect(all.nextOwner == nil)
    }

    @Test("an owned session's id is unique across accounts that reuse an id")
    func ownedIdentity() {
        let s = SessionDayGroupTests.summary(id: "same", end: "2026-08-05T18:00:00.000Z")
        #expect(OwnedSession(owner: "default", session: s).id != OwnedSession(owner: "codex", session: s).id)
    }
}
