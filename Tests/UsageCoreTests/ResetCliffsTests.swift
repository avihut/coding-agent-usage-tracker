import Foundation
import Testing

@testable import UsageCore

@Suite("ResetCliffs")
struct ResetCliffsTests {
    private func date(_ t: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: t)
    }

    private func sample(_ t: TimeInterval, _ percent: Int, reset: TimeInterval? = nil)
        -> ResetCliffs.Sample
    {
        ResetCliffs.Sample(t: date(t), percent: percent, resetsAt: reset.map(date))
    }

    @Test("a stamped drop cliffs exactly at the old window's end")
    func stampedCliff() {
        let cliffs = ResetCliffs.cliffs(
            between: [sample(0, 80, reset: 600), sample(3600, 3, reset: 18600)],
            window: 18000, currentReset: date(18600))
        #expect(cliffs == [ResetCliffs.Cliff(at: date(600), from: 80)])
    }

    @Test("a drop with an unmoved stamp is jitter, not a reset")
    func unmoved() {
        let cliffs = ResetCliffs.cliffs(
            between: [sample(0, 80, reset: 9000), sample(600, 70, reset: 9000)],
            window: 18000, currentReset: date(9000))
        #expect(cliffs.isEmpty)
    }

    @Test("an unstamped drop lands on the reset-schedule grid")
    func gridFallback() {
        // Weekly window ending at 1200; current reset one window later.
        let cliffs = ResetCliffs.cliffs(
            between: [sample(0, 90), sample(3600, 5)],
            window: 18000, currentReset: date(19200))
        #expect(cliffs == [ResetCliffs.Cliff(at: date(1200), from: 90)])
    }

    @Test("a small unstamped drop stays a slope — jitter tolerance")
    func smallDrop() {
        let cliffs = ResetCliffs.cliffs(
            between: [sample(0, 80), sample(600, 77)],
            window: 18000, currentReset: date(9000))
        #expect(cliffs.isEmpty)
    }

    @Test("a gap spanning several windows cliffs at the earliest boundary")
    func multiWindow() {
        // Boundaries inside (0, 40000]: 39000, 21000, 3000 — the hold must
        // break where the old window actually ended.
        let cliffs = ResetCliffs.cliffs(
            between: [sample(0, 90), sample(40000, 5)],
            window: 18000, currentReset: date(57000))
        #expect(cliffs == [ResetCliffs.Cliff(at: date(3000), from: 90)])
    }

    @Test("no stamp and no live reset falls back to the gap's midpoint")
    func midpoint() {
        let cliffs = ResetCliffs.cliffs(
            between: [sample(0, 90), sample(4000, 5)],
            window: 18000, currentReset: nil)
        #expect(cliffs == [ResetCliffs.Cliff(at: date(2000), from: 90)])
    }

    @Test("a stamp outside the gap defers to the grid")
    func stampOutside() {
        // The stamp claims a window end after b — inconsistent; the grid
        // line at 1200 wins.
        let cliffs = ResetCliffs.cliffs(
            between: [sample(0, 90, reset: 5000), sample(3600, 5, reset: 19200)],
            window: 18000, currentReset: date(19200))
        #expect(cliffs == [ResetCliffs.Cliff(at: date(1200), from: 90)])
    }

    @Test("a rising series has no cliffs")
    func rising() {
        let cliffs = ResetCliffs.cliffs(
            between: [sample(0, 10), sample(600, 20), sample(1200, 30)],
            window: 18000, currentReset: date(9000))
        #expect(cliffs.isEmpty)
    }

    @Test("empty and single-sample series have no cliffs")
    func degenerate() {
        #expect(ResetCliffs.cliffs(between: [], window: 18000, currentReset: nil).isEmpty)
        #expect(ResetCliffs.cliffs(
            between: [sample(0, 50)], window: 18000, currentReset: nil).isEmpty)
    }

    @Test("samples without reset stamps decode from the legacy history format")
    func legacyDecode() throws {
        let legacy = #"[{"t":776822400,"percents":{"Session":42}}]"#
        let decoded = try JSONDecoder().decode(
            [UsageSample].self, from: Data(legacy.utf8))
        #expect(decoded.first?.resets == nil)
        #expect(decoded.first?.percents["Session"] == 42)
    }
}
