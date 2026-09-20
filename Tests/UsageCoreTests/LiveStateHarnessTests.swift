import Foundation
import Testing

@testable import UsageCore

/// The digest with SEVERAL harnesses in it — the second golden fixture, and
/// the identity rules that keep one vendor's facts off another's account.
/// `UPDATE_GOLDENS=1 swift test --filter LiveState` rewrites the fixture;
/// the Rust TUI decodes this file too.
@Suite("LiveState harnesses")
struct LiveStateHarnessTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let posix = Locale(identifier: "en_US_POSIX")
    private let now = ISO8601DateFormatter().date(from: "2026-09-19T12:00:00Z")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func profile(
        id: String, providerID: String, home: String?, nickname: String? = nil, order: Int
    ) -> Profile {
        Profile(
            id: id, providerID: providerID, home: home.map { URL(filePath: $0) },
            nickname: nickname, order: order,
            addedAt: date("2026-09-01T09:00:00Z"))
    }

    /// One account's published section: a couple of meters, nothing else, so
    /// the fixture stays small and every field in it is deliberate.
    private func section(
        provider: any UsageProvider, percent: Int, label: String, tag: String
    ) -> LiveState {
        let meter = Meter(
            id: "session", label: label, percent: percent,
            resetsAt: date("2026-09-19T14:00:00Z"), level: .normal, rank: 0, limitWindow: 5 * 3600)
        return LiveStateBuilder.build(
            provider: provider, host: "daemon", pid: 909, appVersion: "0.101.0",
            state: .live(Snapshot(meters: [meter], fetchedAt: date("2026-09-19T11:58:00Z"))),
            predictions: [:], samples: [], timeline: [], activity: [],
            pricing: provider.bundledRates, colorLedger: ModelColorLedger(),
            graceSeconds: ActivityGrace.defaultSeconds, activeInterval: 300, paceMultiplier: 1,
            nextPollAt: date("2026-09-19T12:03:00Z"), backoffUntil: nil, apiBudget: nil,
            now: now, calendar: utc, locale: posix)
    }

    /// Codex's own ledger holds a reset named by the same minute Claude's
    /// could be — which is exactly why the digest qualifies its ids.
    private var codexNotices: [Notice] {
        [
            Notice(
                id: Notice.resetID(at: date("2026-09-18T18:10:00Z")), kind: "reset",
                occurredAt: date("2026-09-18T18:10:00Z"), endedAt: date("2026-09-18T18:10:00Z"),
                ongoing: false, recordedAt: date("2026-09-18T18:11:00Z"),
                meterLabel: "Weekly", fromPercent: 62)
        ]
    }

    /// Two Claude accounts (one dormant), Codex beside them, and Gemini
    /// hidden — every arm a face has to render.
    private func buildFixture() -> LiveState {
        let claude = ClaudeProvider()
        let codex = CodexProvider()
        let gemini = GeminiProvider()
        let work = profile(id: "default", providerID: "claude", home: "/Users/t/.claude", order: 0)
        let personal = profile(
            id: "c982130e", providerID: "claude", home: "/Users/t/.claude-personal",
            nickname: "Personal", order: 1)
        let codexAccount = profile(id: "default", providerID: "codex", home: nil, order: 0)
        let geminiAccount = profile(id: "default", providerID: "gemini", home: nil, order: 0)

        return MeteringDigest.compose(
            harnesses: [
                HarnessSection(
                    provider: claude, recentFiles: 412, activeDays: 9,
                    serviceStatus: nil, notices: [], outages: []),
                HarnessSection(
                    provider: codex, recentFiles: 22, activeDays: 6,
                    serviceStatus: nil, notices: codexNotices, outages: nil),
                HarnessSection(
                    provider: gemini, shown: false, recentFiles: 0, activeDays: 0,
                    serviceStatus: nil, notices: [], outages: nil),
            ],
            sections: [
                ProfileSection(
                    profile: work, label: "work@example.com", monogram: "W", dormant: false,
                    lastActivityAt: date("2026-09-19T11:30:00Z"), homeDisplayPath: "~/.claude",
                    state: section(provider: claude, percent: 41, label: "Session (5h)", tag: "S")),
                ProfileSection(
                    profile: personal, label: "Personal", monogram: "P", dormant: true,
                    lastActivityAt: date("2026-08-02T09:00:00Z"),
                    homeDisplayPath: "~/.claude-personal", state: nil),
                ProfileSection(
                    profile: codexAccount, label: "Codex", monogram: "C", dormant: false,
                    lastActivityAt: date("2026-09-19T10:05:00Z"), homeDisplayPath: nil,
                    state: section(provider: codex, percent: 13, label: "Session", tag: "S")),
                ProfileSection(
                    profile: geminiAccount, label: "Gemini CLI", monogram: "G", dormant: false,
                    lastActivityAt: date("2026-09-17T08:00:00Z"), homeDisplayPath: nil,
                    state: section(
                        provider: gemini, percent: 4, label: "Daily · counted locally", tag: "D")),
            ],
            focused: "codex", pinned: nil, host: "daemon", pid: 909, appVersion: "0.101.0",
            systemAccent: nil, activeInterval: 300, appUpdate: nil,
            nextReprobeAt: date("2026-09-19T12:10:00Z"), now: now, calendar: utc, locale: posix)
    }

    @Test("every harness rides the digest with its own identity and standing")
    func harnessList() throws {
        let state = buildFixture()
        let harnesses = try #require(state.harnesses)
        #expect(harnesses.map(\.id) == ["claude", "codex", "gemini"])
        #expect(harnesses.map(\.shown) == [true, true, false])
        #expect(harnesses.map(\.accountCount) == [2, 1, 1])
        #expect(harnesses.map(\.activeDays) == [9, 6, 0])
        #expect(harnesses.map(\.isLocalProvider) == [false, true, true])
        #expect(harnesses.map(\.glyph) == ["✳︎", "⬡", "✦"])
        #expect(harnesses.map(\.shortName) == ["Claude", "Codex", "Gemini"])
        #expect(harnesses[0].accent != harnesses[1].accent)
        #expect(harnesses[1].accent != harnesses[2].accent)
        // Newest write across a harness's own accounts.
        #expect(harnesses[0].newestActivityAt == date("2026-09-19T11:30:00Z"))
        // Absent ≠ empty: Codex records no outages at all.
        #expect(harnesses[0].outages == [])
        #expect(harnesses[1].outages == nil)
    }

    @Test("accounts are keyed across harnesses, and cells carry their own mark")
    func keysAndCells() throws {
        let state = buildFixture()
        #expect(state.profiles?.map(\.id) == ["default", "c982130e", "codex", "gemini"])
        #expect(state.profiles?.map(\.accountID) == ["default", "c982130e", "default", "default"])
        #expect(state.focusedProfile == "codex")
        #expect(state.profiles?.first { $0.id == "codex" }?.isFocused == true)

        // A hidden harness owns no cell; a dormant account owns none either.
        let cells = try #require(state.menuBarCells)
        #expect(cells.map(\.profile) == ["default", "codex"])
        #expect(cells.map(\.glyph) == ["✳︎", "⬡"])
        #expect(cells.map(\.providerID) == ["claude", "codex"])
        #expect(cells[0].accent == RGBColor(ClaudeProvider().accent))
        #expect(cells[1].accent == RGBColor(CodexProvider().accent))
    }

    /// The top level mirrors the FOCUSED harness — its meters and its vendor
    /// cards — and any other account projects onto it with its own.
    @Test("the top level is the focused harness, and projections swap the vendor whole")
    func projections() throws {
        let state = buildFixture()
        #expect(state.engine.providerID == "codex")
        #expect(state.engine.glyph == "⬡")
        #expect(state.meters.first?.percent == 13)
        // The focused harness's notices, with its ids qualified.
        #expect(state.notices?.items.map(\.id) == ["codex:reset|1789755000"])
        #expect(state.notices?.items.first?.profile == "codex")
        #expect(state.notices?.items.first?.title.contains("ChatGPT") == true)

        let work = try #require(state.viewing(profile: "default"))
        #expect(work.engine.providerID == "claude")
        #expect(work.meters.first?.percent == 41)
        // Claude's own ledger is empty — the Codex reset must not follow it.
        #expect(work.notices?.items.isEmpty == true)
        #expect(work.outages == [])

        let dormant = try #require(state.viewing(profile: "c982130e"))
        #expect(dormant.engine.providerID == "claude")
        #expect(dormant.engine.agentName == "Claude Code")
        #expect(dormant.meters.isEmpty && dormant.engine.stale)

        let hidden = try #require(state.viewing(profile: "gemini"))
        #expect(hidden.engine.providerID == "gemini")
        #expect(hidden.notices?.items.isEmpty == true)
        #expect(hidden.outages == nil)
        #expect(state.viewing(profile: "nope") == nil)
    }

    /// A handover seeds each engine's gate with ITS account's last fetch —
    /// keyed the way the host keys engines, across harnesses.
    @Test("gate seeds are keyed across harnesses")
    func gateSeeds() {
        let seeds = buildFixture().gateSeeds()
        #expect(seeds.keys.sorted() == ["codex", "default", "gemini"])
        #expect(seeds["codex"] == date("2026-09-19T11:58:00Z"))
    }

    @Test("the notice router names a harness's ledger and finds it again")
    func noticeRouting() {
        let bundled = HarnessResolution.bundledProviderID
        #expect(NoticeRouting.qualify("reset|17", providerID: bundled) == "reset|17")
        #expect(NoticeRouting.qualify("reset|17", providerID: "codex") == "codex:reset|17")
        #expect(NoticeRouting.split("reset|17") == (bundled, "reset|17"))
        #expect(NoticeRouting.split("codex:reset|17") == ("codex", "reset|17"))
        // Ids of the bundled harness pass through untouched, colon or not.
        #expect(NoticeRouting.split("outage|abc:def") == (bundled, "outage|abc:def"))
        #expect(NoticeRouting.split("\(bundled):reset|17") == (bundled, "\(bundled):reset|17"))
    }

    @Test("the harness golden stays decodable and equal to the crafted state")
    func golden() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest/live-state-v1-harnesses.json")
        let state = buildFixture()
        if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] != nil {
            try FileManager.default.createDirectory(
                at: fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LiveState.encoder().encode(state).write(to: fixtureURL)
        }
        let data = try Data(contentsOf: fixtureURL)
        #expect(try LiveState.decoder().decode(LiveState.self, from: data) == state)
    }
}
