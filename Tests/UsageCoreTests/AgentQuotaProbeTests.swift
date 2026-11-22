import Foundation
import Synchronization
import Testing

@testable import UsageCore

/// A scripted runner — no test ever spawns the real CLI. `--version` gets
/// its own answer; every other run gets `quota`, after `delay`.
actor FakeAgentRunner: AgentCommandRunner {
    var version = AgentCommandResult(
        termination: .exited(0), stdout: Data("1.5.14\n".utf8), stderr: Data(), duration: 0.01)
    var quota: AgentCommandResult
    var delay: Duration = .zero
    /// Awaited by every limits run before it answers — a test holds a run
    /// in flight for exactly as long as it needs, no wall clock involved.
    var hold: (@Sendable () async -> Void)?
    private(set) var invocations: [AgentCommandInvocation] = []
    /// Called as each run starts — what the world looked like at the spawn.
    var onRun: (@Sendable (AgentCommandInvocation) -> Void)?

    init(quota: AgentCommandResult) { self.quota = quota }

    func run(_ invocation: AgentCommandInvocation) async -> AgentCommandResult {
        invocations.append(invocation)
        onRun?(invocation)
        if invocation.arguments == ["--version"] { return version }
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let hold { await hold() }
        return quota
    }

    var quotaRuns: [AgentCommandInvocation] { invocations.filter { $0.arguments != ["--version"] } }
    var versionRuns: Int { invocations.count - quotaRuns.count }
    func set(quota: AgentCommandResult) { self.quota = quota }
    func set(version: AgentCommandResult) { self.version = version }
    func set(delay: Duration) { self.delay = delay }
    func set(hold: @escaping @Sendable () async -> Void) { self.hold = hold }
    func set(onRun: @escaping @Sendable (AgentCommandInvocation) -> Void) { self.onRun = onRun }
}

extension AgentCommandResult {
    /// A run that exited with this output (the fakes' shorthand).
    static func exited(_ code: Int32 = 0, stdout: Data, stderr: String = "") -> AgentCommandResult {
        AgentCommandResult(
            termination: .exited(code), stdout: stdout, stderr: Data(stderr.utf8), duration: 2)
    }
}

