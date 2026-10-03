import Foundation
import Testing

@testable import UsageCore

/// `headroom` — the gate a caller asks before spending on a harness — and
/// the `--max-data-age` guard it rides on. Every case is a digest built in
/// code (the goldens can't carry a stale snapshot, a rolled window or a red
/// forecast) except the harness selection, which reads the multi-harness
/// golden the way `LiveStateHarnessTests` does. `now` is pinned throughout.
///
/// The exit code IS the answer here, so every case pins it, in every
/// register: 0 room, 24 at or over the cap, 25 a failing forecast, 26
/// nothing to judge, 21 numbers older than the caller allows.
@Suite("headroom")
struct DigestQueryHeadroomTests {
    let now = Self.at("2026-08-16T12:00:00Z")

    static func at(_ text: String) -> Date { DigestQueryTests.iso(text) }

    /// One account's engine. `fetchedAt` (when the numbers were measured)
    /// and `generatedAt` (when the digest was written) are apart on purpose:
    /// that gap is what the data-age guard exists to see.
    static func engine(
        fetchedAt: Date? = at("2026-08-16T11:58:00Z"), generatedAt: Date = at("2026-08-16T12:00:00Z")
    ) -> EngineStatus {
        EngineStatus(
            providerID: "codex", serviceName: "Codex", agentName: "Codex", glyph: "⬡",
            accent: RGBColor(red: 0.4, green: 0.4, blue: 0.9), planLabel: "Pro plan",
            planSubscriptionType: "pro", planRateLimitTier: nil, appVersion: "0.102.0", pid: 4242,
            host: "daemon", generatedAt: generatedAt, fetchedAt: fetchedAt, nextPollAt: nil,
            backoffUntil: nil, stale: false, isLocalProvider: true, activeIntervalSeconds: 300,
            paceMultiplier: 1, apiBudgetUsed: nil, apiBudgetCeiling: nil, apiBudgetFraction: nil,
            gateFloorSeconds: 180, error: nil, spend: nil)
    }

    /// A meter resetting Thursday unless told otherwise, with a forecast of
    /// the given verdict (nil = none fitted yet).
    static func meter(
        _ id: String, _ tag: String, _ label: String, percent: Int?,
        resetsAt: Date? = at("2026-08-20T00:00:00Z"), forecast verdict: String? = "green"
    ) -> LiveMeter {
        let severities: [String: Double] = ["green": 0, "yellow": 0.5, "red": 0.9]
        let severity = severities[verdict ?? ""] ?? 0.7
        return LiveMeter(
            id: id, label: label, tag: tag, percent: percent, level: "normal", rank: 0,
            rateWindowSeconds: 2700, forcesWarning: false, risk: nil, resetsAt: resetsAt,
            limitWindow: 604_800, scopedModelName: nil,
            resetCaption: resetsAt.map { _ in "resets Thu 00:00" },
            forecast: verdict.map { verdict in
                MeterForecast(
                    projectedAtReset: verdict == "green" ? 60 : 100,
                    exhaustsAt: verdict == "green" ? nil : at("2026-08-18T09:00:00Z"),
                    verdict: verdict, rawVerdict: verdict, severity: severity, ratePerHour: 1,
                    baselineRatePerHour: nil, paceFactor: nil, basis: "recentOnly",
                    caption: verdict == "green" ? nil : "runs out Tue 09:00", curve: [])
            },
            series: [], stretches: [])
    }

    static let session = meter("0-session", "S", "Session (5h)", percent: 20)
    static let weekly = meter("1-weekly", "W", "Weekly", percent: 61)
    static let scoped = meter("2-weekly_scoped", "F", "Weekly · Fable", percent: 40)

    func state(_ meters: [LiveMeter], engine: EngineStatus = engine()) -> LiveState {
        DigestQueryTests.minimalState(engine: engine, meters: meters)
    }

