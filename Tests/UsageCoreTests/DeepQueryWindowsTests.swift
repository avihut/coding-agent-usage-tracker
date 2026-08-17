import Foundation
import Testing
@testable import UsageCore

/// `DeepQuery.windowsVerb` — pinned against synthetic `WindowOutcome` rows
/// written into a temp `window-ledger.json` via the real `WindowLedger`
/// write path (never the real user's support directory: every test passes
/// `directory:` explicitly, the test-only seam `windowsVerb` carries for
/// exactly this reason). Selector resolution against a live digest reuses
/// the golden fixture `DigestQueryTests` pins (`Fixtures/digest/
/// live-state-v1.json`; meters "session"/"S"/"Session (5h)" and
/// "weekly_all"/"W"/"Weekly (all)").
@Suite("DeepQuery.windows")
struct DeepQueryWindowsTests {
    let golden: LiveState
    let now = DeepQueryWindowsTests.iso("2026-08-16T12:00:00Z")

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        golden = try LiveState.decoder().decode(LiveState.self, from: try Data(contentsOf: fixtureURL))
    }

    static func iso(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    /// A fresh temp directory, cleaned up by the caller's `defer` — never
    /// the real `~/Library/Application Support` path.
    func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "deep-query-windows-tests-\(UUID().uuidString)")
    }

    /// Writes `outcomes` through the real `WindowLedger` persistence path
    /// (round-tripped through disk, not hand-serialized) so the verb's own
    /// `WindowLedger(directory:).load()` is genuinely exercised.
    func seed(_ outcomes: [WindowOutcome], in directory: URL) {
        _ = WindowLedger(directory: directory).record(outcomes, existing: [])
    }

    func outcome(
        meterID: String = "session", label: String = "Session (5h)", end: String,
        start: String? = nil, last: Int?, peak: Int?
    ) -> WindowOutcome {
        WindowOutcome(
            meterID: meterID, label: label, end: Self.iso(end), start: start.map(Self.iso),
            lastPercent: last, peakPercent: peak, recordedAt: Self.iso(end))
    }

    func run(
        _ args: [String], digest: LiveState?, directory: URL
    ) -> QueryOutput {
        let parsed = DigestQuery.parseArgs(args)
        #expect(parsed.error == nil)
        return DeepQuery.windowsVerb(
            parsed: parsed, digest: digest, providerID: "claude", now: now, directory: directory)
    }
}

// MARK: - Listing (no field)

extension DeepQueryWindowsTests {
    @Test func listsNewestFirstAcrossRegisters() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([
            outcome(end: "2026-08-15T21:00:00Z", last: 53, peak: 88),
            outcome(end: "2026-08-16T02:00:00Z", last: 100, peak: 100),
            // A different meter's row must never leak into "session"'s list.
            outcome(meterID: "weekly_all", label: "Weekly (all)", end: "2026-08-16T03:00:00Z", last: 10, peak: 10),
        ], in: directory)

