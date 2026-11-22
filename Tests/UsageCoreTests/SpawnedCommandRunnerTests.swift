import Darwin
import Foundation
import Testing

@testable import UsageCore

/// The real runner, against system binaries only (`/bin/sh`, `/bin/sleep`,
/// `/usr/bin/env`) — never an agent's CLI.
@Suite("Spawned command runner")
struct SpawnedCommandRunnerTests {
    let runner = SpawnedCommandRunner()

    func sh(
        _ script: String, timeout: TimeInterval = 10, environment: [String: String] = [:],
        cwd: String = "/", stdoutCap: Int = 256 * 1024
    ) async -> AgentCommandResult {
        await runner.run(AgentCommandInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: environment, workingDirectory: cwd, timeout: timeout,
            stdoutCap: stdoutCap))
    }

    func text(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? "" }

    @Test("output, errors and the exit status come back as they were")
    func basics() async {
        let result = await sh("echo out; echo err >&2; exit 3")
        #expect(result.termination == .exited(3))
        #expect(text(result.stdout) == "out\n")
        #expect(text(result.stderr) == "err\n")
    }

    @Test("the child gets exactly the environment and folder it was given")
    func isolation() async throws {
        let env = await runner.run(AgentCommandInvocation(
            executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
            environment: ["ONLY": "this"], timeout: 10))
        #expect(text(env.stdout) == "ONLY=this\n")
        let pwd = await sh("/bin/pwd", cwd: "/usr/bin")
        #expect(text(pwd.stdout) == "/usr/bin\n")
        let root = await sh("/bin/pwd")
        #expect(text(root.stdout) == "/\n")
    }

    @Test("stdin is /dev/null, and no other descriptor of ours reaches the child")
    func descriptors() async throws {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "fd-probe-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Deliberately without O_CLOEXEC, and well clear of 0–3 (ls itself
        // opens fd 3 to read the listing).
        let raw = open(path, O_RDONLY)
        let fd = dup2(raw, 77)
        close(raw)
        try #require(fd == 77)
        defer { close(fd) }
        let result = await sh("ls /dev/fd; read line && echo got-input")
        let listed = Set(text(result.stdout).split(separator: "\n").map(String.init))
        #expect(!listed.contains(String(fd)))
        #expect(listed.isSuperset(of: ["0", "1", "2"]))
        #expect(!listed.contains("got-input"))
    }

    /// 2026-11-22: a utility clamp (priority 20) starved the quota probe's
    /// CLI past its timeout on a saturated Mac. The child runs unclamped —
    /// at whatever priority any child of this process gets. Judged against
    /// a baseline child spawned without the runner, because a clamp on the
    /// test process itself (`taskpolicy -c utility`, `-b`) reaches every
    /// child whatever the runner does.
    @Test("the child runs as any child of the host would — never below it")
    func unclamped() async throws {
        let script = "/bin/ps -o pri= -p $$"
        let baseline = Process()
        baseline.executableURL = URL(fileURLWithPath: "/bin/sh")
        baseline.arguments = ["-c", script]
        let pipe = Pipe()
        baseline.standardOutput = pipe
        try baseline.run()
        baseline.waitUntilExit()
        let host = try #require(Int(text(pipe.fileHandleForReading.readDataToEndOfFile())
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let result = await sh(script)
        let child = try #require(Int(text(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(child >= host)
        // An unclamped host's children run above utility's 20.
        if host > 20 { #expect(child > 20) }
    }

    @Test("a timeout terminates the whole process group, and reaps it")
    func timeout() async throws {
        let result = await sh("/bin/sleep 30 & echo $!; wait", timeout: 0.5)
        #expect(result.termination == .timedOut)
        #expect(result.duration < 5)
        let grandchild = try #require(pid_t(text(result.stdout).trimmingCharacters(in: .newlines)))
        // Gone (or a zombie on its way out) once launchd reaps it.
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(grandchild, 0) != 0
            if !gone { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(gone)
    }

    @Test("a grandchild holding stdout open can't stall the result, nor outlive the run")
    func grandchildHoldsOutput() async throws {
        let result = await sh("/bin/sleep 30 & echo $!", timeout: 20)
        #expect(result.termination == .exited(0))
        #expect(result.duration < 5)
        let leftover = try #require(pid_t(text(result.stdout).trimmingCharacters(in: .newlines)))
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(leftover, 0) != 0
            if !gone { try await Task.sleep(for: .milliseconds(50)) }
        }
        if !gone { kill(leftover, SIGKILL) }
        #expect(gone)
    }

    @Test("a clean exit's status survives the group kill")
    func cleanExitStatus() async {
        let result = await sh("exit 3", timeout: 5)
        #expect(result.termination == .exited(3))
    }

    @Test("output past its cap is a failure, and stops the run")
    func overflow() async {
        let result = await runner.run(AgentCommandInvocation(
            executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [],
            environment: [:], timeout: 10, stdoutCap: 1000))
        #expect(result.termination == .outputOverflow)
        #expect(result.duration < 5)
    }

    @Test("a missing executable is a launch failure, not a crash")
    func missing() async {
        let result = await runner.run(AgentCommandInvocation(
            executable: URL(fileURLWithPath: "/nonexistent/agy"), arguments: [],
            environment: [:], timeout: 10))
        #expect(result.termination == .launchFailed(ENOENT))
    }

    @Test("a child killed by a signal says so")
    func signaled() async {
        let result = await sh("kill -9 $$")
        #expect(result.termination == .signaled(SIGKILL))
    }
}
