import Foundation
import Testing
@testable import UsageCore

private func sample(_ minutesAgo: Double, _ percent: Int, label: String = "Session (5h)", now: Date) -> UsageSample {
    UsageSample(t: now.addingTimeInterval(-minutesAgo * 60), percents: [label: percent])
}

private let gmt: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "GMT")!
    return calendar
}()

/// A ready profile with the given per-bucket rates, built directly rather
/// than learned: `build`'s shrinkage toward the global mean leaves buckets
/// only *almost* equal, and the pace-decay math below is asserted against a
/// closed form that needs the rates it was given.
private func readyProfile(rates: [Double]) -> WeeklyProfile {
    WeeklyProfile(
        rates: rates,
        observedHours: Array(repeating: 24.0, count: WeeklyProfile.bucketCount),
        globalRatePerHour: rates.reduce(0, +) / Double(rates.count),
        historySpan: 21 * 86400,
        pairCount: 500,
        calendar: gmt)
}

@Suite("PredictionEngine")
struct PredictionEngineTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("steady climb yields percent-per-hour slope")
    func slope() {
        let samples = [sample(60, 10, now: now), sample(30, 15, now: now), sample(0, 20, now: now)]
        let rate = PredictionEngine.ratePerHour(samples: samples, label: "Session (5h)", window: 2 * 3600, now: now)
        #expect(rate != nil)
        #expect(abs(rate! - 10) < 0.01)
    }

    @Test("a reset drop discards pre-drop samples")
    func resetDrop() {
        let samples = [
            sample(90, 80, now: now), sample(60, 90, now: now),
            sample(30, 5, now: now), sample(0, 10, now: now),
        ]
        let rate = PredictionEngine.ratePerHour(samples: samples, label: "Session (5h)", window: 3 * 3600, now: now)
        #expect(rate != nil)
        #expect(abs(rate! - 10) < 0.01)
    }

    @Test("insufficient span or points yields nil")
    func insufficient() {
        #expect(PredictionEngine.ratePerHour(samples: [sample(0, 10, now: now)], label: "Session (5h)", window: 3600, now: now) == nil)
        let tight = [sample(2, 10, now: now), sample(0, 11, now: now)]
        #expect(PredictionEngine.ratePerHour(samples: tight, label: "Session (5h)", window: 3600, now: now) == nil)
        #expect(PredictionEngine.ratePerHour(samples: [], label: "missing", window: 3600, now: now) == nil)
    }

    @Test("least-squares rate mutes a single quantized endpoint step")
    func quantizedStep() {
        // Flat for 10 minutes, then one +1 integer step: an endpoint secant
        // reads 4%/h; the fit stays below it because the plateau counts.
        let samples = [
            sample(15, 10, now: now), sample(10, 10, now: now),
            sample(5, 10, now: now), sample(0, 11, now: now),
        ]
        let rate = PredictionEngine.ratePerHour(samples: samples, label: "Session (5h)", window: 3600, now: now)
        #expect(rate != nil)
        #expect(abs(rate! - 3.6) < 0.1)
    }

    @Test("red: current rate exhausts before reset, curve knees at 100")
    func red() {
        let reset = now.addingTimeInterval(2 * 3600)
        let prediction = PredictionEngine.prediction(
            percent: 80, resetsAt: reset, ratePerHour: 20, now: now)
        #expect(prediction.verdict == .red)
        #expect(prediction.rawVerdict == .red)
        #expect(prediction.basis == .recentOnly)
        #expect(prediction.severity == 1)
        #expect(prediction.text.contains("1h"))
        #expect(prediction.projectedAtReset == 100)
        #expect(prediction.exhaustsAt == now.addingTimeInterval(3600))
        #expect(prediction.curve == [
            .init(t: now, percent: 80),
            .init(t: now.addingTimeInterval(3600), percent: 100),
            .init(t: reset, percent: 100),
        ])
    }

    @Test("yellow: projected close to the limit at reset")
    func yellow() {
        let reset = now.addingTimeInterval(3 * 3600)
        let prediction = PredictionEngine.prediction(
            percent: 60, resetsAt: reset, ratePerHour: 10, now: now)
        #expect(prediction.verdict == .yellow)
        // Projected 90 sits a third of the way up the 85→100 ramp.
        #expect(abs(prediction.severity - 1.0 / 3.0) < 0.0001)
        #expect(prediction.text.contains("90%"))
        #expect(prediction.projectedAtReset == 90)
        #expect(prediction.exhaustsAt == nil)
        #expect(prediction.curve == [
            .init(t: now, percent: 60), .init(t: reset, percent: 90),
        ])
    }

    @Test("green: comfortable projection with straight curve")
    func green() {
        let reset = now.addingTimeInterval(3 * 3600)
        let prediction = PredictionEngine.prediction(
            percent: 20, resetsAt: reset, ratePerHour: 5, now: now)
        #expect(prediction.verdict == .green)
        #expect(prediction.severity == 0)
        #expect(prediction.text.contains("35%"))
        #expect(prediction.projectedAtReset == 35)
        #expect(prediction.curve == [
            .init(t: now, percent: 20), .init(t: reset, percent: 35),
        ])
    }

    @Test("flat rate is green and steady with a flat curve")
    func steady() {
        let reset = now.addingTimeInterval(3600)
        let prediction = PredictionEngine.prediction(
            percent: 50, resetsAt: reset, ratePerHour: 0.05, now: now)
        #expect(prediction.verdict == .green)
        #expect(prediction.severity == 0)
        #expect(prediction.text == "steady — not burning")
        #expect(prediction.projectedAtReset == 50)
        #expect(prediction.curve == [
            .init(t: now, percent: 50), .init(t: reset, percent: 50),
        ])
    }

    @Test("no live reset: exhaustion date but no projection or curve")
    func noReset() {
        let prediction = PredictionEngine.prediction(
            percent: 50, resetsAt: nil, ratePerHour: 10, now: now)
        #expect(prediction.verdict == .green)
        #expect(prediction.severity == 0)
        #expect(prediction.text.contains("to limit"))
        #expect(prediction.projectedAtReset == nil)
        #expect(prediction.exhaustsAt == now.addingTimeInterval(5 * 3600))
        #expect(prediction.curve.isEmpty)
        // A reset in the past counts as no live reset.
        let stale = PredictionEngine.prediction(
            percent: 50, resetsAt: now.addingTimeInterval(-60), ratePerHour: 10, now: now)
        #expect(stale.curve.isEmpty)
    }

    @Test("predict pulls percent and rate from the meter and samples")
    func predictEndToEnd() {
        let meter = Meter(
            id: "0-session", label: "Session (5h)", percent: 20,
            resetsAt: now.addingTimeInterval(3 * 3600), level: .normal, rank: 0,
            limitWindow: 5 * 3600)
        let samples = [sample(60, 10, now: now), sample(30, 15, now: now), sample(0, 20, now: now)]
        let prediction = PredictionEngine.predict(meter: meter, samples: samples, now: now)
        #expect(prediction?.verdict == .green)
        #expect(abs((prediction?.ratePerHour ?? 0) - 10) < 0.01)
        // The 5h session window stays pure-linear — bursts there ARE the signal.
        #expect(prediction?.basis == .recentOnly)
        // Too little data → no prediction at all.
        #expect(PredictionEngine.predict(meter: meter, samples: [], now: now) == nil)
    }

    // MARK: - Damped blend

    @Test("a weekly burst damps toward the window's average pace")
    func weeklyBurstDamped() {
        // 20% used, 3 days into the week, a hot session measuring 4%/h.
        // Naive linear says 20 + 4×96 = 404% — exhausted within a day. The
        // damped forecast charges the burst about one hour of its excess and
        // hands the rest of the horizon to the average pace (0.28%/h).
        let reset = now.addingTimeInterval(96 * 3600)
        let prediction = PredictionEngine.prediction(
            percent: 20, resetsAt: reset, ratePerHour: 4,
            windowLength: 7 * 86400, now: now)
        #expect(prediction.basis == .windowAverage)
        #expect(prediction.verdict == .green)
        #expect(prediction.exhaustsAt == nil)
        #expect(prediction.projectedAtReset == 50)
        #expect(abs((prediction.baselineRatePerHour ?? 0) - 20.0 / 72) < 0.001)
        // The curve bends: burst slope at the start, baseline slope later.
        let curve = prediction.curve
        #expect(curve.count > 10)
        #expect(zip(curve, curve.dropFirst()).allSatisfy { $0.0.t < $0.1.t })
        let early = (curve[1].percent - curve[0].percent)
            / (curve[1].t.timeIntervalSince(curve[0].t) / 3600)
        let late = (curve[curve.count - 1].percent - curve[curve.count - 2].percent)
            / (curve[curve.count - 1].t.timeIntervalSince(curve[curve.count - 2].t) / 3600)
        #expect(early > late)
    }

    @Test("a quiet window with typical pace still projects forward")
    func quietWindowProjects() {
        // Not burning right now, but 30% went in the first 3 days — the
        // baseline keeps projecting that pace instead of "steady forever".
        let reset = now.addingTimeInterval(96 * 3600)
        let prediction = PredictionEngine.prediction(
            percent: 30, resetsAt: reset, ratePerHour: 0,
            windowLength: 7 * 86400, now: now)
        #expect(prediction.basis == .windowAverage)
        // 30/72 %/h × 96h ≈ 40 more — minus the ~1h the idle "burst" gives back.
        #expect(prediction.projectedAtReset == 70)
        #expect(prediction.verdict == .green)
    }

    @Test("blended crossing lands where the baseline math says")
    func blendedCrossing() {
        // 90% used at the window-average pace of 1.25%/h, no excess: the
        // remaining 10% goes in exactly 8 hours.
        let reset = now.addingTimeInterval(96 * 3600)
        let prediction = PredictionEngine.prediction(
            percent: 90, resetsAt: reset, ratePerHour: 1.25,
            windowLength: 7 * 86400, now: now)
        #expect(prediction.rawVerdict == .red)
        #expect(prediction.projectedAtReset == 100)
        let exhaust = prediction.exhaustsAt
        #expect(exhaust != nil)
        #expect(abs(exhaust!.timeIntervalSince(now) - 8 * 3600) < 60)
        #expect(prediction.curve.last == .init(t: reset, percent: 100))
        #expect(zip(prediction.curve, prediction.curve.dropFirst())
            .allSatisfy { $0.0.t < $0.1.t })
    }

    @Test("blended quiet-and-empty window reads steady")
    func blendedSteady() {
        let reset = now.addingTimeInterval(96 * 3600)
        let prediction = PredictionEngine.prediction(
            percent: 0, resetsAt: reset, ratePerHour: 0.05,
            windowLength: 7 * 86400, now: now)
        #expect(prediction.text == "steady — not burning")
        #expect(prediction.projectedAtReset == 0)
        #expect(prediction.severity == 0)
    }

    @Test("verdict changes need two consecutive agreeing readings")
    func hysteresis() {
        let reset = now.addingTimeInterval(96 * 3600)
        func read(percent: Int, previous: UsagePrediction?) -> UsagePrediction {
            PredictionEngine.prediction(
                percent: percent, resetsAt: reset, ratePerHour: 1,
                windowLength: 7 * 86400, previous: previous, now: now)
        }
        let calm = read(percent: 20, previous: nil)
        #expect(calm.verdict == .green)
        // First hot reading: raw flips, display holds.
        let hot1 = read(percent: 70, previous: calm)
        #expect(hot1.rawVerdict == .red)
        #expect(hot1.verdict == .green)
        // Second agreeing reading: display follows.
        let hot2 = read(percent: 70, previous: hot1)
        #expect(hot2.verdict == .red)
        // De-escalation is symmetric.
        let cool1 = read(percent: 20, previous: hot2)
        #expect(cool1.rawVerdict == .green)
        #expect(cool1.verdict == .red)
        let cool2 = read(percent: 20, previous: cool1)
        #expect(cool2.verdict == .green)
    }

    @Test("the weekly profile becomes the baseline once ready")
    func profileBaseline() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        // Three weeks of half-hourly samples: burn 2%/h on weekdays
        // 08:00–16:00, silence otherwise, weekly reset drops to 0.
        var samples: [UsageSample] = []
        let start = Date(timeIntervalSince1970: 1_000_000)
        var percent = 0
        var t = start
        for _ in 0..<(21 * 48) {
            let weekday = calendar.component(.weekday, from: t)
            let hour = calendar.component(.hour, from: t)
            if calendar.component(.weekday, from: t.addingTimeInterval(1800))
                != weekday, weekday == 1 {
                percent = 0  // Sunday midnight: the window resets.
            } else if (2...6).contains(weekday), (8..<16).contains(hour) {
                percent += 1  // +1% per half hour = 2%/h
            }
            t = t.addingTimeInterval(1800)
            samples.append(UsageSample(t: t, percents: ["Weekly · all models": percent]))
        }
        let profile = WeeklyProfile.build(
            samples: samples, label: "Weekly · all models", calendar: calendar)
        #expect(profile != nil)
        #expect(profile!.isReady)

        let meter = Meter(
            id: "1-weekly_all", label: "Weekly · all models", percent: 30,
            resetsAt: t.addingTimeInterval(2 * 86400), level: .normal, rank: 1,
            limitWindow: 7 * 86400)
        let prediction = PredictionEngine.predict(
            meter: meter, samples: samples, profile: profile, now: t)
        #expect(prediction != nil)
        #expect(prediction?.basis == .weeklyProfile)
        #expect(prediction?.paceFactor != nil)
        #expect((prediction?.projectedAtReset ?? 0) >= 30)
    }

    // MARK: - Pace decay

    /// 2020-09-13 12:00:00 GMT — a Sunday, and a multiple of 4 hours since
    /// the epoch, so it sits exactly on a profile block boundary. The block
    /// walks below then cover whole blocks and their sums are exact.
    static let blockAligned = Date(timeIntervalSince1970: 1_599_998_400)
    /// Rates repeating 0, 1, 2 %/h across the 42 buckets. Deliberately NOT
    /// uniform, so a block walk that mis-attributes a slice shows up — and
    /// 42 is a multiple of 3, so any six consecutive blocks sum to 6 %/h
    /// (= 24 percentage points over their 24 hours) wherever they wrap.
    static let steppedRates = (0..<WeeklyProfile.bucketCount).map { Double($0 % 3) }

    @Test("a hot pace steepens the next day, not the whole remaining window")
    func paceDecaysOverTheHorizon() throws {
        // 24h of window elapsed at the typical rhythm's 24 points, but 38%
        // actually spent: the window reads hot. The horizon is five more
        // days — far past the one-day decay constant.
        let now = Self.blockAligned
        let profile = readyProfile(rates: Self.steppedRates)
        let reset = now.addingTimeInterval(120 * 3600)
        let baseline = try #require(PredictionEngine.baseline(
            percent: 38, reset: reset, windowLength: 144 * 3600,
            profile: profile, now: now))
        #expect(baseline.basis == .weeklyProfile)
        let pace = try #require(baseline.paceFactor)
        // Strictly inside the clamp, or the assertions below would hold for
        // reasons unrelated to the decay.
        #expect(pace > 1.01 && pace < WeeklyProfile.paceFactorRange.upperBound - 0.01)

        let gained = baseline.gained(now, reset)
        let atRhythm = profile.expectedPercent(from: now, to: reset)
        #expect(atRhythm > 0)
        // More than the plain rhythm — the window IS running hot…
        #expect(gained > atRhythm + 0.01)
        // …but far less than the old flat multiplier, which charged every
        // one of the five remaining days the full pace factor.
        #expect(gained < pace * atRhythm - 0.01)

        // The rate at `now` still reports the full pace factor: the decay is
        // about the horizon, not about what the meter is doing right now.
        #expect(abs(baseline.rate(now) - profile.rate(at: now) * pace) < 1e-9)
    }

    @Test("past the decay constant the pace adds τ hours of baseline, no more")
    func paceExtraConvergesToTau() throws {
        // A uniform 0.5%/h rhythm so the block walk's sum equals the
        // analytic integral exactly, and a 168h horizon = 7τ.
        let now = Self.blockAligned
        let rate = 0.5
        let profile = readyProfile(
            rates: Array(repeating: rate, count: WeeklyProfile.bucketCount))
        let horizon = 168.0
        let reset = now.addingTimeInterval(horizon * 3600)
        // windowStart = now − 24h, where the rhythm expected 12 points.
        let baseline = try #require(PredictionEngine.baseline(
            percent: 20, reset: reset, windowLength: (horizon + 24) * 3600,
            profile: profile, now: now))
        let pace = try #require(baseline.paceFactor)
        #expect(abs(pace - 25.0 / 17.0) < 1e-9)

        let tau = PredictionEngine.paceDecayHours
        // ∫₀^H r·(1 + (p−1)e^(−h/τ)) dh = r·H + r·(p−1)·τ·(1 − e^(−H/τ)),
        // and at H = 7τ the trailing e^(−7) ≈ 9e-4 is all that separates it
        // from the limit r·H + r·(p−1)·τ.
        let extra = rate * (pace - 1) * tau
        let closedForm = rate * horizon + extra
        let residual = extra * exp(-horizon / tau)
        #expect(residual < 0.01)
        // The extra is ~5.6 points — three orders above the tolerance, so
        // this really is asserting the decay's size, not just its sign.
        #expect(extra > 5)
        #expect(abs(baseline.gained(now, reset) - closedForm) < 0.01)
    }

    @Test("a pace of exactly 1 reproduces the plain weekly rhythm")
    func paceOfOneIsTheRhythm() throws {
        // The stepped profile expects exactly 24 points over the 24h of
        // window already elapsed; spending exactly 24 makes the pace factor
        // (24+5)/(24+5) = 1, where the multiplier is identically 1 and the
        // block walk must collapse onto `expectedPercent`.
        let now = Self.blockAligned
        let profile = readyProfile(rates: Self.steppedRates)
        let windowStart = now.addingTimeInterval(-24 * 3600)
        #expect(abs(profile.expectedPercent(from: windowStart, to: now) - 24) < 1e-9)

        let reset = now.addingTimeInterval(72 * 3600)
        let baseline = try #require(PredictionEngine.baseline(
            percent: 24, reset: reset, windowLength: 96 * 3600,
            profile: profile, now: now))
        #expect(baseline.paceFactor == 1)
        for hours in [1.0, 5.0, 26.0, 72.0] {
            let t = now.addingTimeInterval(hours * 3600)
            #expect(abs(baseline.gained(now, t)
                - profile.expectedPercent(from: now, to: t)) < 1e-9)
            #expect(abs(baseline.rate(t) - profile.rate(at: t)) < 1e-9)
        }
    }

    @Test("curve interpolation crosses the knee correctly")
    func curveInterpolation() {
        let curve: [UsagePrediction.Point] = [
            .init(t: now, percent: 80),
            .init(t: now.addingTimeInterval(3600), percent: 100),
            .init(t: now.addingTimeInterval(7200), percent: 100),
        ]
        #expect(PredictionEngine.percent(onCurve: curve, at: now.addingTimeInterval(1800)) == 90)
        #expect(PredictionEngine.percent(onCurve: curve, at: now.addingTimeInterval(5400)) == 100)
        #expect(PredictionEngine.percent(onCurve: curve, at: now.addingTimeInterval(-60)) == 80)
        #expect(PredictionEngine.percent(onCurve: curve, at: now.addingTimeInterval(9999)) == 100)
        #expect(PredictionEngine.percent(onCurve: [], at: now) == nil)
    }

    @Test("duration formatting")
    func durations() {
        #expect(PredictionEngine.durationText(hours: 1.5) == "1h 30m")
        #expect(PredictionEngine.durationText(hours: 0.05) == "3m")
        #expect(PredictionEngine.durationText(hours: 30) == "1d 6h")
        #expect(PredictionEngine.durationText(hours: 2) == "2h")
    }

    /// A spent limit is a record, not a forecast: the crossing is recalled
    /// from the samples that witnessed it and must not drift toward `now`
    /// on every refresh (which is what made an exhausted meter keep
    /// promising it was about to run out).
    @Test("an exhausted limit pins the moment it was spent")
    func spent() {
        let now = Date()
        let meter = Meter(
            id: "weekly_scoped", label: "Weekly · Fable", percent: 100,
            resetsAt: now.addingTimeInterval(5 * 3600), level: .critical, rank: 2,
            limitWindow: 7 * 86400)
        let samples = [
            sample(180, 82, label: "Weekly · Fable", now: now),
            sample(150, 96, label: "Weekly · Fable", now: now),
            sample(120, 100, label: "Weekly · Fable", now: now),
            sample(30, 100, label: "Weekly · Fable", now: now),
        ]
        let first = try! #require(
            PredictionEngine.predict(meter: meter, samples: samples, now: now))
        let crossing = now.addingTimeInterval(-120 * 60)
        #expect(first.verdict == .red)
        #expect(first.severity == 1)
        #expect(first.projectedAtReset == 100)
        #expect(abs(first.exhaustsAt!.timeIntervalSince(crossing)) < 1)

        // Ten minutes later the crossing has not moved.
        let later = now.addingTimeInterval(600)
        let second = try! #require(
            PredictionEngine.predict(meter: meter, samples: samples, now: later))
        #expect(second.exhaustsAt == first.exhaustsAt)

        // A flat all-100 tail has no measurable rate — the forecast used to
        // vanish there, taking the "spent" state with it.
        let flat = [
            sample(120, 100, label: "Weekly · Fable", now: now),
            sample(60, 100, label: "Weekly · Fable", now: now),
        ]
        let stillSpent = try! #require(
            PredictionEngine.predict(meter: meter, samples: flat, now: now))
        #expect(stillSpent.verdict == .red)
        #expect(stillSpent.exhaustsAt != nil)

        // Nothing witnessed the crossing: still spent, just no moment.
        let unwitnessed = try! #require(
            PredictionEngine.predict(meter: meter, samples: [], now: now))
        #expect(unwitnessed.verdict == .red)
        #expect(unwitnessed.exhaustsAt == nil)

        // An unwitnessed reset leaves no drop in the history, so the tail
        // seam alone would reach back into the PREVIOUS window and recall
        // its crossing. The window's own start is the boundary that holds.
        let staleMeter = Meter(
            id: "weekly_scoped", label: "Weekly · Fable", percent: 100,
            resetsAt: now.addingTimeInterval(3600), level: .critical, rank: 2,
            limitWindow: 6 * 3600)
        let acrossWindows = [
            sample(600, 100, label: "Weekly · Fable", now: now), // last window
            sample(120, 100, label: "Weekly · Fable", now: now), // this one
        ]
        let scoped = try! #require(
            PredictionEngine.predict(meter: staleMeter, samples: acrossWindows, now: now))
        #expect(
            abs(scoped.exhaustsAt!.timeIntervalSince(now.addingTimeInterval(-120 * 60))) < 1,
            "the crossing must come from the current window, not the last one")
    }

    // MARK: - Lockouts

    /// A meter shaped like the ones the Claude provider builds.
    private func meter(
        _ label: String, percent: Int?, resetsAt: Date?, window: TimeInterval?,
        rank: Int = 1
    ) -> Meter {
        Meter(
            id: label, label: label, percent: percent, resetsAt: resetsAt,
            level: .normal, rank: rank, limitWindow: window)
    }

    /// The invariant the whole change exists to hold: a crossing is never
    /// reported at an instant the account could not have spent in.
    private func assertOutsideLockouts(
        _ t: Date?, _ lockouts: [DateInterval],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let t else { return }
        #expect(
            !lockouts.contains { $0.start < t && t < $0.end },
            "the crossing landed inside a lockout",
            sourceLocation: sourceLocation)
    }

    @Test("a spent shorter window gates the wider one until it resets")
    func lockoutFromSpentSibling() {
        let sessionReset = now.addingTimeInterval(2 * 3600)
        let session = meter(
            "Session (5h)", percent: 100, resetsAt: sessionReset,
            window: 5 * 3600, rank: 0)
        let weekly = meter(
            "Weekly · all models", percent: 30,
            resetsAt: now.addingTimeInterval(3 * 86400), window: 7 * 86400)
        let gates = PredictionEngine.lockouts(
            on: weekly, from: [session, weekly], predictions: [:], now: now)
        #expect(gates == [DateInterval(start: now, end: sessionReset)])
        // The shortest window receives nothing — it gates, it isn't gated.
        #expect(PredictionEngine.lockouts(
            on: session, from: [session, weekly], predictions: [:], now: now).isEmpty)
    }

    @Test("a sibling's forecast crossing opens the gate at the crossing")
    func lockoutFromForecastCrossing() {
        let sessionReset = now.addingTimeInterval(4 * 3600)
        let crossing = now.addingTimeInterval(3600)
        let session = meter(
            "Session (5h)", percent: 70, resetsAt: sessionReset,
            window: 5 * 3600, rank: 0)
        let weekly = meter(
            "Weekly · all models", percent: 30,
            resetsAt: now.addingTimeInterval(3 * 86400), window: 7 * 86400)
        let forecast = PredictionEngine.prediction(
            percent: 70, resetsAt: sessionReset, ratePerHour: 30, now: now)
        #expect(forecast.exhaustsAt == crossing)
        let gates = PredictionEngine.lockouts(
            on: weekly, from: [session, weekly],
            predictions: ["Session (5h)": forecast], now: now)
        #expect(gates == [DateInterval(start: crossing, end: sessionReset)])
    }

    @Test("a stale, equal or unknown sibling window gates nothing")
    func lockoutsThatDoNotApply() {
        let weekly = meter(
            "Weekly · all models", percent: 30,
            resetsAt: now.addingTimeInterval(3 * 86400), window: 7 * 86400)
        // Spent, but its window already rolled: nothing is gated.
        let stale = meter(
            "Session (5h)", percent: 100, resetsAt: now.addingTimeInterval(-60),
            window: 5 * 3600, rank: 0)
        #expect(PredictionEngine.lockouts(
            on: weekly, from: [stale, weekly], predictions: [:], now: now).isEmpty)
        // The scoped weekly is spent, but other models can still spend.
        let scoped = meter(
            "Weekly · Fable", percent: 100, resetsAt: now.addingTimeInterval(2 * 86400),
            window: 7 * 86400, rank: 2)
        #expect(PredictionEngine.lockouts(
            on: weekly, from: [scoped, weekly], predictions: [:], now: now).isEmpty)
        // A window the provider doesn't know: it neither issues…
        let unknown = meter(
            "Mystery", percent: 100, resetsAt: now.addingTimeInterval(3600), window: nil)
        #expect(PredictionEngine.lockouts(
            on: weekly, from: [unknown, weekly], predictions: [:], now: now).isEmpty)
        // …nor receives.
        let session = meter(
            "Session (5h)", percent: 100, resetsAt: now.addingTimeInterval(2 * 3600),
            window: 5 * 3600, rank: 0)
        #expect(PredictionEngine.lockouts(
            on: unknown, from: [session, unknown], predictions: [:], now: now).isEmpty)
    }

    @Test("two overlapping gates merge into one stretch")
    func lockoutsMerge() {
        let weekly = meter(
            "Weekly · all models", percent: 30,
            resetsAt: now.addingTimeInterval(3 * 86400), window: 7 * 86400)
        let session = meter(
            "Session (5h)", percent: 100, resetsAt: now.addingTimeInterval(2 * 3600),
            window: 5 * 3600, rank: 0)
        let daily = meter(
            "Daily", percent: 100, resetsAt: now.addingTimeInterval(5 * 3600),
            window: 24 * 3600, rank: 2)
        let gates = PredictionEngine.lockouts(
            on: weekly, from: [session, daily, weekly], predictions: [:], now: now)
        #expect(gates == [
            DateInterval(start: now, end: now.addingTimeInterval(5 * 3600)),
        ])
    }

    @Test("a lockout flattens the blended forecast by exactly its own span")
    func blendedPlateau() throws {
        // 20% spent, 3 days into a 7-day window: the average pace baseline
        // is 20/72 %/h, and the measured 4%/h is the burst above it.
        let reset = now.addingTimeInterval(96 * 3600)
        let lockStart = now.addingTimeInterval(3600)
        let lockEnd = now.addingTimeInterval(4 * 3600)
        let gate = DateInterval(start: lockStart, end: lockEnd)
        func read(_ lockouts: [DateInterval]) -> UsagePrediction {
            PredictionEngine.prediction(
                percent: 20, resetsAt: reset, ratePerHour: 4,
                windowLength: 7 * 86400, lockouts: lockouts, now: now)
        }
        let plain = read([])
        let locked = read([gate])
        #expect(locked.basis == .windowAverage)

        // Flat across the gate: the account cannot spend in there.
        let atStart = try #require(
            PredictionEngine.percent(onCurve: locked.curve, at: lockStart))
        let atEnd = try #require(
            PredictionEngine.percent(onCurve: locked.curve, at: lockEnd))
        #expect(abs(atStart - atEnd) < 1e-9)
        // …and the plain forecast really does climb over the same hours,
        // so the assertion above is about the gate, not about a flat curve.
        let plainStart = try #require(
            PredictionEngine.percent(onCurve: plain.curve, at: lockStart))
        let plainEnd = try #require(
            PredictionEngine.percent(onCurve: plain.curve, at: lockEnd))
        #expect(plainEnd - plainStart > 1)

        // The corners are exact, not smeared over a 2h uniform step.
        #expect(locked.curve.contains { $0.t == lockStart })
        #expect(locked.curve.contains { $0.t == lockEnd })

        // Neither forecast crosses, so the last curve point is the
        // unclamped projection at reset — the closed form to assert against.
        #expect(locked.exhaustsAt == nil)
        let baseRate = 20.0 / 72.0
        let excess = 4.0 - baseRate
        let tau = PredictionEngine.burstDecayHours
        let withheld = baseRate * 3
            + excess * tau * (exp(-1 / tau) - exp(-4 / tau))
        #expect(withheld > 1)
        let plainAtReset = try #require(plain.curve.last?.percent)
        let lockedAtReset = try #require(locked.curve.last?.percent)
        #expect(abs(lockedAtReset - (plainAtReset - withheld)) < 1e-9)
    }

    @Test("a gate covering the rest of the window freezes the forecast")
    func lockoutCoversWholeWindow() {
        let reset = now.addingTimeInterval(96 * 3600)
        let prediction = PredictionEngine.prediction(
            percent: 40, resetsAt: reset, ratePerHour: 4,
            windowLength: 7 * 86400,
            lockouts: [DateInterval(start: now, end: reset)], now: now)
        #expect(prediction.projectedAtReset == 40)
        #expect(prediction.exhaustsAt == nil)
        #expect(prediction.verdict == .green)
        #expect(prediction.severity == 0)
        #expect(prediction.text == "steady — not burning")
    }

    @Test("the linear crossing slides past a gate by the gate's own length")
    func linearPlateau() throws {
        // 80% at 10%/h: two hours of spending left. A gate from +1h to +3h
        // pushes the crossing to +4h — not to +2h, where nothing is burning.
        let reset = now.addingTimeInterval(10 * 3600)
        let lockStart = now.addingTimeInterval(3600)
        let lockEnd = now.addingTimeInterval(3 * 3600)
        let gate = DateInterval(start: lockStart, end: lockEnd)
        let prediction = PredictionEngine.prediction(
            percent: 80, resetsAt: reset, ratePerHour: 10,
            lockouts: [gate], now: now)
        #expect(prediction.basis == .recentOnly)
        #expect(prediction.rawVerdict == .red)
        #expect(prediction.exhaustsAt == now.addingTimeInterval(4 * 3600))
        assertOutsideLockouts(prediction.exhaustsAt, [gate])
        // Flat across the gate, rising on both sides of it.
        #expect(prediction.curve == [
            .init(t: now, percent: 80),
            .init(t: lockStart, percent: 90),
            .init(t: lockEnd, percent: 90),
            .init(t: now.addingTimeInterval(4 * 3600), percent: 100),
            .init(t: reset, percent: 100),
        ])
        #expect(PredictionEngine.percent(
            onCurve: prediction.curve, at: now.addingTimeInterval(2 * 3600)) == 90)
        // Without the gate it would have crossed at +2h.
        #expect(PredictionEngine.prediction(
            percent: 80, resetsAt: reset, ratePerHour: 10, now: now)
            .exhaustsAt == now.addingTimeInterval(2 * 3600))
        // With no live reset there is no curve, but the crossing still
        // walks the gate — and the caption speaks wall-clock time.
        let openEnded = PredictionEngine.prediction(
            percent: 80, resetsAt: nil, ratePerHour: 10, lockouts: [gate], now: now)
        #expect(openEnded.exhaustsAt == now.addingTimeInterval(4 * 3600))
        #expect(openEnded.text == "≈4h to limit")
    }

    @Test("a crossing that happens as the gate opens reports the gate's end")
    func crossingAtTheGatesEnd() throws {
        // A window-average baseline of 1.25%/h with no excess over it: the
        // remaining 10% goes in exactly 8 hours. The gate opens ONE SECOND
        // before that, so the un-gated crossing falls strictly inside it and
        // all that is left to spend when the gate lifts is that one second.
        // The crossing therefore happens as the gate ends — and the flat
        // 13-hour stretch is where a plateau-blind search would put it.
        let reset = now.addingTimeInterval(96 * 3600)
        let lockStart = now.addingTimeInterval(8 * 3600 - 1)
        let lockEnd = now.addingTimeInterval(20 * 3600)
        let gate = DateInterval(start: lockStart, end: lockEnd)
        func read(_ lockouts: [DateInterval]) -> UsagePrediction {
            PredictionEngine.prediction(
                percent: 90, resetsAt: reset, ratePerHour: 1.25,
                windowLength: 7 * 86400, lockouts: lockouts, now: now)
        }
        let plainCrossing = try #require(read([]).exhaustsAt)
        #expect(plainCrossing > lockStart && plainCrossing < lockEnd)

        let crossing = try #require(read([gate]).exhaustsAt)
        assertOutsideLockouts(crossing, [gate])
        // The gate's end, to the second — bisection converges from above.
        #expect(crossing >= lockEnd)
        #expect(crossing.timeIntervalSince(lockEnd) <= 2.001)
    }

    @Test("predictAll gates the weeklies on a spent session")
    func predictAllGates() throws {
        let sessionLabel = "Session (5h)"
        let weeklyLabel = "Weekly · all models"
        func combined(_ minutesAgo: Double, session: Int, weekly: Int) -> UsageSample {
            UsageSample(
                t: now.addingTimeInterval(-minutesAgo * 60),
                percents: [sessionLabel: session, weeklyLabel: weekly])
        }
        let sessionReset = now.addingTimeInterval(2 * 3600)
        let weekly = meter(
            weeklyLabel, percent: 20, resetsAt: now.addingTimeInterval(96 * 3600),
            window: 7 * 86400)

        // A spent session: no measurable rate of its own (flat 100 tail),
        // so the gate has to come off the METER, not off its prediction.
        let spentSession = meter(
            sessionLabel, percent: 100, resetsAt: sessionReset,
            window: 5 * 3600, rank: 0)
        let spentSamples = [
            combined(240, session: 100, weekly: 10),
            combined(120, session: 100, weekly: 15),
            combined(0, session: 100, weekly: 20),
        ]
        let gated = PredictionEngine.predictAll(
            meters: [spentSession, weekly], samples: spentSamples,
            profiles: [:], previous: [:], now: now)
        let weeklyForecast = try #require(gated[weeklyLabel])
        #expect(weeklyForecast.basis == .windowAverage)
        // Flat until the session resets, climbing after.
        let atReset = try #require(
            PredictionEngine.percent(onCurve: weeklyForecast.curve, at: sessionReset))
        #expect(abs(atReset - 20) < 1e-9)
        #expect(PredictionEngine.percent(
            onCurve: weeklyForecast.curve, at: now.addingTimeInterval(3600)) == atReset)
        #expect(weeklyForecast.curve.contains { $0.t == sessionReset })
        let later = try #require(PredictionEngine.percent(
            onCurve: weeklyForecast.curve, at: now.addingTimeInterval(24 * 3600)))
        #expect(later > 20.5)

        // An unspent session on track gates nothing, so predictAll must
        // agree with predicting each meter on its own.
        let liveSession = meter(
            sessionLabel, percent: 30, resetsAt: sessionReset,
            window: 5 * 3600, rank: 0)
        let liveSamples = [
            combined(240, session: 10, weekly: 10),
            combined(120, session: 20, weekly: 15),
            combined(0, session: 30, weekly: 20),
        ]
        let free = PredictionEngine.predictAll(
            meters: [liveSession, weekly], samples: liveSamples,
            profiles: [:], previous: [:], now: now)
        #expect(free[sessionLabel]?.exhaustsAt == nil)
        var perMeter: [String: UsagePrediction] = [:]
        for one in [liveSession, weekly] {
            perMeter[one.label] = PredictionEngine.predict(
                meter: one, samples: liveSamples, now: now)
        }
        #expect(free == perMeter)
    }

    @Test("spent limits speak in the past tense")
    func spentPhrasing() {
        let now = Date()
        let utc = TimeZone(identifier: "UTC")!
        let posix = Locale(identifier: "en_US_POSIX")
        // The bug: a crossing at or behind `now` phrased as a future event.
        #expect(
            UsageFormatting.exhaustText(now, now: now, timeZone: utc, locale: posix)
                .hasPrefix("spent at "))
        #expect(
            UsageFormatting.forecastCaption(
                percent: 100, exhaustsAt: now.addingTimeInterval(-3600),
                now: now, timeZone: utc, locale: posix)?
                .hasPrefix("spent at ") == true)
        // Spent, but no sample saw it happen.
        #expect(
            UsageFormatting.forecastCaption(
                percent: 100, exhaustsAt: nil, now: now, timeZone: utc, locale: posix) == "spent")
        // Still room: the forecast keeps its future tense.
        #expect(
            UsageFormatting.forecastCaption(
                percent: 64, exhaustsAt: now.addingTimeInterval(3600),
                now: now, timeZone: utc, locale: posix) == "runs out in 1h")
        // Clean forecast, nothing to say.
        #expect(
            UsageFormatting.forecastCaption(
                percent: 64, exhaustsAt: nil, now: now, timeZone: utc, locale: posix) == nil)
    }
}
