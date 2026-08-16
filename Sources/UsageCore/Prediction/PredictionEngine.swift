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
        /// Definitely exceeding — projected to exhaust the limit before reset.
        case red
    }

    /// What the projection leaned on beyond the recent burn rate.
    public enum Basis: Sendable, Equatable {
        /// Pure linear extrapolation of the recent rate — no live reset, or
        /// a window too young to know its own pace yet.
        case recentOnly
        /// Recent burn damped toward this window's average pace so far.
        case windowAverage
        /// Recent burn damped toward the learned weekly rhythm.
        case weeklyProfile
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
    /// What the baseline expects right now (pace-scaled), %/hour; nil when
    /// the forecast had only the recent rate to go on.
    public let baselineRatePerHour: Double?
    /// How this window compares to the typical one so far (weekly-profile
    /// basis only): >1 running hot, <1 running cool.
    public let paceFactor: Double?
    public let basis: Basis
    /// Projected percent at the window reset (clamped to 100); nil without a
    /// live reset time.
    public let projectedAtReset: Int?
    /// When the forecast crosses 100% — before the reset would save it.
    /// Nil when the trajectory stays under the limit or no reset is known.
    public let exhaustsAt: Date?
    /// The displayed verdict — smoothed: changing it takes two consecutive
    /// refreshes agreeing, so one odd sample never flips the panel's state.
    public let verdict: Verdict
    /// This refresh's un-smoothed classification; the smoothing's memory.
    public let rawVerdict: Verdict
    /// How hard the forecast presses on the limit, as a continuous scale:
    /// 0 while the projection sits at or below the yellow threshold,
    /// ramping linearly to 1 where the reset-time projection reaches the
    /// limit. Risk surfaces (meter bars, menu bar segments) blend their
    /// color yellow→red by this — no hard warning/critical cliff.
    public let severity: Double
    /// The meter-caption insight, e.g. "on track — proj. 35% at reset".
    public let text: String
    /// Trajectory from now to reset for charting, clamped at 100 (a knee
    /// point marks the crossing). Curved under a damped forecast — it bends
    /// from the burst's slope toward the baseline's. Empty without a live
    /// future reset.
    public let curve: [Point]

    /// Memberwise, public so a client-mode app can rebuild predictions
    /// verbatim from the live-state digest's forecast mirror.
    public init(
        ratePerHour: Double, baselineRatePerHour: Double?, paceFactor: Double?,
        basis: Basis, projectedAtReset: Int?, exhaustsAt: Date?,
        verdict: Verdict, rawVerdict: Verdict, severity: Double, text: String,
        curve: [Point]
    ) {
        self.ratePerHour = ratePerHour
        self.baselineRatePerHour = baselineRatePerHour
        self.paceFactor = paceFactor
        self.basis = basis
        self.projectedAtReset = projectedAtReset
        self.exhaustsAt = exhaustsAt
        self.verdict = verdict
        self.rawVerdict = rawVerdict
        self.severity = severity
        self.text = text
        self.curve = curve
    }
}

/// The forecast engine. The recent burn rate is a least-squares slope over
/// the monotonic sample tail; the projection lets that burst decay toward a
/// baseline — the window's own average pace, or the learned weekly rhythm
/// once enough history exists — instead of assuming the last hour repeats
/// for the rest of the window.
public enum PredictionEngine {
    /// Projected-at-reset percentage above which the verdict turns yellow.
    public static let yellowProjectionThreshold = 85.0
    /// Minimum sample span before a rate is considered meaningful.
    public static let minimumSpan: TimeInterval = 300
    /// Rates below this count as flat — noise, not consumption.
    public static let flatRateThreshold = 0.1
    /// A burst's staying power, in hours: the recent rate's excess over the
    /// baseline decays with this time constant, so a hot session contributes
    /// about one hour of itself to the forecast — not the whole window.
    public static let burstDecayHours = 1.0
    /// Youngest window age that can carry an average-pace baseline; before
    /// this, percent ÷ elapsed is mostly noise.
    public static let minimumBaselineElapsed: TimeInterval = 1800
    /// Windows shorter than this keep the pure-linear forecast. At session
    /// scale the burst IS the signal — a working session sustains its rate
    /// for a meaningful share of the 5-hour window, and damping it would
    /// under-warn. The blend exists to stop a short burst from being
    /// extrapolated across days.
    public static let minimumWindowForBaseline: TimeInterval = 86400
    /// Sampling resolution of a damped trajectory between now and reset.
    static let curveSampleCount = 48