    func run(_ args: [String], _ digest: LiveState, now: Date? = nil) -> QueryOutput {
        DigestQuery.run(
            arguments: args, digest: digest, rawDigest: (try? LiveState.encoder().encode(digest)) ?? Data(),
            environment: [:], now: now ?? self.now)
    }

    /// `--json`'s object as a dictionary — `NSNull` where the answer is
    /// absent, so a test can tell a null key from a missing one.
    func object(_ output: QueryOutput) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
        return try #require(value as? [String: Any])
    }
}

// MARK: - The cap

extension DigestQueryHeadroomTests {
    @Test("under the cap is room; at the cap and over it are not")
    func capBoundaries() {
        let digest = state([Self.meter("1-weekly", "W", "Weekly", percent: 35)])
        let under = run(["headroom", "--cap", "80"], digest)
        #expect(under.exitCode == 0)
        #expect(under.stdout == "codex · W 35% of cap 80% · 45 pts left · resets Thu 00:00")
        #expect(under.note == nil)
        let at = run(["headroom", "--cap", "35"], digest)
        #expect(at.exitCode == 24)
        #expect(at.stdout == "codex · W 35% of cap 35% · at the cap · resets Thu 00:00")
        let over = run(["headroom", "--cap", "30"], digest)
        #expect(over.exitCode == 24)
        #expect(over.stdout == "codex · W 35% of cap 30% · 5 pts over · resets Thu 00:00")
        #expect(run(["headroom", "--cap", "36"], digest).stdout.contains(" · 1 pt left · "))
        #expect(run(["headroom", "--cap", "34"], digest).stdout.contains(" · 1 pt over · "))
        // A cap of 0 refuses everything there is a number for; 100 refuses
        // only a spent limit.
        #expect(run(["headroom", "--cap", "0"], digest).exitCode == 24)
        #expect(run(["headroom", "--cap", "100"], digest).exitCode == 0)
        #expect(run(["headroom", "--cap", "100"], state([Self.meter("w", "W", "Weekly", percent: 100)])).exitCode == 24)
    }

    @Test("with no selector every meter is judged and the closest to the cap binds — not the first")
    func bindingMeter() throws {
        let digest = state([Self.session, Self.weekly, Self.scoped])
        let room = run(["headroom", "--cap", "80", "--json"], digest)
        #expect(room.exitCode == 0)
        #expect(try object(room)["tag"] as? String == "W")
        #expect(try object(room)["headroom"] as? Int == 19)
        // Two meters over: the one furthest over is reported.
        let over = run(["headroom", "--cap", "30"], digest)
        #expect(over.exitCode == 24)
        #expect(over.stdout == "codex · W 61% of cap 30% · 31 pts over · resets Thu 00:00")
    }

    @Test("a tie on percent goes to the riskier forecast")
    func tieGoesToTheRiskierForecast() {
        let digest = state([
            Self.meter("0-session", "S", "Session (5h)", percent: 50),
            Self.meter("1-weekly", "W", "Weekly", percent: 50, forecast: "yellow"),
        ])
        let out = run(["headroom", "--cap", "80"], digest)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "codex · W 50% of cap 80% · 30 pts left · resets Thu 00:00 · forecast yellow — runs out Tue 09:00")
    }

    @Test("a selector narrows the judgment to one meter, with limit's grammar")
    func selector() {
        let digest = state([Self.session, Self.weekly, Self.scoped])
        let session = run(["headroom", "S", "--cap", "50"], digest)
        #expect(session.exitCode == 0)
        #expect(session.stdout == "codex · S 20% of cap 50% · 30 pts left · resets Thu 00:00")
        #expect(run(["headroom", "1-weekly", "--cap", "50"], digest).exitCode == 24)
        #expect(run(["headroom", "fable", "--cap", "50"], digest).exitCode == 0)
        let miss = run(["headroom", "monthly", "--cap", "50"], digest)
        #expect(miss.exitCode == 20)
        #expect(miss.stdout == "")
        #expect(miss.note == "no meter matches 'monthly'")
        let ambiguous = run(["headroom", "weekly", "--cap", "50"], digest)
        #expect(ambiguous.exitCode == 19)
        #expect(ambiguous.note == "ambiguous selector 'weekly' matches: 1-weekly, 2-weekly_scoped")
        // A field name in the selector slot is a selector — fields go in --fields.
        #expect(run(["headroom", "percent", "--cap", "50"], digest).exitCode == 20)
    }
}

