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

@Suite("SessionChartModel")
struct SessionChartModelTests {
    static let pricing = PricingTable(
        rates: [
            "claude-fable-5": ModelRates(input: 0.00001, output: 0.00005),
        ],
        fetchedAt: Date(timeIntervalSince1970: 0), source: .bundled)

    /// Pre-prompt work, then two prompt sections; one unpriced model in the
    /// first section.
    static func rows() -> [SessionEvent] {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        func call(_ id: Int, _ model: String, _ input: Int, _ output: Int) -> SessionEvent {
            SessionEvent(id: id, t: t.addingTimeInterval(Double(id) * 60), kind: .apiCall(
                model: model, tally: TokenTally(input: input, output: output), toolUses: 0))
        }
        return [
            SessionEvent(id: 0, t: t, kind: .command(name: "/model")),
            call(1, "claude-fable-5", 1000, 100),
            SessionEvent(id: 2, t: t.addingTimeInterval(120), kind: .prompt(preview: "first")),
            call(3, "claude-fable-5", 2000, 200),
            call(4, "mystery-model", 500, 50),
            SessionEvent(id: 5, t: t.addingTimeInterval(300), kind: .prompt(preview: "second")),
            call(6, "claude-fable-5", 3000, 300),
            SessionEvent(id: 7, t: t.addingTimeInterval(420), kind: .compaction),
        ]
    }

    static func build() -> SessionChartModel {
        let rows = rows()
        return SessionChartModel.build(
            rows: rows, ledger: SessionLedger.runningCost(rows: rows, pricing: pricing))
    }

    @Test("running series carry forward through non-call rows")
    func runningSeries() throws {
        let model = Self.build()
        let rates = try #require(Self.pricing.rates(for: "claude-fable-5"))
        let c0 = rates.dollars(for: TokenTally(input: 1000, output: 100))
        let c1 = rates.dollars(for: TokenTally(input: 2000, output: 200))
        #expect(model.runningCost.count == 8)
        #expect(model.runningCost[0] == 0)
        #expect(model.runningCost[1] == c0)
        // Carried over the prompt row, and the unpriced call adds nothing.
        #expect(model.runningCost[2] == c0)
        #expect(model.runningCost[4] == c0 + c1)
        #expect(model.runningTokens == [0, 1100, 1100, 3300, 3850, 3850, 7150, 7150])
        #expect(model.running(.cost) == model.runningCost)
        #expect(model.running(.tokens) == model.runningTokens)
    }

    @Test("model series: priced ones carry cost curves, unpriced only tokens")
    func modelSeries() throws {
        let model = Self.build()
        #expect(model.models.map { $0.model } == ["claude-fable-5", "mystery-model"])
        let fable = model.models[0]
        let mystery = model.models[1]
        #expect(fable.cost != nil)
        #expect(fable.tokens.last == 6600)
        #expect(fable.tokens[2] == 1100)
        // An unpriced model draws no cost curve at all — never a flat $0.
        #expect(mystery.cost == nil)
        #expect(mystery.tokens.last == 550)
        #expect(mystery.values(.cost) == nil)
        #expect(mystery.values(.tokens)?.count == 8)
    }

    @Test("sections span prompt to prompt; pre-prompt rows belong to none")
    func sections() throws {
        let model = Self.build()
        let rates = try #require(Self.pricing.rates(for: "claude-fable-5"))
        #expect(model.promptRows == [2, 5])
        #expect(model.compactionRows == [7])
        #expect(model.sections.count == 2)
        #expect(model.sections[0].range == 2..<5)
        #expect(model.sections[0].cost == rates.dollars(for: TokenTally(input: 2000, output: 200)))
        #expect(model.sections[0].tokens == 2750)
        #expect(model.sections[1].range == 5..<8)
        #expect(model.sections[1].tokens == 3300)
        #expect(model.section(containing: 0) == nil)
        #expect(model.section(containing: 1) == nil)
        #expect(model.section(containing: 2) == model.sections[0])
        #expect(model.section(containing: 4) == model.sections[0])
        #expect(model.section(containing: 5) == model.sections[1])
        #expect(model.section(containing: 7) == model.sections[1])
    }

    @Test("headless sessions chart without prompts or sections")
    func headless() {
        let rows = [Self.rows()[1]].map {
            SessionEvent(id: 0, t: $0.t, kind: $0.kind)
        }
        let model = SessionChartModel.build(
            rows: rows, ledger: SessionLedger.runningCost(rows: rows, pricing: Self.pricing))
        #expect(model.promptRows.isEmpty)
        #expect(model.sections.isEmpty)
        #expect(model.runningTokens == [1100])
    }

    @Test("empty and misaligned inputs yield the empty model")
    func degenerate() {
        #expect(SessionChartModel.build(rows: [], ledger: []) == .empty)
        let rows = Self.rows()
        #expect(SessionChartModel.build(rows: rows, ledger: []) == .empty)
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
