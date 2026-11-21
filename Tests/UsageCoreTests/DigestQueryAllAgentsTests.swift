import Foundation
import Testing

@testable import UsageCore

/// `usage-cli --all-agents`: the consumption nouns over the digest's
/// all-agents section, the grammar around it, and every call without it
/// unchanged.
@Suite("DigestQuery all agents")
struct DigestQueryAllAgentsTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-09-19T12:00:00Z")!

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/\(name)"))
    }

    /// The multi-harness golden — Claude `default` and Codex counted, a
    /// dormant Claude account and hidden Gemini out — optionally edited as
    /// JSON first, the way an older or a mid-scan writer would have written it.
    private func run(
        _ args: [String], file: String = "live-state-v1-harnesses.json",
        environment: [String: String] = [:], edit: ((inout [String: Any]) -> Void)? = nil
    ) throws -> QueryOutput {
        var raw = try fixture(file)
        if let edit {
            var object = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
            edit(&object)
            raw = try JSONSerialization.data(withJSONObject: object)
        }
        let digest = try LiveState.decoder().decode(LiveState.self, from: raw)
        return DigestQuery.run(
            arguments: args, digest: digest, rawDigest: raw, environment: environment, now: Self.now)
    }

    private func allAgents() throws -> AllAgentsState {
        try #require(try LiveState.decoder().decode(LiveState.self, from: fixture("live-state-v1-harnesses.json")).allAgents)
    }

    @Test("activity and cost answer for every counted account")
    func totals() throws {
        let all = try allAgents()
        let total = try #require(all.activity)
        let today = try run(["activity", "today", "tokens", "--all-agents", "--raw"])
        #expect(today.stdout == String(total.todayTokens))
        #expect(today.exitCode == 0)
        let week = try run(["activity", "7d", "--all-agents", "--json"])
        let box = try #require(try JSONSerialization.jsonObject(with: Data(week.stdout.utf8)) as? [String: Any])
        #expect(box["tokens"] as? Int == total.days.reduce(0) { $0 + $1.tokens })
        #expect(try run(["cost", "today", "--all-agents", "--raw"]).stdout
            == DigestQueryFormat.rawMoney(all.activity?.todayCost))
        // Without the flag the focused account (Codex) answers, as ever.
        #expect(try run(["activity", "today", "tokens", "--raw"]).stdout == "41175")
    }

    @Test("model rows name their agent: last raw column, first human one, a JSON key")
    func rows() throws {
        let raw = try run(["models", "--all-agents", "--raw", "--header"])
        let lines = raw.stdout.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        #expect(lines.first == ["id", "name", "tokens", "cost", "agent"])
        #expect(lines.dropFirst().map { String($0.last ?? "") } == ["claude", "codex", "codex", "claude"])
        let human = try run(["models", "--all-agents"])
        #expect(human.stdout.split(separator: "\n").first?.hasPrefix("Claude") == true)
        #expect(try run(["models", "--all-agents", "--json"]).stdout.contains("\"agent\" : \"codex\""))
        #expect(try run(["activity", "7d", "models", "--all-agents", "--raw"]).stdout
            .split(separator: "\n").count == 4)
        // The per-account register is untouched: four columns, no agent.
        #expect(try run(["models", "--raw", "--header"]).stdout.hasPrefix("id\tname\ttokens\tcost\n"))
    }

    @Test("an id two agents share is ambiguous; agent:id names one")
    func sharedIDs() throws {
        let shared = try run(["model", "unknown", "--all-agents"])
        #expect(shared.exitCode == 19)
        #expect(shared.note?.contains("codex:unknown") == true)
        #expect(shared.note?.contains("claude:unknown") == true)
        #expect(try run(["model", "codex:unknown", "tokens", "--all-agents"]).stdout == "75")
        #expect(try run(["model", "top", "agent", "--all-agents"]).stdout == "claude")
        // A per-account row has no agent: the field is absent, never invented.
        #expect(try run(["model", "top", "agent", "--json"]).stdout == "null")
    }

    @Test("the flag can't also name an account, and belongs to the consumption nouns")
    func grammar() throws {
        #expect(try run(["activity", "--all-agents", "--account", "default"]).exitCode == 19)
        #expect(try run(["models", "--all-agents", "--provider", "codex"]).exitCode == 19)
        #expect(try run(["limits", "--all-agents"]).exitCode == 19)
        #expect(try run(["sessions", "--all-agents"]).exitCode == 19)
        // A status line's home variable selects nothing under it.
        let total = try #require(try allAgents().activity)
        #expect(try run(
            ["activity", "today", "tokens", "--all-agents", "--raw"],
            environment: ["CLAUDE_CONFIG_DIR": "/Users/t/.claude-personal"]).stdout
            == String(total.todayTokens))
    }

    @Test("no section: one account answers itself, several mean an older writer")
    func absentSection() throws {
        let older = try run(["activity", "--all-agents"]) { $0["allAgents"] = nil }
        #expect(older.exitCode == 20)
        #expect(older.note?.contains("written before") == true)
        // The single-harness golden meters one account: its own numbers are the total.
        let alone = try run(["activity", "today", "tokens", "--all-agents", "--raw"], file: "live-state-v1.json")
        let plain = try run(["activity", "today", "tokens", "--raw"], file: "live-state-v1.json")
        #expect(alone.exitCode == 0)
        #expect(alone.stdout == plain.stdout)
    }

    @Test("a partial total says so on stderr, and on a human summary line only")
    func partial() throws {
        func scanning(_ object: inout [String: Any]) {
            guard var all = object["allAgents"] as? [String: Any],
                  var members = all["members"] as? [[String: Any]] else { return }
            members[1]["state"] = "scanning"
            all["members"] = members
            all["partial"] = true
            object["allAgents"] = all
        }
        let human = try run(["activity", "today", "--all-agents"], edit: scanning)
        #expect(human.stdout.hasSuffix(" · partial"))
        #expect(human.note == "partial — Codex still scanning, left out of the total")
        #expect(human.exitCode == 0)
        let raw = try run(["activity", "today", "tokens", "--all-agents", "--raw"], edit: scanning)
        #expect(!raw.stdout.contains("partial"))
        #expect(raw.note?.hasPrefix("partial") == true)
        let field = try run(["activity", "today", "tokens", "--all-agents"], edit: scanning)
        #expect(!field.stdout.contains("partial"))
    }

    @Test("nobody counted yet: no total, never a zero one")
    func noTotalYet() throws {
        func nobody(_ object: inout [String: Any]) {
            guard var all = object["allAgents"] as? [String: Any],
                  var members = all["members"] as? [[String: Any]] else { return }
            for index in members.indices { members[index]["state"] = "scanning" }
            all["members"] = members
            all["partial"] = true
            all["models"] = nil
            all["activity"] = nil
            object["allAgents"] = all
        }
        for args in [
            ["activity", "today", "tokens", "--all-agents", "--raw"], ["cost", "today", "--all-agents"],
            ["models", "--all-agents"],
        ] {
            let out = try run(args, edit: nobody)
            #expect(out.exitCode == 20)
            #expect(out.stdout.isEmpty)
            #expect(out.note == "no all-agents total yet — Claude Code, Codex still scanning")
        }
    }

    @Test("hours past the total's cap say why")
    func hoursCap() throws {
        let out = try run(["activity", "2026-08-01", "hours", "--all-agents"])
        #expect(out.exitCode == 20)
        #expect(out.note?.contains("keeps hours for the last 8 days") == true)
    }
}