        let out = run(["session"], digest: golden, directory: directory)
        #expect(out.exitCode == 0)
        let lines = out.stdout.components(separatedBy: "\n")
        #expect(lines.count == 2)
        // Newest end first.
        #expect(lines[0].hasPrefix("2026-08-16T02:00:00Z"))
        #expect(lines[0].hasSuffix("hit"))
        #expect(lines[1].hasPrefix("2026-08-15T21:00:00Z"))
        // A real `reachedLimit == false` reads "miss" — the em-dash stays
        // reserved for ABSENT (see the absent-rendering test below).
        #expect(lines[1].hasSuffix("miss"))
    }

    @Test func rawRegisterIsTSVWithOptionalHeader() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([
            outcome(end: "2026-08-16T02:00:00Z", start: "2026-08-15T21:00:00Z", last: 100, peak: 100),
        ], in: directory)

        let out = run(["session", "--raw", "--header"], digest: golden, directory: directory)
        #expect(out.exitCode == 0)
        let lines = out.stdout.components(separatedBy: "\n")
        #expect(lines[0] == "end\tstart\tlast\tpeak\thit")
        #expect(lines[1] == "2026-08-16T02:00:00Z\t2026-08-15T21:00:00Z\t100\t100\ttrue")
    }

    @Test func jsonRegisterEncodesFullOutcomes() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([outcome(end: "2026-08-16T02:00:00Z", last: 53, peak: 88)], in: directory)

        let out = run(["session", "--json"], digest: golden, directory: directory)
        #expect(out.exitCode == 0)
        let data = try #require(out.stdout.data(using: .utf8))
        let decoded = try LiveState.decoder().decode([WindowOutcome].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded[0].peakPercent == 88)
    }

    /// Pins "absent is not zero" on the LISTING path itself (every other
    /// listing test seeds non-nil last/peak, and `start` is otherwise only
    /// exercised non-nil in `rawRegisterIsTSVWithOptionalHeader`) — a row
    /// with no retained percent or start must render em-dash/empty/null,
    /// never the humanPercent(nil)/rawInt(nil)-defeating "0%"/"0".
    @Test func absentPercentsAndStartRenderAsAbsentAcrossRegisters() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([outcome(end: "2026-08-16T02:00:00Z", start: nil, last: nil, peak: nil)], in: directory)

        let human = run(["session"], digest: golden, directory: directory)
        #expect(human.exitCode == 0)
        #expect(human.stdout == "2026-08-16T02:00:00Z · — · — · — · miss")

        let raw = run(["session", "--raw"], digest: golden, directory: directory)
        #expect(raw.stdout == "2026-08-16T02:00:00Z\t\t\t\tfalse")

        let json = run(["session", "--json"], digest: golden, directory: directory)
        let data = try #require(json.stdout.data(using: .utf8))
        let decoded = try LiveState.decoder().decode([WindowOutcome].self, from: data)
        #expect(decoded.count == 1)
        #expect(decoded[0].start == nil)
        #expect(decoded[0].lastPercent == nil)
        #expect(decoded[0].peakPercent == nil)
    }

    @Test func emptyMatchIsAnEmptyListNotNoMatch() throws {
        // A valid, resolvable meter that has simply never closed a window
        // yet — an empty list (exit 0), never exit 20 ("selector matched
        // nothing" is about the METER, not its window count).
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = run(["session"], digest: golden, directory: directory)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "")
        let raw = run(["session", "--raw"], digest: golden, directory: directory)
        #expect(raw.stdout == "")
        let json = run(["session", "--json"], digest: golden, directory: directory)
        // The house `LiveState.encoder()` (pretty-printed) renders an empty
        // Codable array as "[\n\n]" on this toolchain, not "[]" — the same
        // shape every other noun's `jsonValue` on an empty list produces
        // (`DigestQueryFormat.jsonValue`), not something to special-case
        // here.
        #expect(json.stdout == "[\n\n]")
    }
}

// MARK: - --last / --since

extension DeepQueryWindowsTests {
    @Test func lastTakesTheMostRecentNAfterSorting() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([
            outcome(end: "2026-08-10T00:00:00Z", last: 10, peak: 10),
            outcome(end: "2026-08-14T00:00:00Z", last: 20, peak: 20),
            outcome(end: "2026-08-16T00:00:00Z", last: 30, peak: 30),
        ], in: directory)

