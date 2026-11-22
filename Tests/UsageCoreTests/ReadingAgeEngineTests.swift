import Foundation
import Testing
@testable import UsageCore

/// A real Codex engine over a temp rollout tree: the same climbing history,
/// read once from a fresh `token_count` and once from one three days old.
/// Only the reading's age differs — and only the fresh one is forecast.
@Suite("Reading age — engine", .serialized)
@MainActor
struct ReadingAgeEngineTests {
    private func eventually(
        _ timeout: TimeInterval = 4, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    /// One rollout holding one rate-limit reading, `age` old: session 30%,
    /// weekly 75% resetting in 47 h.
    private func rollout(in sessions: URL, age: TimeInterval) throws {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: now.addingTimeInterval(-age))
        let sessionReset = Int(now.addingTimeInterval(-age + 3 * 3600).timeIntervalSince1970)
        let weeklyReset = Int(now.addingTimeInterval(47 * 3600).timeIntervalSince1970)
        let line = """
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":600,\
        "output_tokens":200,"total_tokens":1200}},"rate_limits":{"primary":{"used_percent":30,\
        "window_minutes":300,"resets_at":\(sessionReset)},"secondary":{"used_percent":75,\
        "window_minutes":10080,"resets_at":\(weeklyReset)},"plan_type":"prolite"}}}
        """
        let day = sessions.appending(path: "2026/11/18")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try (line + "\n").write(
            to: day.appending(path: "rollout-2026-11-18T20-13-00-abc.jsonl"),
            atomically: true, encoding: .utf8)
    }

    /// A steep weekly climb over the last four hours — enough to forecast a
    /// crossing well before the reset.
    private func history(in support: URL) throws {
        let now = Date()
        let samples = (0...8).map { step in
            UsageSample(
                t: now.addingTimeInterval(Double(step - 8) * 1800 - 60),
                percents: ["Weekly": 59 + step * 2])
        }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(samples).write(to: support.appending(path: "history.json"))
    }

    private func engine(readingAge: TimeInterval) throws -> (UsageEngine, Box<LiveState?>, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "reading-age-engine-\(UUID().uuidString)")
        let roots = StorageScope.Roots(
            support: root.appending(path: "support"), caches: root.appending(path: "caches"))
        let sessions = root.appending(path: "sessions")
        try rollout(in: sessions, age: readingAge)
        try history(in: StorageScope.supportDirectory(
            bundleID: "com.test.age", providerID: "codex", profileID: "default", roots: roots))
        let provider = CodexProvider(sessionsRoot: sessions)
        let defaults = UserDefaults(suiteName: "reading-age-\(UUID().uuidString)")!
        let published = Box<LiveState?>(nil)
        let engine = UsageEngine(
            provider: provider, profileID: "default",
            services: ProviderServices(
                provider: provider, bundleID: "com.test.age", roots: roots, pollsStatus: false),
            defaults: defaults, bundleID: "com.test.age", roots: roots, host: .daemon,
            publish: { published.value = $0 })
        return (engine, published, root)
    }

    @Test("a fresh reading is forecast")
    func fresh() async throws {
        let (engine, published, root) = try engine(readingAge: 60)
        defer {
            engine.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        #expect(await eventually { !engine.predictions.isEmpty })
        #expect(engine.predictions["Weekly"]?.exhaustsAt != nil)
        #expect(await eventually { published.value?.meters.contains { $0.forecast != nil } == true })
        #expect(published.value?.engine.asOf == nil)
    }

    @Test("an old reading is shown as of its stamp and forecast nothing")
    func old() async throws {
        let (engine, published, root) = try engine(readingAge: 3 * 86400)
        defer {
            engine.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        #expect(await eventually { published.value?.engine.asOf != nil })
        let digest = try #require(published.value)
        #expect(digest.engine.asOfCaption?.hasPrefix("as of ") == true)
        #expect(digest.engine.planLabel == "Pro Lite plan")
        // The session window reset since the reading: rolled, 0%.
        #expect(digest.meters.first { $0.rank == 0 }?.percent == 0)
        #expect(digest.meters.first { $0.rank == 1 }?.percent == 75)
        // Give a forecast pass every chance to land, then: nothing.
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.predictions.isEmpty)
        #expect(engine.forecastOvershoots.isEmpty)
        #expect(published.value?.meters.allSatisfy { $0.forecast == nil } == true)
        #expect(engine.state.asOf(at: Date()) != nil)
    }
}
