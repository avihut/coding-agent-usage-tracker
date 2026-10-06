import Foundation
import Testing
@testable import UsageCore

@Suite("MeterColumns")
struct MeterColumnsTests {
    private func meter(_ id: String, rank: Int, window: TimeInterval? = nil) -> Meter {
        Meter(id: id, label: id, percent: 10, resetsAt: nil, level: .normal, rank: rank, limitWindow: window)
    }

    private let hour: TimeInterval = 3600

    private func ids(_ rows: [[Meter?]]) -> [[String]] {
        rows.map { row in row.map { $0?.id ?? "·" } }
    }

    @Test("a lone weekly sits under the other accounts' weeklies, a blank cell before it")
    func claudeBesideCodex() {
        let claude = [meter("S", rank: 0, window: 5 * hour), meter("W", rank: 1, window: 168 * hour),
                      meter("F", rank: 2, window: 168 * hour)]
        let codex = [meter("CW", rank: 1, window: 168 * hour)]
        #expect(ids(MeterColumns.arrange([claude, codex])) == [["S", "W", "F"], ["·", "CW", "·"]])
    }

    @Test("two long windows: the shorter is the weekly column, the longer follows; no blank session column")
    func codexWeekAndMonth() {
        let codex = [meter("M", rank: 1, window: 720 * hour), meter("W", rank: 1, window: 168 * hour)]
        #expect(ids(MeterColumns.arrange([codex])) == [["W", "M"]])
    }

    @Test("scoped meters flow after the fixed columns, in the provider's order")
    func twoScoped() {
        let claude = [meter("S", rank: 0, window: 5 * hour), meter("W", rank: 1, window: 168 * hour),
                      meter("F1", rank: 2), meter("F2", rank: 3)]
        let other = [meter("S2", rank: 0, window: 5 * hour)]
        #expect(ids(MeterColumns.arrange([claude, other]))
            == [["S", "W", "F1", "F2"], ["S2", "·", "·", "·"]])
    }

    @Test("a daily-only account keeps the short column; a weekly column nobody has is dropped")
    func geminiDailyOnly() {
        let gemini = [meter("D", rank: 0, window: 24 * hour)]
        #expect(ids(MeterColumns.arrange([gemini])) == [["D"]])
        let codex = [meter("CW", rank: 1, window: 168 * hour)]
        #expect(ids(MeterColumns.arrange([gemini, codex])) == [["D", "·"], ["·", "CW"]])
    }

    @Test("an account with no meters is a blank row, never zeros")
    func empty() {
        let claude = [meter("S", rank: 0), meter("W", rank: 1)]
        #expect(ids(MeterColumns.arrange([claude, []])) == [["S", "W"], ["·", "·"]])
        #expect(MeterColumns.arrange([]).isEmpty)
    }
}
