import Foundation
import Testing

@testable import UsageCore

/// Which samples are a limit window's OWN. The poll that lands on the
/// boundary still reports the window it is leaving, so the selection goes by
/// reset stamp; time alone let the old window's height enter the new one and
/// priced its tokens several times over (user-reported 2026-09-24).
@Suite("Window samples")
struct WindowSamplesTests {
    private let label = "Session (5h)"

    /// The live shape, to the second: a 5h window running 15:39:59Z →
    /// 20:39:59Z, with the previous one ending exactly where it starts.
    private let windowStart = Date(timeIntervalSince1970: 1_758_728_399)
    private var windowEnd: Date { windowStart.addingTimeInterval(5 * 3600) }

    private func at(_ seconds: TimeInterval) -> Date {
        windowStart.addingTimeInterval(seconds)
    }

    private func sample(_ t: Date, _ percent: Int, stamp: Date?) -> UsageSample {
        UsageSample(t: t, percents: [label: percent], resets: stamp.map { [label: $0] })
    }

    /// The four polls the bug was reported from. The 15:36:57Z poll is
    /// out of the window and only seeds the stamp memory; the 15:39:59Z one
    /// sits exactly ON the boundary, reports the OLD window's 79%, and the
    /// API blanked its stamp.
    private var live: [UsageSample] {
        [
            sample(at(-182), 78, stamp: windowStart),
            sample(at(0), 79, stamp: nil),
            sample(at(183), 0, stamp: windowEnd.addingTimeInterval(1)),
            sample(at(364), 1, stamp: windowEnd),
            sample(at(3600), 13, stamp: windowEnd),
        ]
    }

    @Test("the boundary poll still carrying the old window's stamp is dropped")
    func aStampedBoundaryPollBelongsToTheWindowItNames() {
        // Same moment as the window's start, but the stamp says otherwise.
        let samples = [
            sample(at(0), 79, stamp: windowStart),
            sample(at(183), 0, stamp: windowEnd),
        ]
        let percents = WindowSamples.percents(
            samples, label: label, start: windowStart, end: at(3600), reset: windowEnd)

        #expect(percents == [0])
    }

    @Test("a blank stamp on the boundary is read as the old window's")
    func aBlankBoundaryPollIsAttributedToTheWindowItLeft() {
        let percents = WindowSamples.percents(
            live, label: label, start: windowStart, end: at(3600), reset: windowEnd)

        // 79 is the previous window's last word, not this window's first.
        #expect(percents == [0, 1, 13])
    }

    @Test("stamp jitter inside the tolerance is the same window")
    func jitterKeepsTheSample() {
        // The 15:43:02Z poll stamped 20:40:00Z against a meter resetting at
        // 20:39:59Z: one second of API noise, one window.
        let kept = WindowSamples.own(
            live, label: label, start: windowStart, end: at(3600), reset: windowEnd)

        #expect(kept.map(\.t) == [at(183), at(364), at(3600)])
        #expect(kept.first?.resets?[label] == windowEnd.addingTimeInterval(1))
    }

    @Test("a grant that blanked the stamp mid-window keeps its samples")
    func aBlankStampInsideTheWindowInheritsIt() throws {
        // The 2026-09-04 shape: the vendor zeroed the meter mid-window and
        // the API then omitted `resets_at` until usage resumed. Those polls
        // are this window's — `ResetCarry` carries the stamp into them,
        // since it is still ahead of them.
        let granted = [
            sample(at(600), 60, stamp: windowEnd),
            sample(at(1_200), 0, stamp: nil),
            sample(at(1_800), 5, stamp: nil),
        ]
        let kept = WindowSamples.own(
            granted, label: label, start: windowStart, end: at(3600), reset: windowEnd)

        #expect(kept.map { $0.percents[label] } == [60, 0, 5])
        // The carry, not the time bounds, is what kept them.
        #expect(kept[1].resets?[label] == windowEnd)
        #expect(ModelCurves.holdsGrant(percents: kept.compactMap { $0.percents[label] }))
    }

    @Test("history written before samples carried stamps is kept on time alone")
    func legacySamplesAreKept() {
        let legacy = [
            sample(at(-182), 78, stamp: nil),
            sample(at(0), 79, stamp: nil),
            sample(at(183), 5, stamp: nil),
        ]
        let percents = WindowSamples.percents(
            legacy, label: label, start: windowStart, end: at(3600), reset: windowEnd)

        // Nothing was ever observed to classify against, so nothing is
        // dropped — a blank history must not become an empty window.
        #expect(percents == [79, 5])
    }

    @Test("an unknown window classifies nothing, but the bounds still bind")
    func noResetKeepsEveryInRangeSample() {
        #expect(
            WindowSamples.percents(
                live, label: label, start: windowStart, end: at(3600), reset: nil)
                == [79, 0, 1, 13])
        // Out of range is out, stamp or no stamp: the 15:36:57Z poll before
        // the start and the 16:39:59Z one past the end.
        #expect(
            WindowSamples.percents(
                live, label: label, start: windowStart, end: at(400), reset: nil)
                == [79, 0, 1])
    }

    @Test("a sample without this meter's percent is not the window's")
    func aMeterWithNoPercentContributesNothing() {
        let other = [
            UsageSample(t: at(100), percents: ["Weekly": 40], resets: [:]),
            sample(at(200), 6, stamp: windowEnd),
        ]
        #expect(
            WindowSamples.percents(
                other, label: label, start: windowStart, end: at(3600), reset: windowEnd)
                == [6])
    }

    @Test("out-of-order samples are ordered before the stamps are carried")
    func unsortedInputIsSortedFirst() {
        let percents = WindowSamples.percents(
            Array(live.reversed()), label: label, start: windowStart, end: at(3600),
            reset: windowEnd)

        #expect(percents == [0, 1, 13])
    }

    @Test("the window's own percents anchor its own gains, not the last one's")
    func theAnchorReadsOnlyThisWindowsGains() throws {
        let percents = WindowSamples.percents(
            live, label: label, start: windowStart, end: at(3600), reset: windowEnd)
        // 13 points over 130,000 tokens = 0.0001 %/token. Time alone would
        // have read [79, 0, 1, 13]: 79 + 13 = 92 gains, seven times the rate
        // and seven times the curve height.
        #expect(ModelCurves.windowPercentPerToken(percents: percents, tokens: 130_000) == 0.0001)
        #expect(
            ModelCurves.windowPercentPerToken(
                percents: [79, 0, 1, 13], tokens: 130_000)
                != ModelCurves.windowPercentPerToken(percents: percents, tokens: 130_000))
        // And 79 → 0 no longer reads as a vendor grant, so the Current
        // span's curves keep their cap.
        #expect(!ModelCurves.holdsGrant(percents: percents))
        #expect(ModelCurves.holdsGrant(percents: [79, 0, 1, 13]))
    }
}