// MARK: - Nothing to judge

extension DigestQueryHeadroomTests {
    @Test("no meters is nothing to judge — never 0% used")
    func zeroMeters() throws {
        let digest = state([])
        let out = run(["headroom", "--cap", "80"], digest)
        #expect(out.exitCode == 26)
        #expect(out.stdout == "codex · no meters — nothing to judge")
        // A selector has nothing to narrow — still nothing to judge, not a miss.
        #expect(run(["headroom", "W", "--cap", "80"], digest).exitCode == 26)
        let json = try object(run(["headroom", "--cap", "80", "--json"], digest))
        #expect(json["verdict"] as? String == "no-data")
        #expect(json["percent"] is NSNull)
        #expect(json["headroom"] is NSNull)
    }

    @Test("an unreported percent is nothing to judge, unless a selector judges another meter")
    func absentPercent() throws {
        let unreported = Self.meter("1-weekly", "W", "Weekly", percent: nil, forecast: nil)
        let digest = state([Self.session, unreported])
        let out = run(["headroom", "--cap", "80"], digest)
        #expect(out.exitCode == 26)
        #expect(out.stdout == "codex · W — of cap 80% · no percent reported — nothing to judge")
        let json = try object(run(["headroom", "--cap", "80", "--json"], digest))
        #expect(json["tag"] as? String == "W")
        #expect(json["percent"] is NSNull)
        #expect(run(["headroom", "S", "--cap", "80"], digest).exitCode == 0)
        #expect(run(["headroom", "W", "--cap", "80"], digest).exitCode == 26)
        // A known refusal outranks an unknown: over the cap is reported as that.
        let over = state([Self.meter("0-session", "S", "Session (5h)", percent: 90), unreported])
        #expect(run(["headroom", "--cap", "80"], over).exitCode == 24)
    }
}

// MARK: - The data-age guard

extension DigestQueryHeadroomTests {
    /// The issue's own observation: a local snapshot 14.5 h old inside a
    /// digest written a moment ago. `--max-age` passes it — and still does;
    /// `--max-data-age` is the guard that sees it.
    @Test("a stale local snapshot under a fresh digest is 21, ahead of any verdict on its numbers")
    func staleSnapshot() throws {
        let old = state(
            [Self.meter("1-weekly", "W", "Weekly", percent: 95)],
            engine: Self.engine(fetchedAt: Self.at("2026-08-15T21:30:00Z")))
        #expect(run(["headroom", "--cap", "80", "--max-age", "30m"], old).exitCode == 24)
        let stale = run(["headroom", "--cap", "80", "--max-data-age", "30m"], old)
        #expect(stale.exitCode == 21)
        #expect(stale.stdout == "codex · stale — measured 14 hr 30 min ago, past --max-data-age 30m")
        #expect(stale.note == nil)
        // The object still prints, so a refused caller can log why — and an
        // untrusted number is reported neither over nor under.
        let json = try object(run(["headroom", "--cap", "80", "--max-data-age", "30m", "--json"], old))
        #expect(json["verdict"] as? String == "stale")
        #expect(json["percent"] is NSNull)
        #expect(json["headroom"] is NSNull)
        #expect(json["dataAge"] as? Int == 52_200)
        #expect(json["fetchedAt"] as? String == "2026-08-15T21:30:00Z")
        // Within the allowance the numbers are judged as usual.
        #expect(run(["headroom", "--cap", "80", "--max-data-age", "15h"], old).exitCode == 24)
    }

