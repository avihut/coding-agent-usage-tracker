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
    /// One harness's home facts, without naming the vendor here.
    public struct Homes: Sendable, Equatable {
        /// The variable the agent reads its home from (`CLAUDE_CONFIG_DIR`).
        /// Nil = the provider has one fixed home, and the environment
        /// selects nothing.
        public let environmentVariable: String?
        /// The provider's standard home — the path that maps to `default`.
        public let standard: URL?
        /// Expands a leading "~" in a flag value or the variable.
        public let userHome: URL
        /// Which harness these facts belong to — what turns a matched path
        /// into a `ProfileKey` once several harnesses are metered.
        public let providerID: String

        public init(
            environmentVariable: String?, standard: URL?,
            userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
            providerID: String = HarnessResolution.bundledProviderID
        ) {
            self.environmentVariable = environmentVariable
            self.standard = standard
            self.userHome = userHome
            self.providerID = providerID
        }

        public init(provider: any UsageProvider, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
            self.init(
                environmentVariable: provider.homeEnvironmentVariable, standard: provider.homeDirectory,
                userHome: userHome, providerID: provider.id)
        }

        /// A provider with one fixed home.
        public static let none = Homes(environmentVariable: nil, standard: nil)
    }

    public enum Source: String, Sendable, Equatable {
        /// `--provider <id>`: that harness answers, with its focused account.
        case flag, provider, environment, focus, `default`
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
    /// digest's order first. `kind` decides the exit code: a selector nobody
    /// meters is "no match" (20), while an AMBIGUOUS name and a contradicted
    /// `--provider` are bad queries (19) — the person asked something the
    /// grammar can't answer, not for an account that isn't there.
    public struct Unknown: Error, Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case noMatch, ambiguous, contradiction
        }

        public let selector: String
        public let known: [String]
        public let kind: Kind
        /// The keys an ambiguous name matched, for the message.
        public let matches: [String]

        public init(
            selector: String, known: [String], kind: Kind = .noMatch, matches: [String] = []
        ) {
            self.selector = selector
            self.known = known
            self.kind = kind
            self.matches = matches
        }

        public var message: String {
            switch kind {
            case .noMatch:
                "no such account: \(selector) — accounts: \(known.joined(separator: ", "))"
            case .ambiguous:
                "account '\(selector)' names more than one harness's account "
                    + "(\(matches.joined(separator: ", "))) — use the id, or --provider"
            case .contradiction:
                "--account \(selector) and --provider \(matches.first ?? "") name different harnesses"
            }
        }
    }

    /// One harness — the way every caller selected before several were
    /// metered at once.
    public static func resolve(
        flag: String?, environment: [String: String], digest: LiveState?,
        profiles: [Profile], homes: Homes
    ) -> Result<Selection, Unknown> {
        resolve(
            flag: flag, provider: nil, environment: environment, digest: digest,
            profiles: profiles, homes: [homes])
    }

    /// Across every metered harness. Precedence: `--account` > `--provider` >
    /// a harness's home variable in the environment > the digest's focus >
    /// the bundled harness's standard account. A name that matches accounts
    /// in two harnesses is refused rather than guessed; ids always win over
    /// names, so a key is never ambiguous.
    public static func resolve(
        flag: String?, provider providerFlag: String?, environment: [String: String],
        digest: LiveState?, profiles: [Profile], homes: [Homes]
    ) -> Result<Selection, Unknown> {
        let known = knownIDs(digest: digest, profiles: profiles)
        let wantedProvider = providerFlag?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let flag {
            let wanted = flag.trimmingCharacters(in: .whitespacesAndNewlines)
            let sections = digest?.profiles ?? []
            var outcome = matchSelector(
                wanted, sections: sections, profiles: profiles, homes: homes, known: known)
            // A name that means an account in two harnesses is answerable
            // once `--provider` says which — the refusal's own advice.
            if case .failure(let unknown) = outcome, unknown.kind == .ambiguous,
               let wantedProvider, !wantedProvider.isEmpty {
                outcome = matchSelector(
                    wanted, sections: sections.filter { $0.providerID == wantedProvider },
                    profiles: profiles.filter { $0.providerID == wantedProvider },
                    homes: homes.filter { $0.providerID == wantedProvider },
                    known: known.filter {
                        harness(of: $0, digest: digest, profiles: profiles) == wantedProvider
                    })
            }
            let matched: String
            switch outcome {
            case .failure(let unknown): return .failure(unknown)
            case .success(let id): matched = id
            }
            if let wantedProvider, !wantedProvider.isEmpty,
               harness(of: matched, digest: digest, profiles: profiles) != wantedProvider {
                return .failure(Unknown(
                    selector: wanted, known: known, kind: .contradiction, matches: [wantedProvider]))
            }
            return .success(Selection(id: matched, source: .flag))
        }
        // `--provider` narrows when that harness HAS a metered account; an
        // id nobody meters falls through to the ordinary precedence, so the
        // verb's own provider gate is what speaks about it (exit 11) rather
        // than the selector inventing a missing account.
        if let wantedProvider, !wantedProvider.isEmpty,
           let id = harnessAccount(wantedProvider, digest: digest, profiles: profiles, known: known) {
            return .success(Selection(id: id, source: .provider))
        }
        // A home variable in the environment selects inside ITS harness. Set
        // but matching nothing metered is a refusal, never a fallback: a
        // status line rendered under one config dir must not report another
        // account's limits.
        for home in homes {
            guard let variable = home.environmentVariable, let raw = environment[variable] else {
                continue
            }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard let id = matchPath(
                value, sections: digest?.profiles ?? [], profiles: profiles, homes: home,
                known: known)
            else { return .failure(Unknown(selector: "\(variable)=\(value)", known: known)) }
            return .success(Selection(id: id, source: .environment))
        }
        if let focused = digest?.focusedProfile {
            return .success(Selection(id: focused, source: .focus))
        }
        return .success(Selection(id: Profile.defaultID, source: .default))
    }

    /// An id, a name, or a path — across the given harnesses, ids first.
    private static func matchSelector(
        _ wanted: String, sections: [ProfileState], profiles: [Profile], homes: [Homes],
        known: [String]
    ) -> Result<String, Unknown> {
        guard !wanted.isEmpty else {
            return .failure(Unknown(selector: wanted, known: known))
        }
        let folded = wanted.lowercased()
        if let id = known.first(where: { $0.lowercased() == folded }) { return .success(id) }
        let named = namedMatches(folded, sections: sections, profiles: profiles, known: known)
        if named.count > 1 {
            return .failure(Unknown(
                selector: wanted, known: known, kind: .ambiguous, matches: named))
        }
        if let id = named.first { return .success(id) }
        let paths = homes.compactMap {
            matchPath(wanted, sections: sections, profiles: profiles, homes: $0, known: known)
        }
        if Set(paths).count > 1 {
            return .failure(Unknown(
                selector: wanted, known: known, kind: .ambiguous, matches: paths))
        }
        if let id = paths.first { return .success(id) }
        return .failure(Unknown(selector: wanted, known: known))
    }

    /// Every account whose nickname or label is this name, in the digest's
    /// order then the store's.
    private static func namedMatches(
        _ folded: String, sections: [ProfileState], profiles: [Profile], known: [String]
    ) -> [String] {
        var matches: [String] = []
        for section in sections
        where section.nickname?.lowercased() == folded || section.label.lowercased() == folded {
            if known.contains(section.id), !matches.contains(section.id) { matches.append(section.id) }
        }
        for profile in profiles
        where profile.isEnrolled
            && profile.nickname?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == folded
        {
            if known.contains(profile.key), !matches.contains(profile.key) {
                matches.append(profile.key)
            }
        }
        return matches
    }

    /// Which harness an account key belongs to.
    static func harness(of key: String, digest: LiveState?, profiles: [Profile]) -> String {
        if let section = (digest?.profiles ?? []).first(where: { $0.id == key }) {
            return section.providerID
        }
        if let profile = profiles.first(where: { $0.key == key }) { return profile.providerID }
        return HarnessResolution.bundledProviderID
    }

    /// The account `--provider <id>` means: the focused one when it belongs
    /// to that harness, else its first published account, else its standard
    /// account when the store knows it.
    private static func harnessAccount(
        _ providerID: String, digest: LiveState?, profiles: [Profile], known: [String]
    ) -> String? {
        if let focused = digest?.focusedProfile,
           harness(of: focused, digest: digest, profiles: profiles) == providerID {
            return focused
        }
        if let section = (digest?.profiles ?? []).first(where: { $0.providerID == providerID }) {
            return section.id
        }
        if let profile = profiles.first(where: { $0.providerID == providerID && $0.isEnrolled }) {
            return known.contains(profile.key) ? profile.key : nil
        }
        return nil
    }

    /// The keys the digest knows (a pre-profile digest exposes `default`
    /// alone), then any enrolled record the digest has not published yet.
    static func knownIDs(digest: LiveState?, profiles: [Profile]) -> [String] {
        var known = digest?.profileIDs ?? [Profile.defaultID]
        for profile in profiles where profile.isEnrolled && !known.contains(profile.key) {
            known.append(profile.key)
        }
        return known
    }

    /// A home path inside ONE harness: a record's home, the digest's display
    /// path, or — for a home known by id alone — the key the path derives to.
    private static func matchPath(
        _ wanted: String, sections: [ProfileState], profiles: [Profile], homes: Homes,
        known: [String]
    ) -> String? {
        guard let url = expand(wanted, userHome: homes.userHome) else { return nil }
        let path = PathDisplay.trimmed(url.path)
        if let profile = profiles.first(where: {
            $0.isEnrolled && $0.providerID == homes.providerID
                && $0.home.map { PathDisplay.trimmed($0.path) } == path
        }), known.contains(profile.key) {
            return profile.key
        }
        let display = PathDisplay.abbreviated(url, home: homes.userHome)
        if let section = sections.first(where: {
            $0.homeDisplayPath == display && $0.providerID == homes.providerID
        }), known.contains(section.id) {
            return section.id
        }
        let derived = homes.standard.map { ProfileID.forHome(url, standard: $0) }
            ?? ProfileID.derive(homePath: url.path)
        let key = ProfileKey.make(providerID: homes.providerID, profileID: derived)
        return known.contains(key) ? key : nil
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
