import Darwin
import Foundation
import Testing
@testable import UsageCore

@Suite("Storage scoping and migration")
struct StorageScopeTests {
    @Test("scoped paths nest provider and profile under bundle id")
    func scopedPaths() {
        let support = StorageScope.supportDirectory(
            bundleID: "com.test.app", providerID: "claude", profileID: "default")
        #expect(support.path.hasSuffix("com.test.app/claude/default"))
        let caches = StorageScope.cachesDirectory(
            bundleID: "com.test.app", providerID: "codex", profileID: "c982130e")
        #expect(caches.path.hasSuffix("com.test.app/codex/c982130e"))
        let provider = StorageScope.providerDirectory(bundleID: "com.test.app", providerID: "claude")
        #expect(provider.path.hasSuffix("com.test.app/claude"))
        #expect(StorageScope.rootSupportDirectory(bundleID: "com.test.app").path
            .hasSuffix("Application Support/com.test.app"))
        #expect(StorageScope.cachesRootDirectory(bundleID: "com.test.app").path
            .hasSuffix("Caches/com.test.app"))
    }

    @Test("the default profile keeps the vendor key; other profiles insert their id")
    func scopedKeys() {
        #expect(StorageScope.scopedKey("apiHourlyCeiling", providerID: "claude")
            == "claude.apiHourlyCeiling")
        #expect(StorageScope.scopedKey("apiHourlyCeiling", providerID: "claude", profileID: "default")
            == "claude.apiHourlyCeiling")
        #expect(StorageScope.scopedKey("apiHourlyCeiling", providerID: "claude", profileID: "c982130e")
            == "claude.c982130e.apiHourlyCeiling")
        #expect(StorageScope.scopePrefix(providerID: "claude", profileID: "default") == "claude")
        #expect(StorageScope.scopePrefix(providerID: "claude", profileID: "c982130e") == "claude.c982130e")
    }

    @Test("injected roots replace the user-domain bases")
    func injectedRoots() {
        let roots = StorageScope.Roots(
            support: URL(filePath: "/tmp/s"), caches: URL(filePath: "/tmp/c"))
        #expect(StorageScope.supportDirectory(
            bundleID: "b", providerID: "claude", profileID: "default", roots: roots).path
            == "/tmp/s/b/claude/default")
        #expect(StorageScope.cachesDirectory(
            bundleID: "b", providerID: "claude", profileID: "x", roots: roots).path
            == "/tmp/c/b/claude/x")
        #expect(StorageScope.providerDirectory(bundleID: "b", providerID: "codex", roots: roots).path
            == "/tmp/s/b/codex")
        #expect(StorageScope.rootSupportDirectory(bundleID: "b", roots: roots).path == "/tmp/s/b")
        #expect(StorageScope.cachesRootDirectory(bundleID: "b", roots: roots).path == "/tmp/c/b")
    }

    // MARK: - Fresh install: phases 1 → 3 in one run

    @Test("a pre-scope install lands every artifact in its v3 home")
    func migrationMovesFiles() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        try fixture.write("history.json", in: fixture.support, contents: "history-bytes")
        try fixture.write("activity-cache.json", in: fixture.support, contents: "cache")
        try fixture.write("pricing.json", in: fixture.support, contents: "rates")
        try fixture.write("usage.json", in: fixture.caches, contents: "usage")

        fixture.migrate()

        #expect(fixture.read("claude/default/history.json", in: fixture.support) == "history-bytes")
        #expect(fixture.read("claude/default/activity-cache.json", in: fixture.support) == "cache")
        // Pricing describes the vendor: provider-level, not a profile's.
        #expect(fixture.read("claude/pricing.json", in: fixture.support) == "rates")
        #expect(fixture.read("claude/default/usage.json", in: fixture.caches) == "usage")
        #expect(fixture.read("history.json", in: fixture.support) == nil)
        #expect(fixture.read("claude/history.json", in: fixture.support) == nil)
        #expect(fixture.read("usage.json", in: fixture.caches) == nil)
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 3)
    }

    @Test("migration scopes the ceiling and meter popover keys")
    func migrationMovesKeys() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        fixture.defaults.set(33, forKey: "apiHourlyCeiling")
        fixture.defaults.set("Window", forKey: "meterPopoverSpan-0-session")
        fixture.defaults.set("30d", forKey: "meterSlidingFrame-1-weekly_all")

        fixture.migrate()

        #expect(fixture.defaults.integer(forKey: "claude.apiHourlyCeiling") == 33)
        #expect(fixture.defaults.string(forKey: "meterPopoverSpan-claude.0-session") == "Window")
        #expect(fixture.defaults.string(forKey: "meterSlidingFrame-claude.1-weekly_all") == "30d")
        #expect(fixture.defaults.object(forKey: "apiHourlyCeiling") == nil)
        #expect(fixture.defaults.object(forKey: "meterPopoverSpan-0-session") == nil)
    }

    @Test("a second run honors the done-marker")
    func migrationRunsOnce() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        fixture.migrate()
        // A file appearing at an old path after migration must stay put.
        try fixture.write("history.json", in: fixture.support, contents: "late")
        try fixture.write("claude/history.json", in: fixture.support, contents: "later")

        fixture.migrate()

        #expect(fixture.read("history.json", in: fixture.support) == "late")
        #expect(fixture.read("claude/history.json", in: fixture.support) == "later")
        #expect(fixture.read("claude/default/history.json", in: fixture.support) == nil)
    }

    @Test("a half-written destination from an interrupted run is replaced")
    func migrationReplacesPartialDestination() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        try fixture.write("history.json", in: fixture.support, contents: "the-real-history")
        try fixture.write("claude/history.json", in: fixture.support, contents: "torn")

        fixture.migrate()

        #expect(fixture.read("claude/default/history.json", in: fixture.support) == "the-real-history")
        #expect(fixture.read("history.json", in: fixture.support) == nil)
        #expect(fixture.read("claude/history.json", in: fixture.support) == nil)
    }

    @Test("nothing to migrate still completes and marks done")
    func migrationEmpty() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        fixture.migrate()
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 3)
    }

    @Test("v2 scopes the color ledger — including for installs already at v1")
    func ledgerScopedForV1Installs() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        // A v0.26–0.28 install: file scoping done, ledger still unscoped.
        fixture.defaults.set(1, forKey: "storageScopeVersion")
        fixture.defaults.set(
            ["hues": ["Fable": 0], "shades": ["Fable": ["claude-fable-5": 0]]],
            forKey: "modelColorLedger")
        // Old-path files must stay put — phase 1 must not re-run.
        try fixture.write("history.json", in: fixture.support, contents: "post-v1")

        fixture.migrate()

        let scoped = fixture.defaults.dictionary(forKey: "claude.modelColorLedger")
        #expect((scoped?["hues"] as? [String: Int]) == ["Fable": 0])
        #expect(fixture.defaults.object(forKey: "modelColorLedger") == nil)
        #expect(fixture.read("history.json", in: fixture.support) == "post-v1")
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 3)
    }

    // MARK: - v3: per-profile directories

    @Test("v3 steps per-account artifacts into the default profile and leaves vendor files")
    func v3MovesProfileArtifactsOnly() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        fixture.defaults.set(2, forKey: "storageScopeVersion")
        for name in ["history", "activity-cache", "window-ledger", "account-presence", "session-renames"] {
            try fixture.write("claude/\(name).json", in: fixture.support, contents: name)
        }
        try fixture.write("claude/pricing.json", in: fixture.support, contents: "rates")
        try fixture.write("claude/notices.json", in: fixture.support, contents: "notices")
        try fixture.write("claude/usage.json", in: fixture.caches, contents: "usage")
        // A stray pre-scope file: phase 1 must NOT re-run for a v2 install.
        try fixture.write("history.json", in: fixture.support, contents: "stray")
        fixture.defaults.set(7, forKey: "apiHourlyCeiling")

        fixture.migrate()

        for name in ["history", "activity-cache", "window-ledger", "account-presence", "session-renames"] {
            #expect(fixture.read("claude/default/\(name).json", in: fixture.support) == name)
            #expect(fixture.read("claude/\(name).json", in: fixture.support) == nil)
        }
        #expect(fixture.read("claude/pricing.json", in: fixture.support) == "rates")
        #expect(fixture.read("claude/notices.json", in: fixture.support) == "notices")
        #expect(fixture.read("claude/default/usage.json", in: fixture.caches) == "usage")
        #expect(fixture.read("claude/usage.json", in: fixture.caches) == nil)
        #expect(fixture.read("history.json", in: fixture.support) == "stray")
        // No defaults keys move at v3: the default profile keeps today's spelling.
        #expect(fixture.defaults.integer(forKey: "apiHourlyCeiling") == 7)
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 3)
    }

    @Test("v3 walks every provider directory, not just the bundled default")
    func v3WalksEveryProvider() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        fixture.defaults.set(2, forKey: "storageScopeVersion")
        try fixture.write("codex/activity-cache.json", in: fixture.support, contents: "codex-cache")
        try fixture.write("gemini/history.json", in: fixture.support, contents: "gemini-history")
        try fixture.write("codex/usage.json", in: fixture.caches, contents: "codex-usage")

        fixture.migrate()

        #expect(fixture.read("codex/default/activity-cache.json", in: fixture.support) == "codex-cache")
        #expect(fixture.read("gemini/default/history.json", in: fixture.support) == "gemini-history")
        #expect(fixture.read("codex/default/usage.json", in: fixture.caches) == "codex-usage")
        #expect(fixture.read("codex/activity-cache.json", in: fixture.support) == nil)
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 3)
    }

    @Test("v3 replaces a torn destination from an interrupted run")
    func v3ReplacesTornDestination() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        fixture.defaults.set(2, forKey: "storageScopeVersion")
        try fixture.write("claude/history.json", in: fixture.support, contents: "the-real-history")
        try fixture.write("claude/default/history.json", in: fixture.support, contents: "torn")

        fixture.migrate()

        #expect(fixture.read("claude/default/history.json", in: fixture.support) == "the-real-history")
        #expect(fixture.read("claude/history.json", in: fixture.support) == nil)
    }

    @Test("a failed v3 move keeps the marker at 2 so the next launch retries")
    func v3FailureLeavesMarker() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        fixture.defaults.set(2, forKey: "storageScopeVersion")
        try fixture.write("claude/history.json", in: fixture.support, contents: "precious")
        // A regular FILE where the profile directory must go: the copy
        // cannot create its parent, so the move fails and the source stays.
        try fixture.write("claude/default", in: fixture.support, contents: "in-the-way")

        fixture.migrate()

        #expect(fixture.read("claude/history.json", in: fixture.support) == "precious")
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 2)
    }

    @Test("a run waits for the migration lock a peer holds, then finds the work done")
    func migrationWaitsForLock() async throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        fixture.defaults.set(2, forKey: "storageScopeVersion")
        try fixture.write("claude/history.json", in: fixture.support, contents: "held")

        // flock is per open-file-description, so a second descriptor in
        // this very process stands in for the peer.
        let lockURL = StorageMigration.lockURL(support: fixture.support)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)

        let run = Task.detached { fixture.migrate() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.read("claude/history.json", in: fixture.support) == "held")
        #expect(fixture.read("claude/default/history.json", in: fixture.support) == nil)
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 2)

        flock(fd, LOCK_UN)
        close(fd)
        await run.value
        #expect(fixture.read("claude/default/history.json", in: fixture.support) == "held")
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 3)
    }
}

/// Temp support/caches roots plus an isolated UserDefaults suite.
/// `@unchecked`: `UserDefaults` is documented thread-safe (its class is
/// not marked Sendable in the SDK); the lock test hands the fixture to a
/// detached task that only ever calls `migrate()` on it.
private struct MigrationFixture: @unchecked Sendable {
    let root: URL
    let support: URL
    let caches: URL
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "storage-scope-tests-\(UUID().uuidString)")
        support = root.appending(path: "support")
        caches = root.appending(path: "caches")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        suiteName = "storage-scope-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func migrate() {
        StorageMigration.migrate(
            support: support, caches: caches, providerID: "claude",
            providerIDs: ["claude", "codex", "gemini"], defaults: defaults)
    }

    func write(_ name: String, in directory: URL, contents: String) throws {
        let url = directory.appending(path: name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func read(_ name: String, in directory: URL) -> String? {
        (try? Data(contentsOf: directory.appending(path: name)))
            .map { String(decoding: $0, as: UTF8.self) }
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
