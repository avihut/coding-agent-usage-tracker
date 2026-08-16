import Foundation

/// The cross-device sync digest — the exact data this device will publish to
/// its own CloudKit zone once sync ships (docs/SYNC.md is the design; the
/// draft spec §10 amendment there is NOT in force yet, and nothing in this
/// file touches the network).
///
/// Why this exists before any CloudKit code can: production CloudKit schemas
/// are additive-only — fields and record types can be added forever but never
/// removed, renamed, or retyped. Freezing the digest as code, with tests
/// pinning record names and the encoded shape, is what makes the eventual
/// schema deploy a formality instead of a gamble.
///
/// Privacy line (the digest's whole contract): token counts, timestamps,
/// titles, repo folder NAMES, branch names, meter percents, and machine
/// identity may appear here. Full filesystem paths, prompt previews, message
/// text, credentials, and dollar amounts never do — costing stays on the
/// reading side, priced by each viewer's own feed.
public struct SyncDigest: Codable, Sendable, Equatable {
    /// Bump ONLY additively (new fields, new record types). Readers must
    /// tolerate any version ≥ theirs by ignoring unknown fields.
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let device: DeviceDigest
    /// Ascending by dayKey — deterministic output for tests and diffing.
    public let days: [DayDigest]
    /// End-descending, the app's session ordering.
    public let sessions: [SessionDigest]
    /// Nil when the device has no fetched usage state to publish.
    public let meters: MeterSnapshotDigest?

    public init(
        device: DeviceDigest, days: [DayDigest], sessions: [SessionDigest],
        meters: MeterSnapshotDigest?
    ) {
        self.schemaVersion = Self.schemaVersion
        self.device = device
        self.days = days
        self.sessions = sessions
        self.meters = meters
    }
}

/// Who is publishing: one record per (device, provider). The zone already
/// names the device, so this record's job is the human-readable half —
/// what a viewer lists under "My Macs".
public struct DeviceDigest: Codable, Sendable, Equatable {
    /// Per-install UUID, minted by the app on first sync (never derived from
    /// hardware serials). The CLI's preview digest uses a placeholder.
    public let deviceID: String
    /// The user-facing machine name ("Avihu's MacBook Pro").
    public let name: String
    public let providerID: String
    /// Display-only account/plan facts ("Max plan · 20x"). A stable account
    /// identifier is a future ADDITIVE field, added only when a provider can
    /// verifiably supply one — per the roadmap rule, local activity belongs
    /// to the account detected on this machine, and we never guess.
    public let accountLabel: String?
    public let appVersion: String
    /// Day keys below are this device's LOCAL calendar days (the heatmap's
    /// semantics). Viewers need the zone to present them honestly.
    public let timeZone: String
    public let capturedAt: Date

    public init(
        deviceID: String, name: String, providerID: String, accountLabel: String?,
        appVersion: String, timeZone: String, capturedAt: Date
    ) {
        self.deviceID = deviceID
        self.name = name
        self.providerID = providerID
        self.accountLabel = accountLabel
        self.appVersion = appVersion
        self.timeZone = timeZone
        self.capturedAt = capturedAt
    }
}

/// One local calendar day of activity — the heatmap's row, made portable.
/// Mirrors `DailyActivity` minus nothing: prompt-only days (transcripts
/// already cleaned up) publish honestly with zero tokens.
public struct DayDigest: Codable, Sendable, Equatable, Identifiable {
    /// "yyyy-MM-dd" in the publishing device's calendar.
    public let dayKey: String
    public let tokens: Int
    public let apiCalls: Int
    public let prompts: Int
    public let models: [String: TokenTally]

    public var id: String { dayKey }

    public init(dayKey: String, tokens: Int, apiCalls: Int, prompts: Int, models: [String: TokenTally]) {
        self.dayKey = dayKey
        self.tokens = tokens
        self.apiCalls = apiCalls
        self.prompts = prompts
        self.models = models
    }
}

