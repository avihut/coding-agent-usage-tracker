import Foundation
import Testing
@testable import UsageCore

@Suite("Identity migration")
struct IdentityMigrationTests {
    private let legacyID = "old.example.App"
    private let newID = "new.example.App"

    private final class Sandbox {
        let base: URL
        let roots: StorageScope.Roots
        let defaults: UserDefaults
        private let suite: String

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appending(path: "identity-migration-\(UUID().uuidString)")
            roots = StorageScope.Roots(
                support: base.appending(path: "Application Support"),
                caches: base.appending(path: "Caches"))
            try FileManager.default.createDirectory(at: roots.support, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: roots.caches, withIntermediateDirectories: true)
            suite = "identity-migration-tests-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: base)
        }

        func write(_ text: String, _ path: String, under root: URL) throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func read(_ path: String, under root: URL) -> String? {
            (try? Data(contentsOf: root.appending(path: path))).map { String(decoding: $0, as: UTF8.self) }
        }

        func exists(_ path: String, under root: URL) -> Bool {
            FileManager.default.fileExists(atPath: root.appending(path: path).path)
        }
    }

    private func run(
        _ box: Sandbox, legacyDefaults: [String: Any] = [:], retired: @escaping () -> Void = {}
    ) -> IdentityMigration.Outcome? {
        IdentityMigration.migrate(
            from: legacyID, to: newID, roots: box.roots, defaults: box.defaults,
            legacyDefaults: { _ in legacyDefaults },
            retireLegacyAgent: { retired(); return true },
            leaseTimeout: 0)
    }

    @Test("the old roots move whole — data, caches and the digest — and the runtime files stay behind")
    func movesEverything() throws {
        let box = try Sandbox()
        try box.write("history", "\(legacyID)/claude/default/history.json", under: box.roots.support)
        try box.write("digest", "\(legacyID)/live-state.json", under: box.roots.support)
        try box.write("", "\(legacyID)/engine.lock", under: box.roots.support)
        try box.write("", "\(legacyID)/daemon.alive", under: box.roots.support)
        try box.write("usage", "\(legacyID)/claude/default/usage.json", under: box.roots.caches)

        var retiredCalls = 0
        let outcome = try #require(run(box, retired: { retiredCalls += 1 }))

        #expect(box.read("\(newID)/claude/default/history.json", under: box.roots.support) == "history")
        #expect(box.read("\(newID)/live-state.json", under: box.roots.support) == "digest")
        #expect(box.read("\(newID)/claude/default/usage.json", under: box.roots.caches) == "usage")
        #expect(!box.exists("\(newID)/engine.lock", under: box.roots.support))
        #expect(!box.exists("\(newID)/daemon.alive", under: box.roots.support))
        #expect(!box.exists(legacyID, under: box.roots.support))
        #expect(!box.exists(legacyID, under: box.roots.caches))
        // The old engine is retired BEFORE its directory moves, exactly once.
        #expect(retiredCalls == 1)
        #expect(outcome.retiredAgent)
        #expect(outcome.conflicts == 0)
    }

    @Test("a new root that already exists is merged into — what it holds wins, and the old copy stays readable")
    func mergesIntoExistingRoot() throws {
        let box = try Sandbox()
        try box.write("old history", "\(legacyID)/claude/default/history.json", under: box.roots.support)
        try box.write("old ledger", "\(legacyID)/claude/default/window-ledger.json", under: box.roots.support)
        try box.write("old codex", "\(legacyID)/codex/default/history.json", under: box.roots.support)
        // A host that got here first: a lock file and one provider's fresh file.
        try box.write("", "\(newID)/migration.lock", under: box.roots.support)
        try box.write("new history", "\(newID)/claude/default/history.json", under: box.roots.support)

        let outcome = try #require(run(box))

        #expect(box.read("\(newID)/claude/default/history.json", under: box.roots.support) == "new history")
        #expect(box.read("\(newID)/claude/default/window-ledger.json", under: box.roots.support) == "old ledger")
        #expect(box.read("\(newID)/codex/default/history.json", under: box.roots.support) == "old codex")
        #expect(outcome.conflicts == 1)
        // Never overwritten, never deleted: the conflicting file is still where it was.
        #expect(box.read("\(legacyID)/claude/default/history.json", under: box.roots.support) == "old history")
    }

    @Test("settings are carried; a key the new domain already has is not overwritten")
    func carriesDefaults() throws {
        let box = try Sandbox()
        box.defaults.set(900, forKey: "refreshInterval")
        let outcome = try #require(run(box, legacyDefaults: [
            "refreshInterval": 300,
            "daemonAutoInstall": false,
            "NSStatusItem Preferred Position Item-0": 412.0,
        ]))

        #expect(box.defaults.integer(forKey: "refreshInterval") == 900)
        // The sticky opt-out survives the rename — usaged reads it right after.
        #expect(box.defaults.object(forKey: "daemonAutoInstall") as? Bool == false)
        #expect(box.defaults.double(forKey: "NSStatusItem Preferred Position Item-0") == 412.0)
        #expect(outcome.defaultsCarried == 2)
        #expect(box.defaults.string(forKey: IdentityMigration.markerKey) == legacyID)
    }

    @Test("it runs once: the marker makes every later launch a single defaults read")
    func runsOnce() throws {
        let box = try Sandbox()
        try box.write("history", "\(legacyID)/claude/default/history.json", under: box.roots.support)
        #expect(run(box) != nil)
        #expect(!IdentityMigration.isPending(defaults: box.defaults))

        // An old binary runs again later and re-creates its directory: left alone.
        try box.write("stray", "\(legacyID)/claude/default/history.json", under: box.roots.support)
        var retiredCalls = 0
        #expect(run(box, retired: { retiredCalls += 1 }) == nil)
        #expect(retiredCalls == 0)
        #expect(box.read("\(newID)/claude/default/history.json", under: box.roots.support) == "history")
    }

    @Test("an install that never had another identity retires nothing and just stops looking")
    func freshInstall() throws {
        let box = try Sandbox()
        var retiredCalls = 0
        let outcome = try #require(run(box, retired: { retiredCalls += 1 }))
        #expect(outcome == IdentityMigration.Outcome())
        #expect(retiredCalls == 0)
        #expect(box.defaults.string(forKey: IdentityMigration.markerKey) == "")
        #expect(!box.exists(newID, under: box.roots.support))
    }
}

@Suite("App identity")
struct AppIdentityTests {
    @Test("Info.plist and AppIdentity name the same bundle — every path on disk hangs off it")
    func plistAgrees() throws {
        let plist = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Support/Info.plist")
        let data = try Data(contentsOf: plist)
        let info = try #require(try PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any])
        #expect(info["CFBundleIdentifier"] as? String == AppIdentity.bundleID)
        #expect(info["CFBundleExecutable"] as? String == "AgentUsage")
        #expect(info["CFBundleName"] as? String == AppIdentity.displayName)
    }

    @Test("the identity moved: nothing current may equal what it migrates from")
    func legacyIsLegacy() {
        #expect(AppIdentity.bundleID != AppIdentity.legacyBundleID)
        #expect(AppIdentity.daemonLabel != AppIdentity.legacyDaemonLabel)
        #expect(LaunchAgentInstaller.label == AppIdentity.daemonLabel)
    }
}
