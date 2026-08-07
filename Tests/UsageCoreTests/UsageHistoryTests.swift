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

@Suite("BurnRate")
struct BurnRateTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("steady climb yields percent-per-hour slope")
    func slope() {
        let samples = [sample(60, 10, now: now), sample(30, 15, now: now), sample(0, 20, now: now)]
        let rate = BurnRate.ratePerHour(samples: samples, label: "Session (5h)", window: 2 * 3600, now: now)
        #expect(rate != nil)
        #expect(abs(rate! - 10) < 0.01)
    }

    @Test("a reset drop discards pre-drop samples")
    func resetDrop() {
        let samples = [
            sample(90, 80, now: now), sample(60, 90, now: now),
            sample(30, 5, now: now), sample(0, 10, now: now),
        ]
        let rate = BurnRate.ratePerHour(samples: samples, label: "Session (5h)", window: 3 * 3600, now: now)
        #expect(rate != nil)
        #expect(abs(rate! - 10) < 0.01)
    }

    @Test("insufficient span or points yields nil")
    func insufficient() {
        #expect(BurnRate.ratePerHour(samples: [sample(0, 10, now: now)], label: "Session (5h)", window: 3600, now: now) == nil)
        let tight = [sample(2, 10, now: now), sample(0, 11, now: now)]
        #expect(BurnRate.ratePerHour(samples: tight, label: "Session (5h)", window: 3600, now: now) == nil)
        #expect(BurnRate.ratePerHour(samples: [], label: "missing", window: 3600, now: now) == nil)
    }

    @Test("red: current rate exhausts before reset")
    func red() {
        let estimate = BurnRate.estimate(
            percent: 80, resetsAt: now.addingTimeInterval(2 * 3600), ratePerHour: 20, now: now)
        #expect(estimate?.verdict == .red)
        #expect(estimate?.text.contains("1h") == true)
    }

    @Test("yellow: projected close to the limit at reset")
    func yellow() {
        let estimate = BurnRate.estimate(
            percent: 60, resetsAt: now.addingTimeInterval(3 * 3600), ratePerHour: 10, now: now)
        #expect(estimate?.verdict == .yellow)
        #expect(estimate?.text.contains("90%") == true)
    }

    @Test("green: comfortable projection")
    func green() {
        let estimate = BurnRate.estimate(
            percent: 20, resetsAt: now.addingTimeInterval(3 * 3600), ratePerHour: 5, now: now)
        #expect(estimate?.verdict == .green)
        #expect(estimate?.text.contains("35%") == true)
    }

    @Test("flat rate is green and steady; nil rate gives no estimate")
    func steadyAndNil() {
        let flat = BurnRate.estimate(percent: 50, resetsAt: now, ratePerHour: 0.05, now: now)
        #expect(flat?.verdict == .green)
        #expect(BurnRate.estimate(percent: 50, resetsAt: now, ratePerHour: nil, now: now) == nil)
    }

    @Test("duration formatting")
    func durations() {
        #expect(BurnRate.durationText(hours: 1.5) == "1h 30m")
        #expect(BurnRate.durationText(hours: 0.05) == "3m")
        #expect(BurnRate.durationText(hours: 30) == "1d 6h")
        #expect(BurnRate.durationText(hours: 2) == "2h")
    }
}
