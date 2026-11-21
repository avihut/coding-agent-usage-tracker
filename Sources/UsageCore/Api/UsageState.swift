import Foundation

/// User-facing error taxonomy. Every failure mode maps to something readable —
/// an empty or crashed menu bar item is a bug (spec §10).
public enum UsageError: Error, Sendable, Equatable {
    case noCredentials
    case keychainDenied
    case credentialsUnreadable
    case signInExpired
    /// 429. The associated Retry-After seconds feed the backoff, not the UI.
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case network
    case schema
    case noLocalData
    /// The agent's own tool, asked for the plan's limits, didn't answer in
    /// time (the quota probe, spec §10 amendment 2026-11-21, second).
    case agentTimedOut
    /// It answered with something that isn't a limits report.
    case agentOutputUnreadable
    /// It exited with an error, or couldn't be started.
    case agentCommandFailed

    /// `agent` names whichever local agent owns the credentials ("Claude
    /// Code") — the taxonomy itself is provider-neutral.
    public func shortText(agent: String) -> String {
        switch self {
        case .noCredentials: "No \(agent) sign-in found"
        case .keychainDenied: "Keychain access denied"
        case .credentialsUnreadable: "Stored credentials unreadable"
        case .signInExpired: "Sign-in expired — open \(agent)"
        case .rateLimited: "Rate limited — checks paused"
        case .http(let code): "Usage endpoint returned HTTP \(code)"
        case .network: "Network unavailable"
        case .schema: "Unexpected API response"
        case .noLocalData: "No local \(agent) sessions found yet"
        case .agentTimedOut: "\(agent) didn't answer — limits not refreshed"
        case .agentOutputUnreadable: "\(agent)'s limits report wasn't readable"
        case .agentCommandFailed: "\(agent) couldn't report its limits"
        }
    }

    public func hint(agent: String) -> String? {
        switch self {
        case .noCredentials: "Sign in to \(agent), then refresh."
        case .keychainDenied: "The login Keychain refused the read — unlock it, then refresh."
        case .signInExpired: "Open \(agent) once; it refreshes the token automatically."
        case .rateLimited: "The API asked for a pause. Checks back off and resume on their own."
        case .schema: "The undocumented API may have changed shape."
        case .noLocalData: "Run \(agent) once on this Mac — usage is read from its session files."
        case .agentTimedOut, .agentCommandFailed:
            "\(agent) is asked again in a few minutes; limits already read stay shown."
        case .agentOutputUnreadable:
            "A \(agent) update may have changed what it prints; limits already read stay shown."
        case .http, .network, .credentialsUnreadable: nil
        }
    }

    static func from(_ error: CredentialError) -> UsageError {
        switch error {
        case .notFound: .noCredentials
        case .accessDenied: .keychainDenied
        case .unreadable: .credentialsUnreadable
        }
    }

    static func from(_ error: UsageClientError) -> UsageError {
        switch error {
        case .signInExpired: .signInExpired
        case .rateLimited(let retryAfter): .rateLimited(retryAfter: retryAfter)
        case .http(let code): .http(code)
        case .network: .network
        case .schema: .schema
        case .noLocalData: .noLocalData
        }
    }
}

/// One normalized usage snapshot, ready to render. Providers assemble it
/// from whatever their payload looks like; nothing downstream sees provider
/// schemas.
public struct Snapshot: Sendable, Equatable {
    public let meters: [Meter]
    public let summary: MenuBarSummary
    public let spendLine: SpendLine?
    public let fetchedAt: Date
    /// From the credentials read for this fetch; nil on cache-served states.
    public let plan: PlanInfo?

    public init(
        meters: [Meter], spendLine: SpendLine? = nil, fetchedAt: Date,
        plan: PlanInfo? = nil
    ) {
        self.meters = meters
        self.summary = MeterBuilder.menuBarSummary(from: meters)
        self.spendLine = spendLine
        self.fetchedAt = fetchedAt
        self.plan = plan
    }

    /// The same snapshot re-classified under different thresholds — meters
    /// carry everything leveling needs, so no payload is retained or
    /// re-decoded.
    public func rebuilt(thresholds: Thresholds) -> Snapshot {
        Snapshot(
            meters: meters.map { $0.releveled(thresholds: thresholds) },
            spendLine: spendLine, fetchedAt: fetchedAt, plan: plan)
    }
}

public enum DisplayState: Sendable, Equatable {
    case loading
    case live(Snapshot)
    /// The fetch failed but an earlier snapshot exists — rendered greyed with
    /// a "cached HH:mm" note.
    case cached(Snapshot, error: UsageError)
    case unavailable(UsageError)

    public var snapshot: Snapshot? {
        switch self {
        case .live(let snapshot), .cached(let snapshot, _): snapshot
        case .loading, .unavailable: nil
        }
    }

    public var error: UsageError? {
        switch self {
        case .cached(_, let error), .unavailable(let error): error
        case .loading, .live: nil
        }
    }

    /// True when what's on screen isn't fresh.
    public var isStale: Bool {
        if case .live = self { return false }
        return true
    }
}
