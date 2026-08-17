import Foundation
import Testing
@testable import UsageCore

/// Temp projects tree + scanner — the SAME idiom `SessionScanTests`'s private
/// `SessionFixture` uses (that file is read-only reference material, not
/// something this suite may import or modify, so the helper is duplicated
/// rather than shared).
private struct DeepSessionFixture {
    let scanner: TranscriptScanner
    let projectRoot: URL
    private let base: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "deep-query-sessions-tests-\(UUID().uuidString)")
        projectRoot = base.appending(path: "projects/demo")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        scanner = TranscriptScanner(
            root: base.appending(path: "projects"),
            cacheDirectory: base.appending(path: "cache"),
            calendar: calendar)
    }

    func write(_ relativePath: String, _ content: String) throws {
        let url = projectRoot.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }
}

private func at(_ iso: String) -> Date {
    FlexibleISO8601.date(from: iso)!
}

private let fixtureNow = at("2026-08-10T10:00:00.000Z")

/// Interactive, priced session with one subagent — the "rich" fixture:
/// prompts, a tool call, a compaction, an agent version, two priced models
/// (main model `claude-fable-5`, subagent model `claude-haiku-4-5`).
private let priced1Main = #"""
{"type":"user","timestamp":"2026-08-10T09:00:00.000Z","entrypoint":"cli","cwd":"/Users/dev/proj1","gitBranch":"main","version":"2.1.231","message":{"role":"user","content":"Build the thing"}}
{"type":"assistant","timestamp":"2026-08-10T09:01:00.000Z","requestId":"r1","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":100,"output_tokens":50},"content":[{"type":"tool_use","id":"tu1","name":"Bash"}]}}
{"type":"user","timestamp":"2026-08-10T09:02:00.000Z","isCompactSummary":true,"message":{"role":"user","content":"compacting"}}
"""#

private let priced1Subagent = #"""
{"type":"assistant","timestamp":"2026-08-10T09:03:00.000Z","isSidechain":true,"requestId":"sa1","message":{"id":"sm1","model":"claude-haiku-4-5","usage":{"input_tokens":10,"output_tokens":5}}}
"""#

/// A second "aaaa"-prefixed session — exists only to make "aaaa" ambiguous
/// and "aaaa1" unique. No prompt, no metadata, no subagent.
private let priced2Main = #"""
{"type":"assistant","timestamp":"2026-08-10T08:00:00.000Z","requestId":"z1","message":{"id":"zm1","model":"claude-fable-5","usage":{"input_tokens":10,"output_tokens":5}}}
"""#

/// Background (sdk entrypoint), unpriced model, no version/branch recorded —
/// the absent-discipline fixture.
private let unpricedBackgroundMain = #"""
{"type":"user","timestamp":"2026-08-10T07:00:00.000Z","entrypoint":"sdk-py","promptSource":"sdk","message":{"role":"user","content":"Review this change"}}
{"type":"assistant","timestamp":"2026-08-10T07:01:00.000Z","requestId":"b1","message":{"id":"bm1","model":"mystery-model-9000","usage":{"input_tokens":20,"output_tokens":10}}}
"""#

/// Builds the fixture on disk and returns its priced entries — used by every
/// test below except the pure `index`/`select`/`card` unit tests, which build
/// the scan directly. `now`/`calendar` are UTC throughout: these tests exist
/// to prove the injected-`scan` wiring and the deep fields, not timezone
/// math (that's `DigestQueryTests`'s job, already covered there).
private func buildFixtureEntries() throws -> (fixture: DeepSessionFixture, entries: [DeepQuerySessions.Entry]) {
    let fixture = try DeepSessionFixture()
    try fixture.write("aaaa1111.jsonl", priced1Main)
    try fixture.write("aaaa1111/subagents/agent-a.jsonl", priced1Subagent)
    try fixture.write("aaaa9999.jsonl", priced2Main)
    try fixture.write("bbbb2222.jsonl", unpricedBackgroundMain)
    let scan = fixture.scanner.scan(now: fixtureNow)
    let entries = DeepQuerySessions.index(scan: scan, pricing: .bundled)
    return (fixture, entries)
}

private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}()

// MARK: - DeepQuerySessions.index: pricing, absent cost

@Suite("DeepQuerySessions.index")
struct DeepQuerySessionsIndexTests {
    @Test("priced models sum into the whole-session cost; unpriced models contribute nothing")
    func pricesKnownModelsOnly() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let rich = try #require(entries.first { $0.summary.id == "aaaa1111" })
        let fableRates = try #require(PricingTable.bundled.rates(for: "claude-fable-5"))
        let haikuRates = try #require(PricingTable.bundled.rates(for: "claude-haiku-4-5"))
        let expectedFable = fableRates.dollars(for: TokenTally(input: 100, output: 50))
        let expectedHaiku = haikuRates.dollars(for: TokenTally(input: 10, output: 5))
        #expect(rich.modelCosts["claude-fable-5"] == expectedFable)
        #expect(rich.modelCosts["claude-haiku-4-5"] == expectedHaiku)
        #expect(rich.cost == expectedFable + expectedHaiku)
    }

    @Test("a session priced ONLY in unknown models has an absent cost, never zero")
    func unpricedSessionCostIsAbsent() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let bg = try #require(entries.first { $0.summary.id == "bbbb2222" })
        #expect(bg.cost == nil)
        #expect(bg.modelCosts.isEmpty)
    }
}

// MARK: - DeepQuerySessions.select / .card

@Suite("DeepQuerySessions.select and .card")
struct DeepQuerySessionsSelectCardTests {
    @Test("id-prefix selection: none, exactly one, and ambiguous")
    func prefixSelection() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        #expect(DeepQuerySessions.select("zzzz", in: entries).isNone)
        guard case .found(let unique) = DeepQuerySessions.select("aaaa1", in: entries) else {
            Issue.record("expected a unique match for 'aaaa1'")
            return
        }
        #expect(unique.summary.id == "aaaa1111")
        guard case .ambiguous(let ids) = DeepQuerySessions.select("aaaa", in: entries) else {
            Issue.record("expected 'aaaa' to be ambiguous between aaaa1111 and aaaa9999")
            return
        }
        #expect(Set(ids) == ["aaaa1111", "aaaa9999"])
    }

    @Test("card() trims the project path to a basename and leaves colors honestly empty")
    func cardConversion() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let rich = try #require(entries.first { $0.summary.id == "aaaa1111" })
        let card = DeepQuerySessions.card(rich)
        #expect(card.project == "proj1")  // never "/Users/dev/proj1"
        #expect(card.branch == "main")
        #expect(card.tokens == rich.summary.totalTokens)
        #expect(card.modelColors.isEmpty)
        #expect(card.cost == rich.cost)
    }
}

extension DigestQuery.Selection {
    fileprivate var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

// MARK: - `sessions --all` via DigestQuery.runSessionsList (injected scan)

@Suite("sessions --all")
struct SessionsAllTests {
    @Test("lists every scanned session, newest first — the shortlist's columns plus the scan's `end`")
    func fullIndexInShortlistColumns() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["--all", "--raw", "--header"])
        let out = DigestQuery.runSessionsList(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, raw: true,
            scan: { entries })
        #expect(out.exitCode == 0)
        let rows = out.stdout.components(separatedBy: "\n")
        #expect(rows[0] == "id\ttitle\tproject\tbranch\tstarted\tactive\tcost\ttokens\tprompts\tapi-calls\tend")
        let ids = rows.dropFirst().map { $0.components(separatedBy: "\t")[0] }
        // end-descending: aaaa1111 (09:03) > aaaa9999 (08:00) > bbbb2222 (07:01).
        #expect(ids == ["aaaa1111", "aaaa9999", "bbbb2222"])
    }

    @Test("every --all register carries `end` — the human table's lead column must exist in raw/json too")
    func allRegistersCarryEnd() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let raw = DigestQuery.runSessionsList(
            parsed: DigestQuery.parseArgs(["--all", "--raw"]), digest: nil, now: fixtureNow,
            calendar: utcCalendar, json: false, raw: true, scan: { entries })
        let firstRow = raw.stdout.components(separatedBy: "\n")[0].components(separatedBy: "\t")
        #expect(firstRow.count == 11)
        #expect(firstRow.last?.hasPrefix("2026-") == true)

        let json = DigestQuery.runSessionsList(
            parsed: DigestQuery.parseArgs(["--all"]), digest: nil, now: fixtureNow,
            calendar: utcCalendar, json: true, raw: false, scan: { entries })
        #expect(json.stdout.contains("\"end\""))
        #expect(json.stdout.contains("\"startedAt\""))
    }

    @Test("answers with NO digest at all — never exit 13")
    func answersWithNoDigestPresent() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["--all"])
        let out = DigestQuery.runSessionsList(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: true, raw: false,
            scan: { entries })
        #expect(out.exitCode == 0)
        #expect(!out.stdout.isEmpty)
    }

    @Test("--background keeps only background-kind sessions")
    func backgroundFlagFilters() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["--all", "--background", "--raw"])
        let out = DigestQuery.runSessionsList(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, raw: true,
            scan: { entries })
        #expect(out.stdout.contains("bbbb2222"))
        #expect(!out.stdout.contains("aaaa1111"))
        #expect(!out.stdout.contains("aaaa9999"))
    }

    @Test("--no-background excludes background-kind sessions")
    func noBackgroundFlagFilters() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["--all", "--no-background", "--raw"])
        let out = DigestQuery.runSessionsList(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, raw: true,
            scan: { entries })
        #expect(!out.stdout.contains("bbbb2222"))
        #expect(out.stdout.contains("aaaa1111"))
        #expect(out.stdout.contains("aaaa9999"))
    }

    @Test("neither flag lists every kind, background included")
    func noFlagListsEveryKind() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["--all", "--raw"])
        let out = DigestQuery.runSessionsList(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, raw: true,
            scan: { entries })
        #expect(out.stdout.contains("aaaa1111"))
        #expect(out.stdout.contains("aaaa9999"))
        #expect(out.stdout.contains("bbbb2222"))
    }

    @Test("existing sessions filters (--limit) still apply — one formatting/filter path, not a fork")
    func limitFilterStillApplies() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["--all", "--limit", "1", "--raw"])
        let out = DigestQuery.runSessionsList(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, raw: true,
            scan: { entries })
        let rows = out.stdout.components(separatedBy: "\n")
        #expect(rows.count == 1)
        #expect(rows[0].hasPrefix("aaaa1111"))
    }

    @Test("without --all and without a digest, exit 13 — never a filesystem scan")
    func plainSessionsWithNoDigestIsThirteen() {
        let parsed = DigestQuery.parseArgs([])
        let out = DigestQuery.runSessionsList(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, raw: false,
            scan: { Issue.record("scan must not run for a plain 'sessions' miss"); return [] })
        #expect(out.exitCode == 13)
    }

    @Test("--all with no scan capability injected is a bad query, not a crash")
    func allWithoutScanCapabilityIsBadQuery() {
        let parsed = DigestQuery.parseArgs(["--all"])
        let out = DigestQuery.runSessionsList(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, raw: false)
        #expect(out.exitCode == 19)
    }

    @Test("--all against a non-claude provider (scan returns nil) is exit 11")
    func allWrongProviderIsEleven() {
        let parsed = DigestQuery.parseArgs(["--all"])
        let out = DigestQuery.runSessionsList(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, raw: false,
            scan: { nil })
        #expect(out.exitCode == 11)
    }
}

// MARK: - `session <id-prefix>` shortlist-miss fallback via DigestQuery.runSession

@Suite("session shortlist-miss fallback")
struct SessionFallbackTests {
    private func missingShortlistDigest() -> LiveState {
        DigestQueryTests.minimalState(engine: DigestQueryTests.minimalEngine(), sessions: [])
    }

    @Test("a unique id-prefix miss on the shortlist resolves through the scan")
    func uniquePrefixFallsThrough() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["aaaa1", "id"])
        let out = DigestQuery.runSession(
            parsed: parsed, digest: missingShortlistDigest(), now: fixtureNow, calendar: utcCalendar,
            json: false, scan: { entries })
        #expect(out.stdout == "aaaa1111")
        #expect(out.exitCode == 0)
    }

    @Test("with no digest at all, every selector goes straight to the scan")
    func noDigestGoesStraightToScan() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["bbbb2222", "kind"])
        let out = DigestQuery.runSession(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, scan: { entries })
        #expect(out.stdout == "background")
    }

    @Test("an ambiguous scan prefix is a bad query")
    func ambiguousScanPrefixIsBadQuery() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["aaaa"])
        let out = DigestQuery.runSession(
            parsed: parsed, digest: missingShortlistDigest(), now: fixtureNow, calendar: utcCalendar,
            json: false, scan: { entries })
        #expect(out.exitCode == 19)
    }

    @Test("no match anywhere — shortlist or scan — is exit 20")
    func noMatchAnywhereIsTwenty() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["zzzz"])
        let out = DigestQuery.runSession(
            parsed: parsed, digest: missingShortlistDigest(), now: fixtureNow, calendar: utcCalendar,
            json: false, scan: { entries })
        #expect(out.exitCode == 20)
    }

    @Test("no injected scan capability: a miss stays exit 20 WITHOUT ever scanning")
    func missingScanCapabilityNeverScans() {
        let parsed = DigestQuery.parseArgs(["anything"])
        let out = DigestQuery.runSession(
            parsed: parsed, digest: missingShortlistDigest(), now: fixtureNow, calendar: utcCalendar, json: false)
        #expect(out.exitCode == 20)
    }

    @Test("a scan-returns-nil (non-claude provider) fallback is exit 11")
    func scanWrongProviderIsEleven() {
        let parsed = DigestQuery.parseArgs(["anything"])
        let out = DigestQuery.runSession(
            parsed: parsed, digest: missingShortlistDigest(), now: fixtureNow, calendar: utcCalendar, json: false,
            scan: { nil })
        #expect(out.exitCode == 11)
    }

    @Test("a shortlist HIT never consults the scan closure at all")
    func shortlistHitNeverInvokesScan() throws {
        let session = SessionCard(
            id: "aaaa1111", title: "Shortlisted", project: nil, branch: nil, startedAt: fixtureNow,
            activeSeconds: 0, cost: nil, tokens: 0, prompts: 0, apiCalls: 0, modelColors: [])
        let digest = DigestQueryTests.minimalState(
            engine: DigestQueryTests.minimalEngine(), sessions: [session])
        let parsed = DigestQuery.parseArgs(["aaaa1111", "title"])
        let out = DigestQuery.runSession(
            parsed: parsed, digest: digest, now: fixtureNow, calendar: utcCalendar, json: false,
            scan: { Issue.record("scan must not run on a shortlist hit"); return [] })
        #expect(out.stdout == "Shortlisted")
    }
}

// MARK: - New deep fields (end/kind/tool-calls/subagents/compactions/agent-version/models)

@Suite("session deep fields")
struct SessionDeepFieldTests {
    private func field(_ name: String, of id: String, entries: [DeepQuerySessions.Entry], json: Bool = false) -> QueryOutput {
        let args = json ? [id, name, "--json"] : [id, name]
        let parsed = DigestQuery.parseArgs(args)
        return DigestQuery.runSession(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: json, scan: { entries })
    }

    @Test("end/kind/tool-calls/subagents/compactions resolve from a scan hit")
    func deepFieldsResolveRealValues() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        #expect(field("end", of: "aaaa1111", entries: entries).stdout == DigestQueryFormat.iso(at("2026-08-10T09:03:00.000Z")))
        #expect(field("kind", of: "aaaa1111", entries: entries).stdout == "interactive")
        #expect(field("kind", of: "bbbb2222", entries: entries).stdout == "background")
        #expect(field("tool-calls", of: "aaaa1111", entries: entries).stdout == "1")
        #expect(field("subagents", of: "aaaa1111", entries: entries).stdout == "1")
        #expect(field("compactions", of: "aaaa1111", entries: entries).stdout == "1")
        #expect(field("agent-version", of: "aaaa1111", entries: entries).stdout == "2.1.231")
    }

    @Test("a session with no recorded agent version reads absent, never an error")
    func absentSubFieldIsAbsentNotAnError() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let raw = field("agent-version", of: "bbbb2222", entries: entries)
        #expect(raw.stdout == "")
        #expect(raw.exitCode == 0)
        let json = field("agent-version", of: "bbbb2222", entries: entries, json: true)
        #expect(json.stdout == "null")
        #expect(json.exitCode == 0)
    }

    @Test("a deep field name on a plain SHORTLIST hit stays a bad query — the shortlist genuinely has no such field")
    func deepFieldOnShortlistHitIsBadQuery() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let session = SessionCard(
            id: "aaaa1111", title: "t", project: nil, branch: nil, startedAt: fixtureNow, activeSeconds: 0,
            cost: nil, tokens: 0, prompts: 0, apiCalls: 0, modelColors: [])
        let digest = DigestQueryTests.minimalState(engine: DigestQueryTests.minimalEngine(), sessions: [session])
        let parsed = DigestQuery.parseArgs(["aaaa1111", "end"])
        let out = DigestQuery.runSession(
            parsed: parsed, digest: digest, now: fixtureNow, calendar: utcCalendar, json: false, scan: { entries })
        #expect(out.exitCode == 19)
    }

    @Test("models field: priced and unpriced rows, sorted by tokens, header + raw")
    func modelsFieldListsPricedAndUnpriced() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["aaaa1111", "models", "--header"])
        let out = DigestQuery.runSession(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, scan: { entries })
        let rows = out.stdout.components(separatedBy: "\n")
        #expect(rows[0] == "id\ttokens\tcost")
        // fable: 150 tokens > haiku: 15 tokens.
        #expect(rows[1].hasPrefix("claude-fable-5\t150\t"))
        #expect(rows[2].hasPrefix("claude-haiku-4-5\t15\t"))
    }

    @Test("models field: an unpriced model's row carries an absent (null) cost, never $0")
    func modelsFieldUnpricedCostIsAbsent() throws {
        let (fixture, entries) = try buildFixtureEntries()
        defer { fixture.tearDown() }

        let parsed = DigestQuery.parseArgs(["bbbb2222", "models", "--raw"])
        let out = DigestQuery.runSession(
            parsed: parsed, digest: nil, now: fixtureNow, calendar: utcCalendar, json: false, scan: { entries })
        #expect(out.stdout == "mystery-model-9000\t30\t")
    }
}

// MARK: - DeepQuerySessionsCLI.run: the actual usage-cli entry point
//
// Everything here stays hermetic: `--provider not-a-real-provider` makes
// `DeepQuerySessions.buildIndex`'s own `guard providerID == "claude"` fire
// BEFORE any filesystem touch (Digests/DeepQuerySessions.swift), so a case
// that reaches the scan closure still never opens `~/.claude/projects` —
// only the ROUTING behavior (which exit code, whether the closure ran at
// all) is under test, never real transcript content.
@Suite("DeepQuerySessionsCLI.run")
struct DeepQuerySessionsCLITests {
    private func staleDigest(timeZone: String = "UTC", sessions: [SessionCard] = []) -> LiveState {
        // `generatedAt` (2026-08-16T12:00:00Z, `minimalEngine`'s fixed
        // value) is safely more than 1s before `fixtureNow`
        // (2026-08-10T10:00:00Z is EARLIER — pick a `now` after
        // generatedAt instead, so "stale" is unambiguous).
        DigestQueryTests.minimalState(
            engine: DigestQueryTests.minimalEngine(fetchedAt: nil, nextPollAt: nil),
            sessions: sessions, timeZone: timeZone)
    }

    @Test("unknown noun is a bad query — never reaches dispatch")
    func unknownNounIsBadQuery() {
        let out = DeepQuerySessionsCLI.run(
            noun: "bogus", arguments: [], digest: nil, now: DigestQueryTests.iso("2026-08-16T12:05:00Z"))
        #expect(out.exitCode == 19)
    }

    @Test("'sessions' with no digest and no --all is exit 13 — the shortlist has nothing to read")
    func plainSessionsNoDigestIsThirteen() {
        let out = DeepQuerySessionsCLI.run(
            noun: "sessions", arguments: [], digest: nil, now: DigestQueryTests.iso("2026-08-16T12:05:00Z"))
        #expect(out.exitCode == 13)
    }

    @Test("finding 1: 'sessions --all --max-age' with a stale digest still answers — the scan IS live data")
    func allBypassesTheMaxAgeGate() {
        let now = DigestQueryTests.iso("2026-08-16T13:00:00Z")  // 1h past generatedAt.
        let digest = staleDigest()
        let out = DeepQuerySessionsCLI.run(
            noun: "sessions", arguments: ["--all", "--max-age", "1s", "--provider", "not-a-real-provider"],
            digest: digest, now: now)
        // Reaches the wrong-provider exit (11) from INSIDE the scan
        // closure, proving the gate let it through — the pre-fix behavior
        // was exit 21 (stale) without the closure ever running.
        #expect(out.exitCode == 11)
    }

    @Test("a plain 'sessions --max-age' (no --all) still gates on a stale digest — digest-backed answers are not exempt")
    func plainSessionsStillGatesOnMaxAge() {
        let now = DigestQueryTests.iso("2026-08-16T13:00:00Z")
        let digest = staleDigest()
        let out = DeepQuerySessionsCLI.run(
            noun: "sessions", arguments: ["--max-age", "1s"], digest: digest, now: now)
        #expect(out.exitCode == 21)
    }

    @Test("'session <selector> --max-age' (the singular noun) still gates too — the exclusion is --all-scoped, not sessions-noun-scoped")
    func singularSessionStillGatesOnMaxAge() {
        let now = DigestQueryTests.iso("2026-08-16T13:00:00Z")
        let card = SessionCard(
            id: "aaaa1111", title: "t", project: nil, branch: nil, startedAt: now, activeSeconds: 0,
            cost: nil, tokens: 0, prompts: 0, apiCalls: 0, modelColors: [])
        let digest = staleDigest(sessions: [card])
        let out = DeepQuerySessionsCLI.run(
            noun: "session", arguments: ["aaaa1111", "--max-age", "1s"], digest: digest, now: now)
        #expect(out.exitCode == 21)
    }

    @Test("--all still VALIDATES --max-age grammar — only the staleness comparison is scoped out; malformed input is a bad query everywhere")
    func allStillValidatesMalformedMaxAge() {
        let now = DigestQueryTests.iso("2026-08-16T13:00:00Z")
        let out = DeepQuerySessionsCLI.run(
            noun: "sessions",
            arguments: ["--all", "--max-age", "not-a-duration", "--provider", "not-a-real-provider"],
            digest: staleDigest(), now: now)
        #expect(out.exitCode == 19)
        #expect(out.note == "bad --max-age duration 'not-a-duration' — e.g. 90s, 5m, 2h, 7d")
    }

    @Test("--background/--no-background without --all refuse (19) — the shortlist can't filter a kind it doesn't know")
    func backgroundFilterWithoutAllIsABadQuery() {
        let now = DigestQueryTests.iso("2026-08-16T13:00:00Z")
        for flag in ["--background", "--no-background"] {
            let out = DeepQuerySessionsCLI.run(
                noun: "sessions", arguments: [flag], digest: staleDigest(), now: now)
            #expect(out.exitCode == 19)
            #expect(out.note == "--background/--no-background need --all — the shortlist doesn't know a session's kind")
        }
    }

    @Test("'session <id> --all' skips a shortlist HIT and resolves through the scan — the deep-field escape hatch")
    func sessionAllForcesTheScanPastAShortlistHit() {
        let now = DigestQueryTests.iso("2026-08-16T13:00:00Z")
        let card = SessionCard(
            id: "aaaa1111", title: "t", project: nil, branch: nil, startedAt: now, activeSeconds: 0,
            cost: nil, tokens: 0, prompts: 0, apiCalls: 0, modelColors: [])
        let digest = staleDigest(sessions: [card])
        // Without --all the shortlist answers this id directly.
        let shortlist = DeepQuerySessionsCLI.run(
            noun: "session", arguments: ["aaaa1111"], digest: digest, now: now)
        #expect(shortlist.exitCode == 0)
        // With --all the SAME id must go to the scan instead — proven
        // hermetically by the wrong-provider exit firing from inside the
        // scan closure, which a shortlist answer never reaches.
        let scanned = DeepQuerySessionsCLI.run(
            noun: "session", arguments: ["aaaa1111", "--all", "--provider", "not-a-real-provider"],
            digest: digest, now: now)
        #expect(scanned.exitCode == 11)
    }

    @Test("the noun switch dispatches 'sessions' to the plural handler and 'session' to the singular one")
    func nounSwitchDispatchesCorrectly() {
        let now = DigestQueryTests.iso("2026-08-16T12:05:00Z")
        let card = SessionCard(
            id: "aaaa1111", title: "Only Session", project: nil, branch: nil, startedAt: now, activeSeconds: 0,
            cost: nil, tokens: 5, prompts: 1, apiCalls: 1, modelColors: [])
        let digest = staleDigest(sessions: [card])

        // Plural: a selector is a bad query (sessions takes none).
        let plural = DeepQuerySessionsCLI.run(noun: "sessions", arguments: ["aaaa1111"], digest: digest, now: now)
        #expect(plural.exitCode == 19)

        // Singular: the same token IS the selector, and resolves.
        let singular = DeepQuerySessionsCLI.run(
            noun: "session", arguments: ["aaaa1111", "title"], digest: digest, now: now)
        #expect(singular.stdout == "Only Session")
    }

    @Test("--raw threads through into 'sessions': TSV columns, not the human table")
    func rawFlagThreadsIntoSessionsList() {
        let now = DigestQueryTests.iso("2026-08-16T12:05:00Z")
        let card = SessionCard(
            id: "aaaa1111", title: "Raw Row", project: "proj", branch: "main", startedAt: now, activeSeconds: 30,
            cost: 0.5, tokens: 100, prompts: 2, apiCalls: 3, modelColors: [])
        let digest = staleDigest(sessions: [card])
        let out = DeepQuerySessionsCLI.run(noun: "sessions", arguments: ["--raw", "--header"], digest: digest, now: now)
        #expect(out.exitCode == 0)
        #expect(out.stdout.hasPrefix("id\ttitle\tproject\tbranch\tstarted\t"))
        #expect(out.stdout.contains("aaaa1111\tRaw Row\tproj\tmain\t"))
    }

    /// Mirrors `DigestQueryTests.activityRangesResolveInTheDigestsOwnTimeZoneNotTheHosts`:
    /// Pacific/Kiritimati (UTC+14) is ahead of every plausible host zone, so
    /// a regression to `TimeZone.current` (the calendar fallback this
    /// builder copies out of `DigestQuery`'s private `digestCalendar`) fails
    /// on ANY host, not only ones whose local zone differs from the
    /// fixture's.
    @Test("the digest's own activity.timeZone drives --since, not TimeZone.current")
    func calendarFallbackUsesDigestTimeZoneNotHostZone() {
        // Local midnight 2026-08-16 in Kiritimati (UTC+14) is
        // 2026-08-15T10:00:00Z — this session sits 12h after that, so a
        // correct Kiritimati-calendar cutoff includes it; any host zone at
        // or below +12 computes a LATER local-midnight cutoff in UTC and
        // excludes it instead.
        let startedAt = DigestQueryTests.iso("2026-08-15T22:00:00Z")
        let card = SessionCard(
            id: "kiri1", title: "Kiritimati session", project: nil, branch: nil, startedAt: startedAt,
            activeSeconds: 0, cost: nil, tokens: 0, prompts: 0, apiCalls: 0, modelColors: [])
        let digest = staleDigest(timeZone: "Pacific/Kiritimati", sessions: [card])
        let now = DigestQueryTests.iso("2026-08-16T12:05:00Z")

        let out = DeepQuerySessionsCLI.run(
            noun: "sessions", arguments: ["--since", "2026-08-16", "--raw"], digest: digest, now: now)
        #expect(out.stdout.contains("kiri1"))
    }
}
