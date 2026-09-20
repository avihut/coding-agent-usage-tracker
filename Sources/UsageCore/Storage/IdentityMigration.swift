import Foundation

/// The one-time move from the app's old identity to its current one
/// (0.102.0): `com.avihu.ClaudeUsage` → `AppIdentity.bundleID`, and the
/// launch agent's label with it. A bundle identifier is what everything on
/// disk hangs off, so a rename is a data migration:
///
/// - `~/Library/Application Support/<id>/` — history (weeks of forecast
///   learning), ledgers, caches of record, the digest;
/// - `~/Library/Caches/<id>/`;
/// - the defaults domain — every setting, the enrolled accounts, the model
///   colour ledger, and AppKit's own status-item positions;
/// - the launch agent under the old label, which would otherwise keep an old
///   engine alive, writing to the old directories.
///
/// Runs FIRST in every process that writes — the app and usaged — before
/// `StorageMigration` (whose lock file would create the new root) and before
/// usaged's installer verbs (which read `daemonAutoInstall`: a sticky opt-out
/// must survive the rename). `usage-cli` and the TUI are readers and never
/// migrate; until the app or the daemon has run once they find no digest,
/// which is the truth.
///
/// Order matters and is the whole design: (1) retire the old agent, so no old
/// engine is writing; (2) wait for the old engine's lease to fall; (3) MOVE
/// the trees — `rename(2)`, same volume, nothing copied, nothing deleted; an
/// entry the new root already holds is left where it was rather than
/// overwritten; (4) carry the defaults the new domain doesn't already have;
/// (5) set the marker last, so an interrupted run is simply retried. The old
/// preferences plist is left in place: it is the way back.
///
/// What cannot be carried, and is said in the release notes instead: the
/// login item (an `SMAppService` registration belongs to a bundle id — it
/// has to be switched on again), and whatever a menu bar manager remembered
/// about the old app's status item.
public enum IdentityMigration {
    /// In the NEW domain: the identity this install was carried over from, or
    /// "" on an install that never had another.
    static let markerKey = "identityMigratedFrom"
    /// Files that describe a RUNNING engine, not data: never moved.
    static let runtimeFiles: Set<String> = [
        "engine.lock", "migration.lock", "daemon.alive", "control.sock",
    ]

    public struct Outcome: Equatable, Sendable {
        public var moved = 0
        /// Entries the new root already held; the old copy stays where it was.
        public var conflicts = 0
        public var defaultsCarried = 0
        public var retiredAgent = false
    }

