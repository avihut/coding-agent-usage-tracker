import Foundation

/// The spans a meter spent already exhausted — from the moment its limit
/// actually ran out to the reset that gave it back. A meter that hit 100%
/// on Saturday and sat there until Sunday's reset spent that whole stretch
/// unable to do anything; the charts draw it red so the history says so.
///
/// This is a RECALLED fact, not a projection. The crossing comes from
/// `PredictionEngine.spentAt` — the same rule the live meter uses for its
/// own window and the same one behind the "spent at 15:04" caption — so a
/// stretch can never start at a different instant than the text claims.
/// The live window is not our business: its dead zone already comes from
/// the prediction's `exhaustsAt`. We answer for windows that have CLOSED.
public enum ExhaustedStretches {
    /// A slice of activity and whether the limit was already gone during it.
    public struct Stretch: Equatable, Sendable {
        public let span: DateInterval
        public let isExhausted: Bool

        public init(span: DateInterval, isExhausted: Bool) {
            self.span = span
            self.isExhausted = isExhausted
        }
    }

    /// Re-cuts activity stretches against the spans the limit was spent
    /// through, so one that straddles the moment the meter ran out comes
    /// back as two pieces. The crossing lands mid-session far more often
    /// than on a stretch boundary, and a whole session flipped red on
    /// account of its last minute would misreport when work stopped
    /// landing.
    ///
    /// `spans` must be chronological and disjoint — one forward walk per
    /// stretch is what keeps this linear.
    public static func mark(
        _ stretches: [DateInterval], exhausted spans: [DateInterval]
    ) -> [Stretch] {
        guard !spans.isEmpty else {
            return stretches.map { Stretch(span: $0, isExhausted: false) }
        }
        return stretches.flatMap { stretch -> [Stretch] in
            var pieces: [Stretch] = []
            var cursor = stretch.start
            for span in spans where span.end > stretch.start && span.start < stretch.end {
                let spentStart = max(span.start, stretch.start)
                let spentEnd = min(span.end, stretch.end)
                if spentStart > cursor {
                    pieces.append(Stretch(
                        span: DateInterval(start: cursor, end: spentStart),
                        isExhausted: false))
                }
                pieces.append(Stretch(
                    span: DateInterval(start: spentStart, end: spentEnd),
                    isExhausted: true))
                cursor = spentEnd
            }
            if pieces.isEmpty { return [Stretch(span: stretch, isExhausted: false)] }
            if cursor < stretch.end {
                pieces.append(Stretch(
                    span: DateInterval(start: cursor, end: stretch.end),
                    isExhausted: false))
            }
            return pieces
        }
    }

    /// One stretch per closed window that reached its limit, clipped to
    /// `domain` and dropped when the clip leaves nothing. `resets` are the
    /// cliff instants — each one ends the window that reached back `window`
    /// before it.
    public static func build(
        resets: [Date], window: TimeInterval, meterLabel: String,
        samples: [UsageSample], domain: DateInterval
    ) -> [DateInterval] {
        resets.compactMap { reset in
            let windowStart = reset.addingTimeInterval(-window)
            // Bounded at BOTH ends: an open-ended search would hand back the
            // newest window's crossing for every reset in the span.
            guard let spent = PredictionEngine.spentAt(
                samples: samples, label: meterLabel,
                since: windowStart, until: reset)
            else { return nil }
            let start = max(spent, domain.start)
            let end = min(reset, domain.end)
            // A stretch clipped to nothing isn't drawable, and a zero-width
            // one would render as a dot the user would read as a glitch.
            guard end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
    }
}
