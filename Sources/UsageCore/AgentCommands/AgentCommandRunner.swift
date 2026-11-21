import Foundation

/// One run of an agent's own command-line tool, fully specified — nothing
/// is inherited from the host process: not its environment, not its
/// working directory, not its open files (spec §10 amendment 2026-11-21,
/// second: the quota probe). Vendor-neutral: a provider declares what to
/// run (`AgentQuotaCommand`); this says how.
public struct AgentCommandInvocation: Sendable, Equatable {
    public let executable: URL
    /// argv[1...]; argv[0] is the executable's path.
    public let arguments: [String]
    /// The child's WHOLE environment.
    public let environment: [String: String]
    public let workingDirectory: String
    /// Past this the process group is terminated, then killed.
    public let timeout: TimeInterval
    /// Output beyond these caps is a failure, not a truncation: a quota
    /// report is a few KB, and anything far bigger isn't one.
    public let stdoutCap: Int
    public let stderrCap: Int

    public init(
        executable: URL, arguments: [String], environment: [String: String],
        workingDirectory: String = "/", timeout: TimeInterval,
        stdoutCap: Int = 256 * 1024, stderrCap: Int = 16 * 1024
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.stdoutCap = stdoutCap
        self.stderrCap = stderrCap
    }
}

/// What a run came to. Its output is held in memory only, for the
/// provider's reducer — never logged, never written anywhere.
public struct AgentCommandResult: Sendable, Equatable {
    public enum Termination: Sendable, Equatable {
        case exited(Int32)
        case signaled(Int32)
        /// Killed at the invocation's timeout.
        case timedOut
        /// Killed for writing more than its caps allow.
        case outputOverflow
        /// Never started (`errno` from the spawn).
        case launchFailed(Int32)
    }

    public let termination: Termination
    public let stdout: Data
    public let stderr: Data
    public let duration: TimeInterval

    public init(termination: Termination, stdout: Data, stderr: Data, duration: TimeInterval) {
        self.termination = termination
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
    }
}

/// The seam: hosts that may run agent commands get a real runner
/// (`SpawnedCommandRunner`); tests get a fake; every other host gets none
/// at all, so nothing there can spawn (`MeteringHost.Configuration`).
public protocol AgentCommandRunner: Sendable {
    func run(_ invocation: AgentCommandInvocation) async -> AgentCommandResult
}