        let out = run(["session", "--raw", "--last", "2"], digest: golden, directory: directory)
        let lines = out.stdout.components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("2026-08-16T00:00:00Z"))
        #expect(lines[1].hasPrefix("2026-08-14T00:00:00Z"))
    }

    @Test func lastAcceptsADurationAsATimeCutoff() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([
            outcome(end: "2026-08-01T00:00:00Z", last: 10, peak: 10),  // outside 7d of `now`
            outcome(end: "2026-08-15T00:00:00Z", last: 20, peak: 20),  // inside
        ], in: directory)

        // The SAME flag takes both grammars (`DeepQuery.parseLast`): a
        // bare integer is a row count (the test above), a suffixed
        // duration is a time cutoff — never a different meaning one deep
        // verb apart.
        let out = run(["session", "--raw", "--last", "7d"], digest: golden, directory: directory)
        let lines = out.stdout.components(separatedBy: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("2026-08-15T00:00:00Z"))
    }

    @Test func lastRejectsAValueInNeitherGrammar() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = run(["session", "--last", "5x"], digest: golden, directory: directory)
        #expect(out.exitCode == 19)
        #expect(out.note == "bad --last value '5x' — an integer count (8) or a duration (7d)")
    }

    @Test func sinceAcceptsALiteralDayKey() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([
            outcome(end: "2026-08-15T21:00:00Z", last: 10, peak: 10),
            outcome(end: "2026-08-16T02:00:00Z", last: 20, peak: 20),
        ], in: directory)

        // The golden digest's timeZone is UTC: midnight 2026-08-16 cuts
        // the 08-15 row — the same duration-or-day-key grammar history's
        // `--since` and M1's `sessions --since` share (`resolveSinceCutoff`).
        let out = run(["session", "--raw", "--since", "2026-08-16"], digest: golden, directory: directory)
        let lines = out.stdout.components(separatedBy: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("2026-08-16T02:00:00Z"))
    }

    @Test func sinceFiltersByDurationCutoff() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([
            outcome(end: "2026-08-01T00:00:00Z", last: 10, peak: 10),  // outside 7d of `now`
            outcome(end: "2026-08-15T00:00:00Z", last: 20, peak: 20),  // inside
        ], in: directory)

        let out = run(["session", "--raw", "--since", "7d"], digest: golden, directory: directory)
        let lines = out.stdout.components(separatedBy: "\n")
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("2026-08-15T00:00:00Z"))
    }

    @Test func sinceRejectsABadDuration() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = run(["session", "--since", "banana"], digest: golden, directory: directory)
        #expect(out.exitCode == 19)
        #expect(out.note == "bad --since value 'banana' — a duration (5m/2h/7d) or yyyy-MM-dd")
    }

    @Test func humanRowCarriesAllFiveRawColumns() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([
            outcome(end: "2026-08-16T02:00:00Z", start: "2026-08-15T21:00:00Z", last: 100, peak: 100),
        ], in: directory)

        // end · start · last · peak · hit — the same five columns as
        // raw/json, same order, so the registers line up cell for cell.
        let out = run(["session"], digest: golden, directory: directory)
        #expect(out.stdout == "2026-08-16T02:00:00Z · 2026-08-15T21:00:00Z · 100% · 100% · hit")
    }

    @Test func relativeShapesBothTextRegisters() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([outcome(end: "2026-08-16T02:00:00Z", last: 53, peak: 88)], in: directory)

        let human = run(["session", "--relative"], digest: golden, directory: directory)
        #expect(human.stdout.contains(" ago"))
        let raw = run(["session", "--raw", "--relative"], digest: golden, directory: directory)
        #expect(raw.stdout.contains(" ago"))
    }
}

// MARK: - hit-rate

extension DeepQueryWindowsTests {
    /// The catalogue walk for this noun (the digest nouns' lives in
    /// `DigestQueryFieldsTests`, `price`'s in `DeepQueryPricesTests`):
    /// `windows` advertises exactly one field, enumerates it on a typo like
    /// everyone else, and deliberately does NOT take `--fields` — one field
    /// has nothing to combine with, and an inert flag is worse than none.
    @Test("windows enumerates its one field and refuses --fields outright")
    func windowsFieldVocabulary() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([outcome(end: "2026-08-16T00:00:00Z", last: 100, peak: 100)], in: directory)

        #expect(DigestQuery.fieldCatalog["windows"]?.keys.sorted() == ["hit-rate"])
        #expect(run(["session", "hit-rate"], digest: golden, directory: directory).exitCode == 0)

        let typo = run(["session", "hit-rat"], digest: golden, directory: directory)
        #expect(typo.exitCode == 19)
        #expect(typo.note == "windows has no field 'hit-rat' — fields: hit-rate")

