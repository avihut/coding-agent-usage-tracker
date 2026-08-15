import Foundation

/// One metered AI subscription and the local agent that spends it, bundled
/// behind a seam. Everything vendor-specific lives in an implementation of
/// this protocol — where credentials sit, how the quota endpoint speaks and
/// parses, where the agent leaves traces on disk, how its model ids read,
/// which product pages to link. Everything downstream — prediction engine,
/// history, charts, panel — runs on the normalized types a provider
/// produces (`Meter`, `Snapshot`, `DailyActivity`, `TokenTally`) and never
/// names a vendor.
///
/// Exactly one provider is active per app instance; this is a seam for
/// adopting other agents, not for metering several at once.
public protocol UsageProvider: Sendable {
    /// Stable machine id ("claude") — safe to embed in cache paths and keys.
    var id: String { get }
    /// The metered subscription, as marketing names it ("Claude").
    var serviceName: String { get }
    /// The local agent whose sign-in and traces this provider reads
    /// ("Claude Code") — error text and settings copy name it.
    var agentName: String { get }
    /// Product pages the UI may link to; absent links hide their buttons.
    var links: ProviderLinks { get }
    /// The one-character mark drawn ahead of the menu bar digits — vendor
    /// identity ("✳︎" for Claude), not app branding.
    var menuBarGlyph: String { get }
    /// Every host this provider's usage fetches contact. The settings
    /// privacy card renders exactly this list (plus the app's own pricing
    /// feed host) — adding a destination is a spec §10 amendment, not a
    /// code detail.
    var networkDestinations: [String] { get }

    /// Read-only places the agent's access token can be found. Read fresh
    /// every refresh cycle, never cached, never written back (spec §5/§10).
    var credentials: CredentialChain { get }
    /// One quota fetch, raw bytes out — raw so the offline cache can replay
    /// it through `snapshot` later. Throws `UsageClientError` so the
    /// service's retry/backoff taxonomy stays uniform across providers.
    func fetchRawUsage(accessToken: String) async throws -> Data
    /// Provider payload → normalized snapshot. Throws when the bytes don't
    /// parse (surfaced to the user as `.schema`).
    func snapshot(
        fromRawUsage body: Data, fetchedAt: Date, plan: PlanInfo?,
        thresholds: Thresholds
    ) throws -> Snapshot

    /// The agent's on-disk traces, created once and retained (scanners keep
    /// warm caches). Nil when the agent leaves nothing scannable — the
    /// activity section then shows its empty state and cadence relies on
    /// percentages moving. `cacheDirectory` is this provider's scoped
    /// Application Support directory (`StorageScope`), where the scanner
    /// keeps its parse cache.
    func makeLocalActivity(cacheDirectory: URL) -> (any LocalActivitySource)?
    /// The agent's own settings file, for the retention card; nil hides the
    /// card entirely.
    var agentSettings: (any AgentSettingsStore)? { get }

    /// Display cosmetics for this provider's raw model ids.
    var modelCatalog: ModelCatalog { get }
    /// Offline pricing floor for this provider's models — the table used
    /// until (and beneath) the live feed.
    var bundledRates: PricingTable { get }
}

/// Product pages a provider can point the UI at.
public struct ProviderLinks: Sendable, Equatable {
    /// Where the user changes their plan.
    public let planUpgrade: URL?
    /// The service's own usage dashboard.
    public let usageSettings: URL?

    public init(planUpgrade: URL? = nil, usageSettings: URL? = nil) {
        self.planUpgrade = planUpgrade
        self.usageSettings = usageSettings
    }
}

/// The local agent's on-disk traces. Read-only by contract (spec §10):
/// implementations never write inside the scanned trees.
public protocol LocalActivitySource: Sendable {
    /// Directories whose writes mean "the agent is active right now" — the
    /// FSEvents signal that snaps the poll cadence back to the user's pace.
    var watchDirectories: [URL] { get }
    /// Shown by the settings retention card ("~/.claude/projects").
    var displayPath: String { get }
    /// Daily aggregates plus the recent per-minute timeline, from the
    /// agent's transcripts.
    func scanTranscripts(now: Date) -> TranscriptScan
    /// Per-day prompt counts from a log that outlives transcript cleanup;
    /// empty when the agent keeps no such log.
    func scanPromptDays() -> [Date: Int]
    /// Disk footprint of the traces, for the retention card's projection.
    func diskUsage(now: Date) -> TranscriptDiskUsage?
}

/// The one sanctioned write into an agent's own configuration: how long it
/// keeps local transcripts. Nothing else in the agent's settings is ever
/// touched (rule recorded in spec §10 and the repo guidelines).
public protocol AgentSettingsStore: Sendable {
    /// Shown beside the control ("~/.claude/settings.json").
    var displayPath: String { get }
    /// The key's display name in the agent's own vocabulary
    /// ("cleanupPeriodDays").
    var retentionKeyName: String { get }
    /// The agent's own default when the key is absent.
    var defaultRetentionDays: Int { get }
    func readRetentionDays() -> Int?
    /// False when the file couldn't be updated safely (unparseable content
    /// is refused, never overwritten).
    func writeRetentionDays(_ days: Int) -> Bool
}

/// How a provider's raw model ids read on screen. Closures, not a registry:
/// id grammars differ per vendor and new models must display sensibly the
/// day they appear.
public struct ModelCatalog: Sendable {
    /// "claude-fable-5" → "Fable 5".
    public let displayName: @Sendable (String) -> String
    /// Family grouping for rate tables and pickers ("Fable", "Sonnet").
    public let familyName: @Sendable (String) -> String
    /// Sort rank across families — capability tiers first. Ties fall back
    /// to alphabetical at the call site; unknowns should rank last.
    public let familyRank: @Sendable (String) -> Int

    public init(
        displayName: @escaping @Sendable (String) -> String,
        familyName: @escaping @Sendable (String) -> String,
        familyRank: @escaping @Sendable (String) -> Int
    ) {
        self.displayName = displayName
        self.familyName = familyName
        self.familyRank = familyRank
    }

    /// Vendor-neutral fallback: ids display as themselves (minus a trailing
    /// 8-digit release date), the first hyphen-word names the family, and
    /// families order alphabetically (every rank equal).
    public static let generic = ModelCatalog(
        displayName: { id in
            guard id != "unknown" else { return "Other" }
            var tokens = id.split(separator: "-").map(String.init)
            if let last = tokens.last, last.count == 8, last.allSatisfy(\.isNumber) {
                tokens.removeLast()
            }
            return tokens.joined(separator: "-")
        },
        familyName: { id in
            id == "unknown" ? "Other" : String(id.split(separator: "-").first ?? "Other")
        },
        familyRank: { _ in 0 }
    )
}
