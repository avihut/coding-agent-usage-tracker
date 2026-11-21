import Foundation

/// Google's Antigravity CLI (`agy`) behind the provider seam — the Google
/// harness since Gemini CLI's deprecation. LOCAL-FILES-ONLY like Codex:
/// zero network destinations, zero credentials (the CLI keeps its sign-in
/// in the Keychain, which is never touched), nothing written inside
/// `~/.gemini`.
///
/// Two local sources:
/// - TOKENS from each conversation's `transcript.jsonl`
///   (`AntigravityActivitySource`).
/// - PLAN LIMITS from the CLI's own status line: Antigravity hands a
///   person-configured status-line command a payload whose `quota` map is
///   the only local place the plan's remaining fractions and resets appear.
///   `usage-cli export-statusline antigravity` (installed by the person in
///   the CLI's settings) reduces it to one file in this app's own folder,
///   which `fetchRawUsage` reads — as fresh as the last session, like
///   Codex's rate-limit events.
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
    public let networkDestinations: [String] = []
    public let credentials: CredentialChain
    let home: URL
    let exportURL: URL

    public init(home: URL? = nil, exportURL: URL? = nil) {
        self.home = home
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".gemini/antigravity-cli")
        self.exportURL = exportURL
            ?? StorageScope.statusLineExportFile(
                bundleID: AppIdentity.bundleID, providerID: "antigravity")
        self.credentials = CredentialChain(sources: [
            StaticCredentialSource(name: "local Antigravity CLI files")
        ])
    }

    /// Ignores the token. The status-line reading when one exists; with
    /// none but conversations on disk, an honest "no limits read yet"
    /// (zero meters, fresh); with no conversations, `noLocalData`.
    public func fetchRawUsage(accessToken: String) async throws -> Data {
        let tree = AntigravityHome(root: home)
        let reading = (try? Data(contentsOf: exportURL)).flatMap(AntigravityQuota.decodeReading)
        guard reading != nil || tree.hasTranscripts() else {
            throw UsageClientError.noLocalData
        }
        return try AntigravityQuota.encodePayload(AntigravityUsagePayload(
            fetchedAt: Date(), reading: reading,
            conversationWrittenAt: tree.newestConversationWrite()))
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
    /// effort is stripped), so Gemini's grammar reads them; a Claude id is
    /// claimed by Claude's catalog in the union.
    public var modelCatalog: ModelCatalog { .gemini }

    /// No bundled floor: rates arrive with the feed's gemini slice.
    public var bundledRates: PricingTable {
        PricingTable(rates: [:], fetchedAt: .distantPast, source: .bundled)
    }

    public var pricingSelector: PricingFeedSelector { .gemini }

    public var statusLineExport: StatusLineExport? {
        StatusLineExport(
            destination: exportURL,
            settingsPath: "~/.gemini/antigravity-cli/settings.json",
            settingsSnippet: { command in
                // The CLI's documented statusLine entry; stacking keeps its
                // own status line, since the export prints nothing.
                let escaped = command
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return """
                "statusLine": {
                  "type": "command",
                  "command": "\(escaped)",
                  "stack_with_default": true
                }
                """
            },
            reduce: { payload, now in AntigravityQuota.reduce(statusLine: payload, now: now) },
            differs: { stored, fresh in AntigravityQuota.differs(stored: stored, fresh: fresh) })
    }
}
