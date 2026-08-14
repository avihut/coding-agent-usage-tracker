import Foundation

/// One meter's usage forecast: the measured burn rate, the projected
/// trajectory to the window's reset, and the human verdict. Every surface
/// that talks about the future — meter captions, the popover's window graph —
/// reads the same prediction, produced in one place.
public struct UsagePrediction: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// On track — projected to stay under the limit until reset.
        case green
        /// Possibly exceeding — projected close to the limit at reset.
        case yellow
        /// Definitely exceeding — current rate exhausts the limit before reset.
        case red
    }

    /// One point on the projected trajectory.
    public struct Point: Sendable, Equatable {
        public let t: Date
        public let percent: Double

        public init(t: Date, percent: Double) {
            self.t = t
            self.percent = percent
        }
    }

    /// Percent-per-hour measured from the recent monotonic sample tail.
    public let ratePerHour: Double
    /// Projected percent at the window reset (clamped to 100); nil without a
    /// live reset time.
    public let projectedAtReset: Int?
    /// When the current rate crosses 100% — before the reset would save it.
    /// Nil when the rate is flat or the window resets first.
    public let exhaustsAt: Date?
    public let verdict: Verdict
    /// How hard the forecast presses on the limit, as a continuous scale:
    /// 0 while the projection sits at or below the yellow threshold,
    /// ramping linearly to 1 where the reset-time projection reaches the
    /// limit. Risk surfaces (meter bars, menu bar segments) blend their
    /// color yellow→red by this — no hard warning/critical cliff.
    public let severity: Double
    /// The meter-caption insight, e.g. "on track — proj. 35% at reset".
    public let text: String
    /// Trajectory from now to reset for charting, clamped at 100 (a knee
    /// point marks the crossing). Empty without a live future reset.
    public let curve: [Point]
}

/// The consolidated prediction engine (formerly BurnRate + BurnEstimate,
/// which lived beside the sample store and computed only caption text).
public enum PredictionEngine {
    /// Projected-at-reset percentage above which the verdict turns yellow.
    public static let yellowProjectionThreshold = 85.0
    /// Minimum sample span before a rate is considered meaningful.
    public static let minimumSpan: TimeInterval = 300
    /// Rates below this count as flat — noise, not consumption.
    public static let flatRateThreshold = 0.1

    /// Sampling window per meter rank: sessions move fast, weeklies slowly.
    public static func window(forRank rank: Int) -> TimeInterval {
        rank == 0 ? 45 * 60 : 4 * 3600
    }

    /// The one entry point surfaces use: nil when the meter has no percent
    /// or the samples can't support a rate yet.
    public static func predict(
        meter: Meter, samples: [UsageSample], now: Date
    ) -> UsagePrediction? {
        guard let percent = meter.percent,
              let rate = ratePerHour(
                  samples: samples, label: meter.label,
                  window: window(forRank: meter.rank), now: now)
        else { return nil }
        return prediction(percent: percent, resetsAt: meter.resetsAt, ratePerHour: rate, now: now)
    }

    /// Percent-per-hour from recent samples of one meter. Uses only the
    /// monotonic tail after the most recent drop, so a limit reset (percent
    /// falling back to ~0) never produces a bogus negative rate.
    public static func ratePerHour(
        samples: [UsageSample], label: String, window: TimeInterval, now: Date
    ) -> Double? {
        let points = samples
            .filter { now.timeIntervalSince($0.t) <= window }
            .compactMap { sample in sample.percents[label].map { (sample.t, $0) } }
            .sorted { $0.0 < $1.0 }
        guard points.count >= 2 else { return nil }

        var tail = points
        for index in points.indices.dropFirst().reversed() {
            if points[index].1 < points[index - 1].1 {
                tail = Array(points[index...])
                break
            }
        }
        guard let first = tail.first, let last = tail.last else { return nil }
        let span = last.0.timeIntervalSince(first.0)
        guard span >= minimumSpan else { return nil }
        return Double(last.1 - first.1) / (span / 3600)
    }

    /// The deterministic core: given a measured rate, everything else.
    public static func prediction(
        percent: Int, resetsAt: Date?, ratePerHour rate: Double, now: Date
    ) -> UsagePrediction {
        let liveReset = resetsAt.flatMap { $0 > now ? $0 : nil }

        guard rate > flatRateThreshold else {
            return UsagePrediction(
                ratePerHour: rate,
                projectedAtReset: liveReset != nil ? percent : nil,
                exhaustsAt: nil,
                verdict: .green,
                severity: 0,
                text: "steady — not burning",
                curve: liveReset.map { reset in
                    [.init(t: now, percent: Double(percent)),
                     .init(t: reset, percent: Double(percent))]
                } ?? [])
        }

        let hoursToExhaust = Double(100 - percent) / rate
        let exhaustDate = now.addingTimeInterval(hoursToExhaust * 3600)

        guard let reset = liveReset else {
            return UsagePrediction(
                ratePerHour: rate,
                projectedAtReset: nil,
                exhaustsAt: exhaustDate,
                verdict: .green,
                severity: 0,
                text: "≈\(durationText(hours: hoursToExhaust)) to limit",
                curve: [])
        }

        let hoursToReset = reset.timeIntervalSince(now) / 3600
        let projected = Double(percent) + rate * hoursToReset
        // The unclamped projection placed on the yellow-threshold→limit ramp.
        let severity = max(0, min(1,
            (projected - yellowProjectionThreshold) / (100 - yellowProjectionThreshold)))
        let start = UsagePrediction.Point(t: now, percent: Double(percent))

        if projected >= 100 {
            return UsagePrediction(
                ratePerHour: rate,
                projectedAtReset: 100,
                exhaustsAt: exhaustDate,
                verdict: .red,
                severity: severity,
                text: "≈\(durationText(hours: hoursToExhaust)) until limit",
                curve: [start,
                        .init(t: exhaustDate, percent: 100),
                        .init(t: reset, percent: 100)])
        }
        let endpoint = UsagePrediction.Point(t: reset, percent: projected)
        if projected >= yellowProjectionThreshold {
            return UsagePrediction(
                ratePerHour: rate,
                projectedAtReset: Int(projected.rounded()),
                exhaustsAt: nil,
                verdict: .yellow,
                severity: severity,
                text: "tight — proj. \(Int(projected.rounded()))% at reset",
                curve: [start, endpoint])
        }
        return UsagePrediction(
            ratePerHour: rate,
            projectedAtReset: Int(projected.rounded()),
            exhaustsAt: nil,
            verdict: .green,
            severity: 0,
            text: "on track — proj. \(Int(projected.rounded()))% at reset",
            curve: [start, endpoint])
    }

    /// The projected percent at an arbitrary future instant — the window
    /// graph's hover readout right of the now-notch.
    public static func percent(onCurve curve: [UsagePrediction.Point], at t: Date) -> Double? {
        guard let first = curve.first, let last = curve.last else { return nil }
        if t <= first.t { return first.percent }
        if t >= last.t { return last.percent }
        for (p0, p1) in zip(curve, curve.dropFirst()) where t <= p1.t {
            let span = p1.t.timeIntervalSince(p0.t)
            guard span > 0 else { return p1.percent }
            let fraction = t.timeIntervalSince(p0.t) / span
            return p0.percent + fraction * (p1.percent - p0.percent)
        }
        return last.percent
    }

    static func durationText(hours: Double) -> String {
        let totalMinutes = max(1, Int((hours * 60).rounded()))
        let (h, m) = (totalMinutes / 60, totalMinutes % 60)
        if h == 0 { return "\(m)m" }
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}
