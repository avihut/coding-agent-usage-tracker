import Darwin
import Foundation

/// Runs a provider's `AgentQuotaCommand` for ONE engine (spec §10 amendment
/// 2026-11-21, second). Built only when the host was given a runner, so
/// only an engine host — usaged, or the app while it hosts — ever spawns
/// anything; the reading lands in the engine's own scoped folder, which the
/// lease holder alone writes.
///
/// One run at a time: a caller arriving mid-run waits for that run and
/// gets its outcome. Every attempt is persisted before it starts, so a
/// restart or a handover can't beat the floor.
public actor AgentQuotaProbe {
    /// What the engine renders: the newest reading, and the failure of the
    /// LAST attempt when it failed (by construction newer than the reading).
    public struct Status: Sendable, Equatable {
        public let reading: AgentQuotaReading?
        public let failure: AgentQuotaFailure?
    }

    public static let stateFileName = "quota-probe.json"
    /// The version check is a start-up of the same tool; it gets less time.
    static let versionTimeout: TimeInterval = 10

    private let command: AgentQuotaCommand
    private let runner: any AgentCommandRunner
    private let stateURL: URL
    private let lastActivity: @Sendable (Date) -> Date?
    private let environment: [String: String]
    private let clock: @Sendable () -> Date
    private var state: AgentQuotaProbeState
    private var running: Task<Void, Never>?

    public init(
        command: AgentQuotaCommand, runner: any AgentCommandRunner, stateURL: URL,
        lastActivity: @escaping @Sendable (Date) -> Date?,
        hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.command = command
        self.runner = runner
        self.stateURL = stateURL
        self.lastActivity = lastActivity
        self.environment = AgentQuotaCommand.baseEnvironment(host: hostEnvironment)
            .merging(command.environment) { _, provider in provider }
        self.clock = clock
        self.state = AgentQuotaProbeState.load(from: stateURL) ?? AgentQuotaProbeState()
    }

    public var status: Status {
        Status(reading: state.reading, failure: state.lastFailure)
    }

    /// Runs the command when the schedule says so, then reports the
    /// standing status either way.
    public func refreshIfDue() async -> Status {
        if let running {
            await running.value
            return status
        }
        let now = clock()
        guard AgentQuotaSchedule.isDue(
            lastAttemptAt: state.lastAttemptAt,
            consecutiveFailures: state.consecutiveFailures,
            readingStartedAt: state.reading?.startedAt,
            lastWrite: lastActivity(now), now: now, floor: command.floor)
        else { return status }
        let task = Task { await self.attempt(startedAt: now) }
        running = task
        await task.value
        running = nil
        return status
    }

    private func attempt(startedAt: Date) async {
        let executable: URL
        switch await resolveExecutable() {
        case .found(let url):
            executable = url
        case .absent:
            // No tool: a quiet absence — no attempt recorded, nothing shown.
            return
        case .unsettled(let failure):
            // A candidate whose version run didn't finish: that run was a
            // spawn like any other, so it counts as the attempt — the
            // floor and the backoff hold, and the failure is shown.
            state.lastAttemptAt = startedAt
            state.lastFailure = failure
            state.consecutiveFailures += 1
            state.save(to: stateURL)
            return
        }
        state.lastAttemptAt = startedAt
        state.save(to: stateURL)
        let result = await runner.run(AgentCommandInvocation(
            executable: executable, arguments: command.arguments,
            environment: environment, timeout: command.timeout))
        let finishedAt = clock()
        let outcome: AgentQuotaOutcome
        switch result.termination {
        case .exited(let code):
            outcome = command.reduce(code, result.stdout, result.stderr, finishedAt)
        case .timedOut:
            outcome = .failure(.timedOut)
        case .outputOverflow:
            outcome = .failure(.unreadable)
        case .signaled, .launchFailed:
            outcome = .failure(.failed)
        }
        switch outcome {
        case .buckets(let buckets):
            state.reading = AgentQuotaReading(
                startedAt: startedAt, capturedAt: finishedAt, buckets: buckets)
            state.lastFailure = nil
            state.consecutiveFailures = 0
        case .failure(let failure):
            state.lastFailure = failure
            state.consecutiveFailures += 1
        }
        state.save(to: stateURL)
    }

    private enum Resolution {
        case found(URL)
        /// No candidate is the tool (none there, or each one's verdict is
        /// a settled no).
        case absent
        /// None found, and a version run didn't finish: retried at the
        /// next due attempt, not held against the file.
        case unsettled(AgentQuotaFailure)
    }

    /// The first candidate that is really the tool: a regular executable
    /// outside any app bundle (a same-named launcher inside one is the
    /// wrong program), whose version output the provider accepts. A
    /// verdict is remembered per file identity.
    private func resolveExecutable() async -> Resolution {
        var unsettled: AgentQuotaFailure?
        for candidate in command.executableCandidates {
            guard let identity = AgentQuotaProbeState.Binary.identify(candidate) else { continue }
            if let known = state.binaries.first(where: { $0.sameFile(as: identity) }) {
                if known.accepted { return .found(candidate) }
                continue
            }
            let result = await runner.run(AgentCommandInvocation(
                executable: candidate, arguments: command.versionArguments,
                environment: environment, timeout: Self.versionTimeout))
            guard case .exited(0) = result.termination else {
                if unsettled == nil {
                    if case .timedOut = result.termination { unsettled = .timedOut } else {
                        unsettled = .failed
                    }
                }
                continue
            }
            var verdict = identity
            verdict.accepted = command.acceptsVersion(result.stdout)
            state.binaries.removeAll { $0.path == verdict.path }
            state.binaries.append(verdict)
            state.save(to: stateURL)
            if verdict.accepted { return .found(candidate) }
        }
        return unsettled.map(Resolution.unsettled) ?? .absent
    }
}