/// One session's nutrition card, made portable. Everything a remote sessions
/// list needs and nothing the privacy line forbids: the project's folder NAME
/// travels, its full path does not; the display title travels (which, for
/// sessions without an aiTitle, IS the scrubbed first-prompt fallback — an
/// explicit sign-off item in docs/SYNC.md); raw prompt previews as a separate
/// field do not.
public struct SessionDigest: Codable, Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let title: String
    /// Last path component of the local project directory, or nil.
    public let repoName: String?
    public let gitBranch: String?
    /// `SessionKind.rawValue`, kept as a plain string on the wire so future
    /// kinds can't break old readers.
    public let kind: String
    public let start: Date
    public let end: Date
    public let activeSeconds: TimeInterval
    public let prompts: Int
    public let apiCalls: Int
    public let toolCalls: Int
    public let subagentCount: Int
    public let compactions: Int
    public let models: [String: TokenTally]

    public var id: String { sessionID }

    public init(
        sessionID: String, title: String, repoName: String?, gitBranch: String?,
        kind: String, start: Date, end: Date, activeSeconds: TimeInterval,
        prompts: Int, apiCalls: Int, toolCalls: Int, subagentCount: Int,
        compactions: Int, models: [String: TokenTally]
    ) {
        self.sessionID = sessionID
        self.title = title
        self.repoName = repoName
        self.gitBranch = gitBranch
        self.kind = kind
        self.start = start
        self.end = end
        self.activeSeconds = activeSeconds
        self.prompts = prompts
        self.apiCalls = apiCalls
        self.toolCalls = toolCalls
        self.subagentCount = subagentCount
        self.compactions = compactions
        self.models = models
    }
}

/// The device's last-known meter state — what an iPhone glance renders
/// without polling anything. One mutable record per (device, provider),
/// overwritten in place; only its own device ever writes it, so there is
/// nothing to merge.
public struct MeterSnapshotDigest: Codable, Sendable, Equatable {
    public struct MeterDigest: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let percent: Int?
        public let resetsAt: Date?
        public let limitWindow: TimeInterval?

        public init(
            id: String, label: String, percent: Int?, resetsAt: Date?,
            limitWindow: TimeInterval?
        ) {
            self.id = id
            self.label = label
            self.percent = percent
            self.resetsAt = resetsAt
            self.limitWindow = limitWindow
        }
    }

    /// When the underlying usage fetch happened — staleness is the viewer's
    /// first-class fact, not something to hide.
    public let capturedAt: Date
    public let planLabel: String?
    public let meters: [MeterDigest]

    public init(capturedAt: Date, planLabel: String?, meters: [Meter]) {
        self.capturedAt = capturedAt
        self.planLabel = planLabel
        self.meters = meters.map {
            MeterDigest(
                id: $0.id, label: $0.label, percent: $0.percent,
                resetsAt: $0.resetsAt, limitWindow: $0.limitWindow)
        }
    }
}

/// The frozen CloudKit naming scheme. One custom zone per DEVICE in the
/// private database; providers are disambiguated inside record names. Tests
/// pin these strings — changing one after the production schema deploys
/// would strand every already-published record.
public enum SyncRecordName {
    public static func zone(deviceID: String) -> String {
        "device-\(deviceID)"
    }

    public static func device(providerID: String) -> String {
        "device|\(providerID)"
    }

    public static func day(providerID: String, dayKey: String) -> String {
        "day|\(providerID)|\(dayKey)"
    }

    public static func session(providerID: String, sessionID: String) -> String {
        "session|\(providerID)|\(sessionID)"
    }

    public static func meters(providerID: String) -> String {
        "meters|\(providerID)"
    }
}

/// Pure local-state → digest mapping. No CloudKit imports anywhere in this
/// target; the transport layer (membership-gated) will consume the digest,
/// never reshape it.
public enum SyncDigestBuilder {
    /// `daily` should be the MERGED series (transcripts + prompt history via
    /// `ActivityMerge`), so prompt-only days survive into the digest exactly
    /// as they survive into the heatmap.
    public static func build(
        device: DeviceDigest,
        daily: [DailyActivity],
        sessions: [SessionSummary],
        meters: MeterSnapshotDigest?,
        calendar: Calendar
    ) -> SyncDigest {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let days = daily
            .map { day in
                DayDigest(
                    dayKey: formatter.string(from: day.day),
                    tokens: day.tokens,
                    apiCalls: day.messages,
                    prompts: day.prompts,
                    models: day.models)
            }
            .sorted { $0.dayKey < $1.dayKey }

        let sessionDigests = sessions
            .map { session in
                SessionDigest(
                    sessionID: session.id,
                    title: session.title,
                    repoName: session.projectPath.map {
                        URL(fileURLWithPath: $0).lastPathComponent
                    },
                    gitBranch: session.gitBranch,
                    kind: session.kind.rawValue,
                    start: session.start,
                    end: session.end,
                    activeSeconds: session.activeSeconds,
                    prompts: session.prompts,
                    apiCalls: session.apiCalls,
                    toolCalls: session.toolCalls,
                    subagentCount: session.subagentCount,
                    compactions: session.compactions,
                    models: session.models)
            }
            .sorted { $0.end > $1.end }

        return SyncDigest(
            device: device, days: days, sessions: sessionDigests, meters: meters)
    }
}
