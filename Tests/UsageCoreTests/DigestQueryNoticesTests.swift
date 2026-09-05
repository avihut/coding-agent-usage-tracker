import Foundation
import Testing

@testable import UsageCore

/// The `notices` noun against the shared golden, which carries one ongoing
/// minor outage and one dismissable reset from the evening before.
@Suite("DigestQuery.notices")
struct DigestQueryNoticesTests {
    let golden: LiveState
    let goldenRaw: Data
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

    /// A digest from an engine that publishes no card at all.
    var cardless: LiveState {
        LiveState(
            engine: golden.engine, meters: golden.meters, menuBar: golden.menuBar,
            models: golden.models, activity: golden.activity, sessions: golden.sessions)
    }

    @Test("the table lists every pending notice in the digest's own words")
    func table() {
        let out = run(["notices"])
        #expect(out.exitCode == 0)
        let lines = out.stdout.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("kind"))
        #expect(lines[1].contains("outage") && lines[1].contains("ongoing"))
        #expect(lines[2].contains("reset") && lines[2].contains("Limit reset · Claude"))
        #expect(lines[2].contains("pending"))
    }

    @Test("--raw is the same columns with the instant instead of the phrase")
    func raw() {
        let out = run(["notices", "--raw"])
        let rows = out.stdout.split(separator: "\n").map { $0.split(separator: "\t") }
        #expect(rows[0].map(String.init) == DigestQuery.noticeColumns)
        #expect(rows[2][1] == "2026-08-15T18:10:30Z")
        #expect(rows[2][4].hasPrefix("reset|"))
    }

    @Test("--check exits 23 while anything is pending, 0 otherwise")
    func check() {
        #expect(run(["notices", "--check"]).exitCode == 23)
        #expect(run(["notices", "--check"]).stdout == "")
        #expect(run(["notices", "--check"], digest: cardless).exitCode == 0)
    }

    @Test("fields and the whole card")
    func fields() throws {
        #expect(run(["notices", "count"]).stdout == "2")
        #expect(run(["notices", "indicator"]).stdout == "true")
        #expect(run(["notices", "--fields", "count,indicator"]).stdout == "2\ttrue")
        let json = try #require(run(["notices", "--json"]).stdout.data(using: .utf8))
        let card = try LiveState.decoder().decode(NoticesCard.self, from: json)
        #expect(card.items.count == 2)
        #expect(run(["notices", "items", "--json"]).stdout.hasPrefix("["))
    }

    @Test("no card is silence, never 'nothing pending'")
    func absent() {
        #expect(run(["notices"], digest: cardless).stdout == "")
        #expect(run(["notices"], digest: cardless).exitCode == 0)
        #expect(run(["notices", "count"], digest: cardless).stdout == "")
        #expect(run(["notices", "--json"], digest: cardless).stdout == "null")
    }
}
