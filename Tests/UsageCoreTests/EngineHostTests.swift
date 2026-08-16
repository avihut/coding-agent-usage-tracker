import Foundation
import Testing

@testable import UsageCore

@Suite("Engine hosting")
struct EngineHostTests {
    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "engine-host-tests-\(UUID().uuidString)")
            .appending(path: name)
    }

    /// sockaddr_un caps paths at 104 bytes and the sandbox temp dir alone
    /// blows through it — sockets get a short /tmp home instead.
    private func shortTemp(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp")
            .appending(path: "eht-\(String(UInt32.random(in: 0..<0xFFFFFF), radix: 36))")
            .appending(path: name)
    }

    // MARK: - Lease

    @Test("the lease is exclusive, probeable, and reacquirable after release")
    @MainActor
    func leaseExclusivity() {
        let url = temp("engine.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = EngineLease(lockURL: url)
        #expect(EngineLease.isHeld(at: url) == false)
        #expect(first.acquire())
        #expect(first.isAcquired)
        #expect(EngineLease.isHeld(at: url))

        // A second holder in the same process cannot take it. flock locks
        // are per-open-file, so a fresh descriptor contends honestly.
        let second = EngineLease(lockURL: url)
        #expect(second.acquire() == false)

        first.release()
        #expect(EngineLease.isHeld(at: url) == false)
        #expect(second.acquire())
        second.release()
    }

    @Test("acquire is idempotent while held")
    @MainActor
    func leaseIdempotent() {
        let url = temp("engine.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lease = EngineLease(lockURL: url)
        #expect(lease.acquire())
        #expect(lease.acquire())
        lease.release()
    }

    // MARK: - Control socket

    @Test("commands round-trip over the socket and replies come back")
    func socketRoundTrip() async throws {
        let url = shortTemp("control.sock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let socket = ControlSocket(socketURL: url) { command in
            switch command {
            case .refresh: ControlReply(ok: true, message: "gate allowed")
            case .setInterval(let seconds): ControlReply(ok: true, message: "interval \(Int(seconds))")
            default: ControlReply(ok: false, message: "unhandled")
            }
        }
        try socket.start()
        defer { socket.stop() }

        let refresh = await Task.detached {
            ControlSocket.send(.refresh, to: url)
        }.value
        #expect(refresh == ControlReply(ok: true, message: "gate allowed"))

        let interval = await Task.detached {
            ControlSocket.send(.setInterval(seconds: 300), to: url)
        }.value
        #expect(interval == ControlReply(ok: true, message: "interval 300"))
    }

    @Test("sending into a dead socket path returns nil, not an error")
    func socketDead() {
        let url = shortTemp("control.sock")
        #expect(ControlSocket.send(.status, to: url) == nil)
    }

    @Test("the socket file is same-user only (0600)")
    func socketPermissions() throws {
        let url = shortTemp("control.sock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let socket = ControlSocket(socketURL: url) { _ in ControlReply(ok: true) }
        try socket.start()
        defer { socket.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    // MARK: - Broker decisions

    @Test("daemon or a held lease means client; an empty field means host")
    func brokerRole() {
        #expect(EngineHostBroker.role(leaseHeldByOther: false, daemonAlive: false) == .host)
        #expect(EngineHostBroker.role(leaseHeldByOther: true, daemonAlive: false) == .client)
        #expect(EngineHostBroker.role(leaseHeldByOther: false, daemonAlive: true) == .client)
        #expect(EngineHostBroker.role(leaseHeldByOther: true, daemonAlive: true) == .client)
    }

    @Test("a hosting app yields only to a fresh daemon marker")
    func brokerYield() {
        #expect(EngineHostBroker.shouldYield(daemonMarkerAge: nil) == false)
        #expect(EngineHostBroker.shouldYield(daemonMarkerAge: 2))
        #expect(EngineHostBroker.shouldYield(daemonMarkerAge: 60) == false)
    }

    @Test("heartbeat staleness scales with the digest's own poll horizon")
    func brokerStaleness() {
        let generated = Date(timeIntervalSince1970: 1_000_000)
        // 5-minute horizon: stale beyond 10 minutes, not at 8.
        let next = generated.addingTimeInterval(300)
        #expect(
            EngineHostBroker.heartbeatStale(
                generatedAt: generated, nextPollAt: next,
                now: generated.addingTimeInterval(480)) == false)
        #expect(
            EngineHostBroker.heartbeatStale(
                generatedAt: generated, nextPollAt: next,
                now: generated.addingTimeInterval(601)))
        // No horizon: the takeover floor governs.
        #expect(
            EngineHostBroker.heartbeatStale(
                generatedAt: generated, nextPollAt: nil,
                now: generated.addingTimeInterval(120)) == false)
        #expect(
            EngineHostBroker.heartbeatStale(
                generatedAt: generated, nextPollAt: nil,
                now: generated.addingTimeInterval(181)))
    }

    // MARK: - Gate seeding

    @Test("a seeded gate holds the floor across a host handover")
    func gateSeeding() {
        let fetched = Date(timeIntervalSince1970: 2_000_000)
        var seeded = TriggerGate(lastAllowed: fetched)
        // 60s after the dead host's fetch: inside the floor, denied.
        let deniedInsideFloor = seeded.shouldAllow(at: fetched.addingTimeInterval(60))
        let allowedPastFloor = seeded.shouldAllow(at: fetched.addingTimeInterval(181))
        var unseeded = TriggerGate()
        let unseededAllows = unseeded.shouldAllow(at: fetched.addingTimeInterval(60))
        #expect(deniedInsideFloor == false)
        #expect(allowedPastFloor)
        #expect(unseededAllows)
    }
}