/// `quota-probe.json`: the probe's memory across restarts and handovers.
/// Bucket numbers and times only — no output text, no identifier.
struct AgentQuotaProbeState: Codable, Equatable {
    struct Binary: Codable, Equatable {
        let path: String
        let resolvedPath: String
        let size: Int64
        let modifiedAt: Date
        var accepted = false

        enum CodingKeys: String, CodingKey {
            case path, resolvedPath, size, modifiedAt, accepted
        }

        func sameFile(as other: Binary) -> Bool {
            path == other.path && resolvedPath == other.resolvedPath
                && size == other.size
                // The state file keeps whole seconds; the file system doesn't.
                && abs(modifiedAt.timeIntervalSince(other.modifiedAt)) < 1
        }

        static func identify(_ candidate: URL) -> Binary? {
            let resolved = candidate.resolvingSymlinksInPath()
            guard !resolved.pathComponents.contains(where: { $0.hasSuffix(".app") }),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  FileManager.default.isExecutableFile(atPath: resolved.path),
                  let size = (attributes[.size] as? NSNumber)?.int64Value,
                  let modified = attributes[.modificationDate] as? Date
            else { return nil }
            return Binary(
                path: candidate.path, resolvedPath: resolved.path, size: size,
                modifiedAt: modified)
        }
    }

    static let currentVersion = 1

    var version = Self.currentVersion
    var binaries: [Binary] = []
    var lastAttemptAt: Date?
    var lastFailure: AgentQuotaFailure?
    var consecutiveFailures = 0
    var reading: AgentQuotaReading?

    enum CodingKeys: String, CodingKey {
        case version, binaries, lastAttemptAt, lastFailure, consecutiveFailures, reading
    }

    static func load(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(Self.self, from: data),
              state.version == currentVersion
        else { return nil }
        return state
    }

    /// Temp file + rename in the same folder, mode 0600: a reader sees the
    /// old state or the new one, never half of either.
    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        guard (try? manager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return }
        let temporary = folder.appending(
            path: ".\(url.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
        guard manager.createFile(
            atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { return }
        if rename(temporary.path, url.path) != 0 { try? manager.removeItem(at: temporary) }
    }
}
