import Foundation

/// Which harnesses are on this machine (multi-harness metering, v0.101.0 —
/// user-decided: "detected" means present on disk). A harness is PRESENT
/// when any of its session directories exists — one `stat` per directory,
/// never a walk, so every reprobe can afford it — or when the person
/// enrolled an extra home for it. Whether it is actually USED is dormancy's
/// question, per account, not this one's.
///
/// The host LATCHES the answer for the life of its process: a harness
/// installed mid-run joins on the next reprobe, and a folder that vanishes
/// never shrinks the list under the person's eyes.
public enum HarnessPresence {
    public static func probe(
        providers: [any UsageProvider], stored: [Profile], bundleID: String,
        roots: StorageScope.Roots = .standard
    ) -> Set<String> {
        var present: Set<String> = []
        for provider in providers {
            let enrolledExtra = stored.contains {
                $0.providerID == provider.id && !$0.isDefault && $0.isEnrolled
            }
            if enrolledExtra || hasSessionDirectory(provider, bundleID: bundleID, roots: roots) {
                present.insert(provider.id)
            }
        }
        return present
    }

    /// The same directories harness detection scores and the FSEvents
    /// watcher observes. The source is only constructed, never run, so
    /// nothing is read past a `stat` and nothing is written.
    static func hasSessionDirectory(
        _ provider: any UsageProvider, bundleID: String, roots: StorageScope.Roots
    ) -> Bool {
        let support = StorageScope.supportDirectory(
            bundleID: bundleID, providerID: provider.id, profileID: StorageScope.defaultProfileID,
            roots: roots)
        let directories = provider.makeLocalActivity(cacheDirectory: support)?.watchDirectories ?? []
        return directories.contains { directory in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }
}
