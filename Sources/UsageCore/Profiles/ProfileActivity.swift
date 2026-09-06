import Foundation

/// D9 (user-directed 2026-09-06): a profile with no session write in this
/// long is DORMANT — hidden from the bar and the strip, neither polled nor
/// scanned; only its FSEvents watcher stays up so the first write revives
/// it. "I've not been using Codex for months; there's no point showing it."
public enum Dormancy {
    public static let window: TimeInterval = 30 * 86400

    /// The newer of the last write and the enrolment stamp is the
    /// reference: a home enrolled today with a month-old last session was
    /// enrolled on purpose and gets the window before it is declared quiet.
    public static func isDormant(lastActivity: Date?, addedAt: Date?, now: Date) -> Bool {
        let reference = [lastActivity, addedAt].compactMap { $0 }.max()
        guard let reference else { return false }
        return now.timeIntervalSince(reference) > window
    }
}

/// What the focus rule needs to know about one profile.
public struct FocusCandidate: Sendable, Equatable {
    public let id: String
    public let order: Int
    /// Session files written inside the trailing activity window
    /// (`ProfileActivity.window`) — the volume that decides focus.
    public let recentActivity: Int
    public let lastActivity: Date?
    /// enabled ∧ !dormant — may hold focus at all.
    public let eligible: Bool
    /// Shown in the menu bar — preferred for automatic focus, since the
    /// focused profile's digits are what the bar expands.
    public let shown: Bool

    public init(
        id: String, order: Int, recentActivity: Int = 0, lastActivity: Date?, eligible: Bool, shown: Bool
    ) {
        self.id = id
        self.order = order
        self.recentActivity = recentActivity
        self.lastActivity = lastActivity
        self.eligible = eligible
        self.shown = shown
    }
}

/// Which profile the top level of the digest, the expanded menu bar cell
/// and the panel show by default. Focus FOLLOWS ACTIVITY (D9, amended
/// 2026-09-06): the person's pin wins while it is eligible; otherwise, shown
/// profiles ahead of hidden ones, the one with the MOST session writes over
/// the trailing fortnight, the newest write breaking ties, and the lowest
/// order when nothing has ever written. Volume over a long window rather
/// than the last write, because the last write follows whichever session
/// is typing right now — two concurrent sessions in different homes
/// flapped the bar between them — while a fortnight's count moves slowly
/// and names the account this Mac is really used for.
public enum FocusRule {
    public static func focused(_ candidates: [FocusCandidate], pin: String?) -> String? {
        let eligible = candidates.filter(\.eligible)
        if let pin, eligible.contains(where: { $0.id == pin }) { return pin }
        return eligible.sorted { a, b in
            if a.shown != b.shown { return a.shown }
            if a.recentActivity != b.recentActivity { return a.recentActivity > b.recentActivity }
            let aWrite = a.lastActivity ?? .distantPast
            let bWrite = b.lastActivity ?? .distantPast
            if aWrite != bWrite { return aWrite > bWrite }
            return a.order < b.order
        }.first?.id
    }
}

/// The mtime walk behind harness detection and the dormancy probe: over a
/// set of session directories, is anything there, how many files changed
/// since a cutoff, and when was the newest touched. Capped, because launch
/// and reprobe run it over `~/.claude/projects` trees with thousands of
/// transcripts.
public enum MTimeProbe {
    public struct Signal: Sendable, Equatable {
        public let present: Bool
        public let recentFiles: Int
        public let newest: Date?

        public init(present: Bool, recentFiles: Int, newest: Date?) {
            self.present = present
            self.recentFiles = recentFiles
            self.newest = newest
        }
    }

    /// `maxDepth` bounds descent below each directory (1 = its own files
    /// only); nil walks the whole tree, still under `cap` stats.
    public static func signal(
        directories: [URL], recentSince cutoff: Date, cap: Int = HarnessDetector.statCap,
        maxDepth: Int? = nil
    ) -> Signal {
        let manager = FileManager.default
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
                guard statted < cap else { break }
                if let maxDepth, enumerator.level >= maxDepth {
                    enumerator.skipDescendants()
                }
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
        return Signal(present: present, recentFiles: recent, newest: newest)
    }

    /// The modification date of one path, nil when absent.
    public static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// One reprobe's reading of a profile: who is signed in (the identity
/// record, read-only), when the agent last wrote a session there, and how
/// many session files it wrote inside the activity window.
public struct ProfileProbe: Sendable, Equatable {
    public let identity: AccountIdentity?
    public let lastActivityAt: Date?
    public let recentFiles: Int

    public init(identity: AccountIdentity?, lastActivityAt: Date?, recentFiles: Int = 0) {
        self.identity = identity
        self.lastActivityAt = lastActivityAt
        self.recentFiles = recentFiles
    }
}

public enum ProfileActivity {
    /// The focus rule's activity window — harness detection's, so "which
    /// account is this Mac mostly using" and "which harness is this Mac
    /// mostly using" are one story.
    public static let window: TimeInterval = HarnessDetector.window
    /// Stat budget for the window count. Harness detection sits on the
    /// launch path and stops at 2,000; the reprobe runs off-main every ten
    /// minutes and can afford a whole corpus, so this bound only keeps a
    /// runaway tree from turning the probe into a scan.
    public static let statCap = 10_000

    /// All three reads for one home, through the provider retargeted at
    /// it. `cacheDirectory` is the profile's own scoped directory — the
    /// scanner is only constructed here, never run, so nothing is written.
    public static func probe(
        provider: any UsageProvider, cacheDirectory: URL, now: Date
    ) -> ProfileProbe {
        let source = provider.makeLocalActivity(cacheDirectory: cacheDirectory)
        return ProfileProbe(
            identity: provider.accountIdentity?.currentIdentity(),
            lastActivityAt: source?.lastActivity(now: now),
            recentFiles: source?.recentActivity(since: now.addingTimeInterval(-window)) ?? 0)
    }
}
