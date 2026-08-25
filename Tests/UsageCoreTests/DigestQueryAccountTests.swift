import Foundation
import Testing

@testable import UsageCore

/// The `account` noun, against the same golden fixture every query suite
/// uses — which carries a work account signed in for an hour over a closed
/// personal epoch, both reserved buckets populated, and a session that
/// crossed the switch.
@Suite("DigestQuery.account")
struct DigestQueryAccountTests {
    let golden: LiveState
    let goldenRaw: Data
    /// The fixture's own `engine.generatedAt`, as every query suite pins it.
    let now = ISO8601DateFormatter().date(from: "2026-08-16T12:00:00Z")!

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        goldenRaw = try Data(contentsOf: fixtureURL)
        golden = try LiveState.decoder().decode(LiveState.self, from: goldenRaw)
    }

    func run(_ args: [String], digest: LiveState? = nil) -> QueryOutput {
        DigestQuery.run(
            arguments: args, digest: digest ?? golden, rawDigest: goldenRaw,
            environment: [:], now: now)
    }

    /// A digest from an engine that tracks no accounts at all.
    var cardless: LiveState {
        LiveState(
            engine: golden.engine, meters: golden.meters, menuBar: golden.menuBar,
            models: golden.models, activity: golden.activity, sessions: golden.sessions)
    }

    @Test("the summary names who, the org, for how long, and today's usage")
    func summary() {
        let out = run(["account"])
        // Signed in 11:00 against the pinned 12:00; the work account's only
        // model is unpriced, so today reads in tokens, never $0.
        #expect(out.stdout == "work@example.com · Work Inc · for 1 hr · today 55 tokens")
        #expect(out.exitCode == 0)
    }

    @Test("fields answer individually; absent answers stay absent")
    func fields() {
        #expect(run(["account", "label"]).stdout == "work@example.com")
        #expect(run(["account", "email"]).stdout == "work@example.com")
        #expect(run(["account", "name"]).stdout == "Work Person")
        #expect(run(["account", "uuid"]).stdout == "acct-work")
        #expect(run(["account", "org"]).stdout == "Work Inc")
        #expect(run(["account", "tier"]).stdout == "default_claude_max_5x")
        #expect(run(["account", "since"]).stdout == "2026-08-16T11:00:00Z")
        #expect(run(["account", "observed"]).stdout == "2026-08-16T11:58:00Z")
        #expect(run(["account", "age"]).stdout == "120")
        #expect(run(["account", "attribution-since"]).stdout == "2026-08-16T08:00:00Z")
        #expect(run(["account", "distinct"]).stdout == "2")
        #expect(run(["account", "today-tokens"]).stdout == "55")
        // Unpriced is absent — empty, exit 0, never 0.
        let cost = run(["account", "today-cost"])
        #expect(cost.stdout == "")
        #expect(cost.exitCode == 0)
        #expect(run(["account", "window-tokens"]).stdout == "55")
    }

    @Test("the accounts table carries the split, reserved buckets included")
    func accountsTable() {
        let out = run(["account", "accounts"])
        let rows = out.stdout.components(separatedBy: "\n")
        #expect(rows[0] == "label\ttoday-tokens\ttoday-cost\twindow-tokens\twindow-cost")
        #expect(rows[1] == "work@example.com\t55\t\t55\t")
        #expect(rows[2] == "primary@example.com\t480\t0.004\t480\t0.004")
        #expect(rows[3] == "(ambiguous)\t48\t0.0004\t48\t0.0004")
        // Pre-tracking usage: in today, out of the window — a real zero.
        #expect(rows[4] == "(unattributed)\t12\t0.0001\t0\t")
    }

    @Test("the epochs table is the ledger, oldest first")
    func epochsTable() {
        let out = run(["account", "epochs"])
        let rows = out.stdout.components(separatedBy: "\n")
        #expect(rows[0] == "label\tfirst\tlast\tclosed")
        #expect(rows[1] == "primary@example.com\t2026-08-16T08:00:00Z\t2026-08-16T10:05:00Z\tfalse")
        #expect(rows[2] == "work@example.com\t2026-08-16T11:00:00Z\t2026-08-16T11:58:00Z\tfalse")
    }

    @Test("--fields combines scalars; --json prints the whole card")
    func registers() throws {
        #expect(
            run(["account", "--fields", "email,tier"]).stdout
                == "work@example.com\tdefault_claude_max_5x")
        let json = run(["account", "--json"])
        let card = try LiveState.decoder().decode(
            AccountPresenceCard.self, from: Data(json.stdout.utf8))
        #expect(card.current?.label == "work@example.com")
        #expect(card.ambiguous?.todayTokens == 48)
    }

    @Test("an untracked engine prints nothing and exits 0 — never 'no account'")
    func absentCard() {
        let bare = run(["account"], digest: cardless)
        #expect(bare.stdout == "")
        #expect(bare.exitCode == 0)
        #expect(run(["account", "--json"], digest: cardless).stdout == "null")
        let field = run(["account", "email"], digest: cardless)
        #expect(field.stdout == "")
        #expect(field.exitCode == 0)
        #expect(run(["account", "epochs"], digest: cardless).stdout == "")
    }

    @Test("the grammar holds: unknown fields enumerate, foreign flags reject")
    func grammar() {
        let unknown = run(["account", "nope"])
        #expect(unknown.exitCode == DigestQuery.exitBadQuery)
        let foreign = run(["account", "--all"])
        #expect(foreign.exitCode == DigestQuery.exitBadQuery)
        #expect(foreign.note?.contains("--all") == true)
    }
}
