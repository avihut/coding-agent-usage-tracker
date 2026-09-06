import Foundation

/// Which profile a `usage-cli` invocation answers for (multi-account
/// metering phase 1, user-directed: a status line rendered under
/// `CLAUDE_CONFIG_DIR` must never show the OTHER account's limits — so the
/// environment selects, and a selection nobody meters refuses rather than
/// falling back to some account that IS metered). Pure: the CLI hands in the
/// flag, the environment, the digest, the stored profile list and the
/// provider's home facts; the answer is an id or a refusal.
///
/// Precedence: `--account` > the provider's home variable in the
/// environment > the digest's focused profile > `default`.
public enum ProfileSelector {
    /// The provider's home facts, without naming the vendor here.
    public struct Homes: Sendable, Equatable {
        /// The variable the agent reads its home from (`CLAUDE_CONFIG_DIR`).
        /// Nil = the provider has one fixed home, and the environment
        /// selects nothing.
        public let environmentVariable: String?
        /// The provider's standard home — the path that maps to `default`.
        public let standard: URL?
        /// Expands a leading "~" in a flag value or the variable.
        public let userHome: URL

        public init(
            environmentVariable: String?, standard: URL?,
            userHome: URL = FileManager.default.homeDirectoryForCurrentUser
        ) {
            self.environmentVariable = environmentVariable
            self.standard = standard
            self.userHome = userHome
        }

        public init(provider: any UsageProvider, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
            self.init(
                environmentVariable: provider.homeEnvironmentVariable, standard: provider.homeDirectory,
                userHome: userHome)
        }

        /// A provider with one fixed home.
        public static let none = Homes(environmentVariable: nil, standard: nil)
    }

    public enum Source: String, Sendable, Equatable {
        case flag, environment, focus, `default`
    }

    public struct Selection: Sendable, Equatable {
        public let id: String
        public let source: Source

        public init(id: String, source: Source) {
            self.id = id
            self.source = source
        }
    }

    /// The refusal: what was asked for (the flag's value, or
    /// `VARIABLE=value`) and every id the writer and the store know, the
    /// digest's order first.
    public struct Unknown: Error, Sendable, Equatable {
        public let selector: String
        public let known: [String]

        public var message: String {
            "no such account: \(selector) — accounts: \(known.joined(separator: ", "))"
        }
    }

    public static func resolve(
        flag: String?, environment: [String: String], digest: LiveState?,
        profiles: [Profile], homes: Homes
    ) -> Result<Selection, Unknown> {
        let known = knownIDs(digest: digest, profiles: profiles)
        if let flag {
            let wanted = flag.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = matchName(wanted, digest: digest, profiles: profiles, known: known)
                ?? matchPath(wanted, digest: digest, profiles: profiles, homes: homes, known: known) {
                return .success(Selection(id: id, source: .flag))
            }
            return .failure(Unknown(selector: wanted, known: known))
        }
        if let variable = homes.environmentVariable, let raw = environment[variable] {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                guard let id = matchPath(value, digest: digest, profiles: profiles, homes: homes, known: known)
                else { return .failure(Unknown(selector: "\(variable)=\(value)", known: known)) }
                return .success(Selection(id: id, source: .environment))
            }
        }
        if let focused = digest?.focusedProfile {
            return .success(Selection(id: focused, source: .focus))
        }
        return .success(Selection(id: Profile.defaultID, source: .default))
    }

    /// The digest's ids (a pre-profile digest exposes `default` alone),
    /// then any enrolled record the digest has not published yet.
    static func knownIDs(digest: LiveState?, profiles: [Profile]) -> [String] {
        var known = digest?.profileIDs ?? [Profile.defaultID]
        for profile in profiles where profile.isEnrolled && !known.contains(profile.id) {
            known.append(profile.id)
        }
        return known
    }

    /// An id, a nickname, or the digest's label — case-insensitively.
    private static func matchName(
        _ wanted: String, digest: LiveState?, profiles: [Profile], known: [String]
    ) -> String? {
        guard !wanted.isEmpty else { return nil }
        let folded = wanted.lowercased()
        if let id = known.first(where: { $0.lowercased() == folded }) { return id }
        let sections = digest?.profiles ?? []
        if let section = sections.first(where: {
            $0.nickname?.lowercased() == folded || $0.label.lowercased() == folded
        }), known.contains(section.id) {
            return section.id
        }
        if let profile = profiles.first(where: {
            $0.isEnrolled
                && $0.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == folded
        }), known.contains(profile.id) {
            return profile.id
        }
        return nil
    }

    /// A home path: a record's home, the digest's display path, or — for a
    /// home known by id alone — the hash the path derives to.
    private static func matchPath(
        _ wanted: String, digest: LiveState?, profiles: [Profile], homes: Homes, known: [String]
    ) -> String? {
        guard let url = expand(wanted, userHome: homes.userHome) else { return nil }
        let path = PathDisplay.trimmed(url.path)
        if let profile = profiles.first(where: {
            $0.isEnrolled && $0.home.map { PathDisplay.trimmed($0.path) } == path
        }), known.contains(profile.id) {
            return profile.id
        }
        let display = PathDisplay.abbreviated(url, home: homes.userHome)
        if let section = (digest?.profiles ?? []).first(where: { $0.homeDisplayPath == display }),
           known.contains(section.id) {
            return section.id
        }
        let derived = homes.standard.map { ProfileID.forHome(url, standard: $0) }
            ?? ProfileID.derive(homePath: url.path)
        return known.contains(derived) ? derived : nil
    }

    /// "~/.claude-personal" and absolute paths; a bare word is a name, not
    /// a path. Relative paths resolve the way the agent resolves its own
    /// variable — against the working directory.
    private static func expand(_ text: String, userHome: URL) -> URL? {
        guard !text.isEmpty else { return nil }
        if text == "~" { return userHome }
        if text.hasPrefix("~/") { return userHome.appending(path: String(text.dropFirst(2))) }
        guard text.hasPrefix("/") || text.hasPrefix("./") || text.hasPrefix("../") else { return nil }
        return URL(fileURLWithPath: text)
    }
}