    @Test("no measurement stamp fails the guard: absent is not fresh")
    func absentFetchedAt() {
        let unstamped = state([Self.session], engine: Self.engine(fetchedAt: nil))
        let out = run(["headroom", "--cap", "80", "--max-data-age", "7d"], unstamped)
        #expect(out.exitCode == 21)
        #expect(out.stdout == "codex · stale — no measurement time to judge its age by")
        // Without the guard nobody asked about age.
        #expect(run(["headroom", "--cap", "80"], unstamped).exitCode == 0)
    }

    @Test("a stamp ahead of this clock fails the guard past a minute's tolerance")
    func clockSetBack() {
        let slightly = state([Self.session], engine: Self.engine(fetchedAt: now.addingTimeInterval(30)))
        #expect(run(["headroom", "--cap", "80", "--max-data-age", "1m"], slightly).exitCode == 0)
        let ahead = state([Self.session], engine: Self.engine(fetchedAt: now.addingTimeInterval(7200)))
        let out = run(["headroom", "--cap", "80", "--max-data-age", "7d"], ahead)
        #expect(out.exitCode == 21)
        #expect(out.stdout == "codex · stale — measured 2 hr ahead of this clock, so its age can't be judged")
    }

    @Test("--max-age on headroom is a stale verdict too, and its object still prints")
    func maxAgeOnHeadroom() throws {
        let abandoned = state(
            [Self.session],
            engine: Self.engine(
                fetchedAt: Self.at("2026-08-16T09:58:00Z"), generatedAt: Self.at("2026-08-16T10:00:00Z")))
        let out = run(["headroom", "--cap", "80", "--max-age", "30m"], abandoned)
        #expect(out.exitCode == 21)
        #expect(out.stdout == "codex · stale — the digest was written 2 hr ago, past --max-age 30m")
        let json = try object(run(["headroom", "--cap", "80", "--max-age", "30m", "--json"], abandoned))
        #expect(json["verdict"] as? String == "stale")
    }
}

// MARK: - The forecast gate

extension DigestQueryHeadroomTests {
    @Test("--forecast red fails on red; --forecast yellow on yellow or red; without it the exit never moves")
    func forecastLevels() {
        func code(_ verdict: String?, _ level: String?) -> Int32 {
            let digest = state([Self.meter("1-weekly", "W", "Weekly", percent: 40, forecast: verdict)])
            return run(["headroom", "--cap", "80"] + (level.map { ["--forecast", $0] } ?? []), digest).exitCode
        }
        #expect(code("green", "red") == 0)
        #expect(code("yellow", "red") == 0)
        #expect(code("red", "red") == 25)
        #expect(code("green", "yellow") == 0)
        #expect(code("yellow", "yellow") == 25)
        #expect(code("red", "yellow") == 25)
        #expect(code("red", nil) == 0)
        // No forecast fitted yet projects nothing: the cap alone binds.
        #expect(code(nil, "red") == 0)
        #expect(code(nil, "yellow") == 0)
        // A verdict this build doesn't know fails both levels — fail closed.
        #expect(code("purple", "red") == 25)
        #expect(code("purple", "yellow") == 25)
    }

    @Test("over the cap outranks a failing forecast")
    func overCapOutranksForecast() {
        let digest = state([Self.meter("1-weekly", "W", "Weekly", percent: 90, forecast: "red")])
        #expect(run(["headroom", "--cap", "80", "--forecast", "red"], digest).exitCode == 24)
    }