/// A settable instant, shared with a `@Sendable` closure.
final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    var now: Date { value.withLock { $0 } }
    func set(_ date: Date) { value.withLock { $0 = date } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// The real `/quota` output's shape (captured 2026-11-21, every name and
/// description replaced by a placeholder), with its numbers and dates.
enum AntigravityQuotaFixture {
    /// The instant the person's `/usage` screen was read (23:08 IST).
    static let capturedNow = ISO8601DateFormatter().date(from: "2026-11-21T21:08:00Z")!

    static func real() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "antigravity-quota-real-2026-11-21", withExtension: "json",
            subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The same envelope around buckets built in the test.
    static func output(_ buckets: [String], status: String = "SUCCESS") -> Data {
        Data("""
        {"conversation_id":"","status":"\(status)","response":"<placeholder>","num_turns":0,
         "command":{"name":"usage","data":{"description":"<placeholder>","groups":[
           {"name":"<placeholder>","buckets":[\(buckets.joined(separator: ","))]}]}}}
        """.utf8)
    }

    static func bucket(
        _ id: String, window: String? = nil, remaining: Double? = nil, reset: String? = nil
    ) -> String {
        var fields = [#""id":"\#(id)""#, #""name":"<placeholder>""#]
        if let window { fields.append(#""window":"\#(window)""#) }
        if let remaining { fields.append(#""remaining_fraction":\#(remaining)"#) }
        if let reset { fields.append(#""reset_time":"\#(reset)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }
}

/// A temp folder with a fake `agy` (a regular executable file the fake
/// runner never actually runs) and the probe's state file.
struct ProbeFixture {
    let root: URL
    var binary: URL { root.appending(path: "bin/agy") }
    var state: URL { root.appending(path: "support/\(AgentQuotaProbe.stateFileName)") }

    init(installBinary: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "quota-probe-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appending(path: "bin"), withIntermediateDirectories: true)
        if installBinary { try install(at: binary) }
    }

    func install(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: url.path, contents: Data("#!/bin/sh\nexit 99\n".utf8),
            attributes: [.posixPermissions: 0o755])
    }

    func tearDown() { try? FileManager.default.removeItem(at: root) }

    func command(candidates: [URL]? = nil) throws -> AgentQuotaCommand {
        try #require(AntigravityProvider(
            home: root.appending(path: "home"), userHome: root,
            agyCandidates: candidates ?? [binary]).quotaCommand)
    }

    func probe(
        runner: FakeAgentRunner, clock: TestClock, lastWrite: TestClock?,
        candidates: [URL]? = nil, hostEnvironment: [String: String] = ["HOME": "/Users/someone"]
    ) throws -> AgentQuotaProbe {
        AgentQuotaProbe(
            command: try command(candidates: candidates), runner: runner, stateURL: state,
            lastActivity: { _ in lastWrite?.now }, hostEnvironment: hostEnvironment,
            clock: { clock.now })
    }
}

@Suite("Quota probe schedule")
struct AgentQuotaScheduleTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let floor: TimeInterval = 600

    func due(
        lastAttempt: TimeInterval? = nil, failures: Int = 0, readingStarted: TimeInterval? = nil,
        lastWrite: TimeInterval? = -60, manual: Bool = false
    ) -> Bool {
        AgentQuotaSchedule.isDue(
            lastAttemptAt: lastAttempt.map { now.addingTimeInterval($0) },
            consecutiveFailures: failures,
            readingStartedAt: readingStarted.map { now.addingTimeInterval($0) },
            lastWrite: lastWrite.map { now.addingTimeInterval($0) }, now: now, floor: floor,
            manual: manual)
    }

    @Test("no conversation written: never due, so an idle Mac pays nothing")
    func noWrite() {
        #expect(!due(lastWrite: nil))
        #expect(!due(lastWrite: -8 * 86400))
        #expect(due(lastWrite: -6 * 86400))
    }

    @Test("due only when something was written since the last reading began")
    func writtenSince() {
        #expect(!due(lastAttempt: -3600, readingStarted: -3600, lastWrite: -3700))
        #expect(!due(lastAttempt: -3600, readingStarted: -3600, lastWrite: -3600))
        #expect(due(lastAttempt: -3600, readingStarted: -3600, lastWrite: -60))
    }

    @Test("the floor holds from the last attempt — ten minutes, never less")
    func floorHolds() {
        #expect(!due(lastAttempt: -300, readingStarted: -300))
        #expect(!due(lastAttempt: -575, readingStarted: -575))
        #expect(!due(lastAttempt: -599, readingStarted: -599))
        #expect(due(lastAttempt: -600, readingStarted: -600))
        // A clock that jumped back doesn't strand the probe.
        #expect(due(lastAttempt: 3600, readingStarted: -7200))
    }

    @Test("failures back off 20, 40, 80, then 120 minutes")
    func backoff() {
        let steps = (0...6).map {
            AgentQuotaSchedule.interval(consecutiveFailures: $0, floor: floor) / 60
        }
        #expect(steps == [10, 20, 40, 80, 120, 120, 120])
        #expect(!due(lastAttempt: -1000, failures: 1, readingStarted: -7200))
        // The slack lets a 5-minute poll land on a backoff step.
        #expect(due(lastAttempt: -1175, failures: 1, readingStarted: -7200))
        #expect(!due(lastAttempt: -7000, failures: 9, readingStarted: -90000))
        #expect(due(lastAttempt: -7200, failures: 9, readingStarted: -90000))
    }

    @Test("a manual refresh skips the failure backoff, never the floor")
    func manualSkipsBackoff() {
        #expect(!due(lastAttempt: -700, failures: 3, readingStarted: -7200))
        #expect(due(lastAttempt: -700, failures: 3, readingStarted: -7200, manual: true))
        #expect(!due(lastAttempt: -300, failures: 3, readingStarted: -7200, manual: true))
        // Nor the rule that something was written since the last reading.
        #expect(!due(lastAttempt: -700, failures: 3, readingStarted: -60, lastWrite: -120,
                     manual: true))
    }

    @Test("a provider can't ask more often than the hard floor")
    func minimumFloor() throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let command = try fixture.command()
        let quick = AgentQuotaCommand(
            executableCandidates: [], versionArguments: [], acceptsVersion: { _ in true },
            arguments: [], environment: [:], timeout: 1, floor: 5,
            reduce: { _, _, _, _ in .buckets([]) }, privacyLines: [])
        #expect(quick.floor == AgentQuotaCommand.minimumFloor)
        #expect(command.floor == 600)
    }
}

@Suite("Quota probe")
struct AgentQuotaProbeTests {
    let start = AntigravityQuotaFixture.capturedNow

    func realRunner() throws -> FakeAgentRunner {
        FakeAgentRunner(quota: .exited(stdout: try AntigravityQuotaFixture.real()))
    }

    @Test("a first run reads the buckets, keeps only numbers, and writes 0600")
    func firstRun() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let clock = TestClock(start)
        let probe = try fixture.probe(
            runner: runner, clock: clock, lastWrite: TestClock(start.addingTimeInterval(-120)))
        let status = await probe.refreshIfDue()
        #expect(status.failure == nil)
        let reading = try #require(status.reading)
        #expect(reading.buckets.map(\.id)
            == ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h", "gemini-argon-wtu-weekly"])
        #expect(reading.startedAt == start)
        #expect(await runner.versionRuns == 1)
        #expect(await runner.quotaRuns.count == 1)

        let text = try String(contentsOf: fixture.state, encoding: .utf8)
        #expect(!text.contains("placeholder"))
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.state.path)[
            .posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test("exactly the documented invocation, in a minimal environment")
    func invocation() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let probe = try fixture.probe(
            runner: runner, clock: TestClock(start), lastWrite: TestClock(start),
            hostEnvironment: [
                "HOME": "/Users/someone", "USER": "someone", "TMPDIR": "/tmp/x/",
                "SECRET_TOKEN": "nope", "PATH": "/opt/odd/bin", "AGY_ADC_AUTH": "1",
            ])
        _ = await probe.refreshIfDue()
        let run = try #require(await runner.quotaRuns.first)
        #expect(run.executable == fixture.binary)
        #expect(run.arguments == ["-p", "/quota", "--output-format", "json", "--log-file", "/dev/null"])
        #expect(run.environment == [
            "HOME": "/Users/someone", "USER": "someone", "TMPDIR": "/tmp/x/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "AGY_CLI_DISABLE_AUTO_UPDATE": "true",
        ])
        #expect(run.workingDirectory == "/")
        // A safety net against a hung run, not a budget — the version
        // check gets the same one (2026-11-22: 10 s was crossed by a
        // 0.1 s-of-CPU run on a saturated Mac).
        #expect(run.timeout == 120)
        #expect(await runner.invocations.map(\.timeout) == [120, 120])
    }

    @Test("the floor and the activity gate hold, across a restart too")
    func cadence() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let clock = TestClock(start)
        let write = TestClock(start.addingTimeInterval(-60))
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 1)

        // Inside the floor, even with a fresh write: nothing.
        clock.advance(300)
        write.set(clock.now)
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 1)
        // Past it: a run.
        clock.advance(300)
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 2)
        // Past the floor but nothing written since: nothing.
        clock.advance(3600)
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 2)

        // A new host (restart, handover) reads the attempt back and waits.
        write.set(clock.now)
        clock.advance(60)
        let attemptAt = clock.now
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 3)
        clock.set(attemptAt.addingTimeInterval(120))
        let reborn = try fixture.probe(runner: runner, clock: clock, lastWrite: TestClock(clock.now))
        let restored = await reborn.status
        #expect(restored.reading?.buckets.count == 5)
        _ = await reborn.refreshIfDue()
        #expect(await runner.quotaRuns.count == 3)
        // The version verdict was remembered: one check for the one binary.
        #expect(await runner.versionRuns == 1)
    }

    @Test("callers during a run share it: one spawn, one outcome")
    func singleFlight() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        await runner.set(delay: .milliseconds(300))
        let probe = try fixture.probe(runner: runner, clock: TestClock(start), lastWrite: TestClock(start))
        let statuses = await withTaskGroup(of: AgentQuotaProbe.Status.self) { group in
            for _ in 0..<6 { group.addTask { await probe.refreshIfDue() } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(await runner.quotaRuns.count == 1)
        #expect(statuses.count == 6)
        #expect(statuses.allSatisfy { $0.reading?.buckets.count == 5 })
    }

    @Test("real failures are kept, back off, and clear on the next success")
    func failures() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = FakeAgentRunner(
            quota: .exited(1, stdout: Data(), stderr: "You are not logged into Antigravity."))
        let clock = TestClock(start)
        let write = TestClock(start)
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        #expect(await probe.refreshIfDue().failure == .notSignedIn)
        // The 10-minute floor isn't enough after a real failure: 20 minutes.
        clock.advance(700)
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 1)
        clock.advance(600)
        await runner.set(quota: .exited(stdout: Data("not json".utf8)))
        #expect(await probe.refreshIfDue().failure == .unreadable)
        #expect(await runner.quotaRuns.count == 2)
        // Two in a row: 40 minutes.
        clock.advance(1800)
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 2)
        clock.advance(600)
        await runner.set(quota: .exited(stdout: try AntigravityQuotaFixture.real()))
        let recovered = await probe.refreshIfDue()
        #expect(recovered.failure == nil)
        #expect(recovered.reading != nil)
        #expect(await runner.quotaRuns.count == 3)
        #expect(AgentQuotaProbeState.load(from: fixture.state)?.consecutiveFailures == 0)
    }

    @Test("a timeout is transient: shown, retried at the floor, never escalating")
    func timeoutRetriesAtFloor() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = FakeAgentRunner(quota: AgentCommandResult(
            termination: .timedOut, stdout: Data(), stderr: Data(), duration: 120))
        let clock = TestClock(start)
        let write = TestClock(start)
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        for attempt in 1...4 {
            #expect(await probe.refreshIfDue().failure == .timedOut)
            #expect(await runner.quotaRuns.count == attempt)
            #expect(AgentQuotaProbeState.load(from: fixture.state)?.consecutiveFailures == 0)
            // Inside the floor: nothing, timeouts or not.
            clock.advance(540)
            write.set(clock.now)
            _ = await probe.refreshIfDue()
            #expect(await runner.quotaRuns.count == attempt)
            // At the floor: the next try — never the doubled wait.
            clock.advance(60)
        }
        // A timeout then a success: the reading lands and the failure clears.
        await runner.set(quota: .exited(stdout: try AntigravityQuotaFixture.real()))
        let status = await probe.refreshIfDue()
        #expect(status.failure == nil)
        #expect(status.reading?.buckets.count == 5)
    }

    @Test("a timeout between real failures neither escalates nor forgives their backoff")
    func timeoutBetweenFailures() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = FakeAgentRunner(
            quota: .exited(1, stdout: Data(), stderr: "You are not logged into Antigravity."))
        let clock = TestClock(start)
        let write = TestClock(start)
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        #expect(await probe.refreshIfDue().failure == .notSignedIn)
        // One real failure: the next try is due at 20 minutes.
        clock.advance(1200)
        await runner.set(quota: AgentCommandResult(
            termination: .timedOut, stdout: Data(), stderr: Data(), duration: 120))
        #expect(await probe.refreshIfDue().failure == .timedOut)
        #expect(AgentQuotaProbeState.load(from: fixture.state)?.consecutiveFailures == 1)
        // Still one real failure's wait (20 min), not the floor and not 40.
        clock.advance(900)
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 2)
        clock.advance(300)
        await runner.set(
            quota: .exited(1, stdout: Data(), stderr: "You are not logged into Antigravity."))
        #expect(await probe.refreshIfDue().failure == .notSignedIn)
        #expect(await runner.quotaRuns.count == 3)
        // The second REAL failure doubles from where real failures left it.
        #expect(AgentQuotaProbeState.load(from: fixture.state)?.consecutiveFailures == 2)
        clock.advance(2100)
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 3)
        clock.advance(300)
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 4)
    }

    @Test("two hours of polls on a Mac where every run times out: never inside the floor")
    func floorUnderTimeouts() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = FakeAgentRunner(quota: AgentCommandResult(
            termination: .timedOut, stdout: Data(), stderr: Data(), duration: 120))
        let clock = TestClock(start)
        let write = TestClock(start)
        let starts = Mutex<[Date]>([])
        await runner.set { invocation in
            if invocation.arguments != ["--version"] { starts.withLock { $0.append(clock.now) } }
        }
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        // A poll every minute, the agent writing all along, and the person
        // clicking refresh every third minute.
        for minute in 0..<120 {
            write.set(clock.now)
            _ = await probe.refreshIfDue(manual: minute % 3 == 0)
            clock.advance(60)
        }
        let attempts = starts.withLock { $0 }
        #expect(attempts.count == 12)
        for (earlier, later) in zip(attempts, attempts.dropFirst()) {
            #expect(later.timeIntervalSince(earlier) >= AgentQuotaCommand.minimumFloor)
        }
    }

    @Test("each failure kind reads as text, never as a network error")
    func failureText() {
        let agent = "Antigravity CLI"
        #expect(UsageError(quotaFailure: .notSignedIn) == .noCredentials)
        for failure in [AgentQuotaFailure.timedOut, .unreadable, .failed] {
            let error = UsageError(quotaFailure: failure)
            #expect(error != .network)
            #expect(!error.shortText(agent: agent).isEmpty)
            #expect(error.hint(agent: agent)?.isEmpty == false)
        }
        // Waiting and retrying — a busy Mac — never a broken harness.
        #expect(UsageError(quotaFailure: .timedOut).shortText(agent: agent)
            == "Antigravity CLI was slow to answer — asking again soon")
        #expect(UsageError(quotaFailure: .timedOut).hint(agent: agent)?.contains("busy Mac") == true)
    }

    @Test("no CLI installed: a quiet absence — no run, no error, no attempt")
    func missingBinary() async throws {
        let fixture = try ProbeFixture(installBinary: false)
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let probe = try fixture.probe(runner: runner, clock: TestClock(start), lastWrite: TestClock(start))
        let status = await probe.refreshIfDue()
        #expect(status == AgentQuotaProbe.Status(reading: nil, failure: nil))
        #expect(await runner.invocations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
        // Installed later: the next due refresh finds it.
        try fixture.install(at: fixture.binary)
        #expect(await probe.refreshIfDue().reading != nil)
    }

    @Test("an answer that wasn't the limits command: that binary is never asked again")
    func refusedBinary() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let turn = #"{"status":"SUCCESS","conversation_id":"c-1","num_turns":1,"response":"…"}"#
        await runner.set(quota: .exited(stdout: Data(turn.utf8)))
        let clock = TestClock(start)
        let write = TestClock(start)
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        #expect(await probe.refreshIfDue().failure == .notALimitsCommand)
        // The turn's own conversation keeps the schedule due — and still,
        // nothing more runs, however long it goes on.
        for _ in 0..<6 {
            clock.advance(3 * 3600)
            write.set(clock.now)
            #expect(await probe.refreshIfDue().failure == .notALimitsCommand)
        }
        #expect(await runner.quotaRuns.count == 1)
        // A restart remembers it.
        let again = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        clock.advance(3 * 3600)
        write.set(clock.now)
        _ = await again.refreshIfDue()
        #expect(await runner.quotaRuns.count == 1)
        // The CLI updated (the file changed): asked once more.
        FileManager.default.createFile(
            atPath: fixture.binary.path, contents: Data("#!/bin/sh\nexit 98 # v2\n".utf8),
            attributes: [.posixPermissions: 0o755])
        await runner.set(quota: .exited(stdout: AntigravityQuotaFixture.output([
            AntigravityQuotaFixture.bucket("gemini-weekly", window: "weekly", remaining: 0.5),
        ])))
        clock.advance(3 * 3600)
        write.set(clock.now)
        let status = await again.refreshIfDue()
        #expect(await runner.quotaRuns.count == 2)
        #expect(status.failure == nil && status.reading != nil)
    }

    @Test("a version run that finished with an error settles it: quiet, and never re-run")
    func failedVersionSettles() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        await runner.set(version: .exited(2, stdout: Data(), stderr: "usage: agy <file>"))
        let clock = TestClock(start)
        let write = TestClock(start)
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        #expect(await probe.refreshIfDue() == AgentQuotaProbe.Status(reading: nil, failure: nil))
        for _ in 0..<3 {
            clock.advance(3 * 3600)
            write.set(clock.now)
            _ = await probe.refreshIfDue()
        }
        #expect(await runner.versionRuns == 1)
        #expect(await runner.quotaRuns.isEmpty)
    }

    @Test("the attempt is on disk before the first spawn, version check included")
    func stampedBeforeSpawn() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let stateURL = fixture.state
        let seen = Mutex<[Bool]>([])
        await runner.set { _ in
            let stamped = AgentQuotaProbeState.load(from: stateURL)?.lastAttemptAt != nil
            seen.withLock { $0.append(stamped) }
        }
        let probe = try fixture.probe(
            runner: runner, clock: TestClock(start), lastWrite: TestClock(start))
        _ = await probe.refreshIfDue()
        #expect(seen.withLock { $0 } == [true, true])
    }

    @Test("the CLI gone: the failure it left clears; an old failure stops speaking")
    func failureClears() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        await runner.set(quota: AgentCommandResult(
            termination: .timedOut, stdout: Data(), stderr: Data(), duration: 30))
        let clock = TestClock(start)
        let write = TestClock(start)
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        #expect(await probe.refreshIfDue().failure == .timedOut)
        try FileManager.default.removeItem(at: fixture.binary)
        clock.advance(3 * 3600)
        write.set(clock.now)
        #expect(await probe.refreshIfDue().failure == nil)

        // A failure left standing while the agent goes unused for a week no
        // longer speaks for the present.
        try fixture.install(at: fixture.binary)
        clock.advance(3 * 3600)
        write.set(clock.now)
        #expect(await probe.refreshIfDue().failure == .timedOut)
        clock.advance(8 * 86400)
        #expect(await probe.status.failure == nil)
    }

    @Test("two hosts on one state file: the floor holds across the handover")
    func handover() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let clock = TestClock(start)
        let write = TestClock(start)
        // Both built before either ran — as an app and a daemon would be.
        let app = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        let daemon = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        #expect(await app.refreshIfDue().reading != nil)
        clock.advance(120)
        write.set(clock.now)
        let status = await daemon.refreshIfDue()
        #expect(await runner.quotaRuns.count == 1)
        #expect(status.reading != nil) // the app's reading, read from disk
    }

    @Test("a retired probe neither runs nor writes")
    func retired() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let probe = try fixture.probe(
            runner: runner, clock: TestClock(start), lastWrite: TestClock(start))
        probe.retire()
        _ = await probe.refreshIfDue()
        #expect(await runner.invocations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.state.path))
    }

    @Test("a version run that doesn't finish is an attempt: the floor holds, it shows, it's retried at the floor")
    func unsettledVersion() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        await runner.set(version: AgentCommandResult(
            termination: .timedOut, stdout: Data(), stderr: Data(), duration: 120))
        let clock = TestClock(start)
        let write = TestClock(start)
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        #expect(await probe.refreshIfDue().failure == .timedOut)
        #expect(await runner.versionRuns == 1)
        #expect(await runner.quotaRuns.isEmpty)
        // The verdict isn't remembered — a busy Mac says nothing about the file.
        #expect(AgentQuotaProbeState.load(from: fixture.state)?.binaries.isEmpty == true)
        // Every poll inside the floor: no new spawn.
        for _ in 0..<9 {
            clock.advance(60)
            write.set(clock.now)
            _ = await probe.refreshIfDue()
        }
        #expect(await runner.versionRuns == 1)
        // At the floor (not a doubled backoff), the check runs again, and a
        // good answer clears the failure and reads the limits.
        await runner.set(version: .exited(stdout: Data("1.5.14\n".utf8)))
        clock.advance(60)
        write.set(clock.now)
        let status = await probe.refreshIfDue()
        #expect(await runner.versionRuns == 2)
        #expect(status.failure == nil && status.reading != nil)
    }

    @Test("a slow version run and a slow /quota run both finish: the kill is only a safety net")
    func slowRunsFinish() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        // What a saturated Mac measured for a utility-clamped child, as the
        // runner reports it: well past the old 10 s and toward the old 30 s.
        await runner.set(version: AgentCommandResult(
            termination: .exited(0), stdout: Data("1.5.14\n".utf8), stderr: Data(), duration: 11.8))
        await runner.set(quota: AgentCommandResult(
            termination: .exited(0), stdout: try AntigravityQuotaFixture.real(), stderr: Data(),
            duration: 14.3))
        let probe = try fixture.probe(runner: runner, clock: TestClock(start), lastWrite: TestClock(start))
        let status = await probe.refreshIfDue()
        #expect(status.failure == nil)
        #expect(status.reading?.buckets.count == 5)
        let timeouts = await runner.invocations.map(\.timeout)
        #expect(timeouts.allSatisfy { $0 == 120 })
        #expect(timeouts.count == 2)
    }

    /// 2026-11-22: builds before this one counted every timeout as a
    /// failure, so a busy Mac's state file can carry a two-hour backoff of
    /// timeouts. Read by this build, that count is forgiven once — the floor
    /// still holds — and every save marks the file as counted this way.
    @Test("an older build's timeout-inflated backoff is forgiven on upgrade, never the floor")
    func upgradeForgivesTimeouts() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        func seed(failures: Int, lastFailure: AgentQuotaFailure, ago: TimeInterval, marked: Bool) throws {
            var old = AgentQuotaProbeState()
            old.lastAttemptAt = start.addingTimeInterval(-ago)
            old.consecutiveFailures = failures
            old.lastFailure = lastFailure
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var object = try #require(JSONSerialization.jsonObject(
                with: encoder.encode(old)) as? [String: Any])
            if marked { object["timeoutsTransient"] = true } else { object.removeValue(forKey: "timeoutsTransient") }
            try FileManager.default.createDirectory(
                at: fixture.state.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object).write(to: fixture.state)
        }
        // An older build's file: four "failures", all timeouts.
        try seed(failures: 4, lastFailure: .timedOut, ago: 300, marked: false)
        #expect(AgentQuotaProbeState.load(from: fixture.state)?.consecutiveFailures == 0)
        let runner = try realRunner()
        let clock = TestClock(start)
        let write = TestClock(start)
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        // Inside the floor: still nothing.
        _ = await probe.refreshIfDue()
        #expect(await runner.invocations.isEmpty)
        // At the floor — not two hours later — it runs, and the save marks the file.
        clock.advance(300)
        #expect(await probe.refreshIfDue().reading != nil)
        let text = try String(contentsOf: fixture.state, encoding: .utf8)
        #expect(text.contains("\"timeoutsTransient\":true"))

        // This build's own count after real failures is kept, timeout last or not.
        try seed(failures: 2, lastFailure: .timedOut, ago: 700, marked: true)
        #expect(AgentQuotaProbeState.load(from: fixture.state)?.consecutiveFailures == 2)
        // An older build's real failure is kept too.
        try seed(failures: 3, lastFailure: .notSignedIn, ago: 700, marked: false)
        #expect(AgentQuotaProbeState.load(from: fixture.state)?.consecutiveFailures == 3)
    }

    @Test("retired during the version check: no limits run, nothing written after")
    func retiredDuringVersion() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let probe = try fixture.probe(runner: runner, clock: TestClock(start), lastWrite: TestClock(start))
        await runner.set { invocation in
            if invocation.arguments == ["--version"] { probe.retire() }
        }
        let status = await probe.refreshIfDue()
        #expect(await runner.versionRuns == 1)
        #expect(await runner.quotaRuns.isEmpty)
        #expect(status.reading == nil && status.failure == nil)
        // The attempt was stamped before the spawn; the verdict after it wasn't.
        let state = try #require(AgentQuotaProbeState.load(from: fixture.state))
        #expect(state.lastAttemptAt == start)
        #expect(state.binaries.isEmpty)
    }

    @Test("retired during the limits run: its result is dropped, in memory and on disk")
    func retiredDuringQuota() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let probe = try fixture.probe(runner: runner, clock: TestClock(start), lastWrite: TestClock(start))
        await runner.set { invocation in
            if invocation.arguments != ["--version"] { probe.retire() }
        }
        let status = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 1)
        #expect(status.reading == nil)
        #expect(AgentQuotaProbeState.load(from: fixture.state)?.reading == nil)
    }

    @Test("a slow version check can't bring two limits runs closer than the floor")
    func floorPerLimitsRun() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = try realRunner()
        let clock = TestClock(start)
        let write = TestClock(start)
        let quotaStarts = Mutex<[Date]>([])
        // The version check takes 100 s (a cold start on a saturated Mac).
        await runner.set { invocation in
            if invocation.arguments == ["--version"] {
                clock.advance(100)
            } else {
                quotaStarts.withLock { $0.append(clock.now) }
            }
        }
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        let first = await probe.refreshIfDue()
        #expect(first.reading?.startedAt == start.addingTimeInterval(100))
        #expect(AgentQuotaProbeState.load(from: fixture.state)?.lastAttemptAt
            == start.addingTimeInterval(100))
        // 600 s after the attempt began, but only 550 after the limits run: not yet.
        clock.set(start.addingTimeInterval(650))
        write.set(clock.now)
        _ = await probe.refreshIfDue()
        #expect(quotaStarts.withLock { $0.count } == 1)
        clock.set(start.addingTimeInterval(700))
        write.set(clock.now)
        _ = await probe.refreshIfDue()
        let starts = quotaStarts.withLock { $0 }
        #expect(starts.count == 2)
        #expect(starts[1].timeIntervalSince(starts[0]) >= AgentQuotaCommand.minimumFloor)
    }

    @Test("a same-named program that isn't the CLI is never asked for quota")
    func wrongBinary() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        // The desktop editor's launcher lives inside an app bundle…
        let bundled = fixture.root.appending(path: "Antigravity.app/Contents/Resources/bin/agy")
        try fixture.install(at: bundled)
        let link = fixture.root.appending(path: "launcher/agy")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundled)
        let runner = try realRunner()
        // …and an editor-style `--version` prints three lines.
        await runner.set(version: .exited(stdout: Data("1.107.0\nabc123\narm64\n".utf8)))
        let clock = TestClock(start)
        let write = TestClock(start)
        let probe = try fixture.probe(
            runner: runner, clock: clock, lastWrite: write, candidates: [link, fixture.binary])
        let status = await probe.refreshIfDue()
        #expect(status.reading == nil && status.failure == nil)
        #expect(await runner.quotaRuns.isEmpty)
        // The bundled link was never even version-checked; the plain one was
        // checked once and its verdict kept.
        #expect(await runner.invocations.map(\.executable) == [fixture.binary])
        clock.advance(3600)
        write.set(clock.now)
        _ = await probe.refreshIfDue()
        #expect(await runner.invocations.count == 1)

        #expect(AntigravityQuota.acceptsVersion(Data("1.5.14\n".utf8)))
        #expect(AntigravityQuota.acceptsVersion(Data("2.0\n".utf8)))
        #expect(AntigravityQuota.acceptsVersion(Data("agy v1.6.0-beta.2\n".utf8)))
        #expect(AntigravityQuota.acceptsVersion(Data("1.6.0+build.7\n".utf8)))
        #expect(!AntigravityQuota.acceptsVersion(Data("Antigravity CLI is starting…\n".utf8)))
        #expect(!AntigravityQuota.acceptsVersion(Data("1.107.0\nabc\narm64\n".utf8)))
        #expect(!AntigravityQuota.acceptsVersion(Data("agy version 1.5.14\n".utf8)))
        #expect(!AntigravityQuota.acceptsVersion(Data()))
    }
}

