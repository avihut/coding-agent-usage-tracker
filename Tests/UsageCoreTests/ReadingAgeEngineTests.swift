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

    /// The engine, what it publishes, its temp root (removed with its
    /// defaults suite by `teardown`), and the sessions tree it reads.
    private struct Rig {
        let engine: UsageEngine
        let published: Box<LiveState?>
        let root: URL
        let sessions: URL
        let suite: String

        @MainActor func teardown() {
            engine.shutdown()
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func engine(readingAge: TimeInterval) throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "reading-age-engine-\(UUID().uuidString)")
        let roots = StorageScope.Roots(
            support: root.appending(path: "support"), caches: root.appending(path: "caches"))
        let sessions = root.appending(path: "sessions")
        try rollout(in: sessions, age: readingAge)
        try history(in: StorageScope.supportDirectory(
            bundleID: "com.test.age", providerID: "codex", profileID: "default", roots: roots))
        let provider = CodexProvider(sessionsRoot: sessions)
        let suite = "reading-age-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let published = Box<LiveState?>(nil)
        let engine = UsageEngine(
            provider: provider, profileID: "default",
            services: ProviderServices(
                provider: provider, bundleID: "com.test.age", roots: roots, pollsStatus: false),
            defaults: defaults, bundleID: "com.test.age", roots: roots, host: .daemon,
            publish: { published.value = $0 })
        return Rig(engine: engine, published: published, root: root, sessions: sessions, suite: suite)
    }

    @Test("a fresh reading is forecast")
    func fresh() async throws {
        let rig = try engine(readingAge: 60)
        defer { rig.teardown() }
        #expect(await eventually { !rig.engine.predictions.isEmpty })
        #expect(rig.engine.predictions["Weekly"]?.exhaustsAt != nil)
        #expect(await eventually { rig.published.value?.meters.contains { $0.forecast != nil } == true })
        #expect(rig.published.value?.engine.asOf == nil)
    }

    @Test("an old reading is shown as of its stamp and forecast nothing")
    func old() async throws {
        let rig = try engine(readingAge: 3 * 86400)
        defer { rig.teardown() }
        #expect(await eventually { rig.published.value?.engine.asOf != nil })
        let digest = try #require(rig.published.value)
        #expect(digest.engine.asOfCaption?.hasPrefix("as of ") == true)
        #expect(digest.engine.planLabel == "Pro Lite plan")
        // The session window reset since the reading: rolled, 0%.
        #expect(digest.meters.first { $0.rank == 0 }?.percent == 0)
        #expect(digest.meters.first { $0.rank == 1 }?.percent == 75)
        // Every forecast pass this start owed has LANDED (`startupSettled`
        // counts them) — and landed nothing.
        #expect(await eventually { rig.engine.startupSettled })
        #expect(rig.engine.predictions.isEmpty)
        #expect(rig.engine.forecastOvershoots.isEmpty)
        #expect(rig.published.value?.meters.allSatisfy { $0.forecast == nil } == true)
        #expect(rig.engine.state.asOf(at: Date()) != nil)
    }

    /// A cache served past its horizon: the engine recomputes only on
    /// `.live`, so the forecast it held would ride on the cached reading
    /// forever (Claude offline is the case; Codex losing its rollout is the
    /// same path, and needs no network to drive).
    @Test("a cached reading past the horizon drops the forecast the engine held")
    func cachedAndOld() async throws {
        let rig = try engine(readingAge: 3 * 86400)
        defer { rig.teardown() }
        #expect(await eventually { rig.engine.startupSettled })
        // A forecast the engine holds from before — as a live pass leaves it.
        let now = Date()
        let weekly = Meter(
            id: "1-weekly", label: "Weekly", percent: 75,
            resetsAt: now.addingTimeInterval(47 * 3600), level: .normal, rank: 1,
            limitWindow: 7 * 86400)
        let samples = (0...8).map { step in
            UsageSample(t: now.addingTimeInterval(Double(step - 8) * 1800), percents: ["Weekly": 59 + step * 2])
        }
        let held = PredictionEngine.predictAll(
            meters: [weekly], samples: samples, profiles: [:], previous: [:], now: now)
        #expect(!held.isEmpty)
        rig.engine.landPredictions(
            generation: rig.engine.beginPredictionPass(), profiles: [:], predictions: held,
            overshoots: [:])
        #expect(!rig.engine.predictions.isEmpty)
        // The rollout goes; the next read fails and serves the cache — the
        // same three-day-old reading, now `.cached`.
        try FileManager.default.removeItem(at: rig.sessions)
        rig.engine.refresh(.manual)
        #expect(await eventually {
            if case .cached = rig.engine.state { return true }
            return false
        })
        #expect(await eventually { rig.engine.predictions.isEmpty })
        #expect(rig.engine.forecastOvershoots.isEmpty)
        #expect(rig.published.value?.meters.allSatisfy { $0.forecast == nil } == true)
    }
}
