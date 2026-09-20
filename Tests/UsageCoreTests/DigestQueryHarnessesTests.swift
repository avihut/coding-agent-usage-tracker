import Foundation
import Testing

@testable import UsageCore

/// The `harnesses` noun (0.101.0) and the two verbs that had to learn about
/// several vendors: `notices`, which now lists every shown harness's, and
/// `health --check`, which answers about the machine rather than about
/// whichever harness holds focus.
@Suite("Digest query · harnesses") struct DigestQueryHarnessesTests {
    private func harness(
        _ id: String, glyph: String, agent: String, shown: Bool = true, present: Bool = true,
        files: Int? = nil, days: Int? = nil, accounts: Int = 1,
        status: ServiceStatusCard? = nil, notices: NoticesCard? = nil
    ) -> HarnessState {
        HarnessState(
            id: id, serviceName: agent, agentName: agent, glyph: glyph,
            shortName: agent.split(separator: " ").first.map(String.init) ?? agent,
            accent: RGBColor(red: 0.5, green: 0.5, blue: 0.5), isLocalProvider: id != "claude",
            present: present, shown: shown, recentFiles: files, activeDays: days,
            newestActivityAt: files == nil ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
            accountCount: accounts, serviceStatus: status, notices: notices, outages: nil)
    }

    private func card(_ items: [NoticeCard], indicator: Bool = true) -> NoticesCard {
        NoticesCard(indicator: indicator, pendingCount: items.count, items: items)
    }

    private func notice(_ id: String, at: Date, ongoing: Bool = false) -> NoticeCard {
        NoticeCard(
            id: id, kind: "reset", severity: nil, title: "Limit reset", detail: nil,
            when: "~21:10", occurredAt: at, endedAt: at, ongoing: ongoing, dismissable: true,
            seen: false, ownsMenuBarSurface: false, url: nil, components: [],
            meterLabel: nil)
    }

    private let golden: LiveState
    private let goldenRaw: Data