    /// The forecast gate refuses on ANY judged meter: a weekly limit on
    /// course to run out binds even while the session sits nearer the cap,
    /// and the run reports the meter that failed.
    @Test("a failing forecast on a meter that isn't the closest to the cap still refuses, and is the one reported")
    func forecastOnAnyMeter() throws {
        let digest = state([
            Self.meter("0-session", "S", "Session (5h)", percent: 60),
            Self.meter("1-weekly", "W", "Weekly", percent: 30, forecast: "red"),
        ])
        let refused = run(["headroom", "--cap", "80", "--forecast", "red"], digest)
        #expect(refused.exitCode == 25)
        #expect(refused.stdout == "codex · W 30% of cap 80% · 50 pts left · resets Thu 00:00 · forecast red — runs out Tue 09:00")
        let json = try object(run(["headroom", "--cap", "80", "--forecast", "red", "--json"], digest))
        #expect(json["percent"] as? Int == 30)
        let forecast = try #require(json["forecast"] as? [String: Any])
        #expect(forecast["verdict"] as? String == "red")
        #expect(forecast["projected"] as? Int == 100)
        #expect(forecast["exhaustsAt"] as? String == "2026-08-18T09:00:00Z")
        // Unasked, the forecast is reported but the closest meter binds.
        let unasked = run(["headroom", "--cap", "80"], digest)
        #expect(unasked.exitCode == 0)
        #expect(unasked.stdout.hasPrefix("codex · S 60% of cap 80%"))
    }

    @Test("a window whose reset has passed judges as 0%, with no reset and no forecast")
    func rolledWindow() throws {
        let spent = Self.meter(
            "1-weekly", "W", "Weekly", percent: 95, resetsAt: now.addingTimeInterval(-3600), forecast: "red")
        let digest = state([spent])
        let out = run(["headroom", "--cap", "80", "--forecast", "red"], digest)
        #expect(out.exitCode == 0)
        #expect(out.stdout == "codex · W 0% of cap 80% · 80 pts left")
        let json = try object(run(["headroom", "--cap", "80", "--json"], digest))
        #expect(json["percent"] as? Int == 0)
        #expect(json["resetsAt"] is NSNull)
        #expect(json["forecast"] is NSNull)
        // `next` is the soonest reset still ahead — never one already past.
        let upcoming = Self.meter("0-session", "S", "Session (5h)", percent: 30, resetsAt: now.addingTimeInterval(3600))
        let both = state([upcoming, spent])
        #expect(run(["headroom", "next", "--cap", "80", "--fields", "tag"], both).stdout == "S")
    }
}

// MARK: - Whose numbers

extension DigestQueryHeadroomTests {
    /// The multi-harness golden: Codex focused, a Claude account and a
    /// dormant second one, a hidden Gemini — every section fetched 11:58.
    func harnesses(_ args: [String], now: Date = Self.at("2026-09-19T12:00:00Z")) throws -> QueryOutput {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1-harnesses.json")
        let raw = try Data(contentsOf: fixtureURL)
        let digest = try LiveState.decoder().decode(LiveState.self, from: raw)
        return DigestQuery.run(arguments: args, digest: digest, rawDigest: raw, environment: [:], now: now)
    }

