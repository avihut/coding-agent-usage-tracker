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
    case shutdown
}

public struct ControlReply: Codable, Sendable, Equatable {
    public let ok: Bool
    public let message: String?

    public init(ok: Bool, message: String? = nil) {
        self.ok = ok
        self.message = message
    }
}

/// The engine host's command channel: a unix-domain stream socket beside
/// the digest, mode 0600 (same-user only — matching every other artifact).
/// The accept loop blocks on its own utility queue and forwards one decoded
/// command at a time to the MainActor handler; replies serialize naturally.
/// Only the lease holder binds — the lease is what makes unlink-then-bind
/// safe (a socket file with no live holder is by definition stale).
public final class ControlSocket: @unchecked Sendable {
    public typealias Handler = @MainActor @Sendable (ControlCommand) async -> ControlReply

    public let socketURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(
        label: "com.avihu.ClaudeUsage.control-socket", qos: .utility)
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
        guard listen(fd, 4) == 0 else {
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
        guard let line = Self.readLine(from: connection, limit: 64 * 1024),
              let command = try? JSONDecoder().decode(ControlCommand.self, from: line)
        else {
            Self.write(
                ControlReply(ok: false, message: "unreadable command"), to: connection)
            return
        }
        // Block this (background) queue until the MainActor handler answers —
        // commands are rare and serial by design.
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
        _ command: ControlCommand, to socketURL: URL, timeout: TimeInterval = 3
    ) -> ControlReply? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(
            tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
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
        guard connected == 0 else { return nil }
        guard var data = try? JSONEncoder().encode(command) else { return nil }
        data.append(0x0A)
        let sent = data.withUnsafeBytes { bytes in
            Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
        }
        guard sent == data.count else { return nil }
        guard let line = readLine(from: fd, limit: 64 * 1024) else { return nil }
        return try? JSONDecoder().decode(ControlReply.self, from: line)
    }

    // MARK: - Wire helpers

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
