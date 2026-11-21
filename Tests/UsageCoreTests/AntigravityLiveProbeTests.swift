import Foundation
import Testing

@testable import UsageCore

/// OPT-IN, never part of the gate: the real Antigravity CLI home, read the
/// way the engine reads it, with every cache in a scratch folder and the
/// home's file set checked unchanged afterwards. Prints totals only — no
/// row, no id, no path.
///
///     ANTIGRAVITY_LIVE_HOME=~/.gemini/antigravity-cli swift test --filter AntigravityLiveProbe
///
/// With `ANTIGRAVITY_LIVE_DIGEST=<file>` it also runs a scratch host — temp
/// storage roots, its own defaults suite, no socket, no status poll, no
/// network provider — and writes the digest it publishes there, for
/// `usage-cli … --digest <file>` and the app's `--demo-digest`; with
/// `ANTIGRAVITY_LIVE_QUOTA=1` beside it that host runs the real CLI's
/// `/quota` (the quota probe), so the digest carries its meters.
///
///     ANTIGRAVITY_LIVE_QUOTA=1 swift test --filter AntigravityLiveQuota
///
/// runs the provider's own quota command once through the real runner —
/// the documented print mode only, its state in a scratch folder, never the
/// app's — and prints the reduced meters (label, percent, reset) and the
/// plan's bucket ids ("gemini-5h": pool names, not account identifiers).
/// No output text. This is the ONE test that spawns the real CLI (spec §10
/// amendment 2026-11-21, second): by hand, one run per invocation, and it
/// stamps the CLI's home exactly as the probe's runs do.
enum AntigravityLiveEnvironment {
    static func path(_ key: String) -> URL? {
        ProcessInfo.processInfo.environment[key]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
    static let home = path("ANTIGRAVITY_LIVE_HOME")
    static let digestOut = path("ANTIGRAVITY_LIVE_DIGEST")
    static let quota = ProcessInfo.processInfo.environment["ANTIGRAVITY_LIVE_QUOTA"] == "1"
}

@Suite("Antigravity live probe", .serialized)
@MainActor
struct AntigravityLiveProbeTests {
    typealias Env = AntigravityLiveEnvironment

    @Test("the real home scans read-only", .enabled(if: Env.home != nil))
    func realHome() async throws {
        let home = try #require(Env.home)
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "antigravity-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tree = AntigravityHome(root: home)
        func stamps() -> [String: Date] {
            var files: [String: Date] = [:]
            let manager = FileManager.default
            for name in (try? manager.contentsOfDirectory(atPath: tree.conversationsDirectory.path)) ?? [] {
                let path = tree.conversationsDirectory.appending(path: name).path
                files[path] = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            }
            for id in tree.conversationIDs() {
                let path = tree.transcriptURL(for: id).path
                files[path] = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            }
            return files
        }
        let before = stamps()

        let source = AntigravityActivitySource(home: home, cacheDirectory: scratch)
        let scan = source.scanTranscriptsReadOnly(now: Date())
        var models: [String: Int] = [:]
        for day in scan.daily {
            for (model, tally) in day.models { models[model, default: 0] += tally.total }
            print("live-probe day \(day.day): calls \(day.messages) prompts \(day.prompts) tokens \(day.tokens)")
        }
        print("live-probe models: \(models.sorted { $0.key < $1.key })")
        print("live-probe conversations: \(tree.conversationIDs().count) timeline slots: \(scan.timeline.count)")

        let provider = AntigravityProvider(home: home)
        let snapshot = try provider.snapshot(
            fromRawUsage: try await provider.fetchRawUsage(accessToken: ""), fetchedAt: Date(),
            plan: nil, thresholds: .standard)
        print("live-probe meters without a reading: \(snapshot.meters.count)")
        #expect(snapshot.meters.isEmpty)

        // Only the CLI's own writes may have moved anything meanwhile.
        let after = stamps()
        let changed = before.filter { after[$0.key] != $0.value }.count
        print("live-probe files changed during the probe (the CLI's own writes only): \(changed)")
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "activity-cache.json").path))
    }

    @Test("a scratch host publishes the real home's digest",
          .enabled(if: Env.home != nil && Env.digestOut != nil))
    func scratchDigest() async throws {
        let home = try #require(Env.home)
        let out = try #require(Env.digestOut)
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "antigravity-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "antigravity-live-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = MeteringHost(
            providers: [AntigravityProvider(home: home)], defaults: defaults,
            configuration: MeteringHost.Configuration(
                bundleID: "com.test.antigravity-live", kind: .app,
                roots: StorageScope.Roots(
                    support: scratch.appending(path: "support"),
                    caches: scratch.appending(path: "caches")),
                pollsStatus: false, updateFeedURL: nil, userHome: scratch, stagger: 0,
                bindsSocket: false,
                agentCommandRunner: Env.quota ? SpawnedCommandRunner() : nil))
        host.start()
        defer { host.shutdown() }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, host.digest?.activity == nil
            || host.engines.values.first?.state.snapshot == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let digest = try #require(host.digest)
        try FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LiveState.encoder().encode(digest).write(to: out)
        print("live-probe digest: \(digest.meters.count) meters, harnesses \(digest.harnesses?.map(\.id) ?? [])")
    }

    @Test("the real CLI's /quota, reduced to meters", .enabled(if: Env.quota))
    func liveQuota() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "antigravity-quota-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let provider = AntigravityProvider()
        let probe = AgentQuotaProbe(
            command: try #require(provider.quotaCommand), runner: SpawnedCommandRunner(),
            stateURL: scratch.appending(path: AgentQuotaProbe.stateFileName),
            // Forced due: this is the one run being checked.
            lastActivity: { now in now })
        let started = Date()
        let status = await probe.refreshIfDue()
        print("live-quota run: \(String(format: "%.2f", Date().timeIntervalSince(started))) s, "
            + "failure: \(status.failure.map(\.rawValue) ?? "none")")
        let reading = try #require(status.reading)
        print("live-quota bucket ids: \(reading.buckets.map(\.id))")
        let body = try await provider.fetchRawUsage(accessToken: "", quota: reading)
        let snapshot = try provider.snapshot(
            fromRawUsage: body, fetchedAt: Date(), plan: nil, thresholds: .standard)
        for meter in snapshot.meters {
            print("live-quota meter: \(meter.label) \(meter.percent.map { "\($0)%" } ?? "—") "
                + "resets \(meter.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "—") "
                + "tag \(UsageFormatting.tag(for: meter))")
        }
        #expect(!snapshot.meters.isEmpty)
    }
}
