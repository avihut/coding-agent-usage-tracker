import Foundation
import Testing

@testable import UsageCore

/// `prices`/`price` — exercised through the injectable
/// `DeepQuery.pricesVerb(parsed:providerID:cacheDirectory:)` overload, never
/// the dispatcher-facing one: that one resolves this MACHINE'S real
/// `~/Library/Application Support/com.avihu.ClaudeUsage/claude/pricing.json`
/// (which exists and holds real data on a dev box that has run the app —
/// verified present on this one), so hitting it from a test would read live
/// user data and make the suite non-deterministic. Every test here points at
/// a synthetic temp directory it creates and removes, per house rule.
@Suite("DeepQuery prices/price")
struct DeepQueryPricesTests {
    /// A small, hand-built table — deliberately NOT `PricingTable.bundled`
    /// (which can change shape over time) — covering every field this verb
    /// answers: a model with every rate class + context, and one missing
    /// `cache-write-1h` and `context` entirely, to exercise absent
    /// discipline.
    static let table = PricingTable(
        rates: [
            "claude-full-model": ModelRates(
                input: 3e-6, output: 1.5e-5, cacheWrite: 3.75e-6, cacheWrite1h: 6e-6, cacheRead: 3e-7,
                contextTokens: 200_000),
            "claude-no-1h": ModelRates(input: 1e-6, output: 5e-6, cacheWrite: 1.25e-6, cacheRead: 5e-7),
        ],
        fetchedAt: Date(timeIntervalSince1970: 1_785_600_000),
        source: .live)

    /// Writes `table` as `pricing.json` into a fresh temp subdir (the exact
    /// shape `PricingService.current()` reads) and hands back the directory
    /// — callers clean it up with `cleanup(_:)`.
    func makeCache(_ table: PricingTable? = DeepQueryPricesTests.table) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "deepquery-prices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let table {
            try JSONEncoder().encode(table).write(to: dir.appending(path: "pricing.json"))
        }
        return dir
    }

    func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// `args` includes the noun ("prices"/"price") the way a caller would
    /// type it — carried separately (as `DeepQuery.run` carries it) for the
    /// plural/singular arity guard, and dropped from the parsed positionals
    /// exactly as the real dispatcher drops it before parsing.
    func run(_ args: [String], cacheDirectory: URL) -> QueryOutput {
        DeepQuery.pricesVerb(
            noun: args[0], parsed: DigestQuery.parseArgs(Array(args.dropFirst())), providerID: "claude",
            cacheDirectory: cacheDirectory)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Space-pads a table cell to an EXPLICIT width, matching
    /// `DigestQueryTests.pad` — column widths below are named literals
    /// (`18 = len("claude-full-model")`) rather than a hand-typed run of
    /// spaces, which is easy to miscount by one and then fails for the
    /// wrong reason.
    func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: width, withPad: " ", startingAt: 0)
    }
}

// MARK: - prices (the whole catalog)

