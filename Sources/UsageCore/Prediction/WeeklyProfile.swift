import Foundation

/// The learned hour-of-week burn rhythm for one meter: how fast this user
/// typically spends the limit at each moment of the week, estimated from the
/// persisted sample history. Feeds `PredictionEngine` as the baseline a burst
/// decays toward, and the activity section's typical-week overlay.
///
/// Buckets are 4-hour blocks × 7 weekdays (42), in the calendar's local time:
/// fine enough to separate "weekday evenings" from "weekend mornings", coarse
/// enough that two weeks of history observes every bucket a few times. Each
/// bucket's rate is shrunk by `priorHours` of pseudo-observation toward a
/// STRUCTURED estimate — this weekday's own rate × this block-of-day's own
/// rate ÷ the global rate, the independence model over the two margins — so a
/// block seen once doesn't overreact, and a weekday or an hour-of-day the
/// person never uses forecasts zero BY CONSTRUCTION.
///
/// It used to shrink toward the flat whole-history mean, and that was wrong in
/// a way that reached the menu bar (v0.99.3): for a Sun–Thu user with five
/// quiet weeks, the prior still weighed 30–40% of a bucket with 12–20 observed
/// hours, so Fri+Sat carried ~10% and every 00:00–08:00 block another ~11% of
/// the modeled week despite ~0% observed — while the busy blocks were pulled
/// down to pay for it. A flattened expectation also inflates
/// `paceFactor`, so a perfectly normal Tuesday read as 1.28× hot and the
/// forecast steepened every remaining day into a false crossing.
public struct WeeklyProfile: Sendable, Equatable {
    public static let blocksPerDay = 6
    public static let bucketCount = 7 * blocksPerDay
    /// History span needed before the profile drives forecasts and charts —
    /// two full weekly cycles, so every hour-of-week was seen twice.
    public static let activationSpan: TimeInterval = 14 * 86400
    /// Pseudo-observation hours pulling each bucket toward its structured
    /// estimate (weekday rate × block rate ÷ global rate), never toward a flat
    /// mean — an unused weekday or hour-of-day must stay at zero.
    public static let priorHours = 8.0
    /// Sample gaps beyond this are dropped: smearing one delta across days
    /// says nothing about hour-of-week structure.
    public static let maximumGap: TimeInterval = 48 * 3600
    /// Additive shrink (percentage points) keeping the pace factor tame
    /// early in a window, when "expected so far" is still near zero.
    public static let paceShrink = 5.0
    /// Clamped tight (v0.99.3): the factor is a nudge on the typical week, not
    /// a re-estimate of it — a 4× ceiling let two hot days quadruple the
    /// remaining five.
    public static let paceFactorRange = 0.5...2.0

    /// Typical %/hour per bucket, weekday-major: Sunday's six blocks first.
    public let rates: [Double]
    /// Actually observed hours per bucket (diagnostics + settings readout).
    public let observedHours: [Double]
    /// Whole-history mean burn in %/hour — the normalizer of the structured
    /// prior (and the settings readout's headline number).
    public let globalRatePerHour: Double
    /// How much time the samples actually WATCHED: the sum of the gaps
    /// between consecutive samples, holes longer than `maximumGap` left out.
    /// Not oldest-to-newest (0.101.0, user-reported): a harness sampled for
    /// a day in August and a day in September spanned five weeks, read as
    /// "ready", and a rhythm learned from almost nothing replaced a forecast
    /// that had correctly seen the limit running out. A continuously running
    /// install measures the same either way.
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
    /// dropped when the percent fell or the reported reset moved beyond
    /// `ResetStamp` jitter (the window rolled over between reads, so the
    /// delta doesn't describe consumption) and when the gap exceeds
    /// `maximumGap`.
    ///
    /// Each bucket is then shrunk toward its STRUCTURED estimate rather than
    /// toward the flat global mean. With `d` the weekday and `b` the
    /// block-of-day:
    ///
    ///     dayRate[d]   = Σ gained over that weekday's 6 buckets ÷ Σ hours
    ///     blockRate[b] = Σ gained over that block across the 7 weekdays ÷ Σ hours
    ///     global       = Σ gained ÷ Σ hours
    ///     structured   = dayRate[d] × blockRate[b] ÷ global   (0 when global is 0)
    ///     rate         = (gained + priorHours × structured) ÷ (hours + priorHours)
    ///
    /// The multiplicative form is the independence model: a bucket with thin
    /// coverage is guessed from "how busy is this weekday" × "how busy is this
    /// hour-of-day", so a never-used Saturday and a never-used 04:00 both
    /// carry a zero factor and the bucket forecasts zero no matter how little
    /// it was observed. A margin with no observed hours at all counts as zero
    /// too — past `activationSpan` every weekday and block has been seen, so
    /// that only ever concerns a profile too young to drive a forecast.
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
        guard points.count >= 2 else { return nil }

        var gainedByBucket = [Double](repeating: 0, count: bucketCount)
        var hoursByBucket = [Double](repeating: 0, count: bucketCount)
        var pairs = 0
        var watched: TimeInterval = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let dt = b.t.timeIntervalSince(a.t)
            guard dt > 0, dt <= maximumGap else { continue }
            // Watched time counts even where the pair teaches no rate (a
            // reset, a correction): the span is about coverage.
            watched += dt
            guard b.percent >= a.percent else { continue }
            if let resetA = a.reset, let resetB = b.reset,
               ResetStamp.moved(resetA, resetB) { continue }
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

        // The two margins of the 7 × 6 table, each a plain rate over its own
        // observed hours; a margin nobody burned in (or nobody was observed
        // in) is zero, which is what carries a never-used weekday or
        // hour-of-day through the prior as an exact zero.
        var dayGained = [Double](repeating: 0, count: 7)
        var dayHours = [Double](repeating: 0, count: 7)
        var blockGained = [Double](repeating: 0, count: blocksPerDay)
        var blockHours = [Double](repeating: 0, count: blocksPerDay)
        for index in 0..<bucketCount {
            dayGained[index / blocksPerDay] += gainedByBucket[index]
            dayHours[index / blocksPerDay] += hoursByBucket[index]
            blockGained[index % blocksPerDay] += gainedByBucket[index]
            blockHours[index % blocksPerDay] += hoursByBucket[index]
        }
        let dayRate = zip(dayGained, dayHours).map { $1 > 0 ? $0 / $1 : 0 }
        let blockRate = zip(blockGained, blockHours).map { $1 > 0 ? $0 / $1 : 0 }

        let rates = (0..<bucketCount).map { index -> Double in
            let structured = global > 0
                ? dayRate[index / blocksPerDay] * blockRate[index % blocksPerDay] / global
                : 0
            return (gainedByBucket[index] + priorHours * structured)
                / (hoursByBucket[index] + priorHours)
        }
        return WeeklyProfile(
            rates: rates, observedHours: hoursByBucket, globalRatePerHour: global,
            historySpan: watched, pairCount: pairs,
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
