import Darwin
import Foundation

/// One command a consumer can ask of the engine host. The socket carries
/// NDJSON: one request line, one reply line, connection closed — a
/// protocol simple enough for any language's standard library.
public enum ControlCommand: Codable, Sendable, Equatable {
    case status
    /// Manual refresh — same TriggerGate as in-app; the reply says whether
    /// the gate allowed it.
    case refresh
    case setInterval(seconds: TimeInterval)
    case setProvider(id: String)
    /// Settings changed in some other process — re-read defaults.
    case settingsChanged
    case refreshPricing
    case scanNow
    /// Re-read the provider's status page now — a consumer opening a window
    /// on an aging card. The feed's CDN spacing rations it, so an eager
    /// caller can't turn this into a hot loop.
    case refreshStatus
    case checkUpdates
    /// A face rendered these pending notices — the ledger marks them seen.
    case markNoticesSeen(ids: [String])
    /// The person dismissed one notice (refused for an ongoing one).
    case dismissNotice(id: String)
    case dismissAllNotices
    /// Pin the focus on one profile; nil clears the pin so focus follows
    /// activity again (0.96.0).
    case focusProfile(id: String?)
    /// Manual refresh of ONE profile's engine (`refresh` targets the
    /// focused one).
    case refreshProfile(id: String)
    case setProfileEnabled(id: String, enabled: Bool)
    /// The profile list changed in some other process — re-read defaults
    /// and reconcile engines.
    case profilesChanged
    case shutdown
    /// Read-only: one session's numbers from the named profile's engine —
    /// its in-memory index of every session its last scan holds, not only
    /// the published shortlist (issue #24). `profile` is a `ProfileKey`; nil
    /// means the focused one. A profile with no running engine is refused,
    /// never answered from another account. `id` is an id prefix. The
    /// reply's `session` carries the answer; mutates nothing.
    case session(profile: String?, id: String)
}

/// How one exchange with the host ended. `noAnswer` is not `notListening`:
/// a host that took the connection is alive — busy under load, answering
/// late — and may still act on the command; nobody serves a socket that
/// refuses the connect.
public enum ControlExchange: Sendable, Equatable {
    case reply(ControlReply)
    /// Nothing accepted the connection: no host serves the socket.
    case notListening
    /// The host took the connection and no reply line came back in time.
    case noAnswer

    public var reply: ControlReply? {
        if case .reply(let reply) = self { return reply }
        return nil
    }
}

public struct ControlReply: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String?
    /// A `session` lookup's answer; nil for every other verb, and from a
    /// host that predates the verb (it answers "unreadable command").
    public let session: SessionAnswer?
    /// True when a `session` question reached an engine whose first scan
    /// hasn't indexed its sessions yet (2026-11-21): busy, not "no engine"
    /// — a caller that scanned instead would duplicate the engine's own
    /// first scan. Absent from older hosts and every other reply.
    public let indexing: Bool?

    public init(ok: Bool, message: String? = nil, session: SessionAnswer? = nil, indexing: Bool? = nil) {
        self.ok = ok
        self.message = message
        self.session = session
        self.indexing = indexing
    }
}

