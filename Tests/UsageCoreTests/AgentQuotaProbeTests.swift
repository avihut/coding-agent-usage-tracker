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
    private(set) var invocations: [AgentCommandInvocation] = []

    init(quota: AgentCommandResult) { self.quota = quota }

    func run(_ invocation: AgentCommandInvocation) async -> AgentCommandResult {
        invocations.append(invocation)
        if invocation.arguments == ["--version"] { return version }
        if delay > .zero { try? await Task.sleep(for: delay) }
        return quota
    }

    var quotaRuns: [AgentCommandInvocation] { invocations.filter { $0.arguments != ["--version"] } }
    var versionRuns: Int { invocations.count - quotaRuns.count }
    func set(quota: AgentCommandResult) { self.quota = quota }
    func set(version: AgentCommandResult) { self.version = version }
    func set(delay: Duration) { self.delay = delay }
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
        lastWrite: TimeInterval? = -60
    ) -> Bool {
        AgentQuotaSchedule.isDue(
            lastAttemptAt: lastAttempt.map { now.addingTimeInterval($0) },
            consecutiveFailures: failures,
            readingStartedAt: readingStarted.map { now.addingTimeInterval($0) },
            lastWrite: lastWrite.map { now.addingTimeInterval($0) }, now: now, floor: floor)
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

    @Test("the floor holds from the last attempt, with slack for a 5-minute poll")
    func floorHolds() {
        #expect(!due(lastAttempt: -300, readingStarted: -300))
        #expect(!due(lastAttempt: -560, readingStarted: -560))
        #expect(due(lastAttempt: -575, readingStarted: -575))
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
        #expect(due(lastAttempt: -1200, failures: 1, readingStarted: -7200))
        #expect(!due(lastAttempt: -7000, failures: 9, readingStarted: -90000))
        #expect(due(lastAttempt: -7200, failures: 9, readingStarted: -90000))
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
        #expect(run.timeout == 30)
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

    @Test("failures are kept, back off, and clear on the next success")
    func failures() async throws {
        let fixture = try ProbeFixture()
        defer { fixture.tearDown() }
        let runner = FakeAgentRunner(quota: AgentCommandResult(
            termination: .timedOut, stdout: Data(), stderr: Data(), duration: 30))
        let clock = TestClock(start)
        let write = TestClock(start)
        let probe = try fixture.probe(runner: runner, clock: clock, lastWrite: write)
        #expect(await probe.refreshIfDue().failure == .timedOut)
        // The 10-minute floor isn't enough after a failure: 20 minutes.
        clock.advance(700)
        _ = await probe.refreshIfDue()
        #expect(await runner.quotaRuns.count == 1)
        clock.advance(600)
        await runner.set(quota: .exited(1, stdout: Data(), stderr: "You are not logged into Antigravity."))
        #expect(await probe.refreshIfDue().failure == .notSignedIn)
        #expect(await runner.quotaRuns.count == 2)
        clock.advance(2400)
        await runner.set(quota: .exited(stdout: try AntigravityQuotaFixture.real()))
        let recovered = await probe.refreshIfDue()
        #expect(recovered.failure == nil)
        #expect(recovered.reading != nil)
        #expect(await runner.quotaRuns.count == 3)
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
        #expect(UsageError(quotaFailure: .timedOut).shortText(agent: agent)
            == "Antigravity CLI didn't answer — limits not refreshed")
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
