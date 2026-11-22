import Foundation

/// A provider's declaration that its agent's OWN command-line tool can
/// report the plan's limits, and how to ask it (spec §10 amendment
/// 2026-11-21, second — the quota probe). The provider owns every vendor
/// fact here: where the tool lives, what to pass it, how to read what it
/// prints, how the privacy card describes the run. Core owns when it runs
/// (`AgentQuotaSchedule`), how (`AgentCommandRunner`) and what is kept
/// (`AgentQuotaReading`).
public struct AgentQuotaCommand: Sendable {
    /// Where the tool may be installed, in order. A candidate counts only
    /// when it resolves to an executable regular file outside any `.app`
    /// bundle and `acceptsVersion` takes its version output.
    public let executableCandidates: [URL]
    /// What makes the tool print its version, and nothing else.
    public let versionArguments: [String]
    /// Whether that output is the tool's (and not a same-named one's).
    public let acceptsVersion: @Sendable (_ stdout: Data) -> Bool
    public let arguments: [String]
    /// Added to the minimal environment the child gets (`baseEnvironment`).
    public let environment: [String: String]
    /// Past this a run — the version check too — is killed with its process
    /// group. A safety net against a hung tool, sized far above any run on
    /// a busy Mac; hitting it is a TRANSIENT failure (retried at the floor).
    public let timeout: TimeInterval
    /// The least time between two attempts; never below `minimumFloor`.
    public let floor: TimeInterval
    /// What an exited run printed → the buckets, or why there are none.
    /// Pure; it sees the output in memory and keeps only bucket numbers.
    public let reduce: @Sendable (
        _ exitStatus: Int32, _ stdout: Data, _ stderr: Data, _ now: Date
    ) -> AgentQuotaOutcome
    /// The privacy card's lines for this run, in the provider's words.
    public let privacyLines: [String]

    /// The hard floor (spec §10): a provider may ask less often, never more.
    public static let minimumFloor: TimeInterval = 600

    public init(
        executableCandidates: [URL], versionArguments: [String],
        acceptsVersion: @escaping @Sendable (Data) -> Bool, arguments: [String],
        environment: [String: String], timeout: TimeInterval, floor: TimeInterval,
        reduce: @escaping @Sendable (Int32, Data, Data, Date) -> AgentQuotaOutcome,
        privacyLines: [String]
    ) {
        self.executableCandidates = executableCandidates
        self.versionArguments = versionArguments
        self.acceptsVersion = acceptsVersion
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
        self.floor = max(floor, Self.minimumFloor)
        self.reduce = reduce
        self.privacyLines = privacyLines
    }

    /// The child's whole environment: the host's identity and temp folder,
    /// a fixed system `PATH`, and the provider's additions — never the
    /// host's other variables.
    public static func baseEnvironment(
        host: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        environment["HOME"] = host["HOME"] ?? NSHomeDirectory()
        for key in ["USER", "LOGNAME", "TMPDIR"] {
            if let value = host[key] { environment[key] = value }
        }
        return environment
    }
}

/// One limit as the agent's tool reported it. Generic on purpose: a
/// remaining fraction and when it resets are all any of them carry.
public struct AgentQuotaBucket: Codable, Sendable, Equatable {
    /// The tool's own id for the bucket ("gemini-5h").
    public let id: String
    /// 0…1 left; nil when the tool didn't say (never read as 0).
    public let remainingFraction: Double?
    /// Absolute; nil when no window is running.
    public let resetsAt: Date?

    public init(id: String, remainingFraction: Double?, resetsAt: Date?) {
        self.id = id
        self.remainingFraction = remainingFraction
        self.resetsAt = resetsAt
    }

    enum CodingKeys: String, CodingKey {
        case id, remainingFraction, resetsAt
    }
}

/// A successful run's buckets, and when the run started and finished.
public struct AgentQuotaReading: Codable, Sendable, Equatable {
    /// What "written since the last reading" is measured against.
    public let startedAt: Date
    /// When the numbers were known — the snapshot's `fetchedAt`.
    public let capturedAt: Date
    public let buckets: [AgentQuotaBucket]