    /// The one entry point surfaces use: nil when the meter has no percent
    /// or the samples can't support a rate yet. `previous` feeds the verdict
    /// smoothing; `profile` supplies the weekly-rhythm baseline when ready.
    /// Window shapes come from the meter itself — provider data, not rank
    /// heuristics; an unknown limit window keeps the meter pure-linear.
    public static func predict(
        meter: Meter, samples: [UsageSample], profile: WeeklyProfile? = nil,
        previous: UsagePrediction? = nil, now: Date
    ) -> UsagePrediction? {
        guard let percent = meter.percent else { return nil }
        // A spent limit is a measurement, not a forecast — and it must not
        // depend on one. Once every sample reads 100 the rate is
        // unmeasurable (a flat tail has no slope), which used to erase the
        // prediction entirely and with it any word about being spent.
        if percent >= 100 {
            // Scope the search to THIS window: a reset nothing was awake
            // to witness leaves no drop in the history, and an unscoped
            // search would then recall a previous window's crossing —
            // a stale timestamp in place of a sliding one.
            let windowStart = meter.resetsAt.flatMap { reset in
                meter.limitWindow.map { reset.addingTimeInterval(-$0) }
            }
            return spent(
                resetsAt: meter.resetsAt,
                at: spentAt(samples: samples, label: meter.label, since: windowStart),
                now: now)
        }
        guard let rate = ratePerHour(
            samples: samples, label: meter.label,
            window: meter.rateWindow, now: now)
        else { return nil }
        return prediction(
            percent: percent, resetsAt: meter.resetsAt, ratePerHour: rate,
            windowLength: meter.limitWindow ?? 0,
            profile: profile, previous: previous, now: now)
    }

    /// When this window's limit was actually spent: the first sample to
    /// read 100 since the last reset. The crossing is a fact to be
    /// recalled, never a projection to be recomputed — recomputing it each
    /// refresh is what kept an exhausted meter saying "runs out soon" and
    /// left the moment it ran out unrecorded. Nil when no sample witnessed
    /// the crossing (the app wasn't watching).
    ///
    /// `since` is the current window's start where the meter knows it —
    /// the only reliable boundary, since an unwitnessed reset leaves no
    /// drop for the tail seam to find.
    public static func spentAt(
        samples: [UsageSample], label: String, since: Date? = nil
    ) -> Date? {
        let points = samples
            .filter { sample in since.map { sample.t >= $0 } ?? true }
            .compactMap { sample in sample.percents[label].map { (sample.t, $0) } }
            .sorted { $0.0 < $1.0 }
        guard !points.isEmpty else { return nil }
        // The tail after the most recent drop is the current window, the
        // same seam `ratePerHour` cuts on.
        var tail = points
        for index in points.indices.dropFirst().reversed() where points[index].1 < points[index - 1].1 {
            tail = Array(points[index...])
            break
        }
        return tail.first { $0.1 >= 100 }?.0
    }

    /// The forecast for a limit that is already gone: nothing left to
    /// project, the trajectory flat at the ceiling until the reset.
    static func spent(resetsAt: Date?, at spentAt: Date?, now: Date) -> UsagePrediction {
        let liveReset = resetsAt.flatMap { $0 > now ? $0 : nil }
        return UsagePrediction(
            ratePerHour: 0,
            baselineRatePerHour: nil,
            paceFactor: nil,
            basis: .recentOnly,
            projectedAtReset: liveReset != nil ? 100 : nil,
            exhaustsAt: spentAt,
            // Measured, so it skips the verdict smoothing that exists to
            // keep one odd sample from flipping a *forecast*.
            verdict: .red,
            rawVerdict: .red,
            severity: 1,
            text: "limit spent",
            curve: liveReset.map { reset in
                [.init(t: now, percent: 100), .init(t: reset, percent: 100)]
            } ?? [])
    }

    /// Percent-per-hour from recent samples of one meter: a least-squares
    /// slope over the monotonic tail after the most recent drop, so a limit
    /// reset (percent falling back to ~0) never produces a bogus negative
    /// rate — and one integer-quantized step over a short span can't spike
    /// the estimate the way an endpoint secant did.
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

