import Darwin
import Foundation

/// Where a provider's artifacts live and how its UserDefaults keys read.
/// The one place scoping is derived: every per-provider and per-profile
/// path and key routes through here. Since storage v3 (v0.96.0) the layout
/// is three levels deep —
///
///     <root>/<bundleID>/                         live-state.json, engine.lock
///     <root>/<bundleID>/<providerID>/            pricing.json, notices.json
///     <root>/<bundleID>/<providerID>/<profileID>/ history.json, activity-cache.json,
///                                                window-ledger.json, account-presence.json,
///                                                session-renames.json (caches: usage.json)
///
/// — a PROFILE being one agent home (`~/.claude`, `~/.claude-personal`)
/// under one provider. Pricing and notices describe the vendor, not an
/// account, so they stay one level up. Meter labels key records *inside*
/// these files ("Session (5h)" percents in history.json), which is only
/// safe because every profile owns its own files; never share one of these
/// directories between providers or profiles.
public enum StorageScope {
    /// The implicit profile every install has: the provider's standard home
    /// (`~/.claude` for Claude). Its defaults keys keep the pre-profile
    /// spelling (`claude.apiHourlyCeiling`), so v3 moved files only.
    public static let defaultProfileID = "default"

    /// The two user-domain bases every scoped path hangs off. Injectable so
    /// a host under test (MeteringHost, the migration) can run against temp
    /// directories without touching `~/Library`.
    public struct Roots: Sendable {
        /// `~/Library/Application Support`
        public var support: URL
        /// `~/Library/Caches`
        public var caches: URL

        public init(support: URL, caches: URL) {
            self.support = support
            self.caches = caches
        }

        public static let standard = Roots(
            support: base(.applicationSupportDirectory), caches: base(.cachesDirectory))
    }

    /// `~/Library/Application Support/<bundleID>/` — the bundle root above
    /// the provider scopes, for artifacts that describe the ENGINE rather
    /// than one provider's data (live-state.json, engine.lock).
    public static func rootSupportDirectory(bundleID: String, roots: Roots = .standard) -> URL {
        roots.support.appending(path: bundleID)
    }

    /// `~/Library/Caches/<bundleID>/` — the caches bundle root.
    public static func cachesRootDirectory(bundleID: String, roots: Roots = .standard) -> URL {
        roots.caches.appending(path: bundleID)
    }

    /// `~/Library/Application Support/<bundleID>/<providerID>/` — the
    /// vendor-level artifacts shared by every profile of that provider:
    /// pricing.json, notices.json.
    public static func providerDirectory(
        bundleID: String, providerID: String, roots: Roots = .standard
    ) -> URL {
        rootSupportDirectory(bundleID: bundleID, roots: roots).appending(path: providerID)
    }

    /// `~/Library/Application Support/<bundleID>/<providerID>/<profileID>/`
    /// — history.json, activity-cache.json, window-ledger.json,
    /// account-presence.json, session-renames.json.
    public static func supportDirectory(
        bundleID: String, providerID: String, profileID: String, roots: Roots = .standard
    ) -> URL {
        providerDirectory(bundleID: bundleID, providerID: providerID, roots: roots)
            .appending(path: profileID)
    }

    /// `~/Library/Caches/<bundleID>/<providerID>/<profileID>/` — usage.json.
    public static func cachesDirectory(
        bundleID: String, providerID: String, profileID: String, roots: Roots = .standard
    ) -> URL {
        cachesRootDirectory(bundleID: bundleID, roots: roots)
            .appending(path: providerID).appending(path: profileID)
    }

    /// "apiHourlyCeiling" → "claude.apiHourlyCeiling" — for defaults whose
    /// value is a property of one vendor (the model-color ledger), not an
    /// app preference.
    public static func scopedKey(_ key: String, providerID: String) -> String {
        "\(providerID).\(key)"
    }

