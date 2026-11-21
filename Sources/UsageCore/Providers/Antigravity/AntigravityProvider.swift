import Foundation

/// Google's Antigravity CLI (`agy`) behind the provider seam — the Google
/// harness since Gemini CLI's deprecation. No network destination of its
/// own and no credential: the app reads only local files and never touches
/// the CLI's sign-in.
///
/// Two sources:
/// - TOKENS from each conversation's `transcript.jsonl`
///   (`AntigravityActivitySource`).
/// - PLAN LIMITS from the CLI ITSELF (spec §10 amendment 2026-11-21,
///   second — "There shouldn't even be a path that requires extra work from
///   the user to start metering antigravity"): its documented print mode
///   `agy -p /quota --output-format json` reports every quota bucket without
///   an agent turn and without spending any. `quotaCommand` declares the
///   run; core's quota probe makes it, in the engine host only, at most
///   every 10 minutes while Antigravity is in use, and hands the reading to
///   `fetchRawUsage(accessToken:quota:)`. Nothing to set up.
public struct AntigravityProvider: UsageProvider {
    public let id = "antigravity"
    public let serviceName = "Google AI"
    public let agentName = "Antigravity CLI"
    public let links = ProviderLinks(
        planUpgrade: URL(string: "https://one.google.com/about/google-ai-plans"),
        usageSettings: nil)
    public let menuBarGlyph = "∩"
    /// Violet #A142F4 — clear of the other harnesses' accents and of the
    /// warning/critical colours (Antigravity's own brand colour could not be
    /// verified; user-chosen 2026-11-21).
    public let accent = ProviderAccent(red: 0.631, green: 0.259, blue: 0.957)
    /// Empty: the app contacts nothing for this provider. The CLI the quota
    /// probe runs talks to Google itself, under its own sign-in — declared
    /// by `quotaCommand`, never here (spec §10).
    public let networkDestinations: [String] = []
    public let credentials: CredentialChain
    let home: URL
    /// Where the CLI may be installed: the install script's documented
    /// default and Homebrew's `bin` (its cask's wrapper). NOT
    /// `~/.antigravity/antigravity/bin/agy` — the desktop app's editor
    /// launcher of the same name. Tests point it at a fixture.
    let agyCandidates: [URL]

    public init(home: URL? = nil, userHome: URL? = nil, agyCandidates: [URL]? = nil) {
        let userHome = userHome ?? FileManager.default.homeDirectoryForCurrentUser
        self.home = home ?? userHome.appending(path: ".gemini/antigravity-cli")
        self.agyCandidates = agyCandidates ?? [
            userHome.appending(path: ".local/bin/agy"),
            URL(fileURLWithPath: "/opt/homebrew/bin/agy"),
            URL(fileURLWithPath: "/usr/local/bin/agy"),
        ]
        self.credentials = CredentialChain(sources: [
            StaticCredentialSource(name: "local Antigravity CLI files")
        ])
    }

    /// No reading to hand over: the plain fetch is the quota-aware one with
    /// nothing read yet.
    public func fetchRawUsage(accessToken: String) async throws -> Data {
        try await fetchRawUsage(accessToken: accessToken, quota: nil)
    }

    /// Ignores the token. The probe's reading when one exists; with none
    /// but conversations on disk, an honest "no limits read yet" (zero
    /// meters, fresh); with neither, `noLocalData`.
    public func fetchRawUsage(accessToken: String, quota: AgentQuotaReading?) async throws -> Data {
        let tree = AntigravityHome(root: home)
        guard quota != nil || tree.hasTranscripts() else {
            throw UsageClientError.noLocalData
        }
        return try AntigravityQuota.encodePayload(AntigravityUsagePayload(
            fetchedAt: Date(), reading: quota,
            conversationWrittenAt: tree.newestConversationWrite()))
    }

    /// The CLI's own print mode, exactly as the §10 amendment states it.
    /// `--log-file /dev/null` and the documented
    /// update switch keep a run from writing a log or checking for an update
    /// (measured: what's left is three mtime stamps).
    public var quotaCommand: AgentQuotaCommand? {
        AgentQuotaCommand(
            executableCandidates: agyCandidates,
            versionArguments: ["--version"],
            acceptsVersion: { AntigravityQuota.acceptsVersion($0) },
            arguments: ["-p", "/quota", "--output-format", "json", "--log-file", "/dev/null"],
            environment: ["AGY_CLI_DISABLE_AUTO_UPDATE": "true"],
            timeout: 30,
            floor: 600,
            reduce: { status, stdout, stderr, now in
                AntigravityQuota.reduce(exitStatus: status, stdout: stdout, stderr: stderr, now: now)
            },
            privacyLines: [
                "Plan limits: runs `agy -p /quota` (the CLI's own print mode) at most every 10 min "
                    + "while Antigravity is in use, never an agent turn",
                "The CLI asks Google with its own sign-in; this app connects nowhere and keeps "
                    + "only each limit's percent and reset",
                "Each run stamps the CLI's own files in ~/.gemini/antigravity-cli "
                    + "(onboarding.json, conversation_summaries.db, crashes/)",
            ])
    }

    /// The rates table lists what this harness has run, plus Gemini's own
    /// models — not the whole Anthropic and OpenAI catalogues its feed
    /// slices reach into to price the pool's models.
    public func listsUnseenRate(_ modelID: String) -> Bool {
        ModelCatalog.gemini.claims(modelID)
    }

    public func snapshot(
        fromRawUsage body: Data, fetchedAt: Date, plan: PlanInfo?,
        thresholds: Thresholds
    ) throws -> Snapshot {
        try AntigravityQuota.snapshot(fromPayload: body, thresholds: thresholds)
    }

    public func makeLocalActivity(cacheDirectory: URL) -> (any LocalActivitySource)? {
        AntigravityActivitySource(home: home, cacheDirectory: cacheDirectory)
    }

    /// No retention setting to mirror; nothing is ever written there.
    public var agentSettings: (any AgentSettingsStore)? { nil }

    /// Antigravity's own models are Gemini ids (`gemini-4-neon` once the
    /// effort is stripped), and its Claude + GPT pool runs other vendors'
    /// models — each id is read in its own vendor's grammar, Gemini's first
    /// (the digest and the color ledger ask the provider's catalog
    /// directly, never the app's union).
    public var modelCatalog: ModelCatalog { .union([.gemini, .claude, .codex]) }

    /// No bundled floor: rates arrive with the feed.
    public var bundledRates: PricingTable {
        PricingTable(rates: [:], fetchedAt: .distantPast, source: .bundled)
    }

    /// Gemini's slice plus the Claude and OpenAI ones, for the models its
    /// third-party pool runs.
    public var pricingSelector: PricingFeedSelector {
        PricingFeedSelector(
            includes: { key, provider in
                PricingFeedSelector.gemini.includes(key, provider)
                    || PricingFeedSelector.claude.includes(key, provider)
                    || PricingFeedSelector.openAI.includes(key, provider)
            },
            normalizeKey: PricingFeedSelector.gemini.normalizeKey)
    }
}