        let fields = DeepQuery.run(
            noun: "windows", arguments: ["session", "--fields", "hit-rate"], digest: golden,
            environment: [:], now: DeepQueryWindowsTests.iso("2026-08-16T12:00:00Z"))
        #expect(fields.exitCode == 19)
        #expect(fields.note == "unknown flag '--fields'")
    }

    @Test func hitRateIsTheObserved100Share() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([
            outcome(end: "2026-08-16T00:00:00Z", last: 100, peak: 100),
            outcome(end: "2026-08-15T00:00:00Z", last: 53, peak: 88),
            outcome(end: "2026-08-14T00:00:00Z", last: 10, peak: 10),
            outcome(end: "2026-08-13T00:00:00Z", last: 40, peak: 100),
        ], in: directory)

        let out = run(["session", "hit-rate"], digest: golden, directory: directory)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "0.5")
    }

    /// `reachedLimit`, not a bare `peakPercent >= 100`: a row with no
    /// retained peak still counts as a hit when `lastPercent` alone reached
    /// 100 — pins the choice against the cheaper-looking wrong predicate.
    @Test func hitRateCountsALastPercentHitWithNoRetainedPeak() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([outcome(end: "2026-08-16T00:00:00Z", last: 100, peak: nil)], in: directory)

        let out = run(["session", "hit-rate"], digest: golden, directory: directory)
        #expect(out.stdout == "1")
    }

    @Test func hitRateIsAbsentNeverZeroOverNoWindows() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let human = run(["session", "hit-rate"], digest: golden, directory: directory)
        #expect(human.exitCode == 0)
        #expect(human.stdout == "")
        let json = run(["session", "hit-rate", "--json"], digest: golden, directory: directory)
        #expect(json.stdout == "null")
    }

    @Test func unknownFieldIsBadQuery() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = run(["session", "bogus-field"], digest: golden, directory: directory)
        #expect(out.exitCode == 19)
    }
}

// MARK: - selector resolution

extension DeepQueryWindowsTests {
    @Test func selectorResolvesThroughDigestLabels() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([outcome(end: "2026-08-16T00:00:00Z", last: 100, peak: 100)], in: directory)
        // "Session" substring-matches the live meter's label — same
        // vocabulary `limit`'s selector accepts.
        let out = run(["Session", "hit-rate"], digest: golden, directory: directory)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "1")
    }

    @Test func selectorFallsBackToRawMeterIDWithNoDigest() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([outcome(end: "2026-08-16T00:00:00Z", last: 100, peak: 100)], in: directory)
        let out = run(["session", "hit-rate"], digest: nil, directory: directory)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "1")
    }

    @Test func selectorFallsBackToRawLabelEqualityWithNoDigest() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        seed([outcome(meterID: "0-session", label: "Session (5h)", end: "2026-08-16T00:00:00Z", last: 100, peak: 100)], in: directory)
        // Equality, not substring — the fallback vocabulary is deliberately
        // narrower than the digest-backed selector.
        let out = run(["Session (5h)", "hit-rate"], digest: nil, directory: directory)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "1")
    }

    @Test func unresolvableSelectorIsNoMatch() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = run(["not-a-meter"], digest: nil, directory: directory)
        #expect(out.exitCode == 20)
    }

    @Test func ambiguousRawLabelFallbackIsBadQuery() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Two distinct meter ids sharing one label — a rank shift's
        // aftermath (`MeterBuilder`'s ids are "\(index)-\(kind)"), the exact
        // shape the ledger accumulates across a rank change.
        seed([
            outcome(meterID: "0-session", label: "Session (5h)", end: "2026-08-15T00:00:00Z", last: 10, peak: 10),
            outcome(meterID: "1-session", label: "Session (5h)", end: "2026-08-16T00:00:00Z", last: 20, peak: 20),
        ], in: directory)
        let out = run(["Session (5h)"], digest: nil, directory: directory)
        #expect(out.exitCode == 19)
        #expect(out.note?.contains("0-session") == true)
        #expect(out.note?.contains("1-session") == true)
    }

    @Test func ambiguousDigestSelectorIsBadQuery() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Golden fixture's own labels both contain "e" — an ambiguous
        // substring against the live meter list, mirroring `limit`'s own
        // ambiguity contract exactly (delegated straight to `selectMeter`).
        let out = run(["e"], digest: golden, directory: directory)
        #expect(out.exitCode == 19)
    }
}

// MARK: - dispatcher wiring

extension DeepQueryWindowsTests {
    @Test func wrongProviderExits11ThroughTheDispatcher() {
        // Through `DeepQuery.run`, not `windowsVerb` directly — this is the
        // dispatcher's own guard, and `--provider` wins over any stored
        // default so the test never touches `UserDefaults.standard`.
        let out = DeepQuery.run(
            noun: "windows", arguments: ["session", "--provider", "codex"], digest: nil,
            environment: [:], now: now)
        #expect(out.exitCode == 11)
    }

    @Test func noSelectorIsBadQuery() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let out = run([], digest: golden, directory: directory)
        #expect(out.exitCode == 19)
    }
}
