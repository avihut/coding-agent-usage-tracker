import Foundation
import Testing

@testable import UsageCore

/// `DeepQuery.historyVerb` — exercised directly (not through `DeepQuery.run`)
/// with an injected `historyDirectory`, so these tests never touch the real
/// user's `~/Library/Application Support` history file. One route-level test
/// at the bottom covers the provider-11 gate, which lives in `DeepQuery.run`
/// itself and needs no file.
@Suite("DeepQuery.history")
struct DeepQueryHistoryTests {
    let golden: LiveState
    let now = DeepQueryHistoryTests.iso("2026-08-16T12:00:00Z")

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        golden = try LiveState.decoder().decode(LiveState.self, from: Data(contentsOf: fixtureURL))
    }

    static func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// Writes `samples` to a fresh temp directory's `history.json` via the
    /// SAME bare `JSONEncoder` `UsageHistory.append` itself writes with —
    /// deliberately NOT `LiveState.encoder()`'s ISO8601/pretty settings. A
    /// hand-typed ISO-string fixture would silently decode back to an empty
    /// array (`UsageHistory.load()` uses a bare `JSONDecoder()`, whose
    /// default date strategy is `.deferredToDate`) and every assertion
    /// below would keep "passing" against a series that never loaded — see
    /// `emptyFixtureFailsClosed` for the control that proves this file's
    /// fixtures are actually live.
    @discardableResult
    func withSamples<T>(_ samples: [UsageSample], _ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "deep-query-history-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(samples)
        try data.write(to: directory.appending(path: "history.json"))
        return try body(directory)
    }

    func run(
        _ args: [String], digest: LiveState?, directory: URL, now: Date? = nil
    ) -> QueryOutput {
        let parsed = DigestQuery.parseArgs(args)
        return DeepQuery.historyVerb(
            parsed: parsed, digest: digest, providerID: "claude", now: now ?? self.now,
            historyDirectory: directory)
    }

    // A shared four-sample fixture: mixed keys across samples, so the
    // "carries the label" skip rule has something to prove against.
    // 09:00 session only · 10:00 session+weekly · 11:00 weekly only ·
    // 12:00 (=now) session only.
    static let s0900 = UsageSample(t: iso("2026-08-16T09:00:00Z"), percents: ["Session (5h)": 10])
    static let s1000 = UsageSample(
        t: iso("2026-08-16T10:00:00Z"), percents: ["Session (5h)": 30, "Weekly (all)": 5])
    static let s1100 = UsageSample(t: iso("2026-08-16T11:00:00Z"), percents: ["Weekly (all)": 8])
    static let s1200 = UsageSample(t: iso("2026-08-16T12:00:00Z"), percents: ["Session (5h)": 53])
    var mixedSamples: [UsageSample] { [Self.s0900, Self.s1000, Self.s1100, Self.s1200] }
}

// MARK: - core row rule: skip samples that don't carry the selected label

extension DeepQueryHistoryTests {
    @Test func skipsSamplesMissingTheSelectedLabel() throws {
        try withSamples(mixedSamples) { directory in
            // "weekly_all" carries the LABEL "Weekly (all)" — only s1000
            // and s1100 report it; s0900/s1200 are session-only and must
            // not appear, let alone as fabricated 0% rows.
            let out = run(["weekly_all", "--raw"], digest: golden, directory: directory)
            #expect(out.stdout == "2026-08-16T10:00:00Z\t5\n2026-08-16T11:00:00Z\t8")
            #expect(out.exitCode == 0)
        }
    }

    @Test func selectsSessionAndSkipsTheWeeklyOnlySample() throws {
        try withSamples(mixedSamples) { directory in
            let out = run(["session", "--raw"], digest: golden, directory: directory)
            #expect(
                out.stdout
                    == "2026-08-16T09:00:00Z\t10\n2026-08-16T10:00:00Z\t30\n2026-08-16T12:00:00Z\t53")
        }
    }

    /// Absent-is-not-zero governs a MISSING value, not a genuine 0 — a 0%
    /// sample (e.g. right after a limit-window reset) must still be
    /// emitted as a real row, never silently stripped by a stray
    /// truthiness check.
    @Test func genuineZeroPercentSampleIsEmittedNotStripped() throws {
        let reset = UsageSample(t: Self.iso("2026-08-16T08:00:00Z"), percents: ["Session (5h)": 0])
        try withSamples([reset] + mixedSamples) { directory in
            let out = run(["session", "--raw"], digest: golden, directory: directory)
            #expect(
                out.stdout
                    == "2026-08-16T08:00:00Z\t0\n2026-08-16T09:00:00Z\t10\n2026-08-16T10:00:00Z\t30\n2026-08-16T12:00:00Z\t53")
        }
    }

    /// The control: corrupt/absent samples must yield an EMPTY series, not
    /// a passing test for the wrong reason — proves `withSamples`'s fixture
    /// is actually being read.
    @Test func emptyFixtureFailsClosed() throws {
        try withSamples([]) { directory in
            let out = run(["session"], digest: golden, directory: directory)
            #expect(out.stdout == "")
            #expect(out.exitCode == 0)
        }
    }
}