    public init(startedAt: Date, capturedAt: Date, buckets: [AgentQuotaBucket]) {
        self.startedAt = startedAt
        self.capturedAt = capturedAt
        self.buckets = buckets
    }

    enum CodingKeys: String, CodingKey {
        case startedAt, capturedAt, buckets
    }
}

/// Why a run produced no reading — each renders as readable text
/// (`UsageError.init(quotaFailure:)`).
public enum AgentQuotaFailure: String, Codable, Sendable, Equatable {
    case notSignedIn
    case timedOut
    /// It printed something, but not a limits report.
    case unreadable
    /// Exited non-zero, was killed by a signal, or couldn't start.
    case failed
    /// What ran was NOT the tool's limits command — it ran an agent turn,
    /// or answered without the command's result. The probe never asks that
    /// binary again (until the file changes): a tool that started treating
    /// the request as a prompt would otherwise spend the person's quota on
    /// every attempt, and its own conversation would keep the schedule due.
    case notALimitsCommand
}

public enum AgentQuotaOutcome: Sendable, Equatable {
    /// Possibly empty: a sign-in with no plan quota reports none.
    case buckets([AgentQuotaBucket])
    case failure(AgentQuotaFailure)
}

/// When the probe may run — pure, so every rule is a unit test.
public enum AgentQuotaSchedule {
    /// A first reading needs a conversation written this recently, and a
    /// failing probe stops retrying once the newest write is older.
    public static let reach: TimeInterval = 7 * 86400
    /// The longest backoff after failures.
    public static let backoffCap: TimeInterval = 2 * 3600
    /// So an engine polling every 5 minutes lands ON a backoff step rather
    /// than just short of it. Never applied below `minimumFloor`: the
    /// floor is a promise ("at most every 10 minutes"), not a target.
    public static let slack: TimeInterval = 30

    /// The floor, doubled per consecutive failure (a timeout doesn't count
    /// as one), capped.
    public static func interval(consecutiveFailures: Int, floor: TimeInterval) -> TimeInterval {
        guard consecutiveFailures > 0 else { return floor }
        let doubled = floor * pow(2, Double(min(consecutiveFailures, 16)))
        return min(doubled, max(backoffCap, floor))
    }

    /// Due when the agent wrote a conversation since the last reading began
    /// (and within `reach`), and the floor — or the backoff — has passed
    /// since the last attempt. No write, no run: a Mac that doesn't use the
    /// agent pays nothing. A MANUAL refresh skips the failure backoff (the
    /// person may just have fixed what failed — signed in, say), never the
    /// floor.
    public static func isDue(
        lastAttemptAt: Date?, consecutiveFailures: Int, readingStartedAt: Date?,
        lastWrite: Date?, now: Date, floor: TimeInterval, manual: Bool = false
    ) -> Bool {
        guard let lastWrite, now.timeIntervalSince(lastWrite) <= reach else { return false }
        if let readingStartedAt, lastWrite <= readingStartedAt { return false }
        guard let lastAttemptAt else { return true }
        // A clock that jumped back leaves a "future" attempt: don't wait on it.
        if lastAttemptAt > now.addingTimeInterval(60) { return true }
        let elapsed = now.timeIntervalSince(lastAttemptAt)
        let floor = max(floor, AgentQuotaCommand.minimumFloor)
        guard elapsed >= floor else { return false }
        let wait = interval(consecutiveFailures: manual ? 0 : consecutiveFailures, floor: floor)
        return elapsed + slack >= wait
    }
}

extension UsageError {
    /// How a probe failure reads. Not signed in is the existing sign-in
    /// state; the rest are the tool's own failures — never `.network`,
    /// whose transport retry would re-ask at once.
    public init(quotaFailure: AgentQuotaFailure) {
        switch quotaFailure {
        case .notSignedIn: self = .noCredentials
        case .timedOut: self = .agentTimedOut
        case .unreadable, .notALimitsCommand: self = .agentOutputUnreadable
        case .failed: self = .agentCommandFailed
        }
    }
}
