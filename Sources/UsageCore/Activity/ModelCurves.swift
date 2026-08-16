import Foundation

/// Per-model cumulative curves laid onto a meter's percent axis — the
/// overlay both limit-window charts draw over their percent trace.
///
/// The hard part is the axis, not the curves. A percent line sawtooths at
/// every reset while cumulative tokens only ever climb, so the two can only
/// share a y-axis through a rate: how much percent one token buys. Measure
/// that on the gains the span actually shows and the curves read as
/// fractions of a single limit — honestly exceeding it when the span holds
/// more than one window.
public enum ModelCurves {
    public struct Moment: Equatable, Sendable {
        public let model: String
        public let t: Date
        public let amount: Int

        public init(model: String, t: Date, amount: Int) {
            self.model = model
            self.t = t
            self.amount = amount
        }
    }

    public struct Point: Equatable, Sendable {
        public let t: Date
        public let value: Double

        public init(t: Date, value: Double) {
            self.t = t
            self.value = value
        }
    }

    public struct Curve: Equatable, Sendable {
        public let model: String
        public let points: [Point]

        public init(model: String, points: [Point]) {
            self.model = model
            self.points = points
        }

        public var peak: Double { points.map(\.value).max() ?? 0 }
    }

    /// The percent one token buys, read off the span itself: the percent
    /// GAINED across it over the tokens spent in it. Drops are excluded —
    /// summing raw deltas would let a sawtooth cancel itself to nothing.
    /// Nil when the span holds no growth or no tokens, which is the caller's
    /// cue to fall back to a shape-only scale.
    public static func gainsPercentPerToken(percents: [Int], tokens: Int) -> Double? {
        guard tokens > 0 else { return nil }
        let gains = zip(percents, percents.dropFirst())
            .reduce(0) { $0 + max(0, $1.1 - $1.0) }
        guard gains >= 1 else { return nil }
        return Double(gains) / Double(tokens)
    }

    /// One cumulative curve per model over `start...end`.
    ///
    /// `percentPerToken` nil falls back to scaling the tallest curve to 100:
    /// the axis stops speaking percent, but the SHAPE — who climbed when,
    /// and how steeply — is still true, and that beats an empty plot.
    ///
    /// `cap` belongs to a span that is exactly one limit window, where
    /// nothing can honestly exceed the limit and the clamp is a safety net.
    /// Across several windows the overshoot IS the information: it says the
    /// span spent more than one limit's worth.
    public static func build(
        models: [String], moments: [Moment], start: Date, end: Date,
        percentPerToken: Double?, cap: Bool
    ) -> [Curve] {
        let raw = models.map { model in
            (model: model, curve: CumulativeSeries.build(
                moments: moments.filter { $0.model == model }.map { ($0.t, $0.amount) },
                start: start, end: end))
        }
        let norm: Double
        if let percentPerToken {
            norm = percentPerToken
        } else {
            let tallest = raw.compactMap { $0.curve.last?.total }.max() ?? 0
            guard tallest > 0 else { return [] }
            norm = 100.0 / Double(tallest)
        }
        return raw.map { entry in
            Curve(
                model: entry.model,
                points: entry.curve.map { point in
                    let value = Double(point.total) * norm
                    return Point(t: point.t, value: cap ? min(100, value) : value)
                })
        }
    }

    /// The plot's tallest drawn value: 100 when the curves stay inside one
    /// limit, higher when a span holds more than one window's worth. The
    /// caller's headroom band scales from it, so labels never land on data.
    public static func ceiling(_ curves: [Curve]) -> Double {
        max(100, curves.map(\.peak).max() ?? 100)
    }
}
