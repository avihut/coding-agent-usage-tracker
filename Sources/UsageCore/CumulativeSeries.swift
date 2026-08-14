import Foundation

public struct CumulativePoint: Equatable, Sendable {
    public let t: Date
    public let total: Int

    public init(t: Date, total: Int) {
        self.t = t
        self.total = total
    }
}

/// Cumulative token curves for the popover charts: running totals bucketed
/// so a month of minute slots collapses to a couple hundred points — with
/// an explicit hold point just before each idle gap ends, so quiet
/// stretches draw FLAT. Sparse cumulative points interpolate linearly on
/// the chart, and without the hold a gap renders as a phantom ramp:
/// steady apparent growth across hours of nothing.
public enum CumulativeSeries {
    public static func build(
        moments: [(t: Date, amount: Int)], start: Date, end: Date, buckets: Int = 180
    ) -> [CumulativePoint] {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return [] }
        let bucket = max(60, span / Double(buckets))
        var curve: [CumulativePoint] = [CumulativePoint(t: start, total: 0)]
        var total = 0
        var nextBoundary = start.addingTimeInterval(bucket)
        for moment in moments where moment.t >= start && moment.t <= end {
            if moment.t > nextBoundary {
                curve.append(CumulativePoint(t: nextBoundary, total: total))
                while nextBoundary < moment.t { nextBoundary.addTimeInterval(bucket) }
                // The gap's far edge: hold the level to the bucket floor
                // where activity resumes, so the line steps there instead
                // of ramping across the whole quiet stretch.
                let resumeFloor = nextBoundary.addingTimeInterval(-bucket)
                if resumeFloor > curve[curve.count - 1].t {
                    curve.append(CumulativePoint(t: resumeFloor, total: total))
                }
            }
            total += moment.amount
        }
        curve.append(CumulativePoint(t: end, total: total))
        return curve
    }
}
