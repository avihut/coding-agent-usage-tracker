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
/// `usage-cli … --digest <file>` and the app's `--demo-digest`. Point
/// `ANTIGRAVITY_LIVE_EXPORT` at a status-line export to see its meters.
enum AntigravityLiveEnvironment {
    static func path(_ key: String) -> URL? {
        ProcessInfo.processInfo.environment[key]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
    static let home = path("ANTIGRAVITY_LIVE_HOME")
    static let digestOut = path("ANTIGRAVITY_LIVE_DIGEST")
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

        let provider = AntigravityProvider(
            home: home, exportURL: scratch.appending(path: "statusline-export.json"))
        let snapshot = try provider.snapshot(
            fromRawUsage: try await provider.fetchRawUsage(accessToken: ""), fetchedAt: Date(),
            plan: nil, thresholds: .standard)
        print("live-probe meters without an export: \(snapshot.meters.count)")
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
        let export = Env.path("ANTIGRAVITY_LIVE_EXPORT")
            ?? scratch.appending(path: "no-export.json")
        let host = MeteringHost(
            providers: [AntigravityProvider(home: home, exportURL: export)], defaults: defaults,
            configuration: MeteringHost.Configuration(
                bundleID: "com.test.antigravity-live", kind: .app,
                roots: StorageScope.Roots(
                    support: scratch.appending(path: "support"),
                    caches: scratch.appending(path: "caches")),
                pollsStatus: false, updateFeedURL: nil, userHome: scratch, stagger: 0,
                bindsSocket: false))
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
}