    /// True until this install has looked for an old identity once. The app
    /// asks before it goes looking for an old copy of itself to quit.
    public static func isPending(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: markerKey) == nil
    }

    /// The hosts' entry point. `defaults` is the NEW domain as that host
    /// opens it (the app: `.standard`; usaged run bare: the app's suite).
    @discardableResult
    public static func standard(defaults: UserDefaults) -> Outcome? {
        migrate(
            from: AppIdentity.legacyBundleID, to: AppIdentity.bundleID,
            roots: .standard, defaults: defaults,
            legacyDefaults: { UserDefaults.standard.persistentDomain(forName: $0) ?? [:] },
            retireLegacyAgent: { LaunchAgentInstaller.retireLegacy() })
    }

    /// Injectable form. Returns nil when the marker says it already ran.
    @discardableResult
    static func migrate(
        from legacyID: String, to newID: String,
        roots: StorageScope.Roots, defaults: UserDefaults,
        legacyDefaults: (String) -> [String: Any],
        retireLegacyAgent: () -> Bool,
        leaseTimeout: TimeInterval = 5
    ) -> Outcome? {
        // The steady state is a marker hit: one defaults read per launch.
        guard isPending(defaults: defaults) else { return nil }

        // App and daemon start within the same second after an update. The
        // lock lives BESIDE the two roots — inside either, it would create
        // the new one or move with the old.
        let lock = IdentityLock(url: roots.support.appending(path: ".\(newID).identity.lock"))
        defer { lock.unlock() }
        guard isPending(defaults: defaults) else { return nil }

        var outcome = Outcome()
        let fm = FileManager.default
        let oldSupport = StorageScope.rootSupportDirectory(bundleID: legacyID, roots: roots)
        let oldCaches = StorageScope.cachesRootDirectory(bundleID: legacyID, roots: roots)
        let hadLegacy = fm.fileExists(atPath: oldSupport.path)
            || fm.fileExists(atPath: oldCaches.path)
            || !legacyDefaults(legacyID).isEmpty

        if hadLegacy {
            outcome.retiredAgent = retireLegacyAgent()
            waitForLease(
                at: EngineHostBroker.lockURL(bundleID: legacyID, roots: roots),
                timeout: leaseTimeout)
            var complete = true
            for (old, new) in [
                (oldSupport, StorageScope.rootSupportDirectory(bundleID: newID, roots: roots)),
                (oldCaches, StorageScope.cachesRootDirectory(bundleID: newID, roots: roots)),
            ] where fm.fileExists(atPath: old.path) {
                complete = mergeMove(from: old, into: new, outcome: &outcome) && complete
            }
            // A move that threw leaves the marker unset: the next launch
            // retries, and what already moved has no source left to move.
            guard complete else { return outcome }

            let carried = legacyDefaults(legacyID)
            for (key, value) in carried where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                outcome.defaultsCarried += 1
            }
        }
        defaults.set(hadLegacy ? legacyID : "", forKey: markerKey)
        return outcome
    }

    // MARK: - Pieces

    /// Moves every entry of `source` into `destination`, descending only
    /// where both sides hold a directory. Returns false if any move threw.
    private static func mergeMove(from source: URL, into destination: URL, outcome: inout Outcome) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: destination.path) {
            do {
                try fm.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // The common case, and one atomic rename — after the runtime
                // files that must not travel are dropped.
                for name in runtimeFiles {
                    try? fm.removeItem(at: source.appending(path: name))
                }
                try fm.moveItem(at: source, to: destination)
                outcome.moved += 1
                return true
            } catch {
                return false
            }
        }
        guard let names = try? fm.contentsOfDirectory(atPath: source.path) else { return false }
        var complete = true
        for name in names where !runtimeFiles.contains(name) {
            let from = source.appending(path: name)
            let to = destination.appending(path: name)
            var fromIsDirectory: ObjCBool = false
            var toIsDirectory: ObjCBool = false
            _ = fm.fileExists(atPath: from.path, isDirectory: &fromIsDirectory)
            if !fm.fileExists(atPath: to.path, isDirectory: &toIsDirectory) {
                do {
                    try fm.moveItem(at: from, to: to)
                    outcome.moved += 1
                } catch {
                    complete = false
                }
            } else if fromIsDirectory.boolValue, toIsDirectory.boolValue {
                complete = mergeMove(from: from, into: to, outcome: &outcome) && complete
            } else {
                outcome.conflicts += 1
            }
        }
        // Emptied of everything but runtime files: the old root goes. One
        // that still holds a conflict stays, readable, where it always was.
        if let left = try? fm.contentsOfDirectory(atPath: source.path),
           left.allSatisfy(runtimeFiles.contains) {
            try? fm.removeItem(at: source)
        }
        return complete
    }

    /// An old host that is shutting down flushes by PATH; moving its root
    /// mid-flush would have it re-create the old directory. The lease is
    /// kernel-released when that process exits — wait for that, bounded: an
    /// old APP that ignores the request is the app layer's to quit, and
    /// waiting for ever on it would hang a launch.
    private static func waitForLease(at url: URL, timeout: TimeInterval) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while leaseIsHeld(at: url), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// `EngineLease`'s own probe is MainActor-bound and usaged migrates
    /// before it has an actor to stand on; the question is one non-blocking
    /// `flock` either way.
    private static func leaseIsHeld(at url: URL) -> Bool {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }
}

/// A blocking exclusive `flock(2)`, as `StorageMigration`'s: the peer's run
/// finishes, then the marker is found set. Kernel-released with the
/// descriptor, so a crash mid-run can't wedge the next launch.
private struct IdentityLock {
    private let fd: Int32

    init(url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return }
        while flock(fd, LOCK_EX) != 0 && errno == EINTR {}
    }

    func unlock() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }
}