// MARK: - resolved but empty vs. genuinely unresolved

extension DeepQueryHistoryTests {
    @Test func resolvedViaDigestButZeroMatchingSamplesIsEmptyNotAnError() throws {
        // Every sample here is session-only — "weekly_all" resolves fine
        // via the digest (the meter exists), but nothing in history.json
        // ever carried its label. Absent series, not an error: exit 0.
        try withSamples([Self.s0900, Self.s1200]) { directory in
            let out = run(["weekly_all"], digest: golden, directory: directory)
            #expect(out.stdout == "")
            #expect(out.exitCode == 0)
            #expect(out.note == nil)
        }
    }

    @Test func unresolvableSelectorExits20() throws {
        try withSamples(mixedSamples) { directory in
            let out = run(["nonexistent-meter"], digest: golden, directory: directory)
            #expect(out.stdout == "")
            #expect(out.exitCode == 20)
        }
    }

    @Test func ambiguousDigestSelectorExits19BeforeAnyRawFallback() throws {
        // Both meter labels ("Session (5h)", "Weekly (all)") contain "e" —
        // an ambiguous DIGEST match is a real conflict and must fail
        // immediately, never quietly defer to raw-label matching.
        try withSamples(mixedSamples) { directory in
            let out = run(["e"], digest: golden, directory: directory)
            #expect(out.exitCode == 19)
            #expect(out.note == "ambiguous selector 'e' matches: session, weekly_all")
        }
    }
}

// MARK: - digest-nil raw-label fallback

extension DeepQueryHistoryTests {
    @Test func nilDigestFallsBackToRawLabelMatching() throws {
        let custom = UsageSample(t: now, percents: ["Custom Meter": 42])
        try withSamples([custom]) { directory in
            let exact = run(["Custom Meter", "--raw"], digest: nil, directory: directory)
            #expect(exact.stdout == "2026-08-16T12:00:00Z\t42")
            let substring = run(["custom", "--raw"], digest: nil, directory: directory)
            #expect(substring.stdout == "2026-08-16T12:00:00Z\t42")
        }
    }

    @Test func nilDigestUnresolvedExits20() throws {
        let custom = UsageSample(t: now, percents: ["Custom Meter": 42])
        try withSamples([custom]) { directory in
            let out = run(["zzz"], digest: nil, directory: directory)
            #expect(out.exitCode == 20)
        }
    }

    @Test func ambiguousRawLabelFallbackExits19() throws {
        let samples = [
            UsageSample(t: now, percents: ["Alpha One": 1, "Alpha Two": 2]),
        ]
        try withSamples(samples) { directory in
            let out = run(["alpha"], digest: nil, directory: directory)
            #expect(out.exitCode == 19)
            #expect(out.note == "ambiguous selector 'alpha' matches: Alpha One, Alpha Two")
        }
    }

    /// The headline feature this verb exists for: a meter that changed
    /// rank or dropped out of the LIVE digest still resolves via its raw
    /// history label — this is the digest-PRESENT half of that fallthrough
    /// (a digest miss, not just a nil digest); only the nil-digest half was
    /// covered before.
    @Test func digestPresentButMissingSelectorFallsBackToRawLabelMatching() throws {
        let retired = UsageSample(t: now, percents: ["Retired Meter": 7])
        try withSamples([retired]) { directory in
            let out = run(["retired", "--raw"], digest: golden, directory: directory)
            #expect(out.stdout == "2026-08-16T12:00:00Z\t7")
            #expect(out.exitCode == 0)
        }
    }
}

// MARK: - argument validation and exit-code precedence

