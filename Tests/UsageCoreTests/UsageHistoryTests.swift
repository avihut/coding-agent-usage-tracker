import Foundation
import Testing
@testable import UsageCore

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

    @Test("appending thins old samples to the sparse resolution, stably")
    func thinning() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "history-tests-\(UUID().uuidString)")
        // Dense hour, then one sample per 30-minute bucket beyond it.
        let history = UsageHistory(
            directory: directory, retention: 36000,
            denseWindow: 3600, thinnedResolution: 1800)
        let now = Date(timeIntervalSinceReferenceDate: 900_000)
        let response = try UsageResponse.decode(from: loadFixture("real-2026-08-07"))
        let snapshot = Snapshot(response: response, fetchedAt: now)

        let existing = [892_800.0, 894_600, 896_100, 896_400].map {
            UsageSample(
                t: Date(timeIntervalSinceReferenceDate: $0),
                percents: ["Session (5h)": 5])
        }
        let updated = history.append(snapshot, existing: existing, now: now)

        // 892800 and 894600 head their 30-min buckets and stay; 896100
        // shares 894600's bucket (both floor to 497) and drops; 896400 is
        // inside the dense hour and stays untouched.
        #expect(updated.map { $0.t.timeIntervalSinceReferenceDate }
            == [892_800, 894_600, 896_400, 900_000])
        // Thinning is stable: running append again reshapes nothing old.
        let again = history.append(snapshot, existing: updated, now: now)
        #expect(again.dropLast().map { $0.t.timeIntervalSinceReferenceDate }
            == [892_800, 894_600, 896_400, 900_000])
    }
}