    @Test("--provider judges that harness's account; a hidden harness is still judged")
    func providerSelection() throws {
        #expect(try harnesses(["headroom", "--provider", "claude", "--cap", "80"]).stdout
            == "claude · S 41% of cap 80% · 39 pts left · resets in 2h")
        #expect(try harnesses(["headroom", "--provider", "codex", "--cap", "80"]).stdout
            == "codex · S 13% of cap 80% · 67 pts left · resets in 2h")
        let gemini = try harnesses(["headroom", "--provider", "gemini", "--cap", "80", "--fields", "provider,account,percent"])
        #expect(gemini.stdout == "gemini\tgemini\t4")
        #expect(gemini.exitCode == 0)
        // Nothing named: the focus answers, as on every account noun.
        #expect(try harnesses(["headroom", "--cap", "80", "--fields", "provider"]).stdout == "codex")
    }

    /// The selector lets an unmetered `--provider` fall through to the focus
    /// so a verb's own gate speaks — headroom's says nothing to judge, and
    /// never answers with the focused harness's numbers.
    @Test("a harness nobody meters is nothing to judge, never the focused harness's numbers")
    func unmeteredProvider() throws {
        let out = try harnesses(["headroom", "--provider", "nope", "--cap", "80"])
        #expect(out.exitCode == 26)
        #expect(out.stdout == "nope · not metered here — nothing to judge")
        let json = try object(try harnesses(["headroom", "--provider", "nope", "--cap", "80", "--json"]))
        #expect(json["provider"] as? String == "nope")
        #expect(json["account"] is NSNull)
        #expect(json["percent"] is NSNull)
        #expect(json["fetchedAt"] is NSNull)
        // Under the guard there is no measurement to be fresh.
        #expect(try harnesses(["headroom", "--provider", "nope", "--cap", "80", "--max-data-age", "1h"]).exitCode == 21)
        #expect(try harnesses(["headroom", "--provider", " ", "--cap", "80"]).exitCode == 19)
    }

    @Test("--account selects; a dormant account has nothing to judge; refusals are the selector's own")
    func accountSelection() throws {
        let dormant = try harnesses(["headroom", "--account", "c982130e", "--cap", "80"])
        #expect(dormant.exitCode == 26)
        #expect(dormant.stdout == "claude (c982130e) · no meters — nothing to judge")
        #expect(try harnesses(["headroom", "--account", "c982130e", "--cap", "80", "--max-data-age", "1h"]).exitCode == 21)
        #expect(try harnesses(["headroom", "--account", "default", "--cap", "80"]).exitCode == 0)
        #expect(try harnesses(["headroom", "--account", "default", "--provider", "codex", "--cap", "80"]).exitCode == 19)
        #expect(try harnesses(["headroom", "--account", "nope", "--cap", "80"]).exitCode == 20)
    }
}

// MARK: - The question itself

extension DigestQueryHeadroomTests {
    @Test("a missing or malformed --cap, --forecast or duration is a bad query")
    func badQueries() {
        let digest = state([Self.session])
        let missing = run(["headroom"], digest)
        #expect(missing.exitCode == 19)
        #expect(missing.note == "headroom needs --cap <percent> — a whole number from 0 to 100")
        for cap in ["80.5", "-1", "101", "eighty", ""] {
            let out = run(["headroom", "--cap", cap], digest)
            #expect(out.exitCode == 19, "\(cap)")
            #expect(out.note == "bad --cap '\(cap)' — a whole number from 0 to 100")
        }
        #expect(run(["headroom", "--cap"], digest).exitCode == 19)
        #expect(run(["headroom", "--cap", "80", "--forecast", "green"], digest).note == "bad --forecast 'green' — yellow or red")
        #expect(run(["headroom", "--cap", "80", "--max-data-age", "15"], digest).note
            == "bad --max-data-age duration '15' — e.g. 90s, 5m, 2h, 7d")
        #expect(run(["headroom", "--cap", "80", "--max-age", "1.5h"], digest).exitCode == 19)
        #expect(run(["headroom", "S", "W", "--cap", "80"], digest).exitCode == 19)
        // A bad duration is a bad query even when the other guard would fail.
        let old = state([Self.session], engine: Self.engine(generatedAt: Self.at("2026-08-15T00:00:00Z")))
        #expect(run(["headroom", "--cap", "80", "--max-age", "1m", "--max-data-age", "soon"], old).exitCode == 19)
    }
}

// MARK: - Registers

