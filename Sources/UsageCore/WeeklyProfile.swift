import Foundation

/// The learned hour-of-week burn rhythm for one meter: how fast this user
/// typically spends the limit at each moment of the week, estimated from the
/// persisted sample history. Feeds `PredictionEngine` as the baseline a burst
/// decays toward, and the activity section's typical-week overlay.
///
/// Buckets are 4-hour blocks × 7 weekdays (42), in the calendar's local time:
/// fine enough to separate "weekday evenings" from "weekend mornings", coarse
/// enough that two weeks of history observes every bucket a few times. Each
/// bucket's rate is shrunk toward the whole-history mean by `priorHours` of
/// pseudo-observation, so a block seen once doesn't overreact.
public struct WeeklyProfile: Sendable, Equatable {
    public static let blocksPerDay = 6
    public static let bucketCount = 7 * blocksPerDay
    /// History span needed before the profile drives forecasts and charts —
    /// two full weekly cycles, so every hour-of-week was seen twice.
    public static let activationSpan: TimeInterval = 14 * 86400
    /// Pseudo-observation hours pulling each bucket toward the global mean.
    public static let priorHours = 8.0
    /// Sample gaps beyond this are dropped: smearing one delta across days
    /// says nothing about hour-of-week structure.
    public static let maximumGap: TimeInterval = 48 * 3600
    /// Additive shrink (percentage points) keeping the pace factor tame
    /// early in a window, when "expected so far" is still near zero.
    public static let paceShrink = 5.0
    public static let paceFactorRange = 0.25...4.0

    /// Typical %/hour per bucket, weekday-major: Sunday's six blocks first.
    public let rates: [Double]
    /// Actually observed hours per bucket (diagnostics + settings readout).
    public let observedHours: [Double]
    /// Whole-history mean burn in %/hour — the shrinkage prior.
    public let globalRatePerHour: Double
    /// Oldest-to-newest span of the samples that fed the profile.
    public let historySpan: TimeInterval
    /// Consecutive-sample pairs that survived the filters.
    public let pairCount: Int
    let calendar: Calendar

    public var isReady: Bool { historySpan >= Self.activationSpan }
    public var remainingUntilReady: TimeInterval {
        max(0, Self.activationSpan - historySpan)
    }

    /// Builds the profile from the sample history, or nil when the history
    /// doesn't hold two readings of this meter yet.
    ///
    /// Consumption is measured between consecutive samples and attributed
    /// uniformly across the blocks the pair spans — a delta of zero across a
    /// quiet night correctly teaches those blocks a low rate. Pairs are
    /// dropped when the percent fell or the reported reset moved (the window
    /// rolled over between reads, so the delta doesn't describe consumption)
    /// and when the gap exceeds `maximumGap`.
    public static func build(
        samples: [UsageSample], label: String, calendar: Calendar = .current
    ) -> WeeklyProfile? {
        let points = samples
            .compactMap { sample in
                sample.percents[label].map {
                    (t: sample.t, percent: $0, reset: sample.resets?[label])
                }
            }
            .sorted { $0.t < $1.t }
        guard let first = points.first, let last = points.last,
              points.count >= 2
        else { return nil }

        var gainedByBucket = [Double](repeating: 0, count: bucketCount)
        var hoursByBucket = [Double](repeating: 0, count: bucketCount)
        var pairs = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let dt = b.t.timeIntervalSince(a.t)
            guard dt > 0, dt <= maximumGap else { continue }
            guard b.percent >= a.percent else { continue }
            if let resetA = a.reset, let resetB = b.reset, resetA != resetB { continue }
            let gained = Double(b.percent - a.percent)
            pairs += 1
            var cursor = a.t
            while cursor < b.t {
                let sliceEnd = min(blockEnd(after: cursor, calendar: calendar), b.t)
                let slice = sliceEnd.timeIntervalSince(cursor)
                let index = bucketIndex(for: cursor, calendar: calendar)
                hoursByBucket[index] += slice / 3600
                gainedByBucket[index] += gained * (slice / dt)
                cursor = sliceEnd
            }
        }

        let totalHours = hoursByBucket.reduce(0, +)
        guard totalHours > 0 else { return nil }
        let global = gainedByBucket.reduce(0, +) / totalHours
        let rates = zip(gainedByBucket, hoursByBucket).map { gained, observed in
            (gained + priorHours * global) / (observed + priorHours)
        }
        return WeeklyProfile(
            rates: rates, observedHours: hoursByBucket, globalRatePerHour: global,
            historySpan: last.t.timeIntervalSince(first.t), pairCount: pairs,
            calendar: calendar)
    }

    /// The typical rate at an instant, %/hour.
    public func rate(at date: Date) -> Double {
        rates[Self.bucketIndex(for: date, calendar: calendar)]
    }

    /// Expected percent gained across a span at the typical rhythm — the
    /// baseline integral behind profile-based forecasts.
    public func expectedPercent(from start: Date, to end: Date) -> Double {
        guard end > start else { return 0 }
        var total = 0.0
        var cursor = start
        while cursor < end {
            let sliceEnd = min(Self.blockEnd(after: cursor, calendar: calendar), end)
            total += rate(at: cursor) * sliceEnd.timeIntervalSince(cursor) / 3600
            cursor = sliceEnd
        }
        return total
    }

    /// How this window compares to the typical one so far: >1 running hot,
    /// <1 running cool. Additively shrunk so a freshly reset window doesn't
    /// divide near-zero by near-zero, and clamped to stay sane.
    public func paceFactor(percent: Int, windowStart: Date, now: Date) -> Double {
        let expected = expectedPercent(from: windowStart, to: now)
        let raw = (Double(percent) + Self.paceShrink) / (expected + Self.paceShrink)
        return min(max(raw, Self.paceFactorRange.lowerBound), Self.paceFactorRange.upperBound)
    }

    /// Each weekday's share of a typical week's burn (Sunday-first, sums to
    /// 1) — the shape the activity chart stretches over its 7-day bars.
    /// Uniform when the history hasn't seen any burn at all.
    public func weekdayShares() -> [Double] {
        let daily = (0..<7).map { day in
            rates[day * Self.blocksPerDay..<(day + 1) * Self.blocksPerDay].reduce(0, +)
        }
        let total = daily.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1.0 / 7, count: 7) }
        return daily.map { $0 / total }
    }

    /// Absolute weekday-major bucket: (Foundation weekday − 1) × 6 + hour÷4.
    /// Sunday is index 0 regardless of the calendar's first-weekday setting,
    /// so stored profiles and chart columns can never disagree on alignment.
    public static func bucketIndex(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.weekday, .hour], from: date)
        let day = (((components.weekday ?? 1) - 1) % 7 + 7) % 7
        let block = min(blocksPerDay - 1, max(0, (components.hour ?? 0) / 4))
        return day * blocksPerDay + block
    }

    /// The end of the 4-hour block containing `date` — calendar-correct
    /// across DST shifts, and guaranteed to advance past `date` so the
    /// attribution walk always terminates.
    static func blockEnd(after date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        components.hour = ((components.hour ?? 0) / 4) * 4
        let blockStart = calendar.date(from: components) ?? date
        let end = calendar.date(byAdding: .hour, value: 4, to: blockStart)
            ?? date.addingTimeInterval(4 * 3600)
        return end > date ? end : date.addingTimeInterval(4 * 3600)
    }
}
