import Foundation
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
