import Foundation
import Testing
@testable import UsageCore

@Suite("WindowTokens")
struct WindowTokensTests {
    static func minute(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_785_600_000 + TimeInterval(offset * 60))
    }

    static let timeline = [
        TokenSlot(t: minute(0), model: "claude-fable-5",
                  tally: TokenTally(input: 10, output: 5, cacheCreation: 100, cacheRead: 1000)),
        TokenSlot(t: minute(1), model: "claude-haiku-4-5-20251001",
                  tally: TokenTally(input: 7, output: 3)),
        TokenSlot(t: minute(2), model: "claude-fable-5",
                  tally: TokenTally(input: 1, output: 2)),
        TokenSlot(t: minute(10), model: "claude-fable-5",
                  tally: TokenTally(input: 999, output: 999)),
    ]

    @Test("breakdown sums per model inside the window, heaviest first")
    func breakdown() {
        let rows = WindowTokens.breakdown(
            timeline: Self.timeline, from: Self.minute(0), to: Self.minute(5))

        #expect(rows.map(\.model) == ["claude-fable-5", "claude-haiku-4-5-20251001"])
        #expect(rows[0].tally == TokenTally(input: 11, output: 7, cacheCreation: 100, cacheRead: 1000))
        #expect(rows[1].tally == TokenTally(input: 7, output: 3))
        #expect(WindowTokens.total(rows).total == 1128)
    }

    @Test("slots outside the window are excluded entirely")
    func windowEdges() {
        let rows = WindowTokens.breakdown(
            timeline: Self.timeline, from: Self.minute(1), to: Self.minute(2))

        #expect(WindowTokens.total(rows) == TokenTally(input: 8, output: 5))
    }

    @Test("scoped keeps only models matching the display name, case-insensitively")
    func scoped() {
        let rows = WindowTokens.breakdown(
            timeline: Self.timeline, from: Self.minute(0), to: Self.minute(5))

        #expect(WindowTokens.scoped(rows, name: "Fable").map(\.model) == ["claude-fable-5"])
        #expect(WindowTokens.scoped(rows, name: "Opus").isEmpty)
        #expect(WindowTokens.scoped(rows, name: "") == rows)
    }

    @Test("rows orders a models map heaviest first")
    func rows() {
        let rows = WindowTokens.rows(from: [
            "claude-haiku-4-5-20251001": TokenTally(input: 7, output: 3),
            "claude-fable-5": TokenTally(input: 10, output: 5, cacheRead: 1000),
        ])
        #expect(rows.map(\.model) == ["claude-fable-5", "claude-haiku-4-5-20251001"])
        #expect(rows[0].displayName == "Fable 5")
    }

    @Test("tally line: compact counts, cached share only when input exists")
    func tallyText() {
        #expect(UsageFormatting.tallyText(
            TokenTally(input: 10, output: 5, cacheCreation: 100, cacheRead: 1000))
            == "1.1K in · 5 out · 90% cached")
        #expect(UsageFormatting.tallyText(TokenTally(input: 500, output: 20))
            == "500 in · 20 out · 0% cached")
        #expect(UsageFormatting.tallyText(TokenTally(output: 5)) == "0 in · 5 out")
    }

    @Test("tally derived values: input side, total, cached share")
    func tallyMath() {
        let tally = TokenTally(input: 10, output: 5, cacheCreation: 100, cacheRead: 1000)
        #expect(tally.inputSide == 1110)
        // Fresh processing vs cache re-reads partition the input side.
        #expect(tally.uncachedInput == 110)
        #expect(tally.uncachedInput + tally.cacheRead == tally.inputSide)
        #expect(tally.total == 1115)
        #expect(tally.cachedShare! > 0.90 && tally.cachedShare! < 0.91)
        // Output-only work has no input side to take a share of.
        #expect(TokenTally(output: 5).cachedShare == nil)
    }
}

@Suite("ModelNames")
struct ModelNamesTests {
    @Test("current, dated, legacy, and unknown ids")
    func display() {
        #expect(ModelNames.display("claude-fable-5") == "Fable 5")
        #expect(ModelNames.display("claude-opus-5") == "Opus 5")
        #expect(ModelNames.display("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(ModelNames.display("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ModelNames.display("claude-2") == "Claude 2")
        #expect(ModelNames.display("unknown") == "Other")
        // Ids that don't follow the scheme pass through untouched.
        #expect(ModelNames.display("some-other-model") == "some-other-model")
    }
}
