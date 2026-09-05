import Foundation
import Testing

@testable import UsageCore

@Suite("Reset carry")
struct ResetCarryTests {
    private let label = "Weekly"

    private func at(_ hours: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: hours * 3600)
    }

    private func sample(_ t: Double, _ percent: Int, reset: Double? = nil) -> UsageSample {
        UsageSample(
            t: at(t), percents: [label: percent],
            resets: reset.map { [label: at($0)] })
    }

    private func meter(_ percent: Int?, reset: Date?) -> Meter {
        Meter(
            id: "w", label: label, percent: percent, resetsAt: reset,
            level: .normal, rank: 1, limitWindow: 7 * 86400)
    }

    /// The shape observed 2026-09-04: a stamped 30% poll, then a zeroed
    /// poll with no stamp while the window was still running.
    @Test func aStampStillAheadIsCarried() {
        let samples = [sample(1, 20, reset: 100), sample(2, 30, reset: 100)]
        #expect(ResetCarry.carried(label: label, samples: samples, now: at(6)) == at(100))
    }

    @Test func aStampAlreadyPassedIsNotCarried() {
        // A 5h session that ended while idle: the API's silence is the truth.
        let samples = [sample(1, 20, reset: 5), sample(2, 30, reset: 5)]
        #expect(ResetCarry.carried(label: label, samples: samples, now: at(6)) == nil)
    }

    @Test func nothingObservedCarriesNothing() {
        #expect(ResetCarry.carried(label: label, samples: [], now: at(6)) == nil)
        #expect(ResetCarry.carried(
            label: label, samples: [sample(1, 20)], now: at(6)) == nil)
        // Another meter's stamp is not this meter's.
        let other = [UsageSample(t: at(1), percents: ["S": 4], resets: ["S": at(100)])]
        #expect(ResetCarry.carried(label: label, samples: other, now: at(6)) == nil)
    }

    /// The most recent OBSERVED stamp wins, even past a run of stampless
    /// polls — and its own age decides, not the run's.
    @Test func theLatestObservedStampWinsAcrossAGap() {
        let samples = [
            sample(1, 20, reset: 50), sample(2, 0), sample(3, 5, reset: 100), sample(4, 0),
        ]
        #expect(ResetCarry.carried(label: label, samples: samples, now: at(6)) == at(100))
    }

    @Test func aStamplessMeterInheritsTheCarriedStamp() {
        let samples = [sample(2, 30, reset: 100)]
        let snapshot = Snapshot(meters: [meter(0, reset: nil)], fetchedAt: at(6))
        let filled = ResetCarry.fill(snapshot, samples: samples, now: at(6))
        #expect(filled.meters.first?.resetsAt == at(100))
        #expect(filled.meters.first?.percent == 0)
        #expect(filled.meters.first?.limitWindow == 7.0 * 86400)
    }

    @Test func aReportedStampIsNeverOverridden() {
        let samples = [sample(2, 30, reset: 100)]
        let snapshot = Snapshot(meters: [meter(3, reset: at(200))], fetchedAt: at(6))
        let filled = ResetCarry.fill(snapshot, samples: samples, now: at(6))
        #expect(filled == snapshot)
    }

    /// The series form heals the gap already sitting in history.json: the
    /// stampless zero between two polls stamped with the same window end
    /// inherits it, so the cliff detector sees an unmoved stamp.
    @Test func aSeriesGapInheritsTheStampWhileItIsAhead() {
        let samples = [
            sample(1, 30, reset: 100), sample(2, 0), sample(3, 0, reset: 100),
        ]
        let filled = ResetCarry.fill(samples)
        #expect(filled.map { $0.resets?[label] } == [at(100), at(100), at(100)])
        #expect(filled.map { $0.percents[label] } == [30, 0, 0])
    }

    @Test func aSeriesStopsCarryingOnceTheStampHasPassed() {
        let samples = [sample(1, 30, reset: 5), sample(4, 0), sample(6, 0), sample(7, 2)]
        let filled = ResetCarry.fill(samples)
        #expect(filled.map { $0.resets?[label] } == [at(5), at(5), nil, nil])
    }

    @Test func aLabelWithoutAPercentGainsNoStamp() {
        let samples = [
            sample(1, 30, reset: 100),
            UsageSample(t: at(2), percents: ["S": 1], resets: nil),
        ]
        let filled = ResetCarry.fill(samples)
        #expect(filled[1].resets == nil)
        #expect(filled[1] == samples[1])
    }
}
