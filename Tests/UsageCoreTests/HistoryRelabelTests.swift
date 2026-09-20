import Foundation
import Testing

@testable import UsageCore

/// A renamed meter keeps its history (0.101.0): samples are keyed by label,
/// and the day Codex's week stopped being "Session (168h)" its percent line,
/// its forecast and its token scaling all went with the old key.
@Suite("History follows a renamed meter") struct HistoryRelabelTests {
    @Test("Codex's slot-era labels map to what that window is called now")
    func codexLabels() {
        let codex = CodexProvider()
        #expect(codex.currentMeterLabel(forStored: "Session (168h)") == "Weekly")
        #expect(codex.currentMeterLabel(forStored: "Session (24h)") == "Daily")
        // A real session, and everything that isn't the old pattern, stays.
        #expect(codex.currentMeterLabel(forStored: "Session (5h)") == "Session (5h)")
        #expect(codex.currentMeterLabel(forStored: "Weekly") == "Weekly")
        #expect(codex.currentMeterLabel(forStored: "Session (soon)") == "Session (soon)")
        // The default is identity: Claude renames nothing.
        #expect(ClaudeProvider().currentMeterLabel(forStored: "Session (168h)") == "Session (168h)")
    }

    @Test("load carries percents AND resets, and the next append heals the file")
    func loadCarries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "relabel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let reset = now.addingTimeInterval(86400)
        let stored = [
            UsageSample(
                t: now.addingTimeInterval(-7200), percents: ["Session (168h)": 20, "Session (5h)": 3],
                resets: ["Session (168h)": reset]),
            UsageSample(t: now.addingTimeInterval(-3600), percents: ["Session (168h)": 30]),
            // Both spellings in one sample: today's word wins.
            UsageSample(t: now.addingTimeInterval(-60), percents: ["Session (168h)": 1, "Weekly": 35]),
        ]
        try JSONEncoder().encode(stored).write(to: directory.appending(path: "history.json"))

        let codex = CodexProvider()
        let history = UsageHistory(
            directory: directory, relabel: { codex.currentMeterLabel(forStored: $0) })
        let loaded = history.load()
        #expect(loaded.map { $0.percents["Weekly"] } == [20, 30, 35])
        #expect(loaded[0].percents["Session (5h)"] == 3)
        #expect(loaded[0].resets == ["Weekly": reset])
        #expect(loaded.allSatisfy { $0.percents["Session (168h)"] == nil })

        // Without the seam the file reads exactly as written.
        #expect(UsageHistory(directory: directory).load() == stored)

        // The engine appends to what it loaded — the old key leaves the disk.
        let meter = Meter(
            id: "1-weekly", label: "Weekly", percent: 36, resetsAt: reset, level: .normal,
            rank: 1, limitWindow: 7 * 86400, forcesWarning: false, scopedModelName: nil)
        _ = history.append(
            Snapshot(meters: [meter], fetchedAt: now, plan: nil), existing: loaded, now: now)
        let healed = UsageHistory(directory: directory).load()
        #expect(healed.count == 4)
        #expect(healed.allSatisfy { $0.percents["Session (168h)"] == nil })
    }
}

/// Readiness is WATCHED time (0.101.0): two islands of samples weeks apart
/// are not a learned rhythm, however far apart they sit.
@Suite("Weekly profile readiness") struct WeeklyProfileWatchedSpanTests {
    private func run(from start: Date, hours: Int, base: Int) -> [UsageSample] {
        (0...hours * 4).map { step in
            UsageSample(
                t: start.addingTimeInterval(Double(step) * 900),
                percents: ["Weekly": base + step / 8])
        }
    }

    @Test("a five-week hole between two days of samples is not five weeks of history")
    func holeIsNotHistory() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let august = run(from: now.addingTimeInterval(-36 * 86400), hours: 24, base: 0)
        let september = run(from: now.addingTimeInterval(-86400), hours: 24, base: 6)
        let profile = try #require(WeeklyProfile.build(samples: august + september, label: "Weekly"))
        // Oldest-to-newest is 36 days; what was watched is two.
        #expect(abs(profile.historySpan - 2 * 86400) < 60)
        #expect(!profile.isReady)
        #expect(profile.remainingUntilReady > 11 * 86400)
    }

    @Test("a continuously sampled fortnight is ready, exactly as before")
    func continuousIsReady() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let samples = run(from: now.addingTimeInterval(-15 * 86400), hours: 15 * 24, base: 0)
        let profile = try #require(WeeklyProfile.build(samples: samples, label: "Weekly"))
        #expect(abs(profile.historySpan - 15 * 86400) < 60)
        #expect(profile.isReady)
    }
}
