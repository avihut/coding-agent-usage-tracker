import Foundation

/// M2's "deep verbs" dispatcher — `windows`/`history`/`prices`/`price` —
/// sibling to `DigestQuery`, not a case added to it: these verbs read
/// PAST what the live digest publishes (per-meter point histories, priced
/// catalogs) and `prices` must answer with no digest and no daemon running
/// at all (the bundled pricing floor), which `DigestQuery.run`'s contract
/// (a REQUIRED `digest: LiveState`) can't express. Shares `DigestQuery`'s
/// argument grammar (`parseArgs`, `ParsedArgs`, the exit-code constants,
/// `badQuery`/`ok`/`noMatch`) rather than duplicating it — the M2 flag
/// vocabulary (`--last`, `--all`, `--background`, `--no-background`) is
/// registered directly in `DigestQuery`'s shared `booleanFlags`/
/// `valueFlags`, so this file parses through the one grammar everybody
/// else uses instead of standing up a second one.
public enum DeepQuery {
    /// This dispatcher's own noun vocabulary — disjoint from
    /// `DigestQuery.nouns`; the CLI target checks both sets to route.
    public static let nouns: Set<String> = ["windows", "history", "prices", "price"]

    static let exitWrongProvider: Int32 = 11

    /// `--provider <id>` wins; else the registry's persisted pick unless
    /// it's "auto" (no explicit choice); else "claude". Factored out of
    /// `UsageCLI.runSessions`/`.runSyncDigest`, which had this exact
    /// three-way fallback duplicated verbatim — both now call this.
    public static func resolveProviderID(flag: String?) -> String {
        let stored = UserDefaults.standard.string(forKey: HarnessResolution.selectionKey)
        return flag ?? (stored == "auto" ? nil : stored) ?? "claude"
    }

    /// The app's own defaults domain — where the profile list lives. A bare
    /// CLI's `.standard` is its OWN domain (the process name's), so the
    /// suite is opened explicitly, exactly as usaged does; embedded in the
    /// app bundle, `.standard` already IS that domain and the suite call
    /// would return nil.
    static func appDefaults() -> UserDefaults {
        let bundleID = "com.avihu.ClaudeUsage"
        if Bundle.main.bundleIdentifier == bundleID { return .standard }
        return UserDefaults(suiteName: bundleID) ?? .standard
    }

    /// The enrolled profiles for a provider as the app and the daemon see
    /// them (`ProfileStore.resolved`: the implicit default synthesized),
    /// for a CLI run that must root a scan or a history read at one
    /// account's home and directory. Empty for an unknown provider.
    public static func storedProfiles(providerID: String, now: Date) -> [Profile] {
        guard let provider = HarnessResolution.standardProviders().first(where: { $0.id == providerID })
        else { return [] }
        return ProfileStore.resolved(ProfileStore.load(from: appDefaults()), provider: provider, now: now)
    }

    /// Every harness's accounts, in the build's standard order — what the
    /// selector matches a key, a name or a path against now that several
    /// harnesses are metered at once.
    public static func storedProfiles(now: Date) -> [Profile] {
        let stored = ProfileStore.load(from: appDefaults())
        return HarnessResolution.standardProviders().flatMap {
            ProfileStore.resolved(stored, provider: $0, now: now)
        }
    }

    /// The provider's home facts for the selector — its variable and its
    /// standard home. `.none` for an unknown provider.
    public static func storedHomes(providerID: String) -> ProfileSelector.Homes {
        HarnessResolution.standardProviders().first { $0.id == providerID }
            .map { ProfileSelector.Homes(provider: $0) } ?? .none
    }

    /// Every harness's home facts, standard order.
    public static func storedHomes() -> [ProfileSelector.Homes] {
        HarnessResolution.standardProviders().map { ProfileSelector.Homes(provider: $0) }
    }

    /// One profile's scoped support directory — where its history.json and
    /// window-ledger.json live (storage v3). `roots` is injectable so the
    /// resolution is testable without touching the real Application
    /// Support tree.
    public static func profileDirectory(
        providerID: String, profileID: String, roots: StorageScope.Roots = .standard
    ) -> URL {
        StorageScope.supportDirectory(
            bundleID: Bundle.main.bundleIdentifier ?? "com.avihu.ClaudeUsage", providerID: providerID,
            profileID: profileID, roots: roots)
    }

