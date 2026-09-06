import Foundation

/// One Claude Code configuration directory — `~/.claude`, or whatever a
/// `CLAUDE_CONFIG_DIR` names — and every path that hangs off it. The ONE
/// place `~/.claude` is spelled: the provider, the credential chain, the
/// identity source, the scanners, and the settings writer all derive their
/// paths from a home, so a second home (multi-account metering, spec §10
/// amendment 2026-09-06) is the same code reading another directory.
///
/// Two asymmetries of Claude Code's own layout, reproduced here:
/// - the identity record (`.claude.json`) sits BESIDE the standard home
///   (`~/.claude.json`) but INSIDE a custom one (`<home>/.claude.json`);
/// - the Keychain item is `Claude Code-credentials` for the standard home
///   and `Claude Code-credentials-<sha256(path)[0..<8]>` for a custom one.
public struct ClaudeHome: Sendable, Equatable {
    /// Standardized (`..`/`.` folded, trailing slash dropped), symlinks
    /// untouched — the hash must see the path as Claude Code did.
    public let directory: URL
    /// The user home "standard" and "~" are judged against; injectable so
    /// tests can build homes under a temp root.
    public let userHome: URL

    public init(directory: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.directory = URL(filePath: PathDisplay.trimmed(directory.standardizedFileURL.path))
        self.userHome = userHome
    }

    /// `~/.claude` — the home every install has, the `default` profile.
    public static var standard: ClaudeHome {
        standard(userHome: FileManager.default.homeDirectoryForCurrentUser)
    }

    public static func standard(userHome: URL) -> ClaudeHome {
        ClaudeHome(directory: userHome.appending(path: ".claude"), userHome: userHome)
    }

    public var isStandard: Bool {
        directory.path == Self.standard(userHome: userHome).directory.path
    }

    /// `default` for the standard home, else Claude Code's Keychain suffix.
    public var profileID: String {
        isStandard ? ProfileID.standard : ProfileID.derive(homePath: directory.path)
    }

    /// The generic-password service name Claude Code stores this home's
    /// OAuth credentials under.
    public var keychainService: String {
        isStandard ? "Claude Code-credentials" : "Claude Code-credentials-\(profileID)"
    }

    /// The `oauthAccount` record — beside the standard home, inside a
    /// custom one.
    public var identityFileURL: URL {
        isStandard
            ? userHome.appending(path: ".claude.json")
            : directory.appending(path: ".claude.json")
    }

    /// The non-Keychain credential file some setups use. Read-only, access
    /// token only (spec §5/§10).
    public var credentialsFileURL: URL { directory.appending(path: ".credentials.json") }
    /// Transcripts: `<home>/projects/**/*.jsonl`.
    public var projectsDirectory: URL { directory.appending(path: "projects") }
    /// Prompt history, which outlives transcript cleanup.
    public var promptHistoryURL: URL { directory.appending(path: "history.jsonl") }
    /// The one file this app ever writes inside a home (`cleanupPeriodDays`).
    public var settingsFileURL: URL { directory.appending(path: "settings.json") }

    /// "~/.claude-personal".
    public var displayPath: String { PathDisplay.abbreviated(directory, home: userHome) }

    /// Tilde form of any path, judged against this home's user home.
    public func displayPath(of url: URL) -> String {
        PathDisplay.abbreviated(url, home: userHome)
    }

    /// Whether the directory carries the traces of a home Claude Code has
    /// actually RUN in: a projects tree, a prompt history, or (custom homes
    /// only — the standard one keeps it outside) an identity record. A
    /// directory holding nothing but settings — `~/.claude-squad`, tool
    /// configs that borrow the prefix — is not a home. Read-only stats.
    public var looksLikeHome: Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }
        if manager.fileExists(atPath: projectsDirectory.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return true
        }
        if manager.fileExists(atPath: promptHistoryURL.path) { return true }
        return !isStandard && manager.fileExists(atPath: identityFileURL.path)
    }

    /// Every `.claude*` DIRECTORY beside the standard home that looks like
    /// a home — never the standard home itself, never the `.claude.json*`
    /// FILES that sit among them. Sorted by path so offers are stable.
    /// One directory listing plus per-candidate stats; nothing inside a
    /// candidate is read.
    public static func discoverSiblings(of standard: ClaudeHome) -> [ClaudeHome] {
        let parent = standard.directory.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasPrefix(".claude") }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { ClaudeHome(directory: $0, userHome: standard.userHome) }
            .filter { !$0.isStandard && $0.looksLikeHome }
            .sorted { $0.directory.path < $1.directory.path }
    }
}

extension CredentialChain {
    /// File first, Keychain as fallback — per spec §5 — for ONE home: its
    /// own `.credentials.json` and its own Keychain item, read through the
    /// same promptless `/usr/bin/security` path as the standard home's.
    public static func standard(for home: ClaudeHome) -> CredentialChain {
        CredentialChain(sources: [
            FileCredentialSource(fileURL: home.credentialsFileURL),
            KeychainCredentialSource(service: home.keychainService),
        ])
    }
}
