import Darwin
import Foundation
import os
import Testing

@testable import UsageCore

/// The control socket under load (2026-11-21): a busy host answers late,
/// and that must read as busy — never as "no engine" — while a silent or
/// vanished client can never wedge the serial accept loop.
@Suite("Control socket under load")
struct ControlSocketLoadTests {
    private func socketURL(_ tag: String) -> URL {
        URL(fileURLWithPath: "/tmp")
            .appending(path: "\(tag)-\(String(UInt32.random(in: 0..<0xFFFFFF), radix: 36))")
            .appending(path: "control.sock")
    }

    /// Connects and sends nothing, holding the connection open.
    private func silentClient(_ url: URL) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            url.path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return fd
    }

    @Test("a client that connects and never sends can't wedge the loop past the server timeout")
    func silentClientDoesNotWedge() async throws {
        let url = socketURL("csw")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let socket = ControlSocket(socketURL: url) { _ in ControlReply(ok: true, message: "served") }
        try socket.start()
        defer { socket.stop() }

        let squatter = silentClient(url)
        defer { close(squatter) }
        // Queued behind the squatter on a SERIAL loop: without the server's
        // read timeout this caller is never served at all. The wait is
        // deliberately generous — the property is "served", not "served
        // fast": wall-clock bounds measure the machine (a CI runner took 7 s
        // for a 2 s timeout), never the loop.
        let reply = await Task.detached {
            ControlSocket.send(.status, to: url, timeout: ControlSocket.serverTimeout * 15)
        }.value
        #expect(reply == ControlReply(ok: true, message: "served"))
        // And the squatter was dropped, not merely outlived: the server
        // closed its end, so it reads end-of-stream.
        var tv = timeval(tv_sec: Int(ControlSocket.serverTimeout * 15), tv_usec: 0)
        setsockopt(squatter, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        #expect(recv(squatter, &byte, 1, 0) == 0)
    }

    @Test("a host that answers late is busy (noAnswer), a missing one is notListening")
    func lateIsNotAbsent() async throws {
        let url = socketURL("csl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(ControlSocket.exchange(.status, to: url, timeout: 0.2) == .notListening)

        let socket = ControlSocket(socketURL: url) { _ in
            try? await Task.sleep(for: .milliseconds(600))
            return ControlReply(ok: true, message: "late")
        }
        try socket.start()
        defer { socket.stop() }
        let late = await Task.detached { ControlSocket.exchange(.status, to: url, timeout: 0.1) }.value
        #expect(late == .noAnswer)
        // Generous: it queues behind the late one on a serial loop, and a
        // slow runner stretches both handlers.
        let patient = await Task.detached { ControlSocket.exchange(.status, to: url, timeout: 30) }.value
        #expect(patient == .reply(ControlReply(ok: true, message: "late")))
    }

    @Test("a client that half-closes after sending still gets its answer")
    func halfClosedClientIsAnswered() throws {
        let url = socketURL("csh")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let socket = ControlSocket(socketURL: url) { _ in ControlReply(ok: true, message: "here") }
        try socket.start()
        defer { socket.stop() }
        // `printf '{"status":{}}\n' | nc -U control.sock` does exactly this.
        let fd = silentClient(url)
        defer { close(fd) }
        let line = Array(#"{"status":{}}"#.utf8) + [0x0A]
        #expect(Darwin.write(fd, line, line.count) == line.count)
        #expect(shutdown(fd, SHUT_WR) == 0)
        var tv = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var reply = [UInt8](repeating: 0, count: 4096)
        let got = recv(fd, &reply, reply.count, 0)
        let text = String(decoding: reply.prefix(max(0, got)), as: UTF8.self)
        #expect(text.contains(#""message":"here""#), "\(text)")
    }

    @Test("with broken pipes ignored, a write to a closed peer is EPIPE, not death")
    func brokenPipeIsAnError() {
        ProcessSignals.ignoreBrokenPipes()
        #expect(ProcessSignals.brokenPipesIgnored)
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        close(pair[1])
        var byte: UInt8 = 1
        let written = write(pair[0], &byte, 1)
        #expect(written == -1)
        #expect(errno == EPIPE)
        close(pair[0])
    }

    @Test("a full accept queue is busy while the lease is held, absent otherwise")
    func fullBacklogWithLeaseIsBusy() throws {
        let url = socketURL("csq")
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A listener that never accepts, with the smallest queue.
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            url.path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        #expect(listen(listener, 1) == 0)
        var queued: [Int32] = []
        defer { queued.forEach { close($0) } }
        // Fill the queue with clients that sit in it, until a connect is refused.
        for _ in 0..<64 {
            queued.append(silentClient(url))
            if ControlSocket.exchange(.status, to: url, timeout: 0.2) == .notListening { break }
        }
        // The queue is full now: a refused connect, and no lease yet.
        #expect(ControlSocket.exchange(.status, to: url, timeout: 0.2) == .notListening)
        // A host holds the lease beside the socket: alive and behind.
        let lock = open(dir.appending(path: "engine.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        #expect(ControlSocket.exchange(.status, to: url, timeout: 0.2) == .noAnswer)
    }

    @Test("an engine still building its index answers busy, never silence")
    func indexingReplyIsBusy() throws {
        let url = socketURL("csi")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let socket = ControlSocket(socketURL: url) { _ in
            ControlReply(ok: false, message: "default has not indexed its sessions yet", indexing: true)
        }
        try socket.start()
        defer { socket.stop() }
        #expect(DeepQuerySessionsCLI.engineLookup(socket: url, timeout: 30)("default", "abc") == .busy)
    }
}
