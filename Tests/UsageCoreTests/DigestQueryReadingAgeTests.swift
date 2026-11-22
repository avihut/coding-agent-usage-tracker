import Foundation
import Testing

@testable import UsageCore

/// `usage-cli` over an OLD limits reading (`ReadingAge`, 2026-11-22) — the
/// third golden: Claude focused and fresh, Codex on a reading from Wed 20:13.
/// The writer decides "old"; the CLI prints the writer's words, and no exit
/// code moves.
@Suite("query reading age")
struct DigestQueryReadingAgeTests {
    let golden: LiveState
    let goldenRaw: Data
    let now = DigestQueryTests.iso("2026-11-22T09:00:00Z")

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1-old-reading.json")
        goldenRaw = try Data(contentsOf: fixtureURL)
        golden = try LiveState.decoder().decode(LiveState.self, from: goldenRaw)
    }

    func run(_ args: [String], env: [String: String] = [:]) -> QueryOutput {
        DigestQuery.run(
            arguments: args, digest: golden, rawDigest: goldenRaw, environment: env, now: now)
    }

    @Test("status says as of, and the fresh account doesn't")
    func status() {
        let old = run(["status", "--account", "codex"])
        #expect(old.exitCode == 0)
        #expect(old.stdout.hasSuffix(" · as of Wed 20:13"))
        #expect(old.stdout.contains("Pro Lite plan"))
        let fresh = run(["status"])
        #expect(fresh.exitCode == 0)
        #expect(!fresh.stdout.contains("as of"))
    }

    @Test("the as-of field: a date while old, empty or null while current")
    func asOfField() {
        #expect(run(["status", "as-of", "--account", "codex"]).stdout == "2026-11-18T20:13:00Z")
        #expect(run(["status", "as-of", "--account", "codex", "--relative"]).stdout == "as of Wed 20:13")
        #expect(run(["status", "as-of", "--account", "codex", "--json"]).stdout == "\"2026-11-18T20:13:00Z\"")
        #expect(run(["status", "as-of"]).stdout == "")
        #expect(run(["status", "as-of", "--json"]).stdout == "null")
        #expect(run(["limit", "weekly", "as-of", "--account", "codex"]).stdout == "2026-11-18T20:13:00Z")
        #expect(run(["limit", "session", "as-of"]).stdout == "")
        // `stale` keeps its meaning: an old reading isn't cache-served.
        #expect(run(["status", "stale", "--account", "codex"]).stdout == "false")
    }

    @Test("limits rows and the limit line carry the stamp, and no forecast")
    func limits() {
        let table = run(["limits", "--account", "codex"])
        #expect(table.exitCode == 0)
        let rows = table.stdout.split(separator: "\n")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.hasSuffix("as of Wed 20:13") })
        #expect(!table.stdout.contains("runs out"))
        let line = run(["limit", "weekly", "--account", "codex"])
        #expect(line.stdout.hasPrefix("W  Weekly · 75%"))
        #expect(line.stdout.hasSuffix(" · as of Wed 20:13"))
        #expect(run(["limit", "weekly", "forecast.caption", "--account", "codex"]).stdout == "")
        #expect(run(["limit", "weekly", "forecast.verdict", "--account", "codex", "--json"]).stdout == "null")
        // The fresh account's rows are as they always were.
        #expect(!run(["limits"]).stdout.contains("as of"))
    }

    @Test("the status line ends in the stamp, dimmed in colour registers")
    func prompt() throws {
        #expect(run(["prompt", "--account", "codex", "--no-glyph", "--no-color"]).stdout
            == "S 0% W 75% as of Wed 20:13")
        #expect(run(["prompt", "--account", "codex", "--no-glyph", "--tmux"]).stdout
            .hasSuffix(" #[dim]as of Wed 20:13#[default]"))
        let json = run(["prompt", "--account", "codex", "--json"]).stdout
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["asOf"] as? String == "2026-11-18T20:13:00Z")
        #expect(object["stale"] as? Bool == false)
        // No colour on an old reading's digits: it has no risk to carry.
        #expect(!run(["prompt", "--account", "codex", "--no-glyph"]).stdout.contains("38;2"))
        #expect(!run(["prompt", "--no-glyph", "--no-color"]).stdout.contains("as of"))
    }

    @Test("exit codes and the freshness guards don't move")
    func exitCodes() {
        #expect(run(["status", "--check", "--account", "codex"]).exitCode == 0)
        // --max-age judges the publish (2 min ago here): passes.
        #expect(run(["limits", "--account", "codex", "--max-age", "10m"]).exitCode == 0)
        // --max-data-age judges the reading itself: refuses, as it always did.
        #expect(run(["limits", "--account", "codex", "--max-data-age", "6h"]).exitCode == 21)
        #expect(run(["limits", "--max-data-age", "6h"]).exitCode == 0)
    }

    @Test("accounts names the old account's reading as of its stamp")
    func accounts() {
        let out = run(["accounts"])
        #expect(out.exitCode == 0)
        let codex = out.stdout.split(separator: "\n").first { $0.hasPrefix("codex") }
        #expect(codex?.contains("as of Wed 20:13") == true)
        let claude = out.stdout.split(separator: "\n").first { $0.hasPrefix("default") }
        #expect(claude?.contains("ago") == true)
    }
}
