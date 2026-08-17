import Charts
import SwiftUI
import UsageCore

/// The limit-window plot's shared vocabulary. The live meter popover and the
/// read-only audit chart both draw a percent trace over a span with reset
/// cliffs and an activity strip beneath it; every mark that answers a hover
/// the same way in both lives here, so a change lands on both by
/// construction instead of by a second implementation. The audit chart's
/// reset dashes drifting into the system accent (v0.76.2) is what a second
/// implementation costs.
///
/// Deliberately NOT here — the two charts genuinely differ, and unifying
/// would change what ships in one of them:
/// - the y-scale (the popover scales its top from the tallest model curve
///   with a 15% headroom band; the audit chart pins 0…100),
/// - the strip's geometry (a band between stripBottom/stripTop vs a single
///   round-capped rule), so callers draw their own strip and pass nubs here
///   only for the hover curtains,
/// - `liveNub`'s midpoint re-anchoring, which exists because the popover's
///   sliding domain re-anchors at `Date()` every render. The audit chart's
///   domain is fixed and needs none of it.
enum WindowPlot {
    /// A stretch of activity under the plot floor. The richer of the two
    /// shapes the charts used to keep privately: `kind` is what lets a
    /// spent-through stretch read red on both faces from one definition.
    struct Nub: Equatable {
        enum Kind: Equatable {
            case active
            /// A stretch the limit was already spent through — unreachable.
            case exhausted
        }

        let start: Date
        let end: Date
        var kind: Kind = .active
        /// The session's true start when the frame clips its nub at the
        /// domain's left edge — labels and summaries honor it; drawing
        /// keeps `start`.
        var fullStart: Date?

        init(start: Date, end: Date, kind: Kind = .active, fullStart: Date? = nil) {
            self.start = start
            self.end = end
            self.kind = kind
            self.fullStart = fullStart
        }

        var sessionStart: Date { fullStart ?? start }

        func contains(_ moment: Date) -> Bool { start <= moment && moment <= end }
    }

    /// The highlight is everything else dimming — the popover's idiom.
    static let curtain = Color(nsColor: .windowBackgroundColor).opacity(0.5)

    static func nubColor(_ kind: Nub.Kind, accent: Color) -> Color {
        kind == .exhausted ? .red : accent
    }

    /// The hovered nub at full strength; with any nub hovered its peers
    /// recede, along with the curtained graph above them.
    static func nubOpacity(_ nub: Nub, hovered: Nub?) -> Double {
        guard let hovered else { return 0.7 }
        return nub == hovered ? 1 : 0.25
    }

    /// Red diagonal hatching over the spans a limit was — or will be —
    /// unusable. ONE painter for both: the forecast's dead zone past the
    /// projected crossing and the windows that actually ran out and waited
    /// out a reset. They mean the same thing to the user ("nothing could
    /// land here"), so they must not look different; a flat tint for one
    /// and hatching for the other reads as two unrelated features.
    ///
    /// A `chartBackground` painter rather than marks, because the stripes
    /// are screen geometry — a fixed 6pt pitch at a fixed angle, whatever
    /// the domain — and no mark can carry that.
    @ViewBuilder
    static func unusableHatching(
        _ spans: [DateInterval], proxy: ChartProxy, geometry: GeometryProxy
    ) -> some View {
        if let plotFrame = proxy.plotFrame,
           let yTop = proxy.position(forY: 100),
           let yBottom = proxy.position(forY: 0) {
            let plot = geometry[plotFrame]
            Canvas { context, _ in
                for span in spans {
                    guard let xStart = proxy.position(forX: span.start),
                          let xEnd = proxy.position(forX: span.end),
                          xEnd > xStart
                    else { continue }
                    let region = CGRect(
                        x: plot.minX + xStart, y: plot.minY + yTop,
                        width: xEnd - xStart, height: yBottom - yTop)
                    context.drawLayer { layer in
                        layer.clip(to: Path(region))
                        layer.fill(Path(region), with: .color(.red.opacity(0.05)))
                        // Start a full region-height to the left so the
                        // first stripes still cross the region's top-left.
                        var x = region.minX - region.height
                        while x < region.maxX {
                            var stripe = Path()
                            stripe.move(to: CGPoint(x: x, y: region.maxY))
                            stripe.addLine(to: CGPoint(x: x + region.height, y: region.minY))
                            layer.stroke(stripe, with: .color(.red.opacity(0.13)), lineWidth: 1)
                            x += 6
                        }
                    }
                }
            }
        }
    }