@Suite("Quota probe in the service")
struct AgentQuotaServiceTests {
    func service(
        fixture: AntigravityFixture, probeFixture: ProbeFixture, runner: FakeAgentRunner,
        now: Date
    ) throws -> UsageService {
        let provider = AntigravityProvider(
            home: fixture.home, userHome: fixture.root, agyCandidates: [probeFixture.binary])
        let probe = AgentQuotaProbe(
            command: try #require(provider.quotaCommand), runner: runner,
            stateURL: probeFixture.state, lastActivity: { _ in now }, clock: { now })
        return UsageService(
            provider: provider, cache: UsageCache(directory: fixture.root.appending(path: "c")),
            retryDelay: .zero, probe: probe)
    }

    @Test("a reading lands as live meters; a failure keeps a snapshot with the reason")
    func states() async throws {
        let fixture = try AntigravityFixture()
        let probeFixture = try ProbeFixture()
        defer { fixture.tearDown(); probeFixture.tearDown() }
        let now = Date()
        try fixture.conversation(rows: [
            AntigravityFixture.call(at: now.addingTimeInterval(-60), input: 1, output: 1),
        ])
        let reset = AntigravityFixture.stamp(now.addingTimeInterval(3600))
        let good = FakeAgentRunner(quota: .exited(stdout: AntigravityQuotaFixture.output([
            AntigravityQuotaFixture.bucket("gemini-5h", window: "5h", remaining: 0.6, reset: reset),
        ])))
        let live = try await service(
            fixture: fixture, probeFixture: probeFixture, runner: good, now: now).refresh()
        guard case .live(let snapshot) = live else {
            Issue.record("expected live, got \(live)")
            return
        }
        #expect(snapshot.meters.map(\.percent) == [40])

        // A fresh state, and a CLI that times out before any reading: the
        // state still carries a (meterless) snapshot, so focus sees one.
        let otherProbe = try ProbeFixture()
        defer { otherProbe.tearDown() }
        let slow = FakeAgentRunner(quota: AgentCommandResult(
            termination: .timedOut, stdout: Data(), stderr: Data(), duration: 30))
        let failed = try await service(
            fixture: fixture, probeFixture: otherProbe, runner: slow, now: now).refresh()
        guard case .cached(let empty, let error) = failed else {
            Issue.record("expected cached, got \(failed)")
            return
        }
        #expect(empty.meters.isEmpty)
        #expect(error == .agentTimedOut)
    }

