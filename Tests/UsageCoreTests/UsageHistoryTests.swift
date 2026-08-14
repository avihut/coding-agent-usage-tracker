import Foundation
import Testing
@testable import UsageCore

private func sample(_ minutesAgo: Double, _ percent: Int, label: String = "Session (5h)", now: Date) -> UsageSample {
    UsageSample(t: now.addingTimeInterval(-minutesAgo * 60), percents: [label: percent])
}

@Suite("UsageHistory persistence")
struct UsageHistoryTests {
    @Test("append persists, loads back, and prunes old samples")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "history-tests-\(UUID().uuidString)")
        let history = UsageHistory(directory: directory, retention: 3600)
        let now = Date()
        let response = try UsageResponse.decode(from: loadFixture("real-2026-08-07"))
        let snapshot = Snapshot(response: response, fetchedAt: now)

        let stale = UsageSample(t: now.addingTimeInterval(-7200), percents: ["Session (5h)": 3])
        let updated = history.append(snapshot, existing: [stale], now: now)

        #expect(updated.count == 1)
        #expect(updated[0].percents["Session (5h)"] == 6)
        #expect(updated[0].percents["Weekly · Fable"] == 22)
        #expect(history.load() == updated)
    }
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

    @Test("red: current rate exhausts before reset, curve knees at 100")
    func red() {
        let reset = now.addingTimeInterval(2 * 3600)
        let prediction = PredictionEngine.prediction(
            percent: 80, resetsAt: reset, ratePerHour: 20, now: now)
        #expect(prediction.verdict == .red)
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
            resetsAt: now.addingTimeInterval(3 * 3600), level: .normal, rank: 0)
        let samples = [sample(60, 10, now: now), sample(30, 15, now: now), sample(0, 20, now: now)]
        let prediction = PredictionEngine.predict(meter: meter, samples: samples, now: now)
        #expect(prediction?.verdict == .green)
        #expect(abs((prediction?.ratePerHour ?? 0) - 10) < 0.01)
        // Too little data → no prediction at all.
        #expect(PredictionEngine.predict(meter: meter, samples: [], now: now) == nil)
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
}
