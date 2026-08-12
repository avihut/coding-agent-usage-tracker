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

    public var shortText: String {
        switch self {
        case .noCredentials: "No Claude Code sign-in found"
        case .keychainDenied: "Keychain access denied"
        case .credentialsUnreadable: "Stored credentials unreadable"
        case .signInExpired: "Sign-in expired — open Claude Code"
        case .rateLimited: "Rate limited — checks paused"
        case .http(let code): "Usage endpoint returned HTTP \(code)"
        case .network: "Network unavailable"
        case .schema: "Unexpected API response"
        }
    }

    public var hint: String? {
        switch self {
        case .noCredentials: "Sign in to Claude Code, then refresh."
        case .keychainDenied: "Approve the Keychain prompt on the next refresh — \"Always Allow\" stops future prompts."
        case .signInExpired: "Open Claude Code once; it refreshes the token automatically."
        case .rateLimited: "The API asked for a pause. Checks back off and resume on their own."
        case .schema: "The undocumented API may have changed shape."
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
        }
    }
}

/// One decoded usage snapshot, ready to render.
public struct Snapshot: Sendable, Equatable {
    public let meters: [Meter]
    public let summary: MenuBarSummary
    public let spendLine: SpendLine?
    public let fetchedAt: Date

    public init(response: UsageResponse, fetchedAt: Date) {
        let meters = MeterBuilder.meters(from: response)
        self.meters = meters
        self.summary = MeterBuilder.menuBarSummary(from: meters)
        self.spendLine = MeterBuilder.spendLine(from: response)
        self.fetchedAt = fetchedAt
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
