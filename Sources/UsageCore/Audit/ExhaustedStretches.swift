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

    /// Lays the activity stretches and the spent spans onto one strip.
    ///
    /// A spent span draws CONTINUOUSLY, whether or not anything ran during
    /// it — being locked out is the fact the strip is reporting, and the
    /// red must be the same length as the red region above it. (The strip
    /// already treats the PROJECTED dead zone this way: one nub across the
    /// whole unreachable stretch.) Activity keeps only what lies outside
    /// those spans, so a session straddling the crossing still shows the
    /// part that landed while the limit was live, and nothing double-draws.
    ///
    /// `spans` must be chronological and disjoint.
    public static func mark(
        _ stretches: [DateInterval], exhausted spans: [DateInterval]
    ) -> [Stretch] {
        guard !spans.isEmpty else {
            return stretches.map { Stretch(span: $0, isExhausted: false) }
        }
        let live = stretches.flatMap { stretch in
            subtracting(spans, from: stretch).map { Stretch(span: $0, isExhausted: false) }
        }
        let spent = spans.map { Stretch(span: $0, isExhausted: true) }
        return (live + spent).sorted { $0.span.start < $1.span.start }
    }

    /// What remains of `stretch` once every span is cut out of it. Spans are
    /// chronological and disjoint, so one forward walk suffices.
    private static func subtracting(
        _ spans: [DateInterval], from stretch: DateInterval
    ) -> [DateInterval] {
        var remaining: [DateInterval] = []
        var cursor = stretch.start
        for span in spans where span.end > stretch.start && span.start < stretch.end {
            if span.start > cursor {
                remaining.append(DateInterval(start: cursor, end: span.start))
            }
            cursor = max(cursor, span.end)
        }
        if cursor < stretch.end {
            remaining.append(DateInterval(start: cursor, end: stretch.end))
        }
        return remaining
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