/// The engine host's command channel: a unix-domain stream socket beside
/// the digest, mode 0600 (same-user only — matching every other artifact).
/// The accept loop blocks on its own responsive-QoS queue and forwards one decoded
/// command at a time to the MainActor handler; replies serialize naturally.
/// Only the lease holder binds — the lease is what makes unlink-then-bind
/// safe (a socket file with no live holder is by definition stale).
public final class ControlSocket: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (ControlCommand) async -> ControlReply

    /// Connections the kernel queues while one is served. Every open
    /// session's status line may ask for its numbers on the same tick
    /// (`ControlCommand.session`), and a full queue refuses a connect
    /// outright — which a caller can only read as "no engine". Four was
    /// enough while every verb was human-paced.
    static let backlog: Int32 = 64
    /// How long the host waits on one connection's request line, and on its
    /// reply's write. The loop is serial, so a client that connects and
    /// never sends — or stops reading — would otherwise hold every caller
    /// queued behind it (2026-11-21). A real client writes its line the
    /// moment it connects.
    static let serverTimeout: TimeInterval = 2
    /// The default client wait: a person-paced verb's answer.
    public static let clientTimeout: TimeInterval = 3

    public let socketURL: URL
    private let handler: Handler
    /// Above the engine's heavy work (`EngineWork`): answering is the
    /// responsiveness path, and it is tiny.
    private let queue = DispatchQueue(
        label: "\(AppIdentity.bundleID).control-socket", qos: EngineWork.responsiveQoS)
    private var listenFD: Int32 = -1

    public init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    public func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.bindFailed(errno) }
        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        unlink(socketURL.path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw ControlSocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { bytes in
                buffer.copyMemory(from: bytes)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size)
            }
        }
        guard bound == 0 else {
            close(fd)
            throw ControlSocketError.bindFailed(errno)
        }
        chmod(socketURL.path, 0o600)
        guard listen(fd, Self.backlog) == 0 else {
            close(fd)
            throw ControlSocketError.bindFailed(errno)
        }
        listenFD = fd
        queue.async { [weak self] in self?.acceptLoop(fd) }
    }

    public func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketURL.path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { return }  // listener closed
            serve(connection)
        }
    }

    private func serve(_ connection: Int32) {
        defer { close(connection) }
        Self.noSignalOnClosedPeer(connection)
        Self.setTimeouts(connection, seconds: Self.serverTimeout)
        guard let line = Self.readLine(from: connection, limit: 64 * 1024) else { return }
        guard let command = try? JSONDecoder().decode(ControlCommand.self, from: line) else {
            Self.write(
                ControlReply(ok: false, message: "unreadable command"), to: connection)
            return
        }
        // Every command is answered, even one whose caller may have given up:
        // a peek can't tell a vanished caller from one that half-closed after
        // sending (`printf … | nc -U`, `shutdown(SHUT_WR)`) and still waits
        // for its reply, and the write to a vanished one is EPIPE, not death.
        // Block this (background) queue until the MainActor handler answers —
        // serial by design: the verbs are human-paced, and the one a status
        // line repeats (`session`) is a sub-millisecond lookup.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply = ControlReply(ok: false, message: "handler dropped")
        let handler = handler
        Task { @MainActor in
            reply = await handler(command)
            semaphore.signal()
        }
        semaphore.wait()
        Self.write(reply, to: connection)
    }

    // MARK: - Client

    /// Sends one command and waits briefly for the reply. Nil when nobody
    /// listens (no host, stale socket) — callers treat that as "engine
    /// offline", never an error state worth surfacing loudly.
    public static func send(
        _ command: ControlCommand, to socketURL: URL, timeout: TimeInterval = clientTimeout
    ) -> ControlReply? {
        exchange(command, to: socketURL, timeout: timeout).reply
    }

    /// `send`, saying why no reply came back: a busy host (`noAnswer`) is not
    /// an absent one (`notListening`), and a caller that would fall back to
    /// doing the host's work itself must not do it for a host that is merely
    /// late.
    public static func exchange(
        _ command: ControlCommand, to socketURL: URL, timeout: TimeInterval = clientTimeout
    ) -> ControlExchange {
        guard let data = try? JSONEncoder().encode(command) else { return .noAnswer }
        return exchangeLine(data, to: socketURL, timeout: timeout)
    }

    /// The wire seam under `send`: one raw line out, one reply line back —
    /// how a test proves an unreadable verb is refused, not dropped.
    public static func sendLine(
        _ line: Data, to socketURL: URL, timeout: TimeInterval = clientTimeout
    ) -> ControlReply? {
        exchangeLine(line, to: socketURL, timeout: timeout).reply
    }

    static func exchangeLine(
        _ line: Data, to socketURL: URL, timeout: TimeInterval
    ) -> ControlExchange {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .notListening }
        defer { close(fd) }
        noSignalOnClosedPeer(fd)
        setTimeouts(fd, seconds: timeout)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return .notListening }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { bytes in
                buffer.copyMemory(from: bytes)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, size)
            }
        }
        guard connected == 0 else {
            // A full accept queue refuses a connect with the same errno as a
            // stale socket file. The lease beside the socket tells them
            // apart: a host holding it is alive and behind — busy.
            let refused = errno == ECONNREFUSED
            let lease = socketURL.deletingLastPathComponent().appending(path: "engine.lock")
            return refused && EngineLease.isHeld(at: lease) ? .noAnswer : .notListening
        }
        var data = line
        data.append(0x0A)
        let sent = data.withUnsafeBytes { bytes in
            Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
        }
        guard sent == data.count,
              let line = readLine(from: fd, limit: 64 * 1024),
              let reply = try? JSONDecoder().decode(ControlReply.self, from: line)
        else { return .noAnswer }
        return .reply(reply)
    }

    // MARK: - Wire helpers

    /// A write to a connection whose peer already left raises SIGPIPE, and
    /// the default action kills the process: the daemon (launchd restarts it
    /// cold) or the app hosting the engine (the menu bar item vanishes). It
    /// happens whenever a client gives up before its reply — a status line
    /// waits one second, and a busy host's queue can be longer than that.
    /// With the flag set the write just fails with EPIPE, and the reply is
    /// dropped for a caller that is no longer listening.
    private static func noSignalOnClosedPeer(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(
            tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func readLine(from fd: Int32, limit: Int) -> Data? {
        var collected = Data()
        var byte: UInt8 = 0
        while collected.count < limit {
            let got = recv(fd, &byte, 1, 0)
            guard got == 1 else { return collected.isEmpty ? nil : collected }
            if byte == 0x0A { return collected }
            collected.append(byte)
        }
        return collected
    }

    private static func write(_ reply: ControlReply, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(reply) else { return }
        data.append(0x0A)
        _ = data.withUnsafeBytes { bytes in
            Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
        }
    }
}

public enum ControlSocketError: Error, Equatable {
    case bindFailed(Int32)
    case pathTooLong
}