    @Test("only a host given a runner builds a probe, and only for a provider with a command")
    func hostOptIn() throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let antigravity = AntigravityProvider(
            home: fixture.root, userHome: fixture.root, agyCandidates: [fixture.binary])
        let runner = FakeAgentRunner(quota: .exited(stdout: Data()))
        #expect(UsageEngine.quotaProbe(
            provider: antigravity, runner: nil, directory: fixture.root, activity: nil) == nil)
        #expect(UsageEngine.quotaProbe(
            provider: CodexProvider(sessionsRoot: fixture.root), runner: runner,
            directory: fixture.root, activity: nil) == nil)
        #expect(UsageEngine.quotaProbe(
            provider: antigravity, runner: runner, directory: fixture.root, activity: nil) != nil)
        #expect(MeteringHost.Configuration(bundleID: "x", kind: .daemon).agentCommandRunner == nil)
    }
}

@Suite("Digest error codes")
struct DigestErrorCodeTests {
    /// A client face rebuilds its error from the digest's code: every case
    /// the host writes must come back as itself, not as a network error.
    @Test("every error the host writes reads back as itself")
    func roundTrip() {
        let every: [UsageError] = [
            .noCredentials, .keychainDenied, .credentialsUnreadable, .signInExpired,
            .rateLimited(retryAfter: nil), .http(502), .network, .schema, .noLocalData,
            .agentTimedOut, .agentOutputUnreadable, .agentCommandFailed,
        ]
        for error in every {
            let (code, status) = LiveStateBuilder.errorCode(error)
            #expect(LiveStateBuilder.usageError(code: code, httpStatus: status) == error)
        }
        #expect(LiveStateBuilder.usageError(code: "fromTheFuture", httpStatus: nil) == .network)
    }
}
