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
    /// basis only): >1 running hot, <1 running cool. This is the
    /// INSTANTANEOUS reading — the forecast does not carry it flat across
    /// the whole remaining window. A pace deviation is assumed to fade over
    /// about a day (`PredictionEngine.paceDecayHours`), so a hot Tuesday
    /// steepens Wednesday's forecast, not next Monday's.
    public let paceFactor: Double?
    public let basis: Basis
    /// Projected percent at the window reset (clamped to 100); nil without a
    /// live reset time.
    public let projectedAtReset: Int?
    /// What the window would reach at its reset if the limit did not bind —
    /// the same projection as `projectedAtReset` before the clamp, and
    /// un-rounded. Narrower-window lockouts are still respected (the account
    /// genuinely cannot spend inside one), so this is "the pace's own
    /// destination", not an unconstrained ray. Its excess over 100 is how
    /// much extra usage the window would need (`ForecastOvershoot`). Nil
    /// wherever `projectedAtReset` is nil, and on the spent path — a limit
    /// already gone has no forecast left to overshoot.
    public let projectedUnclamped: Double?
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
        curve: [Point], projectedUnclamped: Double? = nil
    ) {
        self.projectedUnclamped = projectedUnclamped
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
///
/// LOCKOUTS — one meter's forecast reads its siblings. A limit window
/// strictly SHORTER than this meter's is a gate on it: while the 5-hour
/// session limit is spent, the account cannot spend anything at all, so the
/// weekly meters gain exactly nothing until that session window resets. The
/// forecast used to climb straight through those hours at the learned
/// rhythm and announce a weekly crossing that the account had no way to
/// reach (the user's report). `lockouts(on:from:predictions:now:)` derives
/// those stretches — from a sibling already at 100, or from a sibling's own
/// fresh forecast crossing before its reset — and `predictAll` feeds them
/// in by predicting narrow windows first. Inside a lockout the wider meter
/// gains nothing: baseline rhythm and burst excess both stop, and both
/// resume where the clock has got to when it ends. Equal or longer windows
/// never gate (the scoped weekly does not lock out the all-models weekly —
/// other models can still spend), and a meter with no known window neither
/// issues nor receives a lockout.
///
/// `exhaustsAt` stays "the FIRST instant the value reaches 100". On the
/// linear path that means accrual finishing exactly at a lockout's start
/// reports the start (no hours accrue inside, so every instant of the
/// lockout carries that same value); on the blended path a trajectory that
/// only reaches 100 after the plateau reports the lockout's END. Neither
/// path ever reports an instant strictly inside a lockout.
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
    /// How long a pace deviation is assumed to persist, in hours: the
    /// weekly-profile baseline's pace factor decays toward 1 with this time
    /// constant instead of scaling the whole remaining window flat. Running
    /// hot today says something about tomorrow and almost nothing about the
    /// same weekday next week — a flat multiplier compressed the learned
    /// week's rhythm into the days before the crossing, steepening every
    /// remaining day at once and pulling a forecast crossing forward.
    public static let paceDecayHours = 24.0
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
    /// `lockouts` are the stretches in which a shorter-window sibling has
    /// the account gated (see `lockouts(on:from:predictions:now:)`); none
    /// is the forecast exactly as it was before they existed.
    public static func predict(
        meter: Meter, samples: [UsageSample], profile: WeeklyProfile? = nil,
        previous: UsagePrediction? = nil, lockouts: [DateInterval] = [],
        now: Date
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
            profile: profile, previous: previous, lockouts: lockouts, now: now)
    }

    // MARK: - Lockouts

    /// The stretches of future time in which `meter` cannot gain anything,
    /// because a sibling on a STRICTLY shorter limit window has the account
    /// gated until that sibling resets.
    ///
    /// A sibling gates when (1) it reads 100% now and its reset is still
    /// ahead — a measured hard stop — or (2) its own fresh forecast crosses
    /// (`exhaustsAt`) before its reset, in which case the gate opens at the
    /// crossing. Rule (1) reads the METER, not the prediction map, so a
    /// spent session still gates the weeklies even when it produced no
    /// prediction of its own (a flat all-100 tail has no measurable rate).
    ///
    /// Equal or longer windows never gate: the scoped weekly running out
    /// leaves the all-models weekly free to spend on other models. A meter
    /// with no known window neither issues nor receives a lockout — its
    /// shape is unknown, and guessing is worse than the old behavior.
    ///
    /// `predictions` is keyed by meter label, the way the engine keeps them.
    /// The result is clipped to the future, sorted and merged.
    public static func lockouts(
        on meter: Meter, from meters: [Meter],
        predictions: [String: UsagePrediction], now: Date
    ) -> [DateInterval] {
        guard let window = meter.limitWindow else { return [] }
        var raw: [DateInterval] = []
        for other in meters {
            // Strictly shorter, which also rules the meter out against
            // itself — nothing is shorter than its own window.
            guard let otherWindow = other.limitWindow, otherWindow < window else { continue }
            guard let reset = other.resetsAt, reset > now else { continue }
            let start: Date
            if let percent = other.percent, percent >= 100 {
                start = now
            } else if let crossing = predictions[other.label]?.exhaustsAt, crossing < reset {
                start = max(crossing, now)
            } else {
                continue
            }
            guard start < reset else { continue }
            raw.append(DateInterval(start: start, end: reset))
        }
        return mergedLockouts(raw, now: now)
    }

    /// Clips lockouts to the future, sorts them and merges the ones that
    /// overlap OR touch — a 5-hour gate ending exactly where a 6-hour one
    /// begins is one continuous stretch of not being able to spend.
    static func mergedLockouts(_ raw: [DateInterval], now: Date) -> [DateInterval] {
        var clipped: [(start: Date, end: Date)] = []
        for interval in raw where interval.end > now {
            let start = max(interval.start, now)
            if interval.end > start { clipped.append((start, interval.end)) }
        }
        clipped.sort { $0.start < $1.start }
        var merged: [DateInterval] = []
        for span in clipped {
            if let last = merged.last, span.start <= last.end {
                guard span.end > last.end else { continue }
                merged[merged.count - 1] = DateInterval(start: last.start, end: span.end)
            } else {
                merged.append(DateInterval(start: span.start, end: span.end))
            }
        }
        return merged
    }

    /// `[start, end]` minus the lockouts: the sub-spans in which this meter
    /// can actually spend. Expects `lockouts` merged and sorted (what
    /// `mergedLockouts` returns); empty lockouts hand back the whole span.
    static func availableSpans(
        from start: Date, to end: Date, lockouts: [DateInterval]
    ) -> [(start: Date, end: Date)] {
        guard end > start else { return [] }
        guard !lockouts.isEmpty else { return [(start, end)] }
        var spans: [(start: Date, end: Date)] = []
        var cursor = start
        for lock in lockouts {
            if lock.end <= cursor { continue }
            if lock.start >= end { break }
            if lock.start > cursor { spans.append((cursor, lock.start)) }
            cursor = max(cursor, lock.end)
            if cursor >= end { return spans }
        }
        if cursor < end { spans.append((cursor, end)) }
        return spans
    }

    /// Hours of the span in which spending is possible.
    static func availableHours(
        from start: Date, to end: Date, lockouts: [DateInterval]
    ) -> Double {
        guard end > start else { return 0 }
        guard !lockouts.isEmpty else { return end.timeIntervalSince(start) / 3600 }
        return availableSpans(from: start, to: end, lockouts: lockouts)
            .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 3600 }
    }

    /// The instant at which `needed` AVAILABLE hours have accrued from
    /// `start` — walking the lockouts and extrapolating past the last one.
    /// Accrual completing exactly at a lockout's start lands on the start:
    /// no hours pass inside, so that is the first instant the total is met.
    static func date(
        afterAvailableHours needed: Double, from start: Date, lockouts: [DateInterval]
    ) -> Date {
        guard !lockouts.isEmpty else { return start.addingTimeInterval(needed * 3600) }
        var remaining = needed * 3600
        var cursor = start
        for lock in lockouts {
            if lock.end <= cursor { continue }
            let free = lock.start.timeIntervalSince(cursor)
            if free > 0 {
                if remaining <= free { return cursor.addingTimeInterval(remaining) }
                remaining -= free
            }
            cursor = max(cursor, lock.end)
        }
        return cursor.addingTimeInterval(remaining)
    }

    /// Every meter's forecast in one pass, narrowest limit window first so
    /// each meter can be told what its shorter siblings have already locked
    /// out (nil windows last, in their original order — they neither issue
    /// nor receive lockouts). Keyed by label, like the engine's own map.
    public static func predictAll(
        meters: [Meter], samples: [UsageSample],
        profiles: [String: WeeklyProfile], previous: [String: UsagePrediction],
        now: Date
    ) -> [String: UsagePrediction] {
        let ordered = meters.enumerated().sorted { lhs, rhs in
            switch (lhs.element.limitWindow, rhs.element.limitWindow) {
            case let (left?, right?):
                return left == right ? lhs.offset < rhs.offset : left < right
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)

        var fresh: [String: UsagePrediction] = [:]
        for meter in ordered {
            let gates = lockouts(
                on: meter, from: meters, predictions: fresh, now: now)
            if let prediction = predict(
                meter: meter, samples: samples, profile: profiles[meter.label],
                previous: previous[meter.label], lockouts: gates, now: now) {
                fresh[meter.label] = prediction
            }
        }
        return fresh
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
    ///
    /// `until` closes the range for a window that has already ended, so the
    /// audit can ask the same question of a CLOSED window and get that
    /// window's own crossing rather than the newest one. Nil (the live
    /// window's case) leaves the range open-ended and the tail seam below
    /// is what finds the boundary.
    public static func spentAt(
        samples: [UsageSample], label: String, since: Date? = nil, until: Date? = nil
    ) -> Date? {
        let points = samples
            .filter { sample in since.map { sample.t >= $0 } ?? true }
            .filter { sample in until.map { sample.t <= $0 } ?? true }
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
            // The pace deviation fades: multiplier(t) = 1 + (pace − 1)·e^(−h/τ),
            // h = hours from `now` to t, τ = paceDecayHours. At `now` it is
            // the full pace factor (so `baselineRatePerHour` still reports
            // what this window is actually doing); a week out it is the
            // learned rhythm untouched.
            func multiplier(_ t: Date) -> Double {
                let hours = t.timeIntervalSince(now) / 3600
                return 1 + (pace - 1) * exp(-hours / paceDecayHours)
            }
            return Baseline(
                basis: .weeklyProfile, paceFactor: pace,
                rate: { profile.rate(at: $0) * multiplier($0) },
                // The profile's own block walk (`expectedPercent`), with the
                // exact integral of the decaying multiplier over each block:
                // r × [(b−a) + (pace−1)·τ·(e^(−(a−now)/τ) − e^(−(b−now)/τ))],
                // all in hours. h is measured from `now`, not from `a`, so
                // spans telescope — gained(now,x) + gained(x,y) ==
                // gained(now,y). Callers only ever ask forward; a span
                // starting before `now` would read a multiplier above the
                // pace factor, which nothing wants.
                gained: { start, end in
                    guard end > start else { return 0 }
                    var total = 0.0
                    var cursor = start
                    while cursor < end {
                        let sliceEnd = min(
                            WeeklyProfile.blockEnd(after: cursor, calendar: profile.calendar),
                            end)
                        let a = cursor.timeIntervalSince(now) / 3600
                        let b = sliceEnd.timeIntervalSince(now) / 3600
                        total += profile.rate(at: cursor)
                            * ((b - a) + (pace - 1) * paceDecayHours
                                * (exp(-a / paceDecayHours) - exp(-b / paceDecayHours)))
                        cursor = sliceEnd
                    }
                    return total
                })
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
        previous: UsagePrediction? = nil, spentAt: Date? = nil,
        lockouts: [DateInterval] = [], now: Date
    ) -> UsagePrediction {
        // Nothing left to forecast once the limit is gone; the crossing
        // comes from the record, not from extrapolating zero headroom. A
        // spent meter ignores its lockouts — there is nothing left to gate.
        if percent >= 100 {
            return spent(resetsAt: resetsAt, at: spentAt, now: now)
        }
        // Normalized here, once, so every path below can assume merged,
        // sorted, future-clipped gates — callers may hand over anything.
        let gates = mergedLockouts(lockouts, now: now)
        let liveReset = resetsAt.flatMap { $0 > now ? $0 : nil }
        if let reset = liveReset,
           let baseline = baseline(
               percent: percent, reset: reset, windowLength: windowLength,
               profile: profile, now: now) {
            return blended(
                percent: percent, reset: reset, rate: rate,
                baseline: baseline, lockouts: gates, previous: previous, now: now)
        }
        return linear(
            percent: percent, liveReset: liveReset, rate: rate,
            lockouts: gates, previous: previous, now: now)
    }

    // MARK: - Pure linear (no baseline)

    /// Pure extrapolation of the recent rate — over AVAILABLE hours only:
    /// a lockout stops the clock, so the projection at reset counts the
    /// hours the account can actually spend in, the crossing is the instant
    /// those hours reach `(100 − percent) / rate`, and the curve carries a
    /// point at every lockout boundary so the plateau is drawn flat instead
    /// of being interpolated straight through.
    private static func linear(
        percent: Int, liveReset: Date?, rate: Double,
        lockouts: [DateInterval], previous: UsagePrediction?, now: Date
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
                } ?? [],
                projectedUnclamped: liveReset != nil ? Double(percent) : nil)
        }

        // The hours of SPENDING it takes, then the wall clock they land on.
        let hoursToExhaust = Double(100 - percent) / rate
        let exhaustDate = date(
            afterAvailableHours: hoursToExhaust, from: now, lockouts: lockouts)
        // Captions speak wall-clock time — identical to `hoursToExhaust`
        // when nothing gates, longer when a lockout sits in between.
        let hoursUntilExhaust = exhaustDate.timeIntervalSince(now) / 3600

        /// The straight-line value at an instant, over available hours.
        func value(at t: Date) -> Double {
            Double(percent) + rate * availableHours(from: now, to: t, lockouts: lockouts)
        }
        /// A point at every lockout boundary strictly between now and
        /// `limit`, so the curve's plateaus have exact corners. Empty
        /// without lockouts — the curve is then exactly what it always was.
        func boundaryPoints(before limit: Date) -> [UsagePrediction.Point] {
            guard !lockouts.isEmpty else { return [] }
            return lockouts
                .flatMap { [$0.start, $0.end] }
                .filter { $0 > now && $0 < limit }
                .sorted()
                .map { .init(t: $0, percent: value(at: $0)) }
        }

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
                text: "≈\(durationText(hours: hoursUntilExhaust)) to limit",
                curve: [])
        }

        let projected = Double(percent)
            + rate * availableHours(from: now, to: reset, lockouts: lockouts)
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
                text: "≈\(durationText(hours: hoursUntilExhaust)) until limit",
                curve: [start]
                    + boundaryPoints(before: exhaustDate)
                    + [.init(t: exhaustDate, percent: 100),
                       .init(t: reset, percent: 100)],
                projectedUnclamped: projected)
        }
        let endpoint = UsagePrediction.Point(t: reset, percent: projected)
        let rising = boundaryPoints(before: reset)
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
                curve: [start] + rising + [endpoint],
                projectedUnclamped: projected)
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
            curve: [start] + rising + [endpoint],
            projectedUnclamped: projected)
    }

    // MARK: - Damped blend

    /// Projected usage gained by time t: the baseline's expectation for the
    /// span, plus the recent rate's excess over it, damped — the excess
    /// contributes `burstDecayHours × (1 − e^(−h/τ))` hours of itself, which
    /// converges to about one hour however long the window runs. Since the
    /// recent rate is never negative, the total is never negative either.
    ///
    /// The BASELINE itself decays the same way on the weekly-profile basis:
    /// its pace factor fades toward 1 over `paceDecayHours`, because a
    /// deviation is news about the next day, not about the whole week. A hot
    /// Tuesday should steepen Wednesday's forecast, not next Monday's.
    /// Scaling the entire remaining window flat compressed the learned
    /// week's rhythm into the days before the crossing — with a flattened
    /// profile it read an ordinary Tuesday as ~1.3× hot and then charged
    /// every remaining day that much, which is what put a red "runs out
    /// Monday" on a week that ends quiet.
    ///
    /// LOCKOUTS make `gained` a sum over the AVAILABLE sub-spans of
    /// [now, t] — the span minus the stretches a shorter-window sibling has
    /// gated (a spent 5-hour session is a hard zero for the weeklies until
    /// it resets; the forecast used to climb straight through those hours at
    /// the learned rhythm). Over each available [a, b], in hours from `now`:
    ///
    ///     baseline.gained(a, b) + excess × τ × (e^(−a/τ) − e^(−b/τ))
    ///
    /// which is the exact integral of the decaying excess over that piece —
    /// the decay is still measured from `now` throughout, so the burst
    /// simply contributes nothing during a lockout and its remainder
    /// resumes at whatever it has decayed to when the gate opens. The
    /// baseline term telescopes the same way. With no lockouts the sum is
    /// the single span [now, t] and this is the original expression.
    private static func blended(
        percent: Int, reset: Date, rate: Double, baseline: Baseline,
        lockouts: [DateInterval], previous: UsagePrediction?, now: Date
    ) -> UsagePrediction {
        let percentD = Double(percent)
        let baseRateNow = baseline.rate(now)
        let excess = rate - baseRateNow
        func gained(by t: Date) -> Double {
            guard !lockouts.isEmpty else {
                let hours = t.timeIntervalSince(now) / 3600
                let damped = burstDecayHours * (1 - exp(-hours / burstDecayHours))
                return baseline.gained(now, t) + excess * damped
            }
            var total = 0.0
            for span in availableSpans(from: now, to: t, lockouts: lockouts) {
                let a = span.start.timeIntervalSince(now) / 3600
                let b = span.end.timeIntervalSince(now) / 3600
                total += baseline.gained(span.start, span.end)
                    + excess * burstDecayHours
                        * (exp(-a / burstDecayHours) - exp(-b / burstDecayHours))
            }
            return total
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
                curve: [start, .init(t: reset, percent: percentD)],
                projectedUnclamped: projectedRaw)
        }

        let severity = max(0, min(1,
            (projectedRaw - yellowProjectionThreshold) / (100 - yellowProjectionThreshold)))

        // Sample the curved trajectory; clamp at the limit with an exact
        // knee where it crosses.
        var curve = [start]
        var exhaustDate: Date?
        let horizon = reset.timeIntervalSince(now)
        var previousT = now
        // The uniform samples, plus a sample at each lockout boundary inside
        // the horizon: a plateau smeared over a 3.5-hour step would read as
        // a gentle slope instead of the flat stretch it is.
        var times = (1...curveSampleCount).map {
            now.addingTimeInterval(horizon * Double($0) / Double(curveSampleCount))
        }
        if !lockouts.isEmpty {
            times += lockouts
                .flatMap { [$0.start, $0.end] }
                .filter { $0 > now && $0 < reset }
            times.sort()
            times = times.reduce(into: [Date]()) { unique, t in
                if unique.last != t { unique.append(t) }
            }
        }
        for t in times {
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
            curve: curve,
            projectedUnclamped: projectedRaw)
    }

    /// Bisects the crossing of the 100% line to the second. The trajectory
    /// is monotonic non-decreasing, so the bracket is sound by construction
    /// — a lockout only ever flattens it (derivative exactly 0 there).
    /// The bracket may now sit on such a plateau; the search converges on
    /// the FIRST instant the value reaches 100, and since `upper` is only
    /// ever moved to an instant that tested `>= 100`, it can never come to
    /// rest strictly inside a flat sub-100 stretch. A crossing that happens
    /// as the gate opens is reported at the lockout's end, not inside it.
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
