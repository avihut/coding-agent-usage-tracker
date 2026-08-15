import Foundation

/// Anthropic's Claude behind the provider seam: plan usage from the OAuth
/// endpoint the Claude app's own Usage screen calls, credentials from Claude
/// Code's sign-in, activity from its local transcripts and prompt history.
/// Every Claude-specific fact the app relies on — hosts, paths, id grammar,
/// limit vocabulary — lives here or in the adapters this type wires up
/// (`UsageClient`, `MeterBuilder`, the scanners).
public struct ClaudeProvider: UsageProvider {
    public let id = "claude"
    public let serviceName = "Claude"
    public let agentName = "Claude Code"
    public let links = ProviderLinks(
        planUpgrade: URL(string: "https://claude.ai/upgrade"),
        usageSettings: URL(string: "https://claude.ai/settings/usage"))
    public let menuBarGlyph = "✳︎"
    /// Anthropic terracotta #D97757.
    public let accent = ProviderAccent(red: 0.851, green: 0.467, blue: 0.341)
    public let networkDestinations = ["api.anthropic.com"]
    public let credentials: CredentialChain
    private let client: UsageClient

    public init(credentials: CredentialChain = .standard, client: UsageClient = UsageClient()) {
        self.credentials = credentials
        self.client = client
    }

    public func fetchRawUsage(accessToken: String) async throws -> Data {
        try await client.fetchRawUsage(accessToken: accessToken)
    }

    public func snapshot(
        fromRawUsage body: Data, fetchedAt: Date, plan: PlanInfo?,
        thresholds: Thresholds
    ) throws -> Snapshot {
        let response = try UsageResponse.decode(from: body)
        return MeterBuilder.snapshot(
            from: response, fetchedAt: fetchedAt, plan: plan, thresholds: thresholds)
    }

    public func makeLocalActivity(cacheDirectory: URL) -> (any LocalActivitySource)? {
        ClaudeActivitySource(cacheDirectory: cacheDirectory)
    }

    public var agentSettings: (any AgentSettingsStore)? { ClaudeCodeSettings.standard() }

    public var modelCatalog: ModelCatalog { .claude }

    public var bundledRates: PricingTable { .bundled }

    public var pricingSelector: PricingFeedSelector { .claude }
}

/// Claude Code's on-disk traces: JSONL transcripts under ~/.claude/projects
/// (tokens per model) and the prompt-history log that outlives transcript
/// cleanup. Strictly read-only (spec §10).
public struct ClaudeActivitySource: LocalActivitySource {
    private let transcripts: TranscriptScanner
    private let prompts: PromptHistoryScanner
    private let root: URL

    public init(cacheDirectory: URL) {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects")
        self.transcripts = TranscriptScanner(root: root, cacheDirectory: cacheDirectory)
        self.prompts = .standard()
        self.root = root
    }

    public var watchDirectories: [URL] { [root] }
    public var displayPath: String { "~/.claude/projects" }

    public func scanTranscripts(now: Date) -> TranscriptScan {
        transcripts.scan(now: now)
    }

    public func scanPromptDays() -> [Date: Int] {
        prompts.scan()
    }

    public func diskUsage(now: Date) -> TranscriptDiskUsage? {
        TranscriptDiskUsage.measure(root: root, now: now)
    }

    public var providesSessions: Bool { true }

    public func sessionDetail(id: String) -> SessionDetail? {
        transcripts.sessionDetail(id: id)
    }
}

/// The retention capability: Claude Code's `cleanupPeriodDays` — the one
/// sanctioned write inside ~/.claude.
extension ClaudeCodeSettings: AgentSettingsStore {
    public var displayPath: String { "~/.claude/settings.json" }
    public var retentionKeyName: String { "cleanupPeriodDays" }
    public var defaultRetentionDays: Int { Self.defaultDays }
    public func readRetentionDays() -> Int? { readCleanupPeriodDays() }
    public func writeRetentionDays(_ days: Int) -> Bool { writeCleanupPeriodDays(days) }
}

extension ModelCatalog {
    /// Claude's id grammar and tier ladder. Families are the first display
    /// word, ordered by the model sizes the product names imply —
    /// Fable/Mythos, Opus, Sonnet, Haiku, then the rest.
    public static let claude = ModelCatalog(
        displayName: { claudeDisplayName($0) },
        familyName: { id in
            claudeDisplayName(id).split(separator: " ").first.map(String.init) ?? id
        },
        familyRank: { family in
            switch family.lowercased() {
            case "fable", "mythos": 0
            case "opus": 1
            case "sonnet": 2
            case "haiku": 3
            default: 4
            }
        }
    )
}

/// "claude-fable-5" → "Fable 5", "claude-haiku-4-5-20251001" → "Haiku 4.5"
/// (a trailing 8-digit component is a release date, not a version) — friendly
/// names without a registry to maintain, so new models read sensibly the day
/// they appear.
private func claudeDisplayName(_ id: String) -> String {
    guard id.hasPrefix("claude-") else { return id == "unknown" ? "Other" : id }
    var tokens = id.dropFirst("claude-".count).lowercased()
        .split(separator: "-").map(String.init)
    if let last = tokens.last, last.count == 8, last.allSatisfy(\.isNumber) {
        tokens.removeLast()
    }
    let words = tokens.filter { !$0.allSatisfy(\.isNumber) }
    let numbers = tokens.filter { $0.allSatisfy(\.isNumber) }
    let name = words.map(\.capitalized).joined(separator: " ")
    let version = numbers.joined(separator: ".")
    switch (name.isEmpty, version.isEmpty) {
    case (false, false): return "\(name) \(version)"
    case (false, true): return name
    case (true, false): return "Claude \(version)"
    case (true, true): return id
    }
}