    /// The per-profile spelling: the default profile keeps the vendor key
    /// verbatim (`claude.apiHourlyCeiling` — nothing in UserDefaults moved
    /// at v3), every other profile inserts its id
    /// (`claude.c982130e.apiHourlyCeiling`).
    public static func scopedKey(_ key: String, providerID: String, profileID: String) -> String {
        "\(scopePrefix(providerID: providerID, profileID: profileID)).\(key)"
    }

    /// `claude` for the default profile, `claude.<id>` otherwise — the
    /// prefix the per-meter popover prefs and the ceiling key hang off.
    public static func scopePrefix(providerID: String, profileID: String) -> String {
        profileID == defaultProfileID ? providerID : "\(providerID).\(profileID)"
    }

    static func base(_ directory: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}

/// One-time moves of on-disk artifacts as the storage layout deepened.
/// Runs before any store exists, in the app AND in usaged, serialized
/// across processes by a blocking `flock` on `<bundle root>/migration.lock`
/// (after an update the app and the daemon start within the same second —
/// two interleaved copy-verify-delete runs could lose a file).
///
/// Phases, each guarded by the persisted marker so it runs exactly once:
/// 1 (v0.26.0) the pre-registry singletons into the bundled provider's
///   scope, plus the vendor-fact defaults keys; 2 (v0.29.0) the model-color
///   ledger key; 3 (v0.96.0) each provider's per-account artifacts into its
///   `default` profile directory — files only, no defaults key moves.
///
/// Copy → verify → delete, so a failure at any step leaves the original in
/// place and readable — history.json carries weeks of irreplaceable
/// forecast learning, and losing it silently would reset the weekly rhythm
/// and restart the "personalized forecast activates in N days" countdown.
public enum StorageMigration {
    static let versionKey = "storageScopeVersion"
    static let currentVersion = 3
    /// The meter ids the pre-scope panel persisted popover prefs under.
    static let legacyMeterIDs = ["0-session", "1-weekly_all", "2-weekly_scoped"]
    static let meterPrefPrefixes = ["meterPopoverSpan-", "meterSlidingFrame-"]
    /// What v3 moves from `<provider>/` into `<provider>/default/`.
    static let profileSupportFiles = [
        "history.json", "activity-cache.json", "window-ledger.json",
        "account-presence.json", "session-renames.json",
    ]
    static let profileCacheFiles = ["usage.json"]

    /// The app's entry point: derives the standard bases and migrates every
    /// bundled provider's scope. `providerIDs` is the v3 walk (every
    /// provider directory that may exist); the pre-scope singletons of
    /// phase 1 always belonged to the bundled default, `claude`.
    public static func standard(
        bundleID: String, providerIDs: [String], defaults: UserDefaults = .standard
    ) {
        migrate(
            support: StorageScope.rootSupportDirectory(bundleID: bundleID),
            caches: StorageScope.cachesRootDirectory(bundleID: bundleID),
            providerID: "claude", providerIDs: providerIDs,
            defaults: defaults)
    }

    /// Injectable form for tests and usaged. `support`/`caches` are the
    /// BUNDLE roots (`…/<bundleID>`); `providerID` is phase 1's target;
    /// `providerIDs` lists every provider directory phase 3 walks (the
    /// target joins it). `defaults` carries the done-marker, the scoped
    /// ceiling key, and the per-meter popover prefs.
    public static func migrate(
        support: URL, caches: URL, providerID: String, providerIDs: [String] = [],
        defaults: UserDefaults = .standard
    ) {
        // Cheap pre-check outside the lock: the steady state is a marker
        // hit, and taking a lock on every launch buys nothing then.
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }

        let lock = MigrationLock(url: lockURL(support: support))
        defer { lock.unlock() }
        // Re-read under the lock: the peer we waited on may have finished
        // the very migration we came for.
        let version = defaults.integer(forKey: versionKey)
        guard version < currentVersion else { return }

