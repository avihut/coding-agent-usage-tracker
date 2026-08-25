import Foundation
import Testing

@testable import UsageCore

/// The 0.84.0 consumer-ergonomics surface, from a real consumer's review of
/// the shipped one: the field CATALOG (what a noun can be asked, enumerated
/// when you ask wrong), `--fields` (four numbers, one invocation, no
/// scraping a presentation string), `--relative` durations, and the TSV
/// sanitizer that makes the raw register positionally safe.
///
/// Same golden fixture as `DigestQueryTests`, loaded the same `#filePath`
/// way — the digest goldens are a cross-suite, cross-language contract.
@Suite("query fields")
struct DigestQueryFieldsTests {
    let golden: LiveState
    let goldenRaw: Data
    let now = DigestQueryTests.iso("2026-08-16T12:00:00Z")

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        goldenRaw = try Data(contentsOf: fixtureURL)
        golden = try LiveState.decoder().decode(LiveState.self, from: goldenRaw)
    }

    func run(_ args: [String], digest: LiveState? = nil, now: Date? = nil) -> QueryOutput {
        DigestQuery.run(
            arguments: args, digest: digest ?? golden, rawDigest: goldenRaw,
            environment: [:], now: now ?? self.now)
    }

    /// The selector each noun needs before a field name, on this fixture.
    static let nounPrefix: [String: [String]] = [
        "status": ["status"],
        "health": ["health"],
        "account": ["account"],
        "limit": ["limit", "session"],
        "budget": ["budget"],
        "spend": ["spend"],
        "activity": ["activity", "today"],
        "model": ["model", "top"],
        "session": ["session", "latest"],
    ]

    /// M2 nouns whose walk lives with the fixture that can answer it
    /// hermetically: `price` needs an injected pricing cache
    /// (DeepQueryPricesTests), `windows` a ledger directory
    /// (DeepQueryWindowsTests). Named here so a NEW catalogued noun can't
    /// slip past the walk below by simply having no prefix.
    static let coveredElsewhere: Set<String> = ["price", "windows"]

    // MARK: - The catalog is the vocabulary

    /// The table lives beside the switches rather than inside them, so it
    /// CAN drift. This is the direction that matters: a name the catalog
    /// advertises (in an error line, or as a `--fields` cell) but no switch
    /// answers. Deep session fields legitimately fail here with their own
    /// "add --all" diagnostic — what must never appear is "has no field".
    @Test("every catalogued field name resolves — no advertised field is unroutable")
    func catalogueMatchesTheSwitches() throws {
        #expect(Set(Self.nounPrefix.keys).union(Self.coveredElsewhere) == Set(DigestQuery.fieldCatalog.keys))
        for (noun, fields) in DigestQuery.fieldCatalog where !Self.coveredElsewhere.contains(noun) {
            let prefix = try #require(Self.nounPrefix[noun])
            for name in fields.keys.sorted() {
                let out = run(prefix + [name])
                #expect(
                    out.note?.hasPrefix("\(noun) has no field") != true,
                    "\(noun) advertises '\(name)' but no switch answers it")
            }
        }
    }

    @Test("an unknown field enumerates the legal ones instead of leaving you to guess")
    func unknownFieldEnumerates() throws {
        let out = run(["session", "latest", "bogusfield"])
        #expect(out.exitCode == 19)
        let note = try #require(out.note)
        #expect(note.hasPrefix("session has no field 'bogusfield' — fields: "))
        // Alphabetical, and the whole vocabulary — deep names included, so
        // the list doesn't depend on which source answered.
        #expect(note.contains("api-calls, branch, compactions"))
        #expect(note.contains("tokens"))

        // Every noun with a catalog does it, not just `session`.
        for (noun, prefix) in Self.nounPrefix {
            let other = run(prefix + ["definitelyNotAField"])
            #expect(other.exitCode == 19)
            #expect(other.note?.contains("\(noun) has no field 'definitelyNotAField' — fields: ") == true)
        }
    }

    // MARK: - --fields

    @Test("--fields answers four questions in one invocation, as one TSV row")
    func fieldsReturnsOneRow() {
        let out = run(["session", "latest", "--fields", "tokens,cost,active,started"])
        #expect(out.exitCode == 0)
        #expect(out.stdout == "9535\t0.069\t5400\t2026-08-16T09:00:00Z")
        // Each cell is exactly what the single-field query prints — the
        // point of the flag is fewer forks, not a second formatting path.
        let singles = ["tokens", "cost", "active", "started"].map { run(["session", "latest", $0]).stdout }
        #expect(out.stdout == singles.joined(separator: "\t"))
    }

    @Test("--header names the columns; --json is an object in the REQUESTED order")
    func fieldsHeaderAndJSON() throws {
        let header = run(["session", "latest", "--fields", "tokens,cost", "--header"])
        #expect(header.stdout == "tokens\tcost\n9535\t0.069")

        let json = run(["session", "latest", "--fields", "tokens,cost", "--json"])
        #expect(json.stdout == "{\n  \"tokens\" : 9535,\n  \"cost\" : 0.069\n}")
        let data = try #require(json.stdout.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(decoded?.count == 2)
    }

    @Test("--fields composes with --relative and --unix rather than reinventing them")
    func fieldsComposeWithRegisterFlags() {
        #expect(run(["session", "latest", "--fields", "active", "--relative"]).stdout == "1 hr 30 min")
        let startedAt = DigestQueryTests.iso("2026-08-16T09:00:00Z")
        #expect(
            run(["session", "latest", "--fields", "started", "--unix"]).stdout
                == String(Int(startedAt.timeIntervalSince1970)))
    }

    @Test("--fields refuses a table-shaped field by NAME, not by sniffing its output")
    func fieldsRefusesTables() {
        let out = run(["limit", "session", "--fields", "percent,series"])
        #expect(out.exitCode == 19)
        #expect(out.note == "--fields can't carry 'series' — it's a table; query it on its own")
    }

    @Test("--fields validates its whole list up front: unknown names enumerate, empties are a bad query")
    func fieldsValidatesTheList() {
        let unknown = run(["status", "--fields", "plan,nope"])
        #expect(unknown.exitCode == 19)
        #expect(unknown.note?.hasPrefix("status has no field 'nope' — fields: ") == true)

        for list in ["tokens,", "", ",cost"] {
            let out = run(["session", "latest", "--fields", list])
            #expect(out.exitCode == 19)
            #expect(out.note == "--fields wants a comma-separated list — e.g. --fields tokens,cost")
        }
    }

    @Test("a positional field and --fields together is a bad query — one or the other names the fields")
    func fieldsRejectsAPositionalToo() {
        let out = run(["session", "latest", "tokens", "--fields", "cost"])
        #expect(out.exitCode == 19)
        #expect(out.note == "'tokens' and --fields both name fields — give one or the other")
    }

    @Test("--fields is only legal where a single field name is — a list noun rejects it as an unknown flag")
    func fieldsIsNotUniversal() {
        for args in [["sessions", "--fields", "tokens"], ["limits", "--fields", "percent"],
                     ["prompt", "--fields", "tokens"], ["models", "--fields", "cost"]] {
            let out = run(args)
            #expect(out.exitCode == 19)
            #expect(out.note == "unknown flag '--fields'")
        }
    }

    @Test("a field that fails past its NAME fails the whole row — never a partial one")
    func fieldsPropagatesAResolutionFailure() {
        // `kind` is catalogued but only the transcript scan answers it; a
        // shortlist hit gives the deep-gate diagnostic, and the row dies
        // with it rather than printing three cells and a lie.
        let out = run(["session", "latest", "--fields", "tokens,kind"])
        #expect(out.exitCode == 19)
        #expect(out.note == "session field 'kind' isn't in the shortlist — add --all to resolve it through the scan")
    }

    // MARK: - --relative durations

    @Test("--relative prints the house duration phrase for a seconds field; --json still gets a number")
    func relativeDurations() {
        #expect(run(["status", "age"]).stdout == "120")
        #expect(run(["status", "age", "--relative"]).stdout == "2 min")
        #expect(run(["status", "age", "--relative", "--json"]).stdout == "120")
        #expect(run(["limit", "session", "resets-in", "--relative"]).stdout == "2 hr")
        #expect(run(["session", "latest", "active", "--relative"]).stdout == "1 hr 30 min")
    }

    @Test("a negative seconds field keeps its sign under --relative — a reset already past isn't 'in 5 min'")
    func relativeSignsNegatives() {
        let later = DigestQueryTests.iso("2026-08-16T16:05:00Z")
        let out = run(["limit", "session", "resets-in", "--relative"], now: later)
        #expect(out.stdout == "-2 hr 5 min")
        #expect(run(["limit", "session", "resets-in"], now: later).stdout == "-7500")
    }

    @Test("an absent seconds field stays absent under --relative — never a fabricated '1 min'")
    func relativeKeepsAbsenceAbsent() {
        let engine = DigestQueryTests.minimalEngine(fetchedAt: nil)
        let state = DigestQueryTests.minimalState(engine: engine)
        let out = run(["status", "age", "--relative"], digest: state)
        #expect(out.stdout == "")
        #expect(out.exitCode == 0)
    }

    // MARK: - The raw register's cells are separator-free

    @Test("a tab inside a title or project can't shift a raw column")
    func tsvCellsAreSanitized() {
        let card = SessionCard(
            id: "tabbed", title: "one\ttwo", project: "pro\tject", branch: "br\nanch",
            startedAt: now, end: now, activeSeconds: 60, cost: nil, tokens: 1, prompts: 1,
            apiCalls: 1, modelColors: [])
        let state = DigestQueryTests.minimalState(engine: DigestQueryTests.minimalEngine(), sessions: [card])
        let out = run(["sessions", "--raw"], digest: state)
        let cells = out.stdout.components(separatedBy: "\t")
        #expect(cells.count == 11)
        #expect(cells[1] == "one two")
        #expect(cells[2] == "pro ject")
        #expect(cells[3] == "br anch")
        // …and the human table can't be knocked out of alignment either.
        #expect(!run(["sessions"], digest: state).stdout.contains("\t"))
    }

    // MARK: - sessions-cap

    @Test("status sessions-cap reports the WRITER's cap, and stays absent when the digest predates it")
    func sessionsCapComesFromTheDigest() throws {
        #expect(run(["status", "sessions-cap"]).stdout == "8")
        #expect(run(["status", "sessions-cap", "--json"]).stdout == "8")

        // A digest published before 0.84.0 has no such key: absent, not this
        // build's own constant dressed up as the writer's.
        var object = try #require(
            try JSONSerialization.jsonObject(with: goldenRaw) as? [String: Any])
        object.removeValue(forKey: "sessionsCap")
        let trimmed = try JSONSerialization.data(withJSONObject: object)
        let older = try LiveState.decoder().decode(LiveState.self, from: trimmed)
        let out = run(["status", "sessions-cap"], digest: older)
        #expect(out.stdout == "")
        #expect(out.exitCode == 0)
        #expect(run(["status", "sessions-cap", "--json"], digest: older).stdout == "null")
    }
}
