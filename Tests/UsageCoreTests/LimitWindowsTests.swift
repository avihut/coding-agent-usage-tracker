import Foundation
import Testing

@testable import UsageCore

@Suite("Limit windows")
struct LimitWindowsTests {
    private let hour: TimeInterval = 3600
    private let now = Date(timeIntervalSinceReferenceDate: 100 * 3600)

    private func at(_ hours: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: hours * 3600)
    }

    private func sample(_ t: Double, reset: Double, label: String = "Session") -> UsageSample {
        UsageSample(t: at(t), percents: [label: 10], resets: [label: at(reset)])
    }

    /// Stamps seen in samples become windows, newest first, each ending at
    /// its stamp and reaching back one limit window; the live window's own
    /// stamp is not a past window.
    @Test func windowsComeFromObservedStampsNewestFirst() {
        let samples = [
            sample(1, reset: 5), sample(2, reset: 5),
            sample(6, reset: 11), sample(9, reset: 11),
            sample(96, reset: 101),
        ]
        let windows = LimitWindows.observed(
            label: "Session", window: 5 * hour, liveReset: at(101),
            samples: samples, outcomes: [], now: now)

        #expect(windows == [
            DateInterval(start: at(6), end: at(11)),
            DateInterval(start: at(0), end: at(5)),
        ])
    }

    /// The API restates a stamp with sub-second noise on every poll; every
    /// jittered restatement of one window collapses to a single page.
    @Test func jitteredStampsCollapseToOneWindow() {
        let base = at(11)
        let samples = [
            UsageSample(t: at(6), percents: ["S": 1], resets: ["S": base]),
            UsageSample(t: at(7), percents: ["S": 2], resets: ["S": base.addingTimeInterval(0.4)]),
            UsageSample(t: at(8), percents: ["S": 3], resets: ["S": base.addingTimeInterval(-0.3)]),
        ]
        let windows = LimitWindows.observed(
            label: "S", window: 5 * hour, liveReset: nil,
            samples: samples, outcomes: [], now: now)

        #expect(windows.count == 1)
    }

    /// Ledger closes count as observations too — a window the samples have
    /// been thinned out of still pages — and a close the samples ALSO saw
    /// is one window, not two.
    @Test func ledgerOutcomesJoinAndDedupAgainstSamples() {
        let samples = [sample(6, reset: 11)]
        let outcomes = [
            WindowOutcome(
                meterID: "0", label: "Session", end: at(11).addingTimeInterval(0.2),
                start: at(6), lastPercent: 40, peakPercent: 40, recordedAt: at(12)),
            WindowOutcome(
                meterID: "0", label: "Session", end: at(30), start: at(25),
                lastPercent: 90, peakPercent: 100, recordedAt: at(31)),
            WindowOutcome(
                meterID: "1", label: "Weekly", end: at(50), start: nil,
                lastPercent: 5, peakPercent: 5, recordedAt: at(51)),
        ]
        let windows = LimitWindows.observed(
            label: "Session", window: 5 * hour, liveReset: at(101),
            samples: samples, outcomes: outcomes, now: now)

        #expect(windows.count == 2)
        // Whichever jittered restatement survives the collapse names the
        // same window — compare within stamp tolerance, not byte-for-byte.
        #expect(abs(windows[0].end.timeIntervalSince(at(30))) < 1)
        #expect(abs(windows[1].end.timeIntervalSince(at(11))) < 1)
    }

    /// A stamp still ahead of now names a window that hasn't closed — never
    /// a page to go back to — and a stale future stamp can't leak in as one.
    @Test func futureStampsAreNotPastWindows() {
        let samples = [sample(96, reset: 101), sample(50, reset: 120)]
        let windows = LimitWindows.observed(
            label: "Session", window: 5 * hour, liveReset: at(101),
            samples: samples, outcomes: [], now: now)

        #expect(windows.isEmpty)
    }

    /// Nothing observed, nothing to page; a degenerate window length yields
    /// nothing rather than zero-length intervals.
    @Test func emptyAndDegenerateInputsYieldNothing() {
        #expect(LimitWindows.observed(
            label: "Session", window: 5 * hour, liveReset: nil,
            samples: [], outcomes: [], now: now).isEmpty)
        #expect(LimitWindows.observed(
            label: "Session", window: 0, liveReset: nil,
            samples: [sample(1, reset: 5)], outcomes: [], now: now).isEmpty)
    }
}