    /// `--last` accepts BOTH grammars the plan wrote for the deep list
    /// verbs: a bare integer is a row count (`windows week --last 8`), a
    /// suffixed duration is a time window (`history session --last 24h`).
    /// The grammars are disjoint (`parseDuration` requires a unit suffix,
    /// `Int` refuses one) and both list verbs honor both, so the same flag
    /// never means different things one noun apart.
    enum LastFilter {
        case count(Int)
        case duration(TimeInterval)
    }

    static func parseLast(_ text: String) -> LastFilter? {
        if let count = Int(text), count >= 0 { return .count(count) }
        if let duration = DigestQuery.parseDuration(text) { return .duration(duration) }
        return nil
    }

    /// `arguments` is argv AFTER the noun (the noun itself travels
    /// separately in `noun:`) — `DigestQuery.ParsedArgs.positionals[0]`
    /// below is therefore the verb's first SELECTOR, never the noun again.
    /// `digest` is optional on purpose: the caller loads live-state.json
    /// when present and passes nil when it's missing or stale-corrupt
    /// (never a fatal condition here) — a verb that genuinely needs the
    /// digest reports its own exit 13; `prices` never does. Verbs that
    /// want METER LABELS (a scoped model name, a tag) but were handed a
    /// nil digest degrade to raw-id matching instead of erroring.
    ///
    /// `profiles`/`homes` nil = read the app's store and the provider's
    /// facts (`storedProfiles`/`storedHomes`); tests inject both.
    public static func run(
        noun: String, arguments: [String], digest: LiveState?,
        environment: [String: String], now: Date,
        profiles: [Profile]? = nil, homes: ProfileSelector.Homes? = nil
    ) -> QueryOutput {
        run(
            noun: noun, arguments: arguments, digest: digest, environment: environment, now: now,
            profiles: profiles, homes: homes.map { [$0] })
    }

    public static func run(
        noun: String, arguments: [String], digest: LiveState?,
        environment: [String: String], now: Date,
        profiles: [Profile]?, homes: [ProfileSelector.Homes]?
    ) -> QueryOutput {
        let parsed = DigestQuery.parseArgs(arguments)
        if let error = parsed.error { return DigestQuery.badQuery(error) }
        if let rejection = DigestQuery.rejectInapplicableFlags(noun: noun, parsed: parsed) {
            return rejection
        }

        // WHICH ACCOUNT FIRST, then whether this verb can read its harness's
        // files: the account decides the harness now that several are metered
        // (`--account codex`, or a Codex account holding focus), and reading
        // one vendor's ledger under another's name would be a wrong answer,
        // not an empty one. `prices`/`price` select nothing and answer for
        // the harness named by `--provider`, else the focused one.
        let account: DigestQuery.Account
        switch DigestQuery.resolveAccount(
            noun: noun, parsed: parsed, environment: environment, digest: digest,
            profiles: profiles ?? storedProfiles(now: now),
            homes: homes ?? storedHomes())
        {
        case .failure(let output): return output
        case .success(let resolved): account = resolved
        }
        let providerID = parsed.flags["provider"] ?? account.providerID
        guard providerID == HarnessResolution.bundledProviderID else {
            // Mirrors the guard `UsageCLI.runSessions`/`.runSyncDigest`
            // already use for a provider this surface isn't wired for —
            // exit 11 is reserved for exactly this across the CLI. It comes
            // BEFORE the projection: which harness a verb can read is not a
            // question about whether that account's section landed yet.
            return QueryOutput(
                stdout: "",
                note: "deep query verbs are not wired for provider '\(providerID)' in the CLI yet",
                exitCode: exitWrongProvider)
        }
        let view: DigestQuery.ProfileView
        switch DigestQuery.projectAccount(account, digest: digest) {
        case .failure(let output): return output
        case .success(let projected): view = projected
        }
        let digest = view.digest ?? digest

        switch noun {
        case "windows":
            return windowsVerb(
                parsed: parsed, digest: digest, providerID: providerID, profileID: view.accountID,
                now: now)
        case "history":
            return historyVerb(
                parsed: parsed, digest: digest, providerID: providerID, profileID: view.accountID,
                now: now)
        case "prices", "price":
            // Unlike windows/history, these two nouns share ONE handler —
            // `noun` travels in so it can enforce the plural/singular arity
            // M1's `runModels`/`runModel` do (a bare noun can't tell them
            // apart from `parsed.positionals` alone).
            return pricesVerb(noun: noun, parsed: parsed, digest: digest, providerID: providerID, now: now)
        default:
            return DigestQuery.badQuery("unknown noun '\(noun)'")
        }
    }
}
