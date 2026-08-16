import Foundation

public struct CumulativePoint: Equatable, Sendable {
    public let t: Date
    public let total: Int

    public init(t: Date, total: Int) {
        self.t = t
        self.total = total
    }
}

/// Cumulative token curves for the popover charts: running totals over a
/// fixed grid of a couple hundred buckets, with a point at EVERY bucket
/// boundary. Missing measurements are zero usage, so grounding each empty
/// bucket at the held total makes phantom growth impossible by
/// construction — the line can only rise inside a bucket that actually
/// held tokens. (Sparse points, however placed, let neighboring bursts
/// interpolate into ramps across the quiet minutes between them.)
public enum CumulativeSeries {
    public static func build(
        moments: [(t: Date, amount: Int)], start: Date, end: Date, buckets: Int = 180
    ) -> [CumulativePoint] {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return [] }
        let bucket = max(60, span / Double(buckets))
        var sums = Array(repeating: 0, count: Int(span / bucket) + 1)
        var any = false
        for moment in moments where moment.t >= start && moment.t <= end {
            let index = min(
                sums.count - 1, Int(moment.t.timeIntervalSince(start) / bucket))
            sums[index] += moment.amount
            any = true
        }
        guard any else {
            return [CumulativePoint(t: start, total: 0), CumulativePoint(t: end, total: 0)]
        }
        var curve: [CumulativePoint] = [CumulativePoint(t: start, total: 0)]
        var total = 0
        for (index, amount) in sums.enumerated() {
            total += amount
            let t = min(start.addingTimeInterval(Double(index + 1) * bucket), end)
            // The last boundary clamps to `end`; when the span divides
            // evenly that collides with the previous point — charts key
            // these by time, so timestamps must stay unique.
            if t > curve[curve.count - 1].t {
                curve.append(CumulativePoint(t: t, total: total))
            } else {
                curve[curve.count - 1] = CumulativePoint(t: t, total: total)
            }
        }
        return curve
    }
}
