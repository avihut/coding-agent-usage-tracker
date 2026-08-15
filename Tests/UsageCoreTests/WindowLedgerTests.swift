import Foundation
import Testing
@testable import UsageCore

@Suite("WindowLedger")
struct WindowLedgerTests {
    private func date(_ iso: String) -> Date {
        FlexibleISO8601.date(from: iso)!
    }

    private func meter(
        id: String = "0-session", label: String = "Session (5h)", percent: Int?,
        resetsAt: Date?, limitWindow: TimeInterval? = 5 * 3600
    ) -> Meter {
        Meter(
            id: id, label: label, percent: percent, resetsAt: resetsAt,
            level: .normal, rank: 0, limitWindow: limitWindow)
    }

    @Test("a forward-rolled reset stamp closes the old window")
    func closesOnRoll() throws {
        let oldReset = date("2026-08-16T03:00:00.000Z")
        let now = date("2026-08-16T03:10:00.000Z")
        let samples = [
            // Before the window: must not feed the peak.
            UsageSample(t: date("2026-08-15T21:00:00.000Z"), percents: ["Session (5h)": 96]),
            UsageSample(t: date("2026-08-16T00:00:00.000Z"), percents: ["Session (5h)": 40]),
            UsageSample(t: date("2026-08-16T01:30:00.000Z"), percents: ["Session (5h)": 88]),
            UsageSample(t: date("2026-08-16T02:55:00.000Z"), percents: ["Session (5h)": 53]),
        ]
        let closed = WindowLedger.closedWindows(
            previous: [meter(percent: 53, resetsAt: oldReset)],
            current: [meter(percent: 4, resetsAt: date("2026-08-16T08:00:00.000Z"))],
            samples: samples, now: now)
        #expect(closed.count == 1)
        let outcome = try #require(closed.first)
        #expect(outcome.end == oldReset)
        #expect(outcome.start == date("2026-08-15T22:00:00.000Z"))
        #expect(outcome.lastPercent == 53)
        // In-window max (88), not the pre-window 96 and not the last 53.
        #expect(outcome.peakPercent == 88)
        #expect(!outcome.reachedLimit)
    }

    @Test("an unchanged stamp closes nothing")
    func noRoll() {
        let reset = date("2026-08-16T03:00:00.000Z")
        let closed = WindowLedger.closedWindows(
            previous: [meter(percent: 50, resetsAt: reset)],
            current: [meter(percent: 60, resetsAt: reset)],
            samples: [], now: date("2026-08-16T02:00:00.000Z"))
        #expect(closed.isEmpty)
    }

    @Test("a stamp still deep in the future is weirdness, not a close")
    func futureStampGuard() {
        let closed = WindowLedger.closedWindows(
            previous: [meter(percent: 50, resetsAt: date("2026-08-16T09:00:00.000Z"))],
            current: [meter(percent: 1, resetsAt: date("2026-08-16T14:00:00.000Z"))],
            samples: [], now: date("2026-08-16T03:00:00.000Z"))
        #expect(closed.isEmpty)
    }

    @Test("the peak never reads below the last observation")
    func peakFloorsAtLast() {
        let oldReset = date("2026-08-16T03:00:00.000Z")
        // Sparse polling saw nothing in-window; the last reading is all we
        // know — and 100 there means the limit was reached.
        let closed = WindowLedger.closedWindows(
            previous: [meter(percent: 100, resetsAt: oldReset)],
            current: [meter(percent: 2, resetsAt: date("2026-08-16T08:00:00.000Z"))],
            samples: [], now: date("2026-08-16T03:05:00.000Z"))
        #expect(closed.first?.peakPercent == 100)
        #expect(closed.first?.reachedLimit == true)
    }

    @Test("record dedups by window identity and persists round-trip")
    func recordAndReload() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "window-ledger-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = WindowLedger(directory: directory)
        let outcome = WindowOutcome(
            meterID: "0-session", label: "Session (5h)",
            end: date("2026-08-16T03:00:00.000Z"),
            start: date("2026-08-15T22:00:00.000Z"),
            lastPercent: 53, peakPercent: 88,
            recordedAt: date("2026-08-16T03:10:00.000Z"))
        let first = ledger.record([outcome], existing: [])
        #expect(first.count == 1)
        // The same close observed again (e.g. a re-compare) records once.
        let second = ledger.record([outcome], existing: first)
        #expect(second.count == 1)
        #expect(ledger.load() == second)
    }
}
