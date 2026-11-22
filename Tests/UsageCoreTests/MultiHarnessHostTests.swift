import Foundation
import Testing

@testable import UsageCore

/// The host with SEVERAL harnesses metered at once — the shape the feature
/// exists for. Two harnesses whose accounts are both called `default`, real
/// engines, the real composer, real storage under temp roots; only the usage
/// endpoint is stubbed (Codex reads local files and needs no stub at all).
@Suite("Multi-harness host", .serialized)
@MainActor
struct MultiHarnessHostTests {
    @MainActor
    final class Fixture {
        let root: URL
        let roots: StorageScope.Roots
        let userHome: URL
        let defaults: UserDefaults
        let suiteName: String
        let claudeHome: ClaudeHome
        let codexSessions: URL
        let geminiTmp: URL
        private let token = uniqueToken()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "multi-harness-\(UUID().uuidString)")
            roots = StorageScope.Roots(
                support: root.appending(path: "support"), caches: root.appending(path: "caches"))
            userHome = root.appending(path: "home")
            try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
            suiteName = "multi-harness-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            claudeHome = ClaudeHome.standard(userHome: userHome)
            codexSessions = userHome.appending(path: ".codex/sessions")
            geminiTmp = userHome.appending(path: ".gemini/tmp")
            StubURLProtocol.register(token: token) { _ in (200, loadFixture("real-2026-08-07")) }
            // A signed-in, recently used Claude home.
            try FileManager.default.createDirectory(
                at: claudeHome.projectsDirectory, withIntermediateDirectories: true)
            try TempTree(root: claudeHome.directory).file("history.jsonl", age: 600, now: Date())
            try Data("""
            {"oauthAccount":{"accountUuid":"u","organizationUuid":"o","emailAddress":"p@example.com"}}
            """.utf8).write(to: claudeHome.identityFileURL)
        }

        var claude: ClaudeProvider {
            ClaudeProvider(
                home: claudeHome,
                credentials: CredentialChain(sources: [StubCredentialSource(result: .success(token))]),
                client: stubbedClient())
        }

        var codex: CodexProvider { CodexProvider(sessionsRoot: codexSessions) }
        var gemini: GeminiProvider { GeminiProvider(tmpRoot: geminiTmp) }
        var antigravityHome: URL { userHome.appending(path: ".gemini/antigravity-cli") }
        /// Where the fixture's (fake) Antigravity CLI is installed, when it is.
        var agyBinary: URL { root.appending(path: "bin/agy") }
        var antigravity: AntigravityProvider {
            AntigravityProvider(home: antigravityHome, userHome: userHome, agyCandidates: [agyBinary])
        }

        /// An Antigravity conversation (synthetic) last written this many days
        /// ago, with one model call in its transcript.
        func antigravityConversation(daysAgo: Double) throws {
            let id = UUID().uuidString.lowercased()
            let written = Date().addingTimeInterval(-daysAgo * 86400)
            let tree = TempTree(root: antigravityHome)
            try tree.write(
                "brain/\(id)/.system_generated/logs/transcript.jsonl",
                AntigravityFixture.call(at: written, input: 10, output: 5) + "\n")
            try tree.file("conversations/\(id).db", age: daysAgo * 86400, now: Date())
        }

        /// A Claude transcript this many days old.
        func claudeSession(daysAgo: Double) throws {
            try TempTree(root: claudeHome.directory).file(
                "projects/-Users-t/\(UUID().uuidString).jsonl", age: daysAgo * 86400, now: Date())
        }

        /// A Codex rollout this many days old, in the tree Codex writes.
        func codexRollout(daysAgo: Double) throws {
            try TempTree(root: codexSessions).file(
                "2026/09/\(Int.random(in: 10...28))/rollout-\(UUID().uuidString).jsonl",
                age: daysAgo * 86400, now: Date())
        }

        func geminiTrace(daysAgo: Double) throws {
            try TempTree(root: geminiTmp).file(
                "abc123/logs.json", age: daysAgo * 86400, now: Date())
        }

        /// One percent sample in a harness's own storage directory — proof of
        /// which directory an engine reads, since the key never names a path.
        func seedHistory(providerID: String, percent: Int) throws {
            let directory = StorageScope.supportDirectory(
                bundleID: "com.test.harnesses", providerID: providerID,
                profileID: StorageScope.defaultProfileID, roots: roots)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sample = UsageSample(
                t: Date().addingTimeInterval(-3600), percents: ["Session (5h)": percent])
            try JSONEncoder().encode([sample])
                .write(to: directory.appending(path: "history.json"))
        }

        func makeHost(
            _ providers: [any UsageProvider], reprobeInterval: TimeInterval = 600,
            stagger: TimeInterval = 0, runner: (any AgentCommandRunner)? = nil
        ) -> MeteringHost {
            MeteringHost(
                providers: providers, defaults: defaults,
                configuration: MeteringHost.Configuration(
                    bundleID: "com.test.harnesses", kind: .app, roots: roots, pollsStatus: false,
                    updateFeedURL: nil, reprobeInterval: reprobeInterval, userHome: userHome,
                    stagger: stagger, bindsSocket: false, agentCommandRunner: runner))
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

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

    @Test("two harnesses, two accounts called default, two engines and one digest")
    func twoHarnesses() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.claudeSession(daysAgo: 0.1)
        try fixture.codexRollout(daysAgo: 0.2)
        try fixture.seedHistory(providerID: "claude", percent: 11)
        try fixture.seedHistory(providerID: "codex", percent: 77)
        let host = fixture.makeHost([fixture.claude, fixture.codex])
        host.start()
        defer { host.shutdown() }

        // Keyed by ProfileKey: the bundled harness keeps `default`, the other
        // takes its harness's name.
        #expect(Set(host.engines.keys) == ["default", "codex"])
        #expect(host.profiles.map(\.key) == ["default", "codex"])
        #expect(host.roster.rows.map(\.id) == ["claude", "codex"])

        // Each engine read ITS harness's own storage directory — the key is
        // never a path component, so no history moved.
        #expect(host.engines["default"]?.samples.first?.percents["Session (5h)"] == 11)
        #expect(host.engines["codex"]?.samples.first?.percents["Session (5h)"] == 77)
        let stray = StorageScope.supportDirectory(
            bundleID: "com.test.harnesses", providerID: "codex", profileID: "codex",
            roots: fixture.roots)
        #expect(!FileManager.default.fileExists(atPath: stray.path))

        let digest = try #require(host.digest)
        #expect(digest.profiles?.map(\.id) == ["default", "codex"])
        #expect(digest.profiles?.map(\.accountID) == ["default", "default"])
        #expect(digest.profiles?.map(\.providerID) == ["claude", "codex"])
        // A home-less account is named by its agent, never "default".
        #expect(digest.profiles?.map(\.label) == ["p@example.com", "Codex"])
        #expect(digest.menuBarCells?.map(\.profile) == ["default", "codex"])
        #expect(digest.menuBarCells?.map(\.glyph) == ["✳︎", "⬡"])
        #expect(digest.menuBarCells?.allSatisfy { $0.accent != nil } == true)
        #expect(digest.menuBarCells?[0].accent != digest.menuBarCells?[1].accent)

        let harnesses = try #require(digest.harnesses)
        #expect(harnesses.map(\.id) == ["claude", "codex"])
        #expect(harnesses.map(\.shortName) == ["Claude", "Codex"])
        #expect(harnesses.map(\.accountCount) == [1, 1])
        #expect(harnesses.map(\.shown) == [true, true])
        #expect(harnesses.map(\.isLocalProvider) == [false, true])
        #expect(harnesses.allSatisfy { $0.present })
        #expect(host.statusSummary.contains("harnesses claude, codex"))
        #expect(host.statusSummary.contains("profiles 2"))
    }

    /// Hiding is display only: the engines keep running and the accounts stay
    /// in the digest — the bar just loses their cells. And the last shown
    /// harness can't be hidden, or there would be nothing to look at.
    @Test("a hidden harness keeps being metered but owns no cell")
    func hiding() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.claudeSession(daysAgo: 0.1)
        try fixture.codexRollout(daysAgo: 0.2)
        let host = fixture.makeHost([fixture.claude, fixture.codex])
        host.start()
        defer { host.shutdown() }

        #expect(host.setHarnessShown(id: "codex", shown: false))
        #expect(host.hidden == ["codex"])
        #expect(Set(host.engines.keys) == ["default", "codex"])
        #expect(host.digest?.menuBarCells?.map(\.profile) == ["default"])
        #expect(host.digest?.profiles?.map(\.id) == ["default", "codex"])
        #expect(host.digest?.harnesses?.first { $0.id == "codex" }?.shown == false)
        #expect(host.focusedProfileID == "default")
        #expect(host.statusSummary.contains("codex (hidden)"))

        // The last shown harness stays shown, and the defaults key is the one
        // a daemon reads.
        #expect(!host.setHarnessShown(id: "claude", shown: false))
        #expect(HarnessRoster.hidden(from: fixture.defaults) == ["codex"])
        #expect(host.setHarnessShown(id: "codex", shown: true))
        #expect(host.digest?.menuBarCells?.count == 2)
    }

    @Test("focus follows the harness used on more days, and a pin overrides it")
    func focusAcrossHarnesses() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        // Claude: two days. Codex: five days, far fewer files per day.
        try fixture.claudeSession(daysAgo: 0.2)
        try fixture.claudeSession(daysAgo: 1.2)
        for day in 1...5 { try fixture.codexRollout(daysAgo: Double(day) + 0.3) }
        let host = fixture.makeHost([fixture.claude, fixture.codex])
        host.start()
        defer { host.shutdown() }

        #expect(host.focusedProfileID == "codex")
        #expect(host.digest?.focusedProfile == "codex")
        // The top level is the focused harness's own section.
        #expect(host.digest?.engine.providerID == "codex")

        // Pinning the account activity already focuses moves nothing, yet
        // the digest must still say it is pinned — a face reads the pin
        // from there — and handing it back must say so too.
        #expect(await host.handle(.focusProfile(id: "codex")).ok)
        #expect(host.focusedProfileID == "codex")
        #expect(host.digest?.pinnedProfile == "codex")
        #expect(await host.handle(.focusProfile(id: nil)).ok)
        #expect(host.focusedProfileID == "codex")
        #expect(host.digest?.pinnedProfile == nil)

        let pinned = await host.handle(.focusProfile(id: "default"))
        #expect(pinned.ok)
        #expect(host.focusedProfileID == "default")
        #expect(host.digest?.pinnedProfile == "default")
        #expect(host.digest?.engine.providerID == "claude")
        #expect(ProfileStore.pin(from: fixture.defaults) == "default")

        let cleared = await host.handle(.focusProfile(id: nil))
        #expect(cleared.ok)
        #expect(host.focusedProfileID == "codex")
        #expect(host.digest?.pinnedProfile == nil)
        // A key nobody meters is refused, never quietly redirected.
        #expect(!(await host.handle(.focusProfile(id: "gemini"))).ok)
    }

    /// 2026-11-21: Antigravity with no limits read (its CLI not installed
    /// yet) reads tokens and no limits — used on more days than Claude, it
    /// must still not take the bar's lead; the moment the quota probe lands a
    /// reading it competes like any harness.
    @Test("a harness reading no limits doesn't take focus until it reads some")
    func meterlessFocus() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.claudeSession(daysAgo: 0.2)
        for day in 1...5 { try fixture.antigravityConversation(daysAgo: Double(day) + 0.3) }
        let reset = AntigravityFixture.stamp(Date().addingTimeInterval(86400))
        let runner = FakeAgentRunner(quota: .exited(stdout: AntigravityQuotaFixture.output([
            AntigravityQuotaFixture.bucket("gemini-weekly", window: "weekly", remaining: 0.6, reset: reset),
        ])))
        let host = fixture.makeHost([fixture.claude, fixture.antigravity], runner: runner)
        host.start()
        defer { host.shutdown() }

        let read = await eventually { host.engines["antigravity"]?.state.snapshot != nil }
        #expect(read)
        #expect(host.engines["antigravity"]?.state.snapshot?.meters.isEmpty == true)
        #expect(host.focusedProfileID == "default")
        #expect(await runner.invocations.isEmpty)

        // The CLI gets installed; the next refresh reads its limits.
        try FileManager.default.createDirectory(
            at: fixture.agyBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: fixture.agyBinary.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        #expect(await host.handle(.refreshProfile(id: "antigravity")).ok)
        let moved = await eventually { host.focusedProfileID == "antigravity" }
        #expect(moved)
        #expect(host.digest?.engine.providerID == "antigravity")
        #expect(await runner.quotaRuns.count == 1)
    }

    /// A host that wasn't given a runner never asks the CLI, installed or not.
    @Test("a host without a runner never runs the quota probe")
    func noRunnerNoProbe() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        for day in 1...2 { try fixture.antigravityConversation(daysAgo: Double(day)) }
        let host = fixture.makeHost([fixture.antigravity])
        host.start()
        defer { host.shutdown() }
        let read = await eventually { host.engines["antigravity"]?.state.snapshot != nil }
        #expect(read)
        #expect(host.engines["antigravity"]?.state.snapshot?.meters.isEmpty == true)
        let state = StorageScope.supportDirectory(
            bundleID: "com.test.harnesses", providerID: "antigravity", profileID: "default",
            roots: fixture.roots).appending(path: AgentQuotaProbe.stateFileName)
        #expect(!FileManager.default.fileExists(atPath: state.path))
    }

    @Test("a CLI that times out: Antigravity reads its failure, and focus stays put")
    func failedProbeKeepsFocus() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.claudeSession(daysAgo: 0.2)
        for day in 1...5 { try fixture.antigravityConversation(daysAgo: Double(day) + 0.3) }
        try FileManager.default.createDirectory(
            at: fixture.agyBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: fixture.agyBinary.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        let runner = FakeAgentRunner(quota: AgentCommandResult(
            termination: .timedOut, stdout: Data(), stderr: Data(), duration: 30))
        let host = fixture.makeHost([fixture.claude, fixture.antigravity], runner: runner)
        host.start()
        defer { host.shutdown() }

        let failed = await eventually { host.engines["antigravity"]?.state.error == .agentTimedOut }
        #expect(failed)
        // A snapshot either way — the harness renders, it just has no limits.
        #expect(host.engines["antigravity"]?.state.snapshot?.meters.isEmpty == true)
        #expect(host.focusedProfileID == "default")
        #expect(await runner.quotaRuns.count == 1)
    }

    /// A host whose Antigravity reading is cached, with the probe due again
    /// (an attempt an hour ago, a conversation written since) and a CLI
    /// whose limits run waits until the test releases it.
    private func primedForSlowProbe(
        _ fixture: Fixture
    ) async throws -> (host: MeteringHost, runner: FakeAgentRunner, release: AsyncStream<Void>.Continuation,
                       support: URL) {
        try fixture.antigravityConversation(daysAgo: 0.1)
        try FileManager.default.createDirectory(
            at: fixture.agyBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: fixture.agyBinary.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        let reset = AntigravityFixture.stamp(Date().addingTimeInterval(86400))
        let output = AntigravityQuotaFixture.output([
            AntigravityQuotaFixture.bucket("gemini-weekly", window: "weekly", remaining: 0.6, reset: reset),
        ])
        let first = fixture.makeHost([fixture.antigravity], runner: FakeAgentRunner(quota: .exited(stdout: output)))
        first.start()
        let read = await eventually { first.engines["antigravity"]?.state.snapshot?.meters.count == 1 }
        #expect(read)
        first.shutdown()

        let support = StorageScope.supportDirectory(
            bundleID: "com.test.harnesses", providerID: "antigravity", profileID: "default",
            roots: fixture.roots)
        let stateURL = support.appending(path: AgentQuotaProbe.stateFileName)
        var state = try #require(AgentQuotaProbeState.load(from: stateURL))
        state.lastAttemptAt = Date().addingTimeInterval(-3600)
        state.save(to: stateURL)
        try fixture.antigravityConversation(daysAgo: 0)
        let slow = FakeAgentRunner(quota: .exited(stdout: output))
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        await slow.set(hold: { for await _ in released { return } })
        let second = fixture.makeHost([fixture.antigravity], runner: slow)
        second.start()
        let deadline = Date().addingTimeInterval(4)
        while await slow.quotaRuns.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await slow.quotaRuns.count == 1)
        return (second, slow, release, support)
    }

    /// 2026-11-22: the probe's kill is now a 120 s safety net, and the
    /// engine awaits the run inside its refresh — so a slow run must leave
    /// what is already known on screen the whole time, never a blank or a
    /// loading shell.
    @Test("a slow probe run leaves the last limits on screen while it runs")
    func slowProbeKeepsWhatIsKnown() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (host, _, release, _) = try await primedForSlowProbe(fixture)
        defer { host.shutdown() }
        let engine = try #require(host.engines["antigravity"])
        #expect(engine.isRefreshing)
        #expect(engine.state.snapshot?.meters.count == 1)
        #expect(host.digest?.meters.count == 1)
        release.yield()
        release.finish()
        let landed = await eventually { !engine.isRefreshing }
        #expect(landed)
        #expect(engine.state.error == nil)
        #expect(engine.state.snapshot?.meters.count == 1)
    }

    /// A run still in flight when its host shuts down (the lease about to
    /// go — the app yielding to the daemon) must land nowhere: not in the
    /// probe's state, not in the engine's history, under the next holder.
    @Test("a probe run that outlives its engine's shutdown writes nothing")
    func shutdownMidProbeWritesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let (host, _, release, support) = try await primedForSlowProbe(fixture)
        let engine = try #require(host.engines["antigravity"])
        let history = support.appending(path: "history.json")
        let state = support.appending(path: AgentQuotaProbe.stateFileName)
        let historyBefore = try? Data(contentsOf: history)
        let stateBefore = try Data(contentsOf: state)
        host.shutdown()
        release.yield()
        release.finish()
        let settled = await eventually { !engine.isRefreshing }
        #expect(settled)
        #expect((try? Data(contentsOf: history)) == historyBefore)
        #expect(try Data(contentsOf: state) == stateBefore)
    }

    /// The next launch (or a host taking over) must not lead with the
    /// meterless harness even for the moment before its first read: focus
    /// answers from the cached last fetch, synchronously, at start.
    @Test("a launch reads meter presence from the cache, before the first read")
    func meterlessFocusAtLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.claudeSession(daysAgo: 0.2)
        for day in 1...5 { try fixture.antigravityConversation(daysAgo: Double(day) + 0.3) }
        let first = fixture.makeHost([fixture.claude, fixture.antigravity])
        first.start()
        let cached = await eventually { first.engines["antigravity"]?.state.snapshot != nil }
        #expect(cached)
        first.shutdown()

        let second = fixture.makeHost([fixture.claude, fixture.antigravity])
        second.start()
        defer { second.shutdown() }
        #expect(second.focusedProfileID == "default")
        #expect(second.digest?.focusedProfile == "default")
    }

    /// A harness with no local data yet publishes no snapshot at all — that
    /// is "unknown", not "no limits", and must not cost it focus.
    @Test("a harness with no local data stays in the focus ranking")
    func noLocalDataStaysEligible() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.claudeSession(daysAgo: 0.2)
        // Rollouts with no token events: Codex is present, reads nothing.
        for day in 1...5 { try fixture.codexRollout(daysAgo: Double(day) + 0.3) }
        let host = fixture.makeHost([fixture.claude, fixture.codex])
        host.start()
        defer { host.shutdown() }
        let read = await eventually { host.engines["codex"]?.state.error != nil }
        #expect(read)
        #expect(host.engines["codex"]?.state.snapshot == nil)
        #expect(host.focusedProfileID == "codex")
    }

    /// The launch stagger spreads polls of a NETWORK endpoint; a local
    /// provider's first read must not wait behind it, or focus would guess
    /// about it for minutes after every update.
    @Test("local harnesses read at once, whatever the launch stagger")
    func localSkipsStagger() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.claudeSession(daysAgo: 0.2)
        try fixture.codexRollout(daysAgo: 0.3)
        try fixture.antigravityConversation(daysAgo: 0.4)
        let host = fixture.makeHost(
            [fixture.claude, fixture.codex, fixture.antigravity], stagger: 60)
        host.start()
        defer { host.shutdown() }
        // With the stagger applied to all three, the last would wait 40s.
        let read = await eventually {
            host.engines["antigravity"]?.state.snapshot != nil
        }
        #expect(read)
    }

    /// The user's own rule: "I've not been using Codex for months; there's no
    /// point showing it." A harness whose standard account was never edited
    /// must still be allowed to fall asleep — its synthesized enrolment stamp
    /// says "now" on every load and must not keep it awake forever.
    @Test("a harness quiet for a month goes dormant even with a synthesized record")
    func dormantHarness() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.claudeSession(daysAgo: 0.1)
        try fixture.codexRollout(daysAgo: 40)
        let host = fixture.makeHost([fixture.claude, fixture.codex])
        host.start()
        defer { host.shutdown() }

        #expect(host.dormant == ["codex"])
        #expect(Set(host.engines.keys) == ["default"])
        #expect(host.digest?.menuBarCells?.map(\.profile) == ["default"])
        let section = try #require(host.digest?.profiles?.first { $0.id == "codex" })
        #expect(section.dormant && section.engine == nil && section.meters == nil)
        #expect(host.focusedProfileID == "default")
        #expect(host.statusSummary.contains("dormant 1"))

        // Its section still names ITS vendor when a face reads it, never the
        // writer's — the projection takes identity from the harness list.
        let viewed = try #require(host.digest?.viewing(profile: "codex"))
        #expect(viewed.engine.providerID == "codex")
        #expect(viewed.engine.agentName == "Codex")
        #expect(viewed.engine.isLocalProvider)
        #expect(viewed.engine.stale && viewed.engine.fetchedAt == nil && viewed.engine.error == nil)
        // A local harness declares no status feed: absent, never "healthy".
        #expect(viewed.serviceStatus == nil)
    }

    @Test("a harness installed mid-session joins on the next reprobe, and presence latches")
    func presenceGrows() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.claudeSession(daysAgo: 0.1)
        let host = fixture.makeHost([fixture.claude, fixture.codex, fixture.gemini])
        host.start()
        defer { host.shutdown() }

        // Neither Codex nor Gemini has written anything here yet.
        #expect(host.roster.rows.map(\.id) == ["claude"])
        #expect(host.present == ["claude"])

        try fixture.geminiTrace(daysAgo: 0.1)
        host.reprobe()
        let joined = await eventually { host.roster.rows.map(\.id) == ["claude", "gemini"] }
        #expect(joined)
        #expect(await eventually { host.engines["gemini"] != nil })
        #expect(host.digest?.harnesses?.map(\.id) == ["claude", "gemini"])

        // Latched: a directory that goes away mid-session never drops a
        // harness out from under the person.
        try FileManager.default.removeItem(at: fixture.geminiTmp)
        host.reprobe()
        _ = await eventually(1) { false }
        #expect(host.roster.rows.map(\.id) == ["claude", "gemini"])
    }

    /// Cached activity counts in the all-agents total (2026-11-21): the
    /// account's numbers are already on screen, stamped with their age, so
    /// the total must never call it "scanning" beside them.
    @Test("the all-agents total counts an account served from its cached scan, and names a scanning one")
    func allAgentsCountsCachedActivity() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.claudeSession(daysAgo: 0.1)
        try fixture.codexRollout(daysAgo: 0.2)
        let host = fixture.makeHost([fixture.claude, fixture.codex])
        host.start()
        defer { host.shutdown() }
        let claude = try #require(host.engines["default"])
        // Same main-actor turn as start(): no scan has landed anywhere.
        let before = try #require(host.digest?.allAgents)
        #expect(before.members.map(\.stateValue) == [.scanning, .scanning])
        #expect(before.activity == nil)
        let cached = CachedScan(
            scan: TranscriptScan(daily: [], timeline: []), asOf: Date().addingTimeInterval(-900))
        #expect(claude.landCachedScan(cached, activity: []))
        let after = try #require(host.digest?.allAgents)
        #expect(after.members.first { $0.profile == "default" }?.stateValue == .counted)
        #expect(after.members.first { $0.profile == "codex" }?.stateValue == .scanning)
        #expect(after.partial)
    }
}