    init() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1.json")
        goldenRaw = try Data(contentsOf: fixtureURL)
        golden = try LiveState.decoder().decode(LiveState.self, from: goldenRaw)
    }

    private func state(_ harnesses: [HarnessState]?) -> LiveState {
        LiveState(
            schemaVersion: golden.schemaVersion, sessionsCap: golden.sessionsCap,
            engine: golden.engine, meters: golden.meters, menuBar: golden.menuBar,
            models: golden.models, activity: golden.activity, sessions: golden.sessions,
            serviceStatus: golden.serviceStatus, appUpdate: golden.appUpdate,
            accountPresence: golden.accountPresence, notices: golden.notices,
            outages: golden.outages, focusedProfile: golden.focusedProfile,
            profiles: golden.profiles, menuBarCells: golden.menuBarCells, harnesses: harnesses)
    }

    private func run(_ arguments: [String], _ harnesses: [HarnessState]?) -> QueryOutput {
        DigestQuery.run(
            arguments: arguments, digest: state(harnesses), rawDigest: goldenRaw,
            environment: [:], now: DigestQueryTests.iso("2026-08-16T12:00:00Z"))
    }

    private var three: [HarnessState] {
        [
            harness("claude", glyph: "✳︎", agent: "Claude Code", files: 217, days: 7, accounts: 2),
            harness("codex", glyph: "⬡", agent: "Codex", files: 15, days: 2),
            harness("gemini", glyph: "✦", agent: "Gemini CLI", shown: false),
        ]
    }

    @Test("the table lists every detected harness, hidden ones included")
    func table() {
        let out = run(["harnesses"], three)
        #expect(out.exitCode == 0)
        let lines = out.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("id"))
        #expect(lines[1].contains("claude") && lines[1].contains("Claude Code"))
        #expect(lines[1].contains("shown") && lines[1].contains("217 session files over 7 active days"))
        // Two accounts of one harness are counted on its own row.
        #expect(lines[1].contains(" 2 "))
        // A harness the person hid is LISTED and says so — hiding is a
        // display choice, and a face that dropped it could not report it.
        #expect(lines[3].contains("gemini") && lines[3].contains("hidden"))
        // The caller's clock, not Date(): the age is computed against the
        // pinned `now`, so it is the same on any host at any time.
        let quiet = UsageFormatting.duration(
            DigestQueryTests.iso("2026-08-16T12:00:00Z")
                .timeIntervalSince(Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(lines[3].contains("quiet — last active \(quiet) ago"))
    }

    @Test("raw is TSV over the same columns")
    func raw() {
        let rows = run(["harnesses", "--raw"], three).stdout
            .split(separator: "\n")
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(rows[0] == DigestQuery.harnessesColumns)
        #expect(rows[1][0] == "claude")
        #expect(rows[1][3] == "2")
        #expect(rows[1][4] == "shown")
        #expect(rows[1][5] == "217 files · 7 days")
        #expect(rows[3][4] == "hidden")
    }

    @Test("scalars count what they name")
    func scalars() {
        #expect(run(["harnesses", "count"], three).stdout == "3")
        #expect(run(["harnesses", "shown"], three).stdout == "2")
        #expect(run(["harnesses", "hidden"], three).stdout == "1")
        // Focus is an ACCOUNT's, so the harness is the one it belongs to.
        #expect(run(["harnesses", "focused"], three).stdout == "claude")
    }

    @Test("a writer that publishes no roster answers absent, never 1")
    func absentRoster() {
        #expect(run(["harnesses"], nil).stdout.isEmpty)
        #expect(run(["harnesses"], nil).exitCode == 0)
        // Absent, in the register's own spelling — never a confident "1",
        // which would be this build's assumption rather than its word.
        #expect(run(["harnesses", "count"], nil).stdout == DigestQueryFormat.rawInt(nil))
        #expect(run(["harnesses", "count", "--json"], nil).stdout == "null")
        #expect(run(["harnesses", "focused"], nil).stdout == DigestQueryFormat.rawInt(nil))
        #expect(run(["harnesses", "--json"], nil).stdout == "null")
    }

    @Test("json is the digest's own list, and an unknown field enumerates")
    func jsonAndFields() throws {
        let json = run(["harnesses", "--json"], three)
        let decoded = try LiveState.decoder().decode(
            [HarnessState].self, from: Data(json.stdout.utf8))
        #expect(decoded.map(\.id) == ["claude", "codex", "gemini"])
        let bad = run(["harnesses", "nope"], three)
        #expect(bad.exitCode == DigestQuery.exitBadQuery)
        #expect(bad.note?.contains("count") == true && bad.note?.contains("shown") == true)
        // --fields renders one TSV row over the requested names, in order.
        let fields = run(["harnesses", "--fields", "shown,count"], three)
        #expect(fields.stdout == "2\t3")
    }

    @Test("notices list every SHOWN harness's, and a dismissal still routes")
    func noticesSpanHarnesses() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(3_600)
        let harnesses = [
            harness(
                "claude", glyph: "✳︎", agent: "Claude Code", files: 10, days: 1,
                notices: card([notice("reset|1700000000", at: older)])),
            harness(
                "codex", glyph: "⬡", agent: "Codex", files: 3, days: 1,
                notices: card([notice("codex:reset|1700003600", at: newer)])),
            // Hidden: metered, but not listed — "not interested" is what
            // hiding means, and the list is what "Dismiss all" dismisses.
            harness(
                "gemini", glyph: "✦", agent: "Gemini CLI", shown: false,
                notices: card([notice("gemini:reset|1700007200", at: newer)])),
        ]
        let out = run(["notices", "--raw"], harnesses)
        #expect(out.stdout.contains("reset|1700000000"))
        // The id stays qualified, so `notices dismiss` reaches one ledger.
        #expect(out.stdout.contains("codex:reset|1700003600"))
        #expect(!out.stdout.contains("gemini:"))
        #expect(run(["notices", "count"], harnesses).stdout == "2")
        // Newest first within the same lifecycle; row 0 is the header.
        let ids = out.stdout.split(separator: "\n").map(String.init)
        #expect(ids.count == 3)
        #expect(ids[1].contains("codex:"))
        #expect(run(["notices", "--check"], harnesses).exitCode == DigestQuery.exitPending)
    }

    @Test("health --check asks about the machine, not about the focused harness")
    func healthSpansHarnesses() {
        func status(_ indicator: String) -> ServiceStatusCard {
            ServiceStatusCard(
                providerID: "x", pageName: "X", pageURL: "https://example.com",
                indicator: indicator, descriptionText: "", checkedAt: Date(), okAt: Date(),
                stale: false, components: [],
                incidents: indicator == "none" ? [] : [
                    StatusIncident(
                        id: "i", name: "Elevated errors", impact: indicator,
                        phase: "identified", startedAt: Date(), lastUpdateAt: Date(),
                        lastMessage: nil, url: nil, componentNames: []),
                ],
                recentlyResolved: [], maintenances: [])
        }
        let quietFocus = [
            harness("claude", glyph: "✳︎", agent: "Claude Code", files: 1, days: 1, status: status("none")),
            harness("codex", glyph: "⬡", agent: "Codex", files: 1, days: 1, status: status("major")),
        ]
        #expect(run(["health", "--check"], quietFocus).exitCode == DigestQuery.exitIncident)
        // A hidden harness's outage is not this machine's news.
        let hiddenTrouble = [
            harness("claude", glyph: "✳︎", agent: "Claude Code", files: 1, days: 1, status: status("none")),
            harness("codex", glyph: "⬡", agent: "Codex", shown: false, status: status("major")),
        ]
        #expect(run(["health", "--check"], hiddenTrouble).exitCode == DigestQuery.exitOK)
        // And a writer with no roster keeps answering from its own card —
        // the golden's carries an open minor incident.
        #expect(run(["health", "--check"], nil).exitCode == DigestQuery.exitIncident)
    }
}
