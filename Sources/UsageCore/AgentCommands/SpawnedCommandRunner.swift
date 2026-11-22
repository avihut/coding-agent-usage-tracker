import Darwin
import Foundation

/// The real runner: `posix_spawn`, because `Process` can't promise what the
/// quota probe needs (spec §10 amendment 2026-11-21, second).
///
/// - `POSIX_SPAWN_CLOEXEC_DEFAULT`: the child gets stdin (`/dev/null`) and
///   two pipes, nothing else — never the host's `engine.lock` descriptor
///   (a long-lived grandchild holding it would wedge the lease) or its
///   control socket.
/// - Its own process group, so a timeout reaches whatever it started.
/// - Default signal dispositions and an empty mask (a host that ignores
///   SIGPIPE mustn't hand that on), and NO QoS clamp: the child runs at
///   default priority, like the agents (`EngineWork.agentCommandQoS` —
///   a utility clamp pushed a 0.1 s run past 10 s on a saturated Mac,
///   2026-11-22). A host under the darwin background policy hands that on
///   regardless (priority 4: 215 s for a cold start), which is one more
///   reason no host may run Background (docs/DAEMON.md "Under load").
/// - The run is over when the CHILD EXITS, never at pipe EOF: a grandchild
///   holding stdout open gets a short drain. Then, on EVERY path, whatever
///   is left in the group is killed: the exit is observed without reaping
///   (`WNOWAIT`), so the group id can't be reused before the kill, and the
///   child is reaped after it. A tool that means to outlive the run
///   detaches into its own session and is out of reach by design.
public struct SpawnedCommandRunner: AgentCommandRunner {
    /// SIGTERM to SIGKILL, on a timeout.
    public static let terminateGrace: TimeInterval = 2
    /// How long output is still collected after the child exits.
    public static let drainAfterExit: TimeInterval = 1

    public init() {}

    public func run(_ invocation: AgentCommandInvocation) async -> AgentCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: EngineWork.agentCommandQoS.qosClass).async {
                continuation.resume(returning: Self.runBlocking(invocation))
            }
        }
    }

    private static func monotonic() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func runBlocking(_ invocation: AgentCommandInvocation) -> AgentCommandResult {
        let start = monotonic()
        func result(_ termination: AgentCommandResult.Termination, _ out: Data = Data(),
                    _ err: Data = Data()) -> AgentCommandResult {
            AgentCommandResult(
                termination: termination, stdout: out, stderr: err,
                duration: monotonic() - start)
        }

        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { return result(.launchFailed(errno)) }
        guard pipe(&errPipe) == 0 else {
            let code = errno
            close(outPipe[0]); close(outPipe[1])
            return result(.launchFailed(code))
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, invocation.workingDirectory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        var noSignal = sigset_t()
        sigemptyset(&noSignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        // No QoS attribute, on purpose (`EngineWork.agentCommandQoS`).

        let path = invocation.executable.path
        let argv: [UnsafeMutablePointer<CChar>?] =
            ([path] + invocation.arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] =
            invocation.environment.sorted { $0.key < $1.key }
                .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        guard spawned == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return result(.launchFailed(spawned))
        }

        var streams = [
            Stream(fd: outPipe[0], cap: invocation.stdoutCap),
            Stream(fd: errPipe[0], cap: invocation.stderrCap),
        ]
        for stream in streams { _ = fcntl(stream.fd, F_SETFL, O_NONBLOCK) }
        defer { for stream in streams where stream.open { close(stream.fd) } }

        let deadline = start + invocation.timeout
        var status: Int32 = 0
        var exitedAt: TimeInterval?
        var forced: AgentCommandResult.Termination?

        while true {
            if exitedAt == nil, hasExited(pid) {
                exitedAt = monotonic()
            }
            let now = monotonic()
            if let exitedAt {
                if streams.allSatisfy({ !$0.open }) || now >= exitedAt + drainAfterExit { break }
            } else if now >= deadline {
                stopGroup(pid)
                forced = .timedOut
                break
            }
            var polls = streams.filter(\.open).map {
                pollfd(fd: $0.fd, events: Int16(POLLIN), revents: 0)
            }
            if polls.isEmpty {
                usleep(20_000)
                continue
            }
            _ = poll(&polls, nfds_t(polls.count), 50)
            for index in streams.indices where streams[index].open {
                streams[index].drain()
            }
            if streams.contains(where: \.overflowed) {
                stopGroup(pid)
                forced = .outputOverflow
                break
            }
        }
        // The child is a zombie or about to be: nothing of its group may
        // outlive the run. Then reap, which frees the pid and group id.
        kill(-pid, SIGKILL)
        while waitpid(pid, &status, 0) == -1, errno == EINTR {}

        let out = streams[0].data
        let err = streams[1].data
        if let forced { return result(forced, out, err) }
        // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift doesn't import.
        let signal = status & 0x7F
        return signal == 0
            ? result(.exited((status >> 8) & 0xFF), out, err)
            : result(.signaled(signal), out, err)
    }

    /// Whether the child has exited — observed WITHOUT reaping it, so its
    /// pid (and the group id) stay reserved until the group is killed.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        let observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        return observed == 0 && info.si_pid == pid
    }

    /// SIGTERM to the whole group and a grace period for the child to go;
    /// the caller then SIGKILLs what's left and reaps.
    private static func stopGroup(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        let until = monotonic() + terminateGrace
        while monotonic() < until, !hasExited(pid) {
            usleep(20_000)
        }
    }

    /// One non-blocking pipe, read to its cap.
    private struct Stream {
        let fd: Int32
        let cap: Int
        var data = Data()
        var open = true
        var overflowed = false

        mutating func drain() {
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while open {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    data.append(buffer, count: count)
                    if data.count > cap {
                        overflowed = true
                        return
                    }
                } else if count == 0 {
                    close(fd)
                    open = false
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    close(fd)
                    open = false
                }
            }
        }
    }
}
