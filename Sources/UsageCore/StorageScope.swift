import Foundation

/// Where a provider's artifacts live and how its UserDefaults keys read.
/// The one place scoping is derived: every per-provider path and key routes
/// through here, so when per-account separation arrives (roadmap), the
/// account becomes one more path component in these two functions — nowhere
/// else. Meter labels key records *inside* these files ("Session (5h)"
/// percents in history.json), which is only cross-provider-safe because
/// every provider owns its own files; never share one of these directories
/// between providers.
public enum StorageScope {
    /// `~/Library/Application Support/<bundleID>/<providerID>/` —
    /// history.json, activity-cache.json, pricing.json.
    public static func supportDirectory(bundleID: String, providerID: String) -> URL {
        base(.applicationSupportDirectory).appending(path: bundleID).appending(path: providerID)
    }

    /// `~/Library/Caches/<bundleID>/<providerID>/` — usage.json.
    public static func cachesDirectory(bundleID: String, providerID: String) -> URL {
        base(.cachesDirectory).appending(path: bundleID).appending(path: providerID)
    }

    /// "apiHourlyCeiling" → "claude.apiHourlyCeiling" — for defaults whose
    /// value is a property of one vendor (a learned endpoint budget), not
    /// an app preference.
    public static func scopedKey(_ key: String, providerID: String) -> String {
        "\(providerID).\(key)"
    }

    static func base(_ directory: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}

/// One-time move of the pre-registry singleton artifacts into the bundled
/// provider's scoped directories (v0.26.0). Runs before any store exists.
/// Copy → verify → delete, so a failure at any step leaves the original in
/// place and readable — history.json carries weeks of irreplaceable
/// forecast learning, and losing it silently would reset the weekly rhythm
/// and restart the "personalized forecast activates in N days" countdown.
public enum StorageMigration {
    static let versionKey = "storageScopeVersion"
    /// The meter ids the pre-scope panel persisted popover prefs under.
    static let legacyMeterIDs = ["0-session", "1-weekly_all", "2-weekly_scoped"]
    static let meterPrefPrefixes = ["meterPopoverSpan-", "meterSlidingFrame-"]

    /// The app's entry point: derives the standard bases and migrates into
    /// `providerID`'s scope.
    public static func standard(bundleID: String, providerID: String) {
        migrate(
            support: StorageScope.base(.applicationSupportDirectory).appending(path: bundleID),
            caches: StorageScope.base(.cachesDirectory).appending(path: bundleID),
            providerID: providerID)
    }

    /// Injectable form for tests. `defaults` carries the done-marker, the
    /// scoped ceiling key, and the per-meter popover prefs.
    public static func migrate(
        support: URL, caches: URL, providerID: String,
        defaults: UserDefaults = .standard
    ) {
        let version = defaults.integer(forKey: versionKey)
        guard version < 2 else { return }

        var allMoved = true
        if version < 1 {
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
        }

        // v2 (0.29.0): the model-color ledger became provider-scoped so
        // every harness's heaviest family wears its own vendor accent.
        moveKey(
            from: "modelColorLedger",
            to: StorageScope.scopedKey("modelColorLedger", providerID: providerID),
            defaults: defaults)

        // A failed file move leaves the marker unset so the next launch
        // retries — already-moved files have no source left and skip.
        if allMoved {
            defaults.set(2, forKey: versionKey)
        }
    }

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