extension DeepQueryHistoryTests {
    @Test func noSelectorIsBadQuery() throws {
        try withSamples([]) { directory in
            let out = run([], digest: golden, directory: directory)
            #expect(out.exitCode == 19)
        }
    }

    @Test func tooManyPositionalsIsBadQuery() throws {
        try withSamples([]) { directory in
            let out = run(["session", "extra"], digest: golden, directory: directory)
            #expect(out.exitCode == 19)
        }
    }

    @Test func badLastValueExits19EvenWithAnAmbiguousSelector() throws {
        // "e" would itself be ambiguous (exit 19 either way) — the point is
        // that value validation happens BEFORE selector resolution, so
        // this exits on the --last message, not a selector one.
        try withSamples(mixedSamples) { directory in
            let out = run(["e", "--last", "5x"], digest: golden, directory: directory)
            #expect(out.exitCode == 19)
            #expect(out.note == "bad --last value '5x' — an integer count (8) or a duration (7d)")
        }
    }

    @Test func badSinceDurationExits19BeforeAnUnresolvableSelector() throws {
        try withSamples(mixedSamples) { directory in
            let out = run(["nonexistent-meter", "--since", "oops"], digest: golden, directory: directory)
            #expect(out.exitCode == 19)
            #expect(out.note == "bad --since value 'oops' — a duration (5m/2h/7d) or yyyy-MM-dd")
        }
    }

    /// `--since` shares M1's duration-OR-day-key grammar (`filterSessions`/
    /// `resolveSince`), not `--last`'s duration-only one — a literal
    /// yyyy-MM-dd must resolve, not exit 19.
    @Test func sinceAcceptsALiteralDayKey() throws {
        try withSamples(mixedSamples) { directory in
            // The digest's fixture timeZone is UTC (see live-state-v1.json);
            // 2026-08-16 at midnight UTC cuts off everything before 09:00
            // the same day, so all four mixed samples survive.
            let out = run(["session", "--since", "2026-08-16", "--raw"], digest: golden, directory: directory)
            #expect(out.exitCode == 0)
            #expect(out.stdout == "2026-08-16T09:00:00Z\t10\n2026-08-16T10:00:00Z\t30\n2026-08-16T12:00:00Z\t53")
        }
    }
}

// MARK: - --last / --since trimming

extension DeepQueryHistoryTests {
    @Test func defaultWindowIsAllSamples() throws {
        try withSamples(mixedSamples) { directory in
            let out = run(["session"], digest: golden, directory: directory)
            #expect(out.stdout.components(separatedBy: "\n").count == 3)
        }
    }

    @Test func lastCutoffIsInclusive() throws {
        // now=12:00, --last 2h -> cutoff exactly 10:00; s1000 sits AT the
        // cutoff and must still be included (>=, not >).
        try withSamples(mixedSamples) { directory in
            let out = run(["session", "--last", "2h", "--raw"], digest: golden, directory: directory)
            #expect(out.stdout == "2026-08-16T10:00:00Z\t30\n2026-08-16T12:00:00Z\t53")
        }
    }

    @Test func lastAcceptsABareIntegerAsASampleCount() throws {
        // The dual grammar (`DeepQuery.parseLast`): a bare integer keeps
        // the LAST n rows of the chronological series — the suffix,
        // windows' newest-n mirrored — while a suffixed duration stays a
        // time cutoff (the test above).
        try withSamples(mixedSamples) { directory in
            let out = run(["session", "--last", "2", "--raw"], digest: golden, directory: directory)
            #expect(out.stdout == "2026-08-16T10:00:00Z\t30\n2026-08-16T12:00:00Z\t53")
        }
    }

    @Test func lastAndSinceTogetherIntersect() throws {
        // --last 3h -> cutoff 09:00; --since 1h -> cutoff 11:00. The more
        // restrictive of the two (11:00) governs: only s1200 survives.
        try withSamples(mixedSamples) { directory in
            let out = run(
                ["session", "--last", "3h", "--since", "1h", "--raw"], digest: golden, directory: directory)
            #expect(out.stdout == "2026-08-16T12:00:00Z\t53")
        }
    }
}

// MARK: - registers