        var reached = version
        if reached < 1, movePreScopeSingletons(support: support, caches: caches, providerID: providerID, defaults: defaults) {
            reached = 1
        }
        if reached == 1 {
            // v2 (0.29.0): the model-color ledger became provider-scoped so
            // every harness's heaviest family wears its own vendor accent.
            moveKey(
                from: "modelColorLedger",
                to: StorageScope.scopedKey("modelColorLedger", providerID: providerID),
                defaults: defaults)
            reached = 2
        }
        if reached == 2 {
            var walk = [providerID]
            for id in providerIDs where !walk.contains(id) { walk.append(id) }
            if moveIntoDefaultProfile(support: support, caches: caches, providerIDs: walk) {
                reached = 3
            }
        }

        // A failed file move leaves the marker at the last completed phase
        // so the next launch retries — already-moved files have no source
        // left and skip.
        if reached > version {
            defaults.set(reached, forKey: versionKey)
        }
    }

    /// Beside engine.lock, at the bundle root.
    static func lockURL(support: URL) -> URL {
        support.appending(path: "migration.lock")
    }

    // MARK: - Phases

    /// Phase 1: `<bundle>/history.json` → `<bundle>/<provider>/history.json`
    /// and friends, plus the defaults keys that name a vendor fact.
    private static func movePreScopeSingletons(
        support: URL, caches: URL, providerID: String, defaults: UserDefaults
    ) -> Bool {
        var allMoved = true
        let files: [(URL, [String])] = [
            (support, ["history.json", "activity-cache.json", "pricing.json"]),
            (caches, ["usage.json"]),
        ]
        for (root, names) in files {
            for name in names {
                let moved = moveVerified(
                    from: root.appending(path: name),
                    to: root.appending(path: providerID).appending(path: name))
                allMoved = allMoved && moved
            }
        }

        moveKey(
            from: "apiHourlyCeiling",
            to: StorageScope.scopedKey("apiHourlyCeiling", providerID: providerID),
            defaults: defaults)
        for meterID in legacyMeterIDs {
            for prefix in meterPrefPrefixes {
                moveKey(
                    from: "\(prefix)\(meterID)",
                    to: "\(prefix)\(providerID).\(meterID)",
                    defaults: defaults)
            }
        }
        return allMoved
    }

    /// Phase 3: every per-account artifact of every provider steps down
    /// into that provider's `default` profile directory. pricing.json and
    /// notices.json describe the vendor and stay where they are.
    private static func moveIntoDefaultProfile(
        support: URL, caches: URL, providerIDs: [String]
    ) -> Bool {
        var allMoved = true
        for providerID in providerIDs {
            let plan: [(URL, [String])] = [
                (support.appending(path: providerID), profileSupportFiles),
                (caches.appending(path: providerID), profileCacheFiles),
            ]
            for (directory, names) in plan {
                for name in names {
                    let moved = moveVerified(
                        from: directory.appending(path: name),
                        to: directory.appending(path: StorageScope.defaultProfileID)
                            .appending(path: name))
                    allMoved = allMoved && moved
                }
            }
        }
        return allMoved
    }

    // MARK: - Primitives

    /// Copies, verifies the byte count, and only then removes the original.
    /// A half-written destination from an interrupted earlier run is
    /// replaced, never trusted. True when the source is absent or fully
    /// migrated.
    private static func moveVerified(from source: URL, to destination: URL) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return true }
        do {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: source, to: destination)
            guard try size(of: source) == size(of: destination) else { return false }
            try manager.removeItem(at: source)
            return true
        } catch {
            // Best-effort: the unmigrated original stays readable at its
            // old path.
            return false
        }
    }

    private static func size(of url: URL) throws -> Int {
        try (url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1)
    }

    private static func moveKey(from old: String, to new: String, defaults: UserDefaults) {
        guard let value = defaults.object(forKey: old) else { return }
        if defaults.object(forKey: new) == nil {
            defaults.set(value, forKey: new)
        }
        defaults.removeObject(forKey: old)
    }
}

/// A BLOCKING exclusive `flock(2)` — unlike `EngineLease`, which must
/// never wait, a migration waits for its peer's run to finish and then
/// finds the marker already set. The kernel drops the lock with the
/// descriptor, so a crash mid-run can't wedge the next launch.
private struct MigrationLock {
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
