import Foundation
import Testing
@testable import UsageCore

/// The host over two temp homes, stubbed usage services per profile, no
/// status poller, no update checker, no socket — everything else real:
/// engines, gates, the composer, the profile store, dormancy and focus.
@Suite("Metering host", .serialized)
@MainActor
struct MeteringHostTests {
    @MainActor
    final class Fixture {
        let root: URL
        let roots: StorageScope.Roots
        let userHome: URL
        let defaults: UserDefaults
        let suiteName: String
        let standard: ClaudeHome
        let personal: ClaudeHome
        let tokens: [String: String]
        let personalID: String

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "metering-host-\(UUID().uuidString)")
            roots = StorageScope.Roots(
                support: root.appending(path: "support"), caches: root.appending(path: "caches"))
            userHome = root.appending(path: "home")
            try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
            suiteName = "metering-host-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            standard = ClaudeHome.standard(userHome: userHome)
            personal = ClaudeHome(directory: userHome.appending(path: ".claude-personal"), userHome: userHome)
            personalID = personal.profileID
            tokens = ["default": uniqueToken(), personalID: uniqueToken()]
            for token in tokens.values {
                StubURLProtocol.register(token: token) { _ in (200, loadFixture("real-2026-08-07")) }
            }
            try write(standard, historyAge: 600)
            try write(personal, historyAge: 600)
        }

        /// A home with a projects tree, a prompt history of a given age, and
        /// a signed-in identity record.
        func write(_ home: ClaudeHome, historyAge: TimeInterval, email: String = "p@example.com") throws {
            let tree = TempTree(root: home.directory)
            try tree.file("history.jsonl", age: historyAge, now: Date())
            try FileManager.default.createDirectory(
                at: home.projectsDirectory, withIntermediateDirectories: true)
            try tree.write(home.identityFileURL.lastPathComponent == ".claude.json" && !home.isStandard
                ? ".claude.json" : "settings.json", "{}")
            let identity = """
            {"oauthAccount":{"accountUuid":"u-\(home.profileID)","organizationUuid":"o","emailAddress":"\(email)"}}
            """
            try Data(identity.utf8).write(to: home.identityFileURL)
        }

        /// One transcript of a given age under the home's projects tree.
        func session(_ home: ClaudeHome, _ name: String, age: TimeInterval) throws {
            try TempTree(root: home.directory).file("projects/-Users-t/\(name).jsonl", age: age, now: Date())
        }

        func enroll(_ home: ClaudeHome, addedAgo: TimeInterval = 0, enabled: Bool = true, order: Int = 1) {
            var stored = ProfileStore.load(from: defaults)
            stored.removeAll { $0.id == home.profileID }
            stored.append(Profile(
                id: home.profileID, providerID: "claude", home: home.directory, enabled: enabled,
                order: order, addedAt: Date().addingTimeInterval(-addedAgo)))
            ProfileStore.save(stored, to: defaults)
        }

        func provider(for home: ClaudeHome) -> ClaudeProvider {
            ClaudeProvider(
                home: home,
                credentials: CredentialChain(sources: [
                    StubCredentialSource(result: .success(tokens[home.profileID] ?? "")),
                ]),
                client: stubbedClient())
        }

        func makeHost(stagger: TimeInterval = 0, reprobeInterval: TimeInterval = 600) -> MeteringHost {
            let host = MeteringHost(
                provider: provider(for: standard), defaults: defaults,
                configuration: MeteringHost.Configuration(
                    bundleID: "com.test.host", kind: .app, roots: roots, pollsStatus: false,
                    updateFeedURL: nil, reprobeInterval: reprobeInterval, userHome: userHome,
                    stagger: stagger, bindsSocket: false),
                serviceFactory: { [self] profile in
                    let home = profile.isDefault ? standard : personal
                    return UsageService(
                        provider: provider(for: home),
                        cache: UsageCache(directory: StorageScope.cachesDirectory(
                            bundleID: "com.test.host", providerID: "claude", profileID: profile.id,
                            roots: roots)),
                        retryDelay: .zero)
                })
            return host
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Polls a condition on the main actor; false on timeout.
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

    @Test("two enrolled profiles run two engines and compose one digest")
    func twoProfilesOneDigest() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.enroll(fixture.personal)
        let host = fixture.makeHost()
        host.start()
        defer { host.shutdown() }

        #expect(Set(host.engines.keys) == ["default", fixture.personalID])
        #expect(host.profiles.map(\.id) == ["default", fixture.personalID])
        let landed = await eventually {
            host.engines.values.allSatisfy { $0.state.snapshot != nil }
        }
        #expect(landed)
        let digest = try #require(host.digest)
        #expect(digest.profiles?.map(\.id) == ["default", fixture.personalID])
        #expect(digest.profiles?.allSatisfy { $0.engine != nil && $0.meters?.isEmpty == false } == true)
        #expect(digest.profiles?.map(\.label) == ["p@example.com", "p@example.com"])
        #expect(digest.menuBarCells?.map(\.profile) == ["default", fixture.personalID])
        #expect(digest.focusedProfile != nil)
        // The digest reached disk under the temp roots.
        let file = LiveState.fileURL(bundleID: "com.test.host", roots: fixture.roots)
        let written = await eventually { FileManager.default.fileExists(atPath: file.path) }
        #expect(written)
        #expect(host.statusSummary.contains("profiles 2"))
    }

    @Test("focus follows the fortnight's volume, holds while the panel is open, and follows a pin")
    func focusFollowsActivity() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write(fixture.standard, historyAge: 3600)
        try fixture.write(fixture.personal, historyAge: 60)
        // Two sessions on the default home this week; one, newer, on the personal home.
        try fixture.session(fixture.standard, "one", age: 3 * 86400)
        try fixture.session(fixture.standard, "two", age: 3600)
        try fixture.session(fixture.personal, "solo", age: 60)
        fixture.enroll(fixture.personal)
        let host = fixture.makeHost()
        host.start()
        defer { host.shutdown() }
        #expect(host.recentActivity["default"] == 2)
        #expect(host.recentActivity[fixture.personalID] == 1)
        #expect(host.focusedProfileID == "default")

        // The personal home overtakes on volume: applied on the next
        // reprobe — unless the panel holds focus, in which case it lands
        // on release.
        host.holdFocus(true)
        try fixture.session(fixture.personal, "second", age: 30)
        try fixture.session(fixture.personal, "third", age: 20)
        host.reprobe()
        let reprobed = await eventually { host.recentActivity[fixture.personalID] == 3 }
        #expect(reprobed)
        #expect(host.focusedProfileID == "default")
        host.holdFocus(false)
        #expect(host.focusedProfileID == fixture.personalID)

        // A pin beats volume while it is eligible.
        let pinned = await host.handle(.focusProfile(id: "default"))
        #expect(pinned.ok)
        #expect(host.focusedProfileID == "default")
        #expect(ProfileStore.pin(from: fixture.defaults) == "default")
        let cleared = await host.handle(.focusProfile(id: nil))
        #expect(cleared.ok)
        #expect(host.focusedProfileID == fixture.personalID)
        let unknown = await host.handle(.focusProfile(id: "nope"))
        #expect(!unknown.ok)
    }

    @Test("a dormant profile starts no engine and comes back on a write")
    func dormantRevives() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write(fixture.personal, historyAge: 40 * 86400)
        fixture.enroll(fixture.personal, addedAgo: 60 * 86400)
        let host = fixture.makeHost()
        host.start()
        defer { host.shutdown() }

        #expect(host.dormant == [fixture.personalID])
        #expect(Set(host.engines.keys) == ["default"])
        let dormantSection = try #require(host.digest?.profiles?.first { $0.id == fixture.personalID })
        #expect(dormantSection.dormant && dormantSection.engine == nil && dormantSection.meters == nil)
        #expect(host.digest?.menuBarCells?.map(\.profile) == ["default"])
        #expect(host.statusSummary.contains("dormant 1"))

        try fixture.write(fixture.personal, historyAge: 1)
        host.reprobe()
        let revived = await eventually { host.engines[fixture.personalID] != nil }
        #expect(revived)
        #expect(host.dormant.isEmpty)
    }

    @Test("an all-dormant host keeps a heartbeat horizon so no client takes over")
    func allDormantHeartbeat() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.write(fixture.standard, historyAge: 40 * 86400)
        // The default profile's enrolment stamp is synthesized at start, so
        // a stored record with an old stamp is what makes it dormant.
        fixture.enroll(fixture.standard, addedAgo: 60 * 86400, order: 0)
        let host = fixture.makeHost(reprobeInterval: 600)
        host.start()
        defer { host.shutdown() }

        #expect(host.engines.isEmpty)
        let digest = try #require(host.digest)
        #expect(digest.engine.stale && digest.engine.fetchedAt == nil && digest.engine.error == nil)
        let horizon = try #require(digest.engine.nextPollAt)
        #expect(abs(horizon.timeIntervalSince(Date().addingTimeInterval(600))) < 5)
        #expect(!EngineHostBroker.heartbeatStale(
            generatedAt: digest.engine.generatedAt, nextPollAt: horizon,
            now: Date().addingTimeInterval(400)))
    }

    @Test("setInterval fans out; refresh targets the focused engine; refreshProfile one engine")
    func verbsFanOutOrTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.enroll(fixture.personal)
        let host = fixture.makeHost()
        host.start()
        defer { host.shutdown() }

        let interval = await host.handle(.setInterval(seconds: 600))
        #expect(interval == ControlReply(ok: true, message: "interval 600s"))
        #expect(host.engines.values.allSatisfy { $0.activeInterval == 600 })

        let focused = await host.handle(.refresh)
        #expect(focused.ok)
        let one = await host.handle(.refreshProfile(id: fixture.personalID))
        #expect(one.ok && one.message?.contains(fixture.personalID) == true)
        let none = await host.handle(.refreshProfile(id: "nope"))
        #expect(!none.ok)
        let status = await host.handle(.status)
        #expect(status.message?.contains("profiles 2") == true)
        // Process-lifecycle verbs are refused without an owner.
        let shutdown = await host.handle(.shutdown)
        #expect(!shutdown.ok)
        let provider = await host.handle(.setProvider(id: "codex"))
        #expect(!provider.ok)
    }

    @Test("an enrolled home answers its own offer")
    func enrolmentAnswersTheOffer() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let host = fixture.makeHost()
        host.start()
        defer { host.shutdown() }
        // Discovery runs off-main at start: the personal home is used and
        // signed in, so an offer lands in the ledger.
        let offered = await eventually {
            host.services.notices.pending.contains { $0.id == "profile|\(fixture.personalID)" }
        }
        #expect(offered)

        fixture.enroll(fixture.personal)
        let changed = await host.handle(.profilesChanged)
        #expect(changed.ok)
        #expect(!host.services.notices.pending.contains { $0.id == "profile|\(fixture.personalID)" })
        #expect(host.services.notices.notices.first { $0.id == "profile|\(fixture.personalID)" }?.dismissedAt != nil)
    }

    @Test("profilesChanged reconciles: a new profile starts, a disabled one stops")
    func profilesReconcile() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let host = fixture.makeHost()
        host.start()
        defer { host.shutdown() }
        #expect(Set(host.engines.keys) == ["default"])

        fixture.enroll(fixture.personal)
        let changed = await host.handle(.profilesChanged)
        #expect(changed.ok)
        #expect(Set(host.engines.keys) == ["default", fixture.personalID])

        let disabled = await host.handle(.setProfileEnabled(id: fixture.personalID, enabled: false))
        #expect(disabled.ok)
        #expect(Set(host.engines.keys) == ["default"])
        let section = try #require(host.digest?.profiles?.first { $0.id == fixture.personalID })
        #expect(!section.enabled && section.engine == nil && section.meters == nil)
        #expect(host.digest?.menuBarCells?.map(\.profile) == ["default"])
        #expect(ProfileStore.load(from: fixture.defaults).first { $0.id == fixture.personalID }?.enabled == false)
    }

    @Test("launch polls stagger across the configured span")
    func staggeredLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        fixture.enroll(fixture.personal)
        let host = fixture.makeHost(stagger: 40)
        host.start()
        defer { host.shutdown() }

        let first = try #require(host.engines["default"])
        let second = try #require(host.engines[fixture.personalID])
        let landed = await eventually { first.state.snapshot != nil }
        #expect(landed)
        // The second engine's first poll is 20s out (index 1 × 40 / 2) and
        // nothing has been fetched for it yet.
        let next = try #require(second.nextRefreshAt)
        #expect(abs(next.timeIntervalSince(Date().addingTimeInterval(20))) < 3)
        #expect(second.state.snapshot == nil)
    }

    @Test("gate seeds from a previous digest keep a handover from double-polling")
    func gateSeeds() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let seed = Date().addingTimeInterval(-30)
        let host = MeteringHost(
            provider: fixture.provider(for: fixture.standard), defaults: fixture.defaults,
            configuration: MeteringHost.Configuration(
                bundleID: "com.test.host", kind: .app, roots: fixture.roots, pollsStatus: false,
                userHome: fixture.userHome, bindsSocket: false),
            serviceFactory: { _ in
                UsageService(
                    provider: fixture.provider(for: fixture.standard),
                    cache: UsageCache(directory: fixture.roots.caches.appending(path: "seeded")),
                    retryDelay: .zero)
            },
            gateSeeds: ["default": seed])
        host.start()
        defer { host.shutdown() }
        let engine = try #require(host.engines["default"])
        // Denied inside the floor: nothing fetched, a timer left behind.
        #expect(!engine.isRefreshing)
        #expect(engine.state.snapshot == nil)
        #expect(engine.nextRefreshAt != nil)
    }
}
