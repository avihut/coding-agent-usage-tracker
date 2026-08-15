import Foundation
import Testing
@testable import UsageCore

@Suite("Storage scoping and migration")
struct StorageScopeTests {
    @Test("scoped paths nest provider under bundle id")
    func scopedPaths() {
        let support = StorageScope.supportDirectory(bundleID: "com.test.app", providerID: "claude")
        #expect(support.path.hasSuffix("com.test.app/claude"))
        let caches = StorageScope.cachesDirectory(bundleID: "com.test.app", providerID: "codex")
        #expect(caches.path.hasSuffix("com.test.app/codex"))
        #expect(StorageScope.scopedKey("apiHourlyCeiling", providerID: "claude")
            == "claude.apiHourlyCeiling")
    }

    @Test("migration moves all four artifacts into the provider scope")
    func migrationMovesFiles() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        try fixture.write("history.json", in: fixture.support, contents: "history-bytes")
        try fixture.write("activity-cache.json", in: fixture.support, contents: "cache")
        try fixture.write("pricing.json", in: fixture.support, contents: "rates")
        try fixture.write("usage.json", in: fixture.caches, contents: "usage")

        fixture.migrate()

        #expect(fixture.read("claude/history.json", in: fixture.support) == "history-bytes")
        #expect(fixture.read("claude/activity-cache.json", in: fixture.support) == "cache")
        #expect(fixture.read("claude/pricing.json", in: fixture.support) == "rates")
        #expect(fixture.read("claude/usage.json", in: fixture.caches) == "usage")
        #expect(fixture.read("history.json", in: fixture.support) == nil)
        #expect(fixture.read("usage.json", in: fixture.caches) == nil)
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 2)
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
        // A file appearing at the old path after migration must stay put.
        try fixture.write("history.json", in: fixture.support, contents: "late")

        fixture.migrate()

        #expect(fixture.read("history.json", in: fixture.support) == "late")
        #expect(fixture.read("claude/history.json", in: fixture.support) == nil)
    }

    @Test("a half-written destination from an interrupted run is replaced")
    func migrationReplacesPartialDestination() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        try fixture.write("history.json", in: fixture.support, contents: "the-real-history")
        try fixture.write("claude/history.json", in: fixture.support, contents: "torn")

        fixture.migrate()

        #expect(fixture.read("claude/history.json", in: fixture.support) == "the-real-history")
        #expect(fixture.read("history.json", in: fixture.support) == nil)
    }

    @Test("nothing to migrate still completes and marks done")
    func migrationEmpty() throws {
        let fixture = try MigrationFixture()
        defer { fixture.tearDown() }
        fixture.migrate()
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 2)
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
        #expect(fixture.defaults.integer(forKey: "storageScopeVersion") == 2)
    }
}

/// Temp support/caches roots plus an isolated UserDefaults suite.
private struct MigrationFixture {
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
            support: support, caches: caches, providerID: "claude", defaults: defaults)
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
