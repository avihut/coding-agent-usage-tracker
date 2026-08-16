import Foundation

/// One harness's local footprint: is it installed here, and how recently
/// and heavily has it actually been used.
public struct HarnessSignal: Sendable, Equatable {
    public let id: String
    /// Any of its session directories exist on this machine.
    public let present: Bool
    /// Session files modified inside the detection window.
    public let recentFiles: Int
    /// The newest session file's mtime, regardless of the window.
    public let newestActivity: Date?

    public init(id: String, present: Bool, recentFiles: Int, newestActivity: Date?) {
        self.id = id
        self.present = present
        self.recentFiles = recentFiles
        self.newestActivity = newestActivity
    }
}

/// Which locally installed harness is actually in use. Scores *session
/// artifacts only* — transcript/rollout files under each provider's watch
/// directories. State databases and config files get touched by background
/// daemons long after real use stops (observed: Codex sqlite files stamped
/// months after its last session), so directory or state mtimes lie;
/// session-file mtimes don't.
public enum HarnessDetector {
    /// Session files newer than this count toward the score.
    public static let window: TimeInterval = 14 * 86400
    /// Upper bound on files statted per candidate — keeps launch-time
    /// detection flat even under ~/.claude/projects trees with tens of
    /// thousands of transcripts.
    public static let statCap = 2000

    /// Signals ranked most-active first: presence, then recent-file count,
    /// then newest activity, then the given order (the app lists its
    /// bundled default first, so all-quiet resolves predictably).
    public static func rank(
        candidates: [(id: String, directories: [URL])], now: Date = Date()
    ) -> [HarnessSignal] {
        let signals = candidates.map { measure(id: $0.id, directories: $0.directories, now: now) }
        let order = Dictionary(
            uniqueKeysWithValues: signals.enumerated().map { ($0.element.id, $0.offset) })
        return signals.sorted { a, b in
            if a.present != b.present { return a.present }
            if a.recentFiles != b.recentFiles { return a.recentFiles > b.recentFiles }
            let aNewest = a.newestActivity ?? .distantPast
            let bNewest = b.newestActivity ?? .distantPast
            if aNewest != bNewest { return aNewest > bNewest }
            return (order[a.id] ?? .max) < (order[b.id] ?? .max)
        }
    }

    /// The winner: the top-ranked present harness, nil when none exists.
    public static func activeID(in ranked: [HarnessSignal]) -> String? {
        ranked.first(where: \.present)?.id
    }

    private static func measure(id: String, directories: [URL], now: Date) -> HarnessSignal {
        let manager = FileManager.default
        let cutoff = now.addingTimeInterval(-window)
        var present = false
        var recent = 0
        var newest: Date?
        var statted = 0

        for directory in directories {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            present = true
            guard let enumerator = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator {
                guard statted < statCap else { break }
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                    values.isRegularFile == true
                else { continue }
                statted += 1
                guard let modified = values.contentModificationDate else { continue }
                if newest.map({ modified > $0 }) ?? true { newest = modified }
                if modified >= cutoff { recent += 1 }
            }
        }
        return HarnessSignal(
            id: id, present: present, recentFiles: recent, newestActivity: newest)
    }
}

/// The shared provider-resolution rules: the app's registry and `usaged`
/// must pick the SAME harness from the same persisted selection and the
/// same detection signals, or a host handover would silently switch
/// vendors. Both call here; neither carries a private copy.
public enum HarnessResolution {
    /// "auto" or a provider id — the persisted Metering choice's key.
    public static let selectionKey = "activeProviderID"
    public static let automatic = "auto"

    /// Every provider this build ships, bundled default first — the
    /// tie-break order when detection sees an all-quiet machine.
    public static func standardProviders() -> [any UsageProvider] {
        [ClaudeProvider(), CodexProvider(), GeminiProvider()]
    }

    /// A manual choice must exist and be present on this machine; anything
    /// else falls back to detection, and an empty machine falls back to
    /// the bundled default.
    public static func resolve(
        selection: String, providers: [any UsageProvider], signals: [HarnessSignal]
    ) -> String {
        if selection != automatic,
           providers.contains(where: { $0.id == selection }),
           signals.first(where: { $0.id == selection })?.present == true {
            return selection
        }
        return HarnessDetector.activeID(in: signals) ?? providers[0].id
    }

    /// Detection scores each provider's session artifacts — the same trees
    /// the FSEvents watcher observes.
    public static func candidates(
        providers: [any UsageProvider], bundleID: String
    ) -> [(id: String, directories: [URL])] {
        providers.map { provider in
            let support = StorageScope.supportDirectory(
                bundleID: bundleID, providerID: provider.id)
            let directories =
                provider.makeLocalActivity(cacheDirectory: support)?.watchDirectories ?? []
            return (provider.id, directories)
        }
    }
}
