import Foundation
import os
import Testing
@testable import UsageCore

/// The socket's wire shapes are API: the TUI hand-writes them
/// (`tui/src/socket.rs`), so the synthesized Codable spelling of every
/// verb — old and new — is pinned here.
@Suite("Control command wire shapes")
struct ControlCommandWireTests {
    private func encoded(_ command: ControlCommand) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(command), as: UTF8.self)
    }

    private func decoded(_ json: String) throws -> ControlCommand {
        try JSONDecoder().decode(ControlCommand.self, from: Data(json.utf8))
    }

    @Test("the TUI's literals decode to the verbs they name")
    func tuiLiterals() throws {
        #expect(try decoded(#"{"setInterval":{"seconds":300}}"#) == .setInterval(seconds: 300))
        #expect(try decoded(#"{"dismissNotice":{"id":"reset|1"}}"#) == .dismissNotice(id: "reset|1"))
        #expect(try decoded(#"{"markNoticesSeen":{"ids":["a","b"]}}"#) == .markNoticesSeen(ids: ["a", "b"]))
        #expect(try decoded(#"{"status":{}}"#) == .status)
        #expect(try decoded(#"{"refresh":{}}"#) == .refresh)
    }

    @Test("the profile verbs spell additively; a nil pin is an empty object")
    func profileVerbs() throws {
        #expect(try encoded(.focusProfile(id: "c982130e")) == #"{"focusProfile":{"id":"c982130e"}}"#)
        #expect(try encoded(.focusProfile(id: nil)) == #"{"focusProfile":{}}"#)
        #expect(try encoded(.refreshProfile(id: "default")) == #"{"refreshProfile":{"id":"default"}}"#)
        #expect(try encoded(.setProfileEnabled(id: "x", enabled: false))
            == #"{"setProfileEnabled":{"enabled":false,"id":"x"}}"#)
        #expect(try encoded(.profilesChanged) == #"{"profilesChanged":{}}"#)
        for command: ControlCommand in [
            .focusProfile(id: "a"), .focusProfile(id: nil), .refreshProfile(id: "b"),
            .setProfileEnabled(id: "c", enabled: true), .profilesChanged,
        ] {
            #expect(try decoded(try encoded(command)) == command)
        }
    }

    @Test("ClientVerbs picks the one-engine verb only for a pre-profile host")
    func clientVerbs() {
        #expect(ClientVerbs.refresh(profileID: "c982130e", legacyHost: true) == .refresh)
        #expect(ClientVerbs.refresh(profileID: "default", legacyHost: true) == .refresh)
        #expect(ClientVerbs.refresh(profileID: "default", legacyHost: false) == .refreshProfile(id: "default"))
        #expect(ClientVerbs.refresh(profileID: "c982130e", legacyHost: false)
            == .refreshProfile(id: "c982130e"))
    }

    @Test("the session lookup spells additively; a nil profile is omitted")
    func sessionVerb() throws {
        #expect(try encoded(.session(profile: "default", id: "e1c8"))
            == #"{"session":{"id":"e1c8","profile":"default"}}"#)
        #expect(try encoded(.session(profile: nil, id: "e1c8")) == #"{"session":{"id":"e1c8"}}"#)
        for command: ControlCommand in [.session(profile: "c982130e", id: "a"), .session(profile: nil, id: "b")] {
            #expect(try decoded(try encoded(command)) == command)
        }
    }

    @Test("a reply carries the answer when there is one, and an older reply still decodes")
    func sessionReplyPayload() throws {
        let card = SessionCard(
            id: "aaaa1111", title: "t", project: "proj", branch: "main",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_000_600),
            activeSeconds: 60, cost: 1.25, tokens: 165, prompts: 1, apiCalls: 2, modelColors: [], accounts: [])
        let answer = SessionAnswer(
            matches: ["aaaa1111"], card: card,
            deep: SessionDeepFields(
                summary: SessionSummary(
                    id: "aaaa1111", title: "t", projectPath: "/x/proj", gitBranch: "main", agentVersion: nil,
                    kind: .background, start: card.startedAt, end: card.end!, activeSeconds: 60, prompts: 1,
                    apiCalls: 2, toolCalls: 3, subagentCount: 0, compactions: 0,
                    models: ["m": TokenTally(input: 100, output: 65)]),
                modelCosts: ["m": 1.25]))
        let reply = ControlReply(ok: true, message: "found aaaa1111", session: answer)
        let wire = try JSONEncoder().encode(reply)
        #expect(try JSONDecoder().decode(ControlReply.self, from: wire) == reply)
        // The full cwd never crosses: only the card's folder name does.
        #expect(!String(decoding: wire, as: UTF8.self).contains("/x/proj"))
        // A host from before the verb answers without the key at all.
        let old = try JSONDecoder().decode(ControlReply.self, from: Data(#"{"ok":false,"message":"unreadable command"}"#.utf8))
        #expect(old.session == nil)
    }

    /// Every open session's status line may ask on the same tick. A
    /// backlog of four refused the fifth connect outright while one was
    /// being served — which a caller can only read as "no engine".
    @Test("connections far past the old backlog of four are queued and all answered")
    func concurrentConnectsAreQueued() async throws {
        let url = URL(fileURLWithPath: "/tmp")
            .appending(path: "ccb-\(String(UInt32.random(in: 0..<0xFFFFFF), radix: 36))")
            .appending(path: "control.sock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A handler slow enough that every client connects while the first
        // is still being served.
        let socket = ControlSocket(socketURL: url) { _ in
            try? await Task.sleep(for: .milliseconds(30))
            return ControlReply(ok: true, message: "served")
        }
        try socket.start()
        defer { socket.stop() }

        // Real threads, not tasks: 32 blocking connects on the cooperative
        // pool would queue behind its few threads and never arrive at once.
        let callers = 32
        let collected = OSAllocatedUnfairLock(initialState: [ControlReply?]())
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for _ in 0..<callers {
                group.enter()
                Thread.detachNewThread {
                    let reply = ControlSocket.send(.status, to: url, timeout: 5)
                    collected.withLock { $0.append(reply) }
                    group.leave()
                }
            }
            group.notify(queue: .global()) { done.resume() }
        }
        let replies = collected.withLock { $0 }
        #expect(replies.count == callers)
        #expect(replies.allSatisfy { $0 == ControlReply(ok: true, message: "served") })
    }

    /// A status line gives up after a second, and under load the host may
    /// not have answered yet. Writing the late reply into the closed
    /// connection must not kill the host with SIGPIPE.
    @Test("a client that hangs up before its reply doesn't take the host down")
    func clientLeavingEarlyIsSurvived() async throws {
        let url = URL(fileURLWithPath: "/tmp")
            .appending(path: "ccp-\(String(UInt32.random(in: 0..<0xFFFFFF), radix: 36))")
            .appending(path: "control.sock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let socket = ControlSocket(socketURL: url) { _ in
            try? await Task.sleep(for: .milliseconds(300))
            return ControlReply(ok: true, message: "late")
        }
        try socket.start()
        defer { socket.stop() }

        let gaveUp = await Task.detached { ControlSocket.send(.status, to: url, timeout: 0.05) }.value
        #expect(gaveUp == nil)
        // The host wrote that reply into a closed connection; it still serves.
        try? await Task.sleep(for: .milliseconds(400))
        let next = await Task.detached { ControlSocket.send(.status, to: url, timeout: 3) }.value
        #expect(next == ControlReply(ok: true, message: "late"))
    }

    @Test("an unknown verb over a live socket is refused, never dropped")
    func unknownVerbRefused() async throws {
        let url = URL(fileURLWithPath: "/tmp")
            .appending(path: "ccw-\(String(UInt32.random(in: 0..<0xFFFFFF), radix: 36))")
            .appending(path: "control.sock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let socket = ControlSocket(socketURL: url) { _ in ControlReply(ok: true, message: "handled") }
        try socket.start()
        defer { socket.stop() }

        let reply = await Task.detached {
            ControlSocket.sendLine(Data(#"{"bogus":{}}"#.utf8), to: url)
        }.value
        #expect(reply == ControlReply(ok: false, message: "unreadable command"))

        let known = await Task.detached {
            ControlSocket.sendLine(Data(#"{"profilesChanged":{}}"#.utf8), to: url)
        }.value
        #expect(known == ControlReply(ok: true, message: "handled"))
    }
}
