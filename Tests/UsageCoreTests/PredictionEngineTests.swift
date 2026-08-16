import Foundation
import Testing
@testable import UsageCore

private func sample(_ minutesAgo: Double, _ percent: Int, label: String = "Session (5h)", now: Date) -> UsageSample {
    UsageSample(t: now.addingTimeInterval(-minutesAgo * 60), percents: [label: percent])
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
