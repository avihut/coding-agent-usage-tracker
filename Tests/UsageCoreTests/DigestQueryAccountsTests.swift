import Foundation
import Testing

@testable import UsageCore

/// `--account`, the home variable, and the `accounts` noun over the golden
/// (two profiles: `default` focused and metered, `c982130e` "Personal"
/// dormant) — and over the golden with its personal profile METERED, built
/// here from the top level's own section under the personal id.
@Suite("DigestQuery accounts")
struct DigestQueryAccountsTests {
    let golden: LiveState
    let goldenRaw: Data
    let now = DigestQueryTests.iso("2026-08-16T12:00:00Z")
    let homes = ProfileSelector.Homes(
        environmentVariable: "CLAUDE_CONFIG_DIR",
        standard: URL(fileURLWithPath: "/Users/t/.claude"),
        userHome: URL(fileURLWithPath: "/Users/t"))
    let personalProfile = Profile(
        id: "c982130e", providerID: "claude", home: URL(fileURLWithPath: "/Users/t/.claude-personal"),
        nickname: "Personal", addedAt: Date(timeIntervalSince1970: 1_755_000_000))

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        goldenRaw = try Data(contentsOf: fixtureURL)
        golden = try LiveState.decoder().decode(LiveState.self, from: goldenRaw)
    }

    func run(
        _ args: [String], digest: LiveState? = nil, env: [String: String] = [:], profiles: [Profile]? = nil
    ) -> QueryOutput {
        DigestQuery.run(
            arguments: args, digest: digest ?? golden, rawDigest: goldenRaw, environment: env, now: now,
            profiles: profiles ?? [personalProfile], homes: homes)
    }

    /// The golden with c982130e metered: one meter, its engine published a
    /// minute before the host's heartbeat, no sessions.
    func metered() throws -> LiveState {
        let profiles = try #require(golden.profiles)
        let personal = ProfileState(
            id: "c982130e", providerID: "claude", label: "Personal", nickname: "Personal", monogram: "P",
            enabled: true, isFocused: false, dormant: false, lastActivityAt: now,
            homeDisplayPath: "~/.claude-personal",
            engine: golden.engine.replacing(
                generatedAt: now.addingTimeInterval(-60), nextPollAt: now.addingTimeInterval(120)),
            meters: Array(golden.meters.prefix(1)), menuBar: Array(golden.menuBar.prefix(1)),
            models: [], activity: golden.activity, sessions: [], accountPresence: nil)
        return LiveState(
            schemaVersion: golden.schemaVersion, sessionsCap: golden.sessionsCap,
            engine: golden.engine, meters: golden.meters, menuBar: golden.menuBar, models: golden.models,
            activity: golden.activity, sessions: golden.sessions, serviceStatus: golden.serviceStatus,
            appUpdate: golden.appUpdate, accountPresence: golden.accountPresence, notices: golden.notices,
            outages: golden.outages, focusedProfile: "default", profiles: [profiles[0], personal],
            menuBarCells: golden.menuBarCells)
    }

    // MARK: - accounts

    @Test("accounts: one row per profile, the strip's facts")
    func accountsTable() throws {
        let out = run(["accounts"])
        #expect(out.exitCode == 0)
        let lines = out.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("id"))
        #expect(lines[1].contains("default") && lines[1].contains("work@example.com"))
        #expect(lines[1].contains("~/.claude ") && lines[1].contains("active") && lines[1].contains("focused"))
        #expect(lines[1].contains("2 min ago") && lines[1].hasSuffix("S 53%"))
        #expect(lines[2].contains("c982130e") && lines[2].contains("Personal"))
        #expect(lines[2].contains("~/.claude-personal") && lines[2].hasSuffix("dormant"))

        let raw = run(["accounts", "--raw"])
        let rows = raw.stdout.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(rows[0] == DigestQuery.accountsColumns)
        #expect(rows[1] == ["default", "work@example.com", "~/.claude", "active", "true", "2026-08-16T11:58:00Z", "S=53"])
        #expect(rows[2] == ["c982130e", "Personal", "~/.claude-personal", "dormant", "false", "", ""])
        let unix = run(["accounts", "--raw", "--unix"])
        let fetchedEpoch = Int(DigestQueryTests.iso("2026-08-16T11:58:00Z").timeIntervalSince1970)
        #expect(unix.stdout.contains("\t\(fetchedEpoch)\t"))

        let json = run(["accounts", "--json"])
        let decoded = try LiveState.decoder().decode([ProfileState].self, from: Data(json.stdout.utf8))
        #expect(decoded == golden.profiles)
    }

    @Test("accounts scalars: count, the writer's focus, and this invocation's selection")
    func accountsScalars() {
        #expect(run(["accounts", "count"]).stdout == "2")
        #expect(run(["accounts", "focused"]).stdout == "default")
        #expect(run(["accounts", "selected"]).stdout == "default")
        #expect(run(["accounts", "selected", "--account", "personal"]).stdout == "c982130e")
        #expect(run(["accounts", "selected", "--json", "--account", "c982130e"]).stdout == "\"c982130e\"")
        #expect(run(["accounts", "--fields", "count,focused,selected", "--account", "personal"]).stdout == "2\tdefault\tc982130e")
        let items = run(["accounts", "items", "--raw"])
        #expect(items.stdout.hasPrefix("id\tlabel"))
        #expect(run(["accounts", "bogus"]).exitCode == 19)
        #expect(run(["accounts", "count", "extra"]).exitCode == 19)
    }

    @Test("a pre-profile digest: the table and count go absent, selected still answers")
    func legacyWriter() {
        let legacy = LiveState(
            engine: golden.engine, meters: golden.meters, menuBar: golden.menuBar, models: golden.models,
            activity: golden.activity, sessions: golden.sessions)
        #expect(run(["accounts"], digest: legacy).stdout == "")
        #expect(run(["accounts", "--json"], digest: legacy).stdout == "null")
        #expect(run(["accounts", "count"], digest: legacy).stdout == "")
        #expect(run(["accounts", "focused", "--json"], digest: legacy).stdout == "null")
        #expect(run(["accounts", "selected"], digest: legacy).stdout == "default")
        #expect(run(["status", "account"], digest: legacy).stdout == "default")
    }

    // MARK: - --account projects a section onto every noun

    @Test("--account lifts the profile's section: its meters, its status, its stamps")
    func flagProjects() throws {
        // The dormant profile: no engine, so nothing fetched and no meters —
        // absent, never the focused profile's numbers.
        #expect(run(["limits", "--raw", "--account", "c982130e"]).stdout == "")
        #expect(run(["status", "stale", "--account", "c982130e"]).stdout == "true")
        #expect(run(["status", "fetched", "--account", "c982130e"]).stdout == "")
        #expect(run(["status", "account"]).stdout == "default")
        #expect(run(["status", "account", "--account", "c982130e"]).stdout == "c982130e")
        #expect(run(["status", "account", "--account", "~/.claude-personal"]).stdout == "c982130e")
        // The focused profile's own bytes are untouched by the selection.
        #expect(run(["limits", "--raw", "--account", "default"]) == run(["limits", "--raw"]))
        #expect(run(["get", "engine.pid", "--account", "default"]) == run(["get", "engine.pid"]))

        // A metered second profile: one meter where the top level has three,
        // and the HOST's heartbeat as its generated stamp.
        let state = try metered()
        let rows = run(["limits", "--raw", "--account", "c982130e"], digest: state).stdout.split(separator: "\n")
        #expect(rows.count == 1)
        #expect(run(["limits", "--raw"], digest: state).stdout.split(separator: "\n").count > 1)
        #expect(run(["status", "generated", "--account", "c982130e"], digest: state).stdout == "2026-08-16T12:00:00Z")
        #expect(run(["status", "next-poll", "--account", "c982130e"], digest: state).stdout == "2026-08-16T12:02:00Z")
        #expect(run(["accounts", "--raw"], digest: state).stdout.contains("c982130e\tPersonal\t~/.claude-personal\tactive\tfalse\t2026-08-16T11:58:00Z\tS=53"))
    }

    @Test("get walks the re-encoded view for a lifted section; the writer's own facts stay")
    func getWalksTheView() throws {
        let state = try metered()
        #expect(run(["get", "meters", "--json", "--account", "c982130e"], digest: state).stdout.contains("\"label\""))
        #expect(run(["get", "focusedProfile", "--account", "c982130e"], digest: state).stdout == "default")
        #expect(run(["get", "engine.fetchedAt", "--json", "--account", "c982130e"]).stdout == "null")
        #expect(run(["get", "profiles", "--json", "--account", "c982130e"]).stdout == run(["get", "profiles", "--json"]).stdout)
    }

    @Test("an unknown account is exit 20 listing the known ones — never a fallback")
    func unknownAccount() {
        let out = run(["limits", "--account", "nope"])
        #expect(out.exitCode == 20)
        #expect(out.stdout == "")
        #expect(out.note == "no such account: nope — accounts: default, c982130e")
        // A record the store knows but the writer has not published yet.
        let fresh = Profile(
            id: "abcd1234", providerID: "claude", home: URL(fileURLWithPath: "/Users/t/.claude-x"), addedAt: Date())
        let pending = run(["limits", "--account", "abcd1234"], profiles: [personalProfile, fresh])
        #expect(pending.exitCode == 20)
        #expect(pending.note?.contains("not in the digest yet") == true)
    }

    @Test("the home variable selects — and refuses a home nobody meters")
    func environmentSelects() {
        let personal = ["CLAUDE_CONFIG_DIR": "/Users/t/.claude-personal"]
        #expect(run(["status", "account"], env: personal).stdout == "c982130e")
        #expect(run(["limits", "--raw"], env: personal).stdout == "")
        #expect(run(["status", "account"], env: ["CLAUDE_CONFIG_DIR": "~/.claude-personal/"]).stdout == "c982130e")
        #expect(run(["status", "account"], env: ["CLAUDE_CONFIG_DIR": "/Users/t/.claude"]).stdout == "default")
        // The flag still wins over the variable.
        #expect(run(["status", "account", "--account", "default"], env: personal).stdout == "default")

        let squad = ["CLAUDE_CONFIG_DIR": "/Users/t/.claude-squad"]
        let refused = run(["limits"], env: squad)
        #expect(refused.exitCode == 20)
        #expect(refused.note == "no such account: CLAUDE_CONFIG_DIR=/Users/t/.claude-squad — accounts: default, c982130e")
        #expect(run(["status", "--check"], env: squad).exitCode == 20)
        // Provider-level nouns answer regardless of the shell's home.
        #expect(run(["health", "ok"], env: squad).exitCode != 20)
        #expect(run(["notices", "count"], env: squad).exitCode == 0)
    }

    @Test("--max-age judges the host's heartbeat, whichever section is lifted")
    func maxAgeIsTheHeartbeat() throws {
        #expect(run(["limits", "--account", "c982130e", "--max-age", "90s"]).exitCode == 0)
        let state = try metered()
        #expect(run(["limits", "--account", "c982130e", "--max-age", "30s"], digest: state).exitCode == 0)
        #expect(run(["limits", "--account", "c982130e", "--max-age", "30s"], digest: state,
                    env: [:]).exitCode == 0)
        let later = DigestQuery.run(
            arguments: ["limits", "--account", "c982130e", "--max-age", "30s"], digest: state,
            rawDigest: goldenRaw, environment: [:], now: now.addingTimeInterval(45),
            profiles: [personalProfile], homes: homes)
        #expect(later.exitCode == 21)
    }

    // MARK: - The other doors

    @Test("the sessions door answers for the profile's shortlist and roots its scan at the home")
    func sessionsDoor() {
        func sessions(_ args: [String], profiles: [Profile]? = nil, env: [String: String] = [:]) -> QueryOutput {
            DeepQuerySessionsCLI.run(
                noun: args[0], arguments: Array(args.dropFirst()), digest: golden, now: now,
                environment: env, profiles: profiles ?? [personalProfile], homes: homes)
        }
        let focused = sessions(["sessions", "--raw"])
        #expect(focused.exitCode == 0 && !focused.stdout.isEmpty)
        // The dormant profile has no shortlist: nothing, exit 0 — not the
        // work account's sessions.
        let personal = sessions(["sessions", "--raw", "--account", "c982130e"])
        #expect(personal.exitCode == 0 && personal.stdout == "")
        #expect(sessions(["sessions", "--raw"], env: ["CLAUDE_CONFIG_DIR": "~/.claude-personal"]).stdout == "")
        #expect(sessions(["session", "latest", "--no-scan", "--account", "c982130e"]).exitCode == 20)
        #expect(sessions(["sessions", "--account", "nope"]).exitCode == 20)
        // A profile the writer names but the store holds no home for: a
        // scan-capable query refuses rather than scanning the standard home.
        let rootless = sessions(["sessions", "--all", "--account", "c982130e"], profiles: [])
        #expect(rootless.exitCode == 20)
        #expect(rootless.note?.contains("no home on record") == true)
        #expect(sessions(["sessions", "--raw", "--account", "c982130e"], profiles: []).exitCode == 0)
        // transcript never selects — the flag is unknown there, and the
        // variable is ignored.
        let transcript = sessions(["transcript", "/nowhere.jsonl", "--account", "c982130e"])
        #expect(transcript.exitCode == 19 && transcript.note == "unknown flag '--account'")
        #expect(sessions(["transcript", "/nowhere.jsonl"], env: ["CLAUDE_CONFIG_DIR": "/Users/t/.claude-squad"]).exitCode == 20)
    }

    @Test("the deep verbs select too; prices never does")
    func deepDoor() {
        func deep(_ args: [String], env: [String: String] = [:]) -> QueryOutput {
            DeepQuery.run(
                noun: args[0], arguments: Array(args.dropFirst()), digest: golden, environment: env, now: now,
                profiles: [personalProfile], homes: homes)
        }
        #expect(deep(["history", "session", "--account", "nope"]).exitCode == 20)
        #expect(deep(["windows", "week", "--account", "nope"]).exitCode == 20)
        #expect(deep(["history", "session"], env: ["CLAUDE_CONFIG_DIR": "/Users/t/.claude-squad"]).exitCode == 20)
        let prices = deep(["prices", "--account", "c982130e"])
        #expect(prices.exitCode == 19 && prices.note == "unknown flag '--account'")
        #expect(deep(["prices"], env: ["CLAUDE_CONFIG_DIR": "/Users/t/.claude-squad"]).exitCode != 20)
    }
}