extension DigestQueryHeadroomTests {
    @Test("--raw is one TSV row, named by --header; --unix stamps the reset in seconds")
    func rawRegister() {
        let digest = state([Self.session, Self.weekly])
        let row = "ok\tcodex\tdefault\tW\t61\t80\t19\t2026-08-20T00:00:00Z\tgreen\t120"
        #expect(run(["headroom", "--cap", "80", "--raw"], digest).stdout == row)
        let named = run(["headroom", "--cap", "80", "--raw", "--header"], digest)
        #expect(named.stdout == DigestQuery.headroomColumns.joined(separator: "\t") + "\n" + row)
        let unix = run(["headroom", "--cap", "80", "--raw", "--unix"], digest)
        #expect(unix.stdout.contains("\t\(Int(Self.at("2026-08-20T00:00:00Z").timeIntervalSince1970))\t"))
        #expect(run(["headroom", "--cap", "50", "--raw"], digest).exitCode == 24)
    }

    @Test("--json is one object with every key in every verdict, absent as null")
    func jsonRegister() throws {
        let digest = state([Self.session, Self.weekly])
        let out = run(["headroom", "--cap", "80", "--json"], digest)
        #expect(out.exitCode == 0)
        let json = try object(out)
        let keys: Set = [
            "verdict", "cap", "percent", "headroom", "label", "tag", "resetsAt", "resetsIn", "forecast",
            "fetchedAt", "dataAge", "plan", "planType", "provider", "account",
        ]
        #expect(Set(json.keys) == keys)
        #expect(json["verdict"] as? String == "ok")
        #expect(json["cap"] as? Int == 80)
        #expect(json["percent"] as? Int == 61)
        #expect(json["label"] as? String == "Weekly")
        #expect(json["resetsAt"] as? String == "2026-08-20T00:00:00Z")
        #expect(json["resetsIn"] as? Int == 302_400)
        #expect(json["dataAge"] as? Int == 120)
        #expect(json["plan"] as? String == "Pro plan")
        #expect(json["planType"] as? String == "pro")
        #expect(json["account"] as? String == "default")
        // The same keys when nothing could be judged.
        let empty = try object(run(["headroom", "--cap", "80", "--json"], state([])))
        #expect(Set(empty.keys) == keys)
        #expect(empty["forecast"] is NSNull)
    }

    @Test("--fields answers in the verdict's exit code, and refuses names it doesn't know")
    func fieldsRegister() {
        let digest = state([Self.session, Self.weekly])
        let row = run(["headroom", "--cap", "80", "--fields", "percent,headroom,verdict"], digest)
        #expect(row.stdout == "61\t19\tok")
        #expect(row.exitCode == 0)
        let over = run(["headroom", "--cap", "50", "--fields", "headroom", "--json"], digest)
        #expect(over.stdout == "{\n  \"headroom\" : -11\n}")
        #expect(over.exitCode == 24)
        let relative = run(["headroom", "--cap", "80", "--fields", "resets-in,data-age", "--relative"], digest)
        #expect(relative.stdout == "3 days 12 hr\t2 min")
        let unknown = run(["headroom", "--cap", "80", "--fields", "bogus"], digest)
        #expect(unknown.exitCode == 19)
        #expect(unknown.note?.hasPrefix("headroom has no field 'bogus' — fields: account, cap, data-age") == true)
    }

    /// `DigestQueryFieldsTests` walks the other nouns with a positional
    /// field; headroom's one positional is the meter selector, so its walk
    /// is through `--fields`, here.
    @Test("every catalogued headroom field resolves through --fields")
    func catalogueWalk() throws {
        let digest = state([Self.session, Self.weekly])
        let names = try #require(DigestQuery.fieldCatalog["headroom"]).keys.sorted()
        #expect(names.count == 17)
        for name in names {
            let out = run(["headroom", "--cap", "80", "--fields", name], digest)
            #expect(out.exitCode == 0, "\(name)")
            #expect(out.note == nil, "\(name)")
        }
    }
}

// MARK: - The consumer's contract

