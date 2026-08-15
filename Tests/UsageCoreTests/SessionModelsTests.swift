import Foundation
import Testing
@testable import UsageCore

@Suite("PromptPreview")
struct PromptPreviewTests {
    @Test("ANSI escapes are stripped")
    func ansi() {
        #expect(PromptPreview.scrub("Set \u{1B}[1mFable 5\u{1B}[22m as default")
            == "Set Fable 5 as default")
    }

    @Test("whitespace runs collapse to single spaces")
    func whitespace() {
        #expect(PromptPreview.scrub("  a\n\n  b\t\tc  ") == "a b c")
    }

    @Test("long base64-ish runs become [data]")
    func base64() {
        let blob = String(repeating: "QUJD", count: 30)
        #expect(PromptPreview.scrub("attached: \(blob) end") == "attached: [data] end")
    }

    @Test("long text caps at maxLength with an ellipsis")
    func cap() {
        let long = String(repeating: "word ", count: 60)
        let scrubbed = PromptPreview.scrub(long)
        #expect(scrubbed?.count == PromptPreview.maxLength + 1)
        #expect(scrubbed?.hasSuffix("…") == true)
    }

    @Test("nothing displayable yields nil")
    func empty() {
        #expect(PromptPreview.scrub("   \n\t ") == nil)
        #expect(PromptPreview.scrub("\u{1B}[1m\u{1B}[0m") == nil)
    }

    @Test("command names extract from their markers")
    func command() {
        #expect(PromptPreview.commandName(
            "<command-name>/compact</command-name><command-message>go</command-message>")
            == "/compact")
        #expect(PromptPreview.commandName("plain text") == nil)
        #expect(PromptPreview.commandName("<command-name>  </command-name>") == nil)
    }
}

@Suite("SessionLedger")
struct SessionLedgerTests {
    static let pricing = PricingTable(
        rates: [
            "claude-fable-5": ModelRates(input: 0.00001, output: 0.00005),
        ],
        fetchedAt: Date(timeIntervalSince1970: 0), source: .bundled)

    static func rows() -> [SessionEvent] {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            SessionEvent(id: 0, t: t, kind: .prompt(preview: "go")),
            SessionEvent(id: 1, t: t, kind: .apiCall(
                model: "claude-fable-5",
                tally: TokenTally(input: 1000, output: 100), toolUses: 1)),
            SessionEvent(id: 2, t: t, kind: .apiCall(
                model: "mystery-model",
                tally: TokenTally(input: 500, output: 50), toolUses: 0)),
            SessionEvent(id: 3, t: t, kind: .apiCall(
                model: "claude-fable-5",
                tally: TokenTally(input: 2000, output: 200), toolUses: 0)),
        ]
    }

    @Test("entries align with rows; running sums match the rates source")
    func running() throws {
        let entries = SessionLedger.runningCost(rows: Self.rows(), pricing: Self.pricing)
        #expect(entries.count == 4)
        // Non-call row: no increment, running carried forward.
        #expect(entries[0].incremental == nil)
        #expect(entries[0].running == 0)
        let rates = try #require(Self.pricing.rates(for: "claude-fable-5"))
        let first = rates.dollars(for: TokenTally(input: 1000, output: 100))
        let second = rates.dollars(for: TokenTally(input: 2000, output: 200))
        #expect(entries[1].incremental == first)
        // Unpriced model: nil increment, flat running line — never $0.
        #expect(entries[2].incremental == nil)
        #expect(entries[2].running == entries[1].running)
        #expect(entries[3].running == first + second)
    }

    @Test("unpriced models are named, not silently zeroed")
    func unpriced() {
        let unpriced = SessionLedger.unpricedModels(rows: Self.rows(), pricing: Self.pricing)
        #expect(unpriced == ["mystery-model"])
    }

    @Test("empty rows yield empty entries")
    func empty() {
        #expect(SessionLedger.runningCost(rows: [], pricing: Self.pricing).isEmpty)
    }
}

@Suite("SessionDayGroup")
struct SessionDayGroupTests {
    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func summary(id: String, end: String) -> SessionSummary {
        let endDate = FlexibleISO8601.date(from: end)!
        return SessionSummary(
            id: id, title: id, projectPath: nil, gitBranch: nil, agentVersion: nil,
            kind: .interactive, start: endDate.addingTimeInterval(-600), end: endDate,
            activeSeconds: 600, prompts: 1, apiCalls: 1, toolCalls: 0,
            subagentCount: 0, compactions: 0, models: [:])
    }

    @Test("groups by end day, newest day first, intra-day order preserved")
    func grouping() {
        let sessions = [
            Self.summary(id: "c", end: "2026-08-02T23:50:00.000Z"),
            Self.summary(id: "b", end: "2026-08-02T09:00:00.000Z"),
            // Started Aug 1 but ended Aug 2? No — ends Aug 1; groups by end.
            Self.summary(id: "a", end: "2026-08-01T23:59:00.000Z"),
        ]
        let groups = SessionDayGroup.build(sessions, calendar: Self.utcCalendar())
        #expect(groups.count == 2)
        #expect(groups[0].sessions.map { $0.id } == ["c", "b"])
        #expect(groups[1].sessions.map { $0.id } == ["a"])
        #expect(groups[0].day > groups[1].day)
    }

    @Test("empty input yields no groups")
    func empty() {
        #expect(SessionDayGroup.build([], calendar: Self.utcCalendar()).isEmpty)
    }
}
