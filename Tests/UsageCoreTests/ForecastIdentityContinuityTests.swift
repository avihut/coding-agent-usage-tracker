import Foundation
import Testing

@testable import UsageCore

/// R5, the requirement that asked to be VERIFIED rather than built: the weekly
/// estimate is learned per harness AND per configuration folder — never pooled
/// — and a login change inside one folder keeps that folder's learned history.
/// ("the idea of changing logins for the same account is changing the usage
/// pull.") These pin both halves so a later refactor can't quietly pool or
/// partition them.
@Suite("Forecast identity continuity")
struct ForecastIdentityContinuityTests {
    private let bundleID = "com.test.continuity"

    private func roots() throws -> StorageScope.Roots {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "continuity-\(UUID().uuidString)")
        return StorageScope.Roots(
            support: root.appending(path: "support"), caches: root.appending(path: "caches"))
    }

    private func history(_ roots: StorageScope.Roots, provider: String, profile: String) -> UsageHistory {
        UsageHistory(directory: StorageScope.supportDirectory(
            bundleID: bundleID, providerID: provider, profileID: profile, roots: roots))
    }

    /// No reset stamp: a stamp that MOVED between two samples is a window
    /// boundary the profile builder skips, and this fixture is about the
    /// rhythm inside one window, not about boundaries.
    private func snapshot(percent: Int, at: Date) -> Snapshot {
        Snapshot(
            meters: [Meter(
                id: "weekly_all", label: "Weekly (all)", percent: percent,
                resetsAt: nil, level: .normal, rank: 1, limitWindow: 7 * 86400)],
            fetchedAt: at)
    }

    /// Four separate files: two accounts of one harness, and another harness
    /// beside them. Nothing is summed, nothing is shared.
    @Test("history is per harness and per account folder, never pooled")
    func perFolder() throws {
        let roots = try roots()
        defer { try? FileManager.default.removeItem(at: roots.support.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_757_000_000)

        let work = history(roots, provider: "claude", profile: "default")
        let personal = history(roots, provider: "claude", profile: "c982130e")
        let codex = history(roots, provider: "codex", profile: "default")
        #expect(Set([work.fileURL, personal.fileURL, codex.fileURL]).count == 3)

        var workSamples: [UsageSample] = []
        var personalSamples: [UsageSample] = []
        var codexSamples: [UsageSample] = []
        for step in 0..<32 {
            let at = start.addingTimeInterval(Double(step) * 43200)
            workSamples = work.append(
                snapshot(percent: step * 3, at: at), existing: workSamples, now: at)
            personalSamples = personal.append(
                snapshot(percent: step / 2, at: at), existing: personalSamples, now: at)
            codexSamples = codex.append(
                snapshot(percent: step, at: at), existing: codexSamples, now: at)
        }

        // Each file holds only its own account's readings.
        #expect(work.load().count == 32)
        #expect(work.load().last?.percents["Weekly (all)"] == 93)
        #expect(personal.load().last?.percents["Weekly (all)"] == 15)
        #expect(codex.load().last?.percents["Weekly (all)"] == 31)

        // And each account's learned rhythm is its own — pooling would make
        // these identical, or make one of them steeper than it earned.
        let workProfile = try #require(WeeklyProfile.build(samples: work.load(), label: "Weekly (all)"))
        let personalProfile = try #require(
            WeeklyProfile.build(samples: personal.load(), label: "Weekly (all)"))
        let codexProfile = try #require(
            WeeklyProfile.build(samples: codex.load(), label: "Weekly (all)"))
        #expect(workProfile.rates != personalProfile.rates)
        #expect(workProfile.rates != codexProfile.rates)
        // Three points a half-day against one: the busier account forecasts faster.
        let workTotal = workProfile.rates.reduce(0, +)
        let personalTotal = personalProfile.rates.reduce(0, +)
        #expect(workTotal > personalTotal)
    }

    /// A different sign-in appears in the SAME folder. The presence ledger
    /// records the switch (that is its job — attribution), and the folder's
    /// learned history is untouched: same samples, same rhythm, nothing reset
    /// and nothing partitioned by identity.
    @Test("a login change inside one folder keeps that folder's learned history")
    func loginChangeKeepsHistory() throws {
        let roots = try roots()
        defer { try? FileManager.default.removeItem(at: roots.support.deletingLastPathComponent()) }
        let directory = StorageScope.supportDirectory(
            bundleID: bundleID, providerID: "claude", profileID: "default", roots: roots)
        let start = Date(timeIntervalSince1970: 1_757_000_000)
        let store = UsageHistory(directory: directory)

        var samples: [UsageSample] = []
        for step in 0..<32 {
            let at = start.addingTimeInterval(Double(step) * 43200)
            samples = store.append(snapshot(percent: step * 2, at: at), existing: samples, now: at)
        }
        let before = store.load()
        let profileBefore = try #require(WeeklyProfile.build(samples: before, label: "Weekly (all)"))

        var presence = AccountPresenceLedger(directory: directory)
        let first = AccountIdentity(
            accountUuid: "u-one", organizationUuid: "o-one", email: "one@example.com")
        let second = AccountIdentity(
            accountUuid: "u-two", organizationUuid: "o-two", email: "two@example.com")
        let opened = presence.observe(first, at: start.addingTimeInterval(16 * 86400))
        let switched = presence.observe(second, at: start.addingTimeInterval(16 * 86400 + 60))
        #expect(opened)
        #expect(switched)
        presence.flush(now: start.addingTimeInterval(16 * 86400 + 60))

        // Two epochs recorded — and the same history, byte for byte.
        #expect(presence.epochs.count == 2)
        #expect(store.load() == before)
        let profileAfter = try #require(
            WeeklyProfile.build(samples: store.load(), label: "Weekly (all)"))
        #expect(profileAfter.rates == profileBefore.rates)

        // A sample written after the switch extends the SAME series — the
        // folder is the unit, not the sign-in.
        let after = store.append(
            snapshot(percent: 70, at: start.addingTimeInterval(17 * 86400)), existing: store.load(),
            now: start.addingTimeInterval(17 * 86400))
        #expect(after.count == before.count + 1)
        #expect(UsageHistory(directory: directory).load().count == before.count + 1)
    }
}