extension DigestQueryHeadroomTests {
    /// The command lines a delegation gate ships (cahoots' agent-usage
    /// meter): it reads `percent` off ONE JSON object and the exit code, and
    /// takes anything but 0/21/24/25/26 as no answer — 19 meaning "this
    /// usage-cli has no headroom noun".
    @Test("the gate's exact command lines answer with one JSON object and an answer code")
    func gateContract() throws {
        let gate = ["headroom", "--provider", "codex", "--cap", "77", "--forecast", "red", "--json", "--max-data-age", "15m"]
        let watch = ["headroom", "--provider", "claude", "--cap", "90", "--json", "--max-data-age", "15m"]
        let probe = ["headroom", "--provider", "claude", "--cap", "100", "--json"]

        func percent(_ output: QueryOutput) throws -> Any? { try object(output)["percent"] }
        let fresh = Self.at("2026-09-19T12:05:00Z")
        #expect(try harnesses(gate, now: fresh).exitCode == 0)
        #expect(try percent(harnesses(gate, now: fresh)) as? Int == 13)
        #expect(try harnesses(watch, now: fresh).exitCode == 0)
        #expect(try percent(harnesses(watch, now: fresh)) as? Int == 41)
        #expect(try harnesses(probe, now: fresh).exitCode == 0)

        // Twenty-two minutes after the 11:58 measurement both gates refuse
        // as stale, still printing their object; the probe sets no guard.
        let late = Self.at("2026-09-19T12:20:00Z")
        for argv in [gate, watch] {
            let out = try harnesses(argv, now: late)
            #expect(out.exitCode == 21)
            #expect(try percent(out) is NSNull)
        }
        #expect(try harnesses(probe, now: late).exitCode == 0)
    }
}

// MARK: - --max-data-age on the other nouns

extension DigestQueryHeadroomTests {
    @Test("--max-data-age is silent 21 on the nouns that read a measurement, where --max-age passes")
    func dataAgeOnTheMeasurementNouns() {
        let old = state([Self.session], engine: Self.engine(fetchedAt: Self.at("2026-08-15T21:30:00Z")))
        #expect(run(["limits", "--max-age", "30m"], old).exitCode == 0)
        for args in [
            ["limits"], ["limit", "S"], ["status"], ["status", "fetched"], ["spend"], ["prompt"],
            ["get", "engine.planLabel"],
        ] {
            let out = run(args + ["--max-data-age", "30m"], old)
            #expect(out.exitCode == 21, "\(args)")
            #expect(out.stdout == "", "\(args)")
            #expect(out.note == nil, "\(args)")
        }
        #expect(run(["limits", "--max-data-age", "15h"], old).exitCode == 0)
        #expect(run(["limits", "--max-data-age", "15h"], old).stdout != "")
        let unstamped = state([Self.session], engine: Self.engine(fetchedAt: nil))
        #expect(run(["limits", "--max-data-age", "7d"], unstamped).exitCode == 21)
        #expect(run(["limits", "--max-data-age", "a while"], old).exitCode == 19)
    }

    @Test("--max-data-age, --cap and --forecast are unknown flags wherever they mean nothing")
    func applicability() {
        let digest = state([Self.session])
        for noun in ["budget", "activity", "cost", "models", "accounts", "account", "harnesses", "health", "notices"] {
            let out = run([noun, "--max-data-age", "1h"], digest)
            #expect(out.exitCode == 19, "\(noun)")
            #expect(out.note == "unknown flag '--max-data-age'", "\(noun)")
        }
        #expect(run(["limits", "--cap", "80"], digest).note == "unknown flag '--cap'")
        #expect(run(["limit", "S", "--forecast", "red"], digest).note == "unknown flag '--forecast'")
        let windows = DeepQuery.run(
            noun: "windows", arguments: ["S", "--max-data-age", "1h"], digest: nil, environment: [:], now: now)
        #expect(windows.note == "unknown flag '--max-data-age'")
        let sessions = DeepQuerySessionsCLI.run(
            noun: "sessions", arguments: ["--max-data-age", "1h"], digest: nil, now: now)
        #expect(sessions.note == "unknown flag '--max-data-age'")
    }
}