extension DeepQueryPricesTests {
    @Test func listHumanTableSortedByID() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["prices"], cacheDirectory: dir)
        #expect(out.exitCode == 0)
        // Sorted "claude-full-model" before "claude-no-1h"; absent
        // cache-write-1h/context render as em-dash, never 0 or blank; the
        // last column (context) is never padded.
        let row0 = [
            pad("claude-full-model", 17), pad("$3", 2), pad("$15", 3), pad("$0.30", 5), pad("$3.75", 5),
            pad("$6", 2), "200K",
        ].joined(separator: " · ")
        let row1 = [
            pad("claude-no-1h", 17), pad("$1", 2), pad("$5", 3), pad("$0.50", 5), pad("$1.25", 5),
            pad("—", 2), "—",
        ].joined(separator: " · ")
        #expect(out.stdout == "\(row0)\n\(row1)")
    }

    @Test func listRawIsTabSeparatedRatesTimesOneMillion() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["prices", "--raw"], cacheDirectory: dir)
        #expect(out.exitCode == 0)
        let lines = out.stdout.components(separatedBy: "\n")
        #expect(lines[0] == "claude-full-model\t3\t15\t0.3\t3.75\t6\t200000")
        // Missing rates/context are empty cells, not "0".
        #expect(lines[1] == "claude-no-1h\t1\t5\t0.5\t1.25\t\t")
    }

    @Test func listRawHeaderNamesEveryField() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["prices", "--raw", "--header"], cacheDirectory: dir)
        let header = out.stdout.components(separatedBy: "\n").first
        #expect(header == "id\tinput\toutput\tcache-read\tcache-write\tcache-write-1h\tcontext")
    }

    /// Shaped exactly like the singular's own `--json` (dollars-per-MTok,
    /// `PriceJSON`'s key vocabulary) — not the raw `PricingTable` wire
    /// shape — so plural and singular agree on units and key names for the
    /// same fact.
    @Test func listJSONIsShapedLikeTheSingularPerRow() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["prices", "--json"], cacheDirectory: dir)
        #expect(out.exitCode == 0)
        struct Row: Decodable, Equatable {
            let id: String
            let input, output: Double
            let cacheRead, cacheWrite, cacheWrite1h: Double?
            let context: Int?
            let source: String
            let fetched: Date?
            let listed: Bool
        }
        let decoded = try LiveState.decoder().decode([Row].self, from: Data(out.stdout.utf8))
        #expect(decoded == [
            Row(
                id: "claude-full-model", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75,
                cacheWrite1h: 6, context: 200_000, source: "live",
                fetched: Date(timeIntervalSince1970: 1_785_600_000), listed: true),
            Row(
                id: "claude-no-1h", input: 1, output: 5, cacheRead: 0.5, cacheWrite: 1.25,
                cacheWrite1h: nil, context: nil, source: "live",
                fetched: Date(timeIntervalSince1970: 1_785_600_000), listed: true),
        ])
    }

    /// No `pricing.json` at all — `PricingService.current()` falls back to
    /// `PricingTable.bundled`, so this verb still answers with no cache file
    /// and (per its own doc comment) no digest/daemon involved anywhere.
    /// `fetched` must be absent (null), never the bundled floor's
    /// `.distantPast` sentinel rendered as a real timestamp.
    @Test func noCacheFileFallsBackToBundledFloor() throws {
        let dir = try makeCache(nil)
        defer { cleanup(dir) }
        let out = run(["prices", "--json"], cacheDirectory: dir)
        struct Row: Decodable {
            let id: String
            let source: String
            let fetched: Date?
        }
        let decoded = try LiveState.decoder().decode([Row].self, from: Data(out.stdout.utf8))
        #expect(!decoded.isEmpty)
        #expect(decoded.allSatisfy { $0.source == "bundled" })
        #expect(decoded.allSatisfy { $0.fetched == nil })
    }
}

// MARK: - price (one model)

