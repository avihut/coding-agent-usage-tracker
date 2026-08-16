import Foundation
import Testing

@testable import UsageCore

@Suite("Exhausted stretches")
struct ExhaustedStretchesTests {
    private let label = "week"
    private let window: TimeInterval = 7 * 86400

    private func sample(_ t: Date, _ percent: Int) -> UsageSample {
        UsageSample(t: t, percents: [label: percent])
    }

    private func at(_ hoursFromEpoch: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: hoursFromEpoch * 3600)
    }

    /// The stretch runs from the FIRST sample that read 100 to the reset —
    /// not from the last one, and not from the window's start.
    @Test func stretchRunsFromTheCrossingToTheReset() {
        let reset = at(100)
        let samples = [
            sample(at(90), 40), sample(at(94), 88),
            sample(at(96), 100), sample(at(98), 100),
        ]
        let stretches = ExhaustedStretches.build(
            resets: [reset], window: window, meterLabel: label, samples: samples,
            domain: DateInterval(start: at(80), end: at(110)))

        #expect(stretches.count == 1)
        #expect(stretches.first?.start == at(96))
        #expect(stretches.first?.end == reset)
    }

    /// A window that never reached its limit contributes nothing — absent,
    /// not a zero-width interval.
    @Test func aWindowThatNeverFilledHasNoStretch() {
        let samples = [sample(at(90), 40), sample(at(96), 91)]
        let stretches = ExhaustedStretches.build(
            resets: [at(100)], window: window, meterLabel: label, samples: samples,
            domain: DateInterval(start: at(80), end: at(110)))

        #expect(stretches.isEmpty)
    }

    /// The reason `spentAt` grew an `until`: with only a `since` bound, the
    /// search for an EARLIER window would run past its reset and return the
    /// LATER window's crossing, painting the gap between them red too.
    @Test func eachWindowRecallsItsOwnCrossing() {
        let firstReset = at(100)
        let secondReset = at(100 + 168)
        let samples = [
            sample(at(96), 100),            // first window ran out here
            sample(at(101), 5),             // reset dropped it
            sample(at(200), 60),
            sample(at(260), 100),           // second window ran out here
        ]
        let stretches = ExhaustedStretches.build(
            resets: [firstReset, secondReset], window: window, meterLabel: label,
            samples: samples, domain: DateInterval(start: at(80), end: at(300)))

        #expect(stretches.count == 2)
        #expect(stretches.first?.start == at(96))
        #expect(stretches.first?.end == firstReset)
        #expect(stretches.last?.start == at(260))
        #expect(stretches.last?.end == secondReset)
    }

    /// Clipped to the drawn span, and dropped entirely when the clip leaves
    /// nothing — a stretch wholly before the domain must not smear onto it.
    @Test func stretchesClipToTheDrawnSpan() {
        let reset = at(100)
        let samples = [sample(at(90), 100)]
        let clipped = ExhaustedStretches.build(
            resets: [reset], window: window, meterLabel: label, samples: samples,
            domain: DateInterval(start: at(95), end: at(110)))
        #expect(clipped.first?.start == at(95))
        #expect(clipped.first?.end == reset)

        let outside = ExhaustedStretches.build(
            resets: [reset], window: window, meterLabel: label, samples: samples,
            domain: DateInterval(start: at(120), end: at(140)))
        #expect(outside.isEmpty)
    }

    /// A session straddling the crossing splits: the work that landed
    /// before the limit went is still live, only the tail is spent. Flipping
    /// the whole session red would misreport when work stopped landing.
    @Test func aSessionStraddlingTheCrossingSplits() {
        let pieces = ExhaustedStretches.mark(
            [DateInterval(start: at(90), end: at(99))],
            exhausted: [DateInterval(start: at(96), end: at(100))])

        #expect(pieces.count == 2)
        #expect(pieces.first?.isExhausted == false)
        #expect(pieces.first?.span == DateInterval(start: at(90), end: at(96)))
        #expect(pieces.last?.isExhausted == true)
        #expect(pieces.last?.span == DateInterval(start: at(96), end: at(99)))
    }

    /// A session wholly inside a spent span is spent end to end — one piece,
    /// not three empty ones.
    @Test func aSessionInsideASpentSpanStaysWhole() {
        let pieces = ExhaustedStretches.mark(
            [DateInterval(start: at(97), end: at(99))],
            exhausted: [DateInterval(start: at(96), end: at(100))])

        #expect(pieces.count == 1)
        #expect(pieces.first?.isExhausted == true)
        #expect(pieces.first?.span == DateInterval(start: at(97), end: at(99)))
    }

    /// Two spent spans across one long session alternate live/spent/live.
    @Test func multipleSpansAlternateAcrossOneSession() {
        let pieces = ExhaustedStretches.mark(
            [DateInterval(start: at(90), end: at(120))],
            exhausted: [
                DateInterval(start: at(95), end: at(100)),
                DateInterval(start: at(110), end: at(115)),
            ])

        #expect(pieces.map(\.isExhausted) == [false, true, false, true, false])
        #expect(pieces.first?.span.start == at(90))
        #expect(pieces.last?.span.end == at(120))
    }

    /// Untouched sessions come back whole and live — no spurious splitting.
    @Test func sessionsClearOfEverySpanAreUntouched() {
        let session = DateInterval(start: at(80), end: at(85))
        let pieces = ExhaustedStretches.mark(
            [session], exhausted: [DateInterval(start: at(96), end: at(100))])

        #expect(pieces.count == 1)
        #expect(pieces.first?.isExhausted == false)
        #expect(pieces.first?.span == session)
    }

    /// A meter with no reading for this label can't have run out.
    @Test func anotherMetersReadingsAreNotOurs() {
        let samples = [UsageSample(t: at(96), percents: ["session": 100])]
        let stretches = ExhaustedStretches.build(
            resets: [at(100)], window: window, meterLabel: label, samples: samples,
            domain: DateInterval(start: at(80), end: at(110)))

        #expect(stretches.isEmpty)
    }
}