        let xs = tail.map { $0.0.timeIntervalSince(first.0) / 3600 }
        let ys = tail.map { Double($0.1) }
        let count = Double(tail.count)
        let meanX = xs.reduce(0, +) / count
        let meanY = ys.reduce(0, +) / count
        var covariance = 0.0
        var variance = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            variance += (x - meanX) * (x - meanX)
        }
        guard variance > 0 else { return nil }
        // The tail is non-decreasing, so the slope can't go negative; the
        // clamp only guards floating-point dust.
        return max(0, covariance / variance)
    }

    /// What the forecast decays toward once the current burst fades.
    struct Baseline {
        let basis: UsagePrediction.Basis
        let paceFactor: Double?
        /// %/hour the baseline expects at an instant.
        let rate: (Date) -> Double
        /// Expected percent gained across a span.
        let gained: (Date, Date) -> Double
    }

    /// The best available baseline: the weekly rhythm once the profile is
    /// ready, the window's own average pace once the window is old enough
    /// to have one, nil for a young window (pure linear then — exactly the
    /// pre-blend behavior, and roughly right at that horizon).
    static func baseline(
        percent: Int, reset: Date, windowLength: TimeInterval,
        profile: WeeklyProfile?, now: Date
    ) -> Baseline? {
        guard windowLength >= minimumWindowForBaseline else { return nil }
        if let profile, profile.isReady {
            let windowStart = reset.addingTimeInterval(-windowLength)
            let pace = profile.paceFactor(percent: percent, windowStart: windowStart, now: now)
            return Baseline(
                basis: .weeklyProfile, paceFactor: pace,
                rate: { profile.rate(at: $0) * pace },
                gained: { profile.expectedPercent(from: $0, to: $1) * pace })
        }
        let elapsed = windowLength - reset.timeIntervalSince(now)
        guard elapsed >= minimumBaselineElapsed else { return nil }
        let averageRate = Double(percent) / (elapsed / 3600)
        return Baseline(
            basis: .windowAverage, paceFactor: nil,
            rate: { _ in averageRate },
            gained: { averageRate * $1.timeIntervalSince($0) / 3600 })
    }

    /// The deterministic core: given a measured rate (and whatever baseline
    /// the window supports), everything else. Defaulted parameters keep the
    /// legacy shape — no window length means no baseline, which means the
    /// original pure-linear behavior.
    public static func prediction(
        percent: Int, resetsAt: Date?, ratePerHour rate: Double,
        windowLength: TimeInterval = 0, profile: WeeklyProfile? = nil,
        previous: UsagePrediction? = nil, spentAt: Date? = nil, now: Date
    ) -> UsagePrediction {
        // Nothing left to forecast once the limit is gone; the crossing
        // comes from the record, not from extrapolating zero headroom.
        if percent >= 100 {
            return spent(resetsAt: resetsAt, at: spentAt, now: now)
        }
        let liveReset = resetsAt.flatMap { $0 > now ? $0 : nil }
        if let reset = liveReset,
           let baseline = baseline(
               percent: percent, reset: reset, windowLength: windowLength,
               profile: profile, now: now) {
            return blended(
                percent: percent, reset: reset, rate: rate,
                baseline: baseline, previous: previous, now: now)
        }
        return linear(
            percent: percent, liveReset: liveReset, rate: rate,
            previous: previous, now: now)
    }

    // MARK: - Pure linear (no baseline)

    private static func linear(
        percent: Int, liveReset: Date?, rate: Double,
        previous: UsagePrediction?, now: Date
    ) -> UsagePrediction {
        guard rate > flatRateThreshold else {
            return UsagePrediction(
                ratePerHour: rate,
                baselineRatePerHour: nil,
                paceFactor: nil,
                basis: .recentOnly,
                projectedAtReset: liveReset != nil ? percent : nil,
                exhaustsAt: nil,
                verdict: smoothed(.green, previous: previous),
                rawVerdict: .green,
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
                baselineRatePerHour: nil,
                paceFactor: nil,
                basis: .recentOnly,
                projectedAtReset: nil,
                exhaustsAt: exhaustDate,
                verdict: smoothed(.green, previous: previous),
                rawVerdict: .green,
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
                baselineRatePerHour: nil,
                paceFactor: nil,
                basis: .recentOnly,
                projectedAtReset: 100,
                exhaustsAt: exhaustDate,
                verdict: smoothed(.red, previous: previous),
                rawVerdict: .red,
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
                baselineRatePerHour: nil,
                paceFactor: nil,
                basis: .recentOnly,
                projectedAtReset: Int(projected.rounded()),
                exhaustsAt: nil,
                verdict: smoothed(.yellow, previous: previous),
                rawVerdict: .yellow,
                severity: severity,
                text: "tight — proj. \(Int(projected.rounded()))% at reset",
                curve: [start, endpoint])
        }
        return UsagePrediction(
            ratePerHour: rate,
            baselineRatePerHour: nil,
            paceFactor: nil,
            basis: .recentOnly,
            projectedAtReset: Int(projected.rounded()),
            exhaustsAt: nil,
            verdict: smoothed(.green, previous: previous),
            rawVerdict: .green,
            severity: 0,
            text: "on track — proj. \(Int(projected.rounded()))% at reset",
            curve: [start, endpoint])
    }

    // MARK: - Damped blend

    /// Projected usage gained by time t: the baseline's expectation for the
    /// span, plus the recent rate's excess over it, damped — the excess
    /// contributes `burstDecayHours × (1 − e^(−h/τ))` hours of itself, which
    /// converges to about one hour however long the window runs. Since the
    /// recent rate is never negative, the total is never negative either.
    private static func blended(
        percent: Int, reset: Date, rate: Double,
        baseline: Baseline, previous: UsagePrediction?, now: Date
    ) -> UsagePrediction {
        let percentD = Double(percent)
        let baseRateNow = baseline.rate(now)
        let excess = rate - baseRateNow
        func gained(by t: Date) -> Double {
            let hours = t.timeIntervalSince(now) / 3600
            let damped = burstDecayHours * (1 - exp(-hours / burstDecayHours))
            return baseline.gained(now, t) + excess * damped
        }

        let projectedRaw = percentD + gained(by: reset)
        let start = UsagePrediction.Point(t: now, percent: percentD)

        // Nothing meaningfully burning and nothing expected to: quiet.
        if projectedRaw - percentD < 0.5 {
            return UsagePrediction(
                ratePerHour: rate,
                baselineRatePerHour: baseRateNow,
                paceFactor: baseline.paceFactor,
                basis: baseline.basis,
                projectedAtReset: percent,
                exhaustsAt: nil,
                verdict: smoothed(.green, previous: previous),
                rawVerdict: .green,
                severity: 0,
                text: "steady — not burning",
                curve: [start, .init(t: reset, percent: percentD)])
        }

        let severity = max(0, min(1,
            (projectedRaw - yellowProjectionThreshold) / (100 - yellowProjectionThreshold)))

        // Sample the curved trajectory; clamp at the limit with an exact
        // knee where it crosses.
        var curve = [start]
        var exhaustDate: Date?
        let horizon = reset.timeIntervalSince(now)
        var previousT = now
        for step in 1...curveSampleCount {
            let t = now.addingTimeInterval(horizon * Double(step) / Double(curveSampleCount))
            let value = percentD + gained(by: t)
            if value >= 100 {
                let crossing = crossingDate(
                    between: previousT, and: t, percent: percentD, gained: gained(by:))
                exhaustDate = crossing
                if crossing > previousT {
                    curve.append(.init(t: crossing, percent: 100))
                }
                break
            }
            curve.append(.init(t: t, percent: value))
            previousT = t
        }
        if exhaustDate != nil, let last = curve.last, last.t < reset {
            curve.append(.init(t: reset, percent: 100))
        }

        let raw: UsagePrediction.Verdict = exhaustDate != nil ? .red
            : projectedRaw >= yellowProjectionThreshold ? .yellow : .green
        let projectedAtReset = Int(min(100, projectedRaw).rounded())
        let text: String = switch raw {
        case .red:
            "≈\(durationText(hours: (exhaustDate ?? reset).timeIntervalSince(now) / 3600)) until limit"
        case .yellow:
            "tight — proj. \(projectedAtReset)% at reset"
        case .green:
            "on track — proj. \(projectedAtReset)% at reset"
        }

        return UsagePrediction(
            ratePerHour: rate,
            baselineRatePerHour: baseRateNow,
            paceFactor: baseline.paceFactor,
            basis: baseline.basis,
            projectedAtReset: projectedAtReset,
            exhaustsAt: exhaustDate,
            verdict: smoothed(raw, previous: previous),
            rawVerdict: raw,
            severity: severity,
            text: text,
            curve: curve)
    }

    /// Bisects the crossing of the 100% line to the second. The trajectory
    /// is monotonic, so the bracket is sound by construction.
    private static func crossingDate(
        between lower: Date, and upper: Date,
        percent: Double, gained: (Date) -> Double
    ) -> Date {
        var lower = lower
        var upper = upper
        while upper.timeIntervalSince(lower) > 1 {
            let mid = lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
            if percent + gained(mid) >= 100 {
                upper = mid
            } else {
                lower = mid
            }
        }
        return upper
    }

    /// Two-refresh hysteresis: the displayed verdict moves only when this
    /// refresh's raw classification repeats the previous refresh's — one
    /// noisy reading (either direction) never flips colors or captions.
    static func smoothed(
        _ raw: UsagePrediction.Verdict, previous: UsagePrediction?
    ) -> UsagePrediction.Verdict {
        guard let previous else { return raw }
        if raw == previous.verdict { return raw }
        return raw == previous.rawVerdict ? raw : previous.verdict
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