extension DeepQueryPricesTests {
    @Test func singularHumanSummaryLine() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["price", "claude-full-model"], cacheDirectory: dir)
        #expect(out.stdout == "claude-full-model · in $3/MTok · out $15/MTok · ctx 200K · live")
        #expect(out.exitCode == 0)

        // No context on this one — the "ctx" clause drops entirely rather
        // than printing a dash mid-sentence.
        let noCtx = run(["price", "claude-no-1h"], cacheDirectory: dir)
        #expect(noCtx.stdout == "claude-no-1h · in $1/MTok · out $5/MTok · live")
    }

    @Test func singularRawIsOneRowMatchingTheListColumns() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["price", "claude-full-model", "--raw", "--header"], cacheDirectory: dir)
        #expect(out.stdout == "id\tinput\toutput\tcache-read\tcache-write\tcache-write-1h\tcontext"
            + "\nclaude-full-model\t3\t15\t0.3\t3.75\t6\t200000")
    }

    @Test func singularJSONCarriesEveryFieldIncludingProvenance() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["price", "claude-full-model", "--json"], cacheDirectory: dir)
        struct Decoded: Decodable, Equatable {
            let id: String
            let input, output: Double
            let cacheRead, cacheWrite, cacheWrite1h: Double?
            let context: Int?
            let source: String
            let fetched: Date?
            let listed: Bool
        }
        let decoded = try LiveState.decoder().decode(Decoded.self, from: Data(out.stdout.utf8))
        #expect(decoded == Decoded(
            id: "claude-full-model", input: 3, output: 15, cacheRead: 0.3, cacheWrite: 3.75,
            cacheWrite1h: 6, context: 200_000, source: "live",
            fetched: Date(timeIntervalSince1970: 1_785_600_000), listed: true))
    }

    /// Every field this verb documents, one at a time — each `--raw` unless
    /// noted, absent renders empty (never "0" or "false" for a missing
    /// number/date).
    @Test func everyFieldOnTheFullModel() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        func field(_ name: String) -> String { run(["price", "claude-full-model", name], cacheDirectory: dir).stdout }
        #expect(field("input") == "3")
        #expect(field("output") == "15")
        #expect(field("cache-read") == "0.3")
        #expect(field("cache-write") == "3.75")
        #expect(field("cache-write-1h") == "6")
        #expect(field("context") == "200000")
        #expect(field("source") == "live")
        #expect(field("fetched") == Self.iso(Date(timeIntervalSince1970: 1_785_600_000)))
        #expect(field("listed") == "true")
    }

    @Test func absentRatesAndContextOnThePartialModel() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        func field(_ name: String) -> QueryOutput { run(["price", "claude-no-1h", name], cacheDirectory: dir) }
        #expect(field("cache-write-1h").stdout == "")
        #expect(field("cache-write-1h").exitCode == 0)
        #expect(field("context").stdout == "")
        #expect(field("context").exitCode == 0)
        // json: absent is null, never 0.
        let jsonOut = run(["price", "claude-no-1h", "cache-write-1h", "--json"], cacheDirectory: dir)
        #expect(jsonOut.stdout == "null")
    }

    /// The bundled floor's `fetchedAt` is a `.distantPast` sentinel, not a
    /// real fetch time — `fetched` is absent for it, not that sentinel date.
    @Test func fetchedIsAbsentOnTheBundledFloor() throws {
        let dir = try makeCache(nil)
        defer { cleanup(dir) }
        let out = run(["price", "claude-sonnet-5", "fetched"], cacheDirectory: dir)
        #expect(out.stdout == "")
        #expect(out.exitCode == 0)
        #expect(run(["price", "claude-sonnet-5", "fetched", "--json"], cacheDirectory: dir).stdout == "null")
    }

    @Test func dateSuffixedIDMatchesViaStrippingAndIsUnlisted() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["price", "claude-no-1h-20260101", "listed"], cacheDirectory: dir)
        #expect(out.stdout == "false")
        #expect(out.exitCode == 0)
        // The resolved RATES still come through — same numbers as the exact id.
        #expect(run(["price", "claude-no-1h-20260101", "input"], cacheDirectory: dir).stdout == "1")
    }

    @Test func exactIDIsListedTrue() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        #expect(run(["price", "claude-no-1h", "listed"], cacheDirectory: dir).stdout == "true")
    }

    @Test func unknownModelExitsTwentyWithNearbyCandidatesInTheNote() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["price", "claude-full-nope"], cacheDirectory: dir)
        #expect(out.exitCode == DigestQuery.exitNoMatch)
        #expect(out.stdout == "")
        // Ranked by shared prefix length: "claude-full-model" (12 chars
        // shared) before "claude-no-1h" (7 shared).
        #expect(out.note == "no priced model matches 'claude-full-nope' — nearby: claude-full-model, claude-no-1h")
    }

    @Test func unknownFieldIsABadQuery() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["price", "claude-full-model", "bogus"], cacheDirectory: dir)
        #expect(out.exitCode == DigestQuery.exitBadQuery)
        // Enumerated like every other noun's (0.84.0) — a field-taking M2
        // verb is not a second class of noun.
        #expect(
            out.note
                == "price has no field 'bogus' — fields: cache-read, cache-write, cache-write-1h, context,"
                + " fetched, input, listed, output, source")
    }

    /// `DigestQueryFieldsTests` walks the digest nouns' catalogue entries;
    /// `price` needs this suite's injected cache, so its walk lives here.
    @Test("every catalogued price field resolves, and --fields carries them in one row")
    func catalogueMatchesTheSwitchesAndComposes() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        for name in (DigestQuery.fieldCatalog["price"] ?? [:]).keys.sorted() {
            let out = run(["price", "claude-full-model", name], cacheDirectory: dir)
            #expect(
                out.note?.hasPrefix("price has no field") != true,
                "price advertises '\(name)' but no switch answers it")
        }
        let row = run(["price", "claude-full-model", "--fields", "input,output,context"], cacheDirectory: dir)
        #expect(row.exitCode == 0)
        #expect(row.stdout == "3\t15\t200000")
    }

    @Test func tooManyArgumentsIsABadQuery() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["price", "claude-full-model", "input", "extra"], cacheDirectory: dir)
        #expect(out.exitCode == DigestQuery.exitBadQuery)
    }

    @Test func pricesTakesNoSelector() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["prices", "claude-full-model"], cacheDirectory: dir)
        #expect(out.exitCode == DigestQuery.exitBadQuery)
        #expect(out.note == "prices takes no selector — did you mean 'price claude-full-model'?")
    }

    @Test func priceNeedsASelector() throws {
        let dir = try makeCache()
        defer { cleanup(dir) }
        let out = run(["price"], cacheDirectory: dir)
        #expect(out.exitCode == DigestQuery.exitBadQuery)
        #expect(out.note == "price needs a selector — a model id")
    }

    /// `run(...)` above calls `DeepQuery.pricesVerb` directly, so nothing
    /// else in this suite exercises `DeepQuery.run`'s `case "prices",
    /// "price"` — the dispatcher switch that threads `noun` through. The
    /// wrong-provider exit alone doesn't prove that: it fires from
    /// `DeepQuery.run`'s OWN guard before the switch is ever reached, so it
    /// would pass even if the switch mis-threaded `noun`. `pricesVerb`
    /// validates arity BEFORE reading the pricing cache, so these two
    /// noun-DISCRIMINATING arity errors reach all the way through the real
    /// dispatcher (its real, unsynthesized cache directory) without ever
    /// touching disk — and each message would be wrong if `noun` arrived
    /// swapped or hardcoded at the call site.
    @Test func dispatcherThreadsNounThroughToPricesVerbWithoutTouchingDisk() {
        // `--provider claude` pins the resolution: `DeepQuery.run`'s
        // provider guard reads the host's persisted `activeProviderID`
        // default BEFORE the arity checks asserted here, and a hermetic
        // test must not depend on what some other app run left there.
        let plural = DeepQuery.run(
            noun: "prices", arguments: ["claude-sonnet-5", "--provider", "claude"],
            digest: nil, environment: [:], now: Date())
        #expect(plural.exitCode == DigestQuery.exitBadQuery)
        #expect(plural.note == "prices takes no selector — did you mean 'price claude-sonnet-5'?")

        let singular = DeepQuery.run(
            noun: "price", arguments: ["--provider", "claude"], digest: nil, environment: [:], now: Date())
        #expect(singular.exitCode == DigestQuery.exitBadQuery)
        #expect(singular.note == "price needs a selector — a model id")
    }

    /// A non-"claude" provider exits 11 before `pricesVerb` runs at all
    /// (`DeepQuery.run`'s own guard, ahead of the switch) — kept as
    /// hermetic coverage of that guard, distinct from the noun-threading
    /// test above.
    @Test func dispatcherRejectsNonClaudeProviderBeforeTouchingDisk() {
        for noun in ["prices", "price"] {
            let out = DeepQuery.run(
                noun: noun, arguments: ["--provider", "codex"], digest: nil, environment: [:], now: Date())
            #expect(out.exitCode == DeepQuery.exitWrongProvider)
        }
    }

    /// The hand-built fixture's rates all multiply by 1e6 exactly, so it
    /// alone can't catch the bundled floor's binary-floating-point noise
    /// (`1e-7 * 1e6 == 0.09999999999999999`). This table is deliberately
    /// noisy on ALL THREE raw/json rendering paths — `priceField` (singular
    /// field), `priceRawRow` (plural `--raw` cell), and the plural
    /// `--json` row — independent of `PricingTable.bundled`'s own values,
    /// which this file doesn't own and could change shape later.
    @Test func rawAndJSONAvoidFloatNoiseOnAllThreeRatePaths() throws {
        let noisy = PricingTable(
            rates: ["noisy-model": ModelRates(input: 2e-7, output: 1e-7, cacheRead: 1e-7)],
            fetchedAt: Date(timeIntervalSince1970: 1_785_600_000), source: .live)
        let dir = try makeCache(noisy)
        defer { cleanup(dir) }

        // Singular field (priceField).
        #expect(run(["price", "noisy-model", "cache-read"], cacheDirectory: dir).stdout == "0.1")
        #expect(run(["price", "noisy-model", "cache-read", "--json"], cacheDirectory: dir).stdout == "0.1")

        // Plural raw row (priceRawRow).
        let rawOut = run(["prices", "--raw"], cacheDirectory: dir)
        #expect(rawOut.stdout == "noisy-model\t0.2\t0.1\t0.1\t\t\t")

        // Plural json row (pricesListOutput → PriceJSON).
        struct Row: Decodable { let cacheRead: Double? }
        let jsonOut = run(["prices", "--json"], cacheDirectory: dir)
        let decoded = try LiveState.decoder().decode([Row].self, from: Data(jsonOut.stdout.utf8))
        #expect(decoded.first?.cacheRead == 0.1)
    }
}