extension DeepQueryHistoryTests {
    /// `history` is a series noun (unbounded cardinality — 56 days of
    /// poll-resolution samples), not a bounded record list — its human
    /// register is TSV like `limit ... series`/`curve`, never an aligned
    /// " · " table (`windows`'s record rows are the different case).
    @Test func humanRegisterIsTSVLikeAnySeriesNoun() throws {
        try withSamples(mixedSamples) { directory in
            let out = run(["session"], digest: golden, directory: directory)
            #expect(out.stdout == "2026-08-16T09:00:00Z\t10\n2026-08-16T10:00:00Z\t30\n2026-08-16T12:00:00Z\t53")
        }
    }

    @Test func rawHeaderIsTPercent() throws {
        try withSamples([Self.s1200]) { directory in
            let out = run(["session", "--raw", "--header"], digest: golden, directory: directory)
            #expect(out.stdout == "t\tpercent\n2026-08-16T12:00:00Z\t53")
        }
    }

    /// `--header` must be honored on the human (non-raw) register too — it
    /// used to be silently dropped there when only the --raw branch read it.
    @Test func humanHeaderIsTPercent() throws {
        try withSamples([Self.s1200]) { directory in
            let out = run(["session", "--header"], digest: golden, directory: directory)
            #expect(out.stdout == "t\tpercent\n2026-08-16T12:00:00Z\t53")
        }
    }

    @Test func jsonRegisterRoundTripsThroughLiveStateDecoder() throws {
        struct Point: Codable, Equatable { let t: Date; let percent: Int }
        try withSamples([Self.s0900, Self.s1200]) { directory in
            let out = run(["session", "--json"], digest: golden, directory: directory)
            let data = try #require(out.stdout.data(using: .utf8))
            let decoded = try LiveState.decoder().decode([Point].self, from: data)
            #expect(decoded == [
                Point(t: Self.iso("2026-08-16T09:00:00Z"), percent: 10),
                Point(t: Self.iso("2026-08-16T12:00:00Z"), percent: 53),
            ])
        }
    }

    /// Pinned exactly (not just decoded) so a date-encoding-strategy drift
    /// fails loudly — matches `LiveState.encoder()`'s own pretty+sortedKeys
    /// shape (percent before t, alphabetically).
    @Test func jsonRegisterExactShapeForOneRow() throws {
        try withSamples([Self.s1200]) { directory in
            let out = run(["session", "--json"], digest: golden, directory: directory)
            #expect(out.stdout == """
                [
                  {
                    "percent" : 53,
                    "t" : "2026-08-16T12:00:00Z"
                  }
                ]
                """)
        }
    }

    /// An empty series is `[]`, never `null` — absent-is-not-zero governs a
    /// missing VALUE, not an empty LIST (same rule `runLimits`/`limit
    /// ... series` follow).
    @Test func jsonRegisterOnEmptySeriesIsEmptyArrayNotNull() throws {
        try withSamples([Self.s0900, Self.s1200]) { directory in
            // "weekly_all" resolves via the digest but nothing here carries
            // its label.
            let out = run(["weekly_all", "--json"], digest: golden, directory: directory)
            #expect(out.stdout == "[\n\n]")
        }
    }

    @Test func unixFlagFormatsEpochSeconds() throws {
        try withSamples([Self.s1200]) { directory in
            let out = run(["session", "--raw", "--unix"], digest: golden, directory: directory)
            #expect(out.stdout == "\(Int(Self.iso("2026-08-16T12:00:00Z").timeIntervalSince1970))\t53")
        }
    }

    @Test func relativeFlagFormatsElapsedPhrase() throws {
        // now=12:00, sample at 09:00 -> 3h elapsed, the same
        // UsageFormatting.duration phrasing `status`'s "fetched N ago" uses.
        try withSamples([Self.s0900]) { directory in
            let out = run(["session", "--raw", "--relative"], digest: golden, directory: directory)
            #expect(out.stdout == "\(UsageFormatting.duration(3 * 3600)) ago\t10")
        }
    }
}

// MARK: - route-level: provider gate lives in DeepQuery.run, not historyVerb

extension DeepQueryHistoryTests {
    @Test func nonClaudeProviderExits11ThroughTheDispatcher() {
        // No file needed: DeepQuery.run's provider guard rejects before
        // historyVerb (and any disk read) ever runs.
        let out = DeepQuery.run(
            noun: "history", arguments: ["session", "--provider", "codex"], digest: golden,
            environment: [:], now: now)
        #expect(out.exitCode == DeepQuery.exitWrongProvider)
    }
}