    /// Re-cuts the strip's stretches against the spans the limit was spent
    /// through, so a nub that straddles the moment the meter ran out is
    /// drawn half accent, half red. The cutting itself is core's
    /// (`ExhaustedStretches.mark`, where it is tested), and it runs ONCE
    /// over the whole strip: `mark` files every spent span alongside the
    /// cut, so the per-nub loop this replaced filed the same span once per
    /// nub — and filed none at all over a quiet strip. This only carries a
    /// nub's `fullStart` onto the live piece that still begins where the
    /// nub did, so a frame-clipped session keeps reporting its true start.
    static func marking(
        _ nubs: [Nub], exhausted spans: [DateInterval]
    ) -> [Nub] {
        guard !spans.isEmpty else { return nubs }
        return ExhaustedStretches.mark(
            nubs.map { DateInterval(start: $0.start, end: $0.end) },
            exhausted: spans)
            .map { piece in
                Nub(
                    start: piece.span.start, end: piece.span.end,
                    kind: piece.isExhausted ? .exhausted : .active,
                    fullStart: piece.isExhausted ? nil
                        : nubs.first { $0.start == piece.span.start }?.fullStart)
            }
    }

    /// Scaffolding under the data: a muted dashed vertical at each reset in
    /// the frame. Conspicuous on purpose — anything softer vanishes against
    /// the dark material — and the hovered line goes full primary.
    ///
    /// `Color.primary`, never the bare hierarchical `.primary`: inside a
    /// Chart the hierarchical styles resolve against the plot's own
    /// accent-derived foreground rather than the label color.
    @ChartContentBuilder
    static func resets(
        _ dates: [Date], hovered: Date?, ceiling: Double
    ) -> some ChartContent {
        ForEach(dates, id: \.timeIntervalSinceReferenceDate) { reset in
            RuleMark(
                x: .value("Reset", reset),
                yStart: .value("Usage", 0), yEnd: .value("Usage", ceiling))
                .foregroundStyle(Color.primary.opacity(hovered == reset ? 1 : 0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        }
    }

    /// Reset hover: curtain-dim everything outside the limit window that
    /// ended at this line — the undimmed stretch IS the window — with a
    /// solid twin marking where that window began.
    @ChartContentBuilder
    static func resetCurtain(
        _ reset: Date, window: TimeInterval,
        start: Date, end: Date, ceiling: Double
    ) -> some ChartContent {
        let windowStart = max(start, reset.addingTimeInterval(-window))
        RuleMark(
            x: .value("Window start", windowStart),
            yStart: .value("Usage", 0), yEnd: .value("Usage", ceiling))
            .foregroundStyle(Color.primary)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        curtains(around: windowStart, to: reset, start: start, end: end, ceiling: ceiling)
    }

    /// Nub hover: the same curtains, drawn around the hovered slice.
    @ChartContentBuilder
    static func nubCurtain(
        _ nub: Nub, start: Date, end: Date, ceiling: Double
    ) -> some ChartContent {
        curtains(around: nub.start, to: nub.end, start: start, end: end, ceiling: ceiling)
    }

    /// The pair of dimming panels flanking a lit stretch. They stop at the
    /// plot floor (yStart 0), so the activity strip below keeps its own
    /// opacity rather than being greyed twice.
    @ChartContentBuilder
    private static func curtains(
        around litStart: Date, to litEnd: Date,
        start: Date, end: Date, ceiling: Double
    ) -> some ChartContent {
        if litStart > start {
            RectangleMark(
                xStart: .value("Time", start), xEnd: .value("Time", litStart),
                yStart: .value("Usage", 0), yEnd: .value("Usage", ceiling))
                .foregroundStyle(curtain)
        }
        if litEnd < end {
            RectangleMark(
                xStart: .value("Time", litEnd), xEnd: .value("Time", end),
                yStart: .value("Usage", 0), yEnd: .value("Usage", ceiling))
                .foregroundStyle(curtain)
        }
    }

    /// The reset line within grabbing distance of the cursor (~4pt of
    /// track). Reset dates are value-stable across renders, so matching the
    /// stored hover by value is drift-proof. `trackWidth` is the caller's —
    /// the popover measures against its pinned chart width, the audit chart
    /// against the live plot it was handed.
    static func nearestReset(
        to date: Date, in resets: [Date], span: TimeInterval, trackWidth: CGFloat
    ) -> Date? {
        guard trackWidth > 0, span > 0 else { return nil }
        let tolerance = span * 4 / Double(trackWidth)
        return resets
            .min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
            .flatMap { abs($0.timeIntervalSince(date)) <= tolerance ? $0 : nil }
    }
}
