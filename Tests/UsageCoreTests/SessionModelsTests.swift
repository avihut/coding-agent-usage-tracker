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

    @Test("context fractions: per-call window share, carried through gaps")
    func contextSeries() {
        let rows = Self.rows()
        let ledger = SessionLedger.runningCost(rows: rows, pricing: Self.pricing)
        let model = SessionChartModel.build(
            rows: rows, ledger: ledger,
            windows: ["claude-fable-5": 10_000, "mystery-model": 5_000])
        // inputSide: fable 1000 → 0.1, fable 2000 → 0.2, mystery 500 → 0.1,
        // fable 3000 → 0.3; non-call rows carry the last value forward.
        #expect(model.contextFraction == [0, 0.1, 0.1, 0.2, 0.1, 0.1, 0.3, 0.3])
        // A model with no known window carries forward instead of dropping
        // the curve to a false zero.
        let partial = SessionChartModel.build(
            rows: rows, ledger: ledger, windows: ["claude-fable-5": 10_000])
        #expect(partial.contextFraction[4] == 0.2)
        // No windows at all → no context data, not an all-zero line.
        let none = SessionChartModel.build(rows: rows, ledger: ledger)
        #expect(none.contextFraction.isEmpty)
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

@Suite("SessionSpanTally")
struct SessionSpanTallyTests {
    @Test("a prompt owns rows up to the next prompt; the last runs to the end")
    func ranges() {
        let rows = SessionChartModelTests.rows()
        #expect(SessionSpanTally.promptRange(at: 2, rows: rows) == 2..<5)
        #expect(SessionSpanTally.promptRange(at: 5, rows: rows) == 5..<8)
    }

    @Test("per-model sums and call counts over a span")
    func tallies() {
        let rows = SessionChartModelTests.rows()
        let first = SessionSpanTally.models(rows: rows, in: 2..<5)
        #expect(first == [
            "claude-fable-5": TokenTally(input: 2000, output: 200),
            "mystery-model": TokenTally(input: 500, output: 50),
        ])
        #expect(SessionSpanTally.calls(rows: rows, in: 2..<5) == 2)
        // The final span prices its one call; the compaction marker adds
        // nothing.
        let last = SessionSpanTally.models(rows: rows, in: 5..<8)
        #expect(last == ["claude-fable-5": TokenTally(input: 3000, output: 300)])
        #expect(SessionSpanTally.calls(rows: rows, in: 5..<8) == 1)
        // Same-model calls fold into one sum across the whole session.
        let all = SessionSpanTally.models(rows: rows, in: 0..<8)
        #expect(all["claude-fable-5"] == TokenTally(input: 6000, output: 600))
        #expect(SessionSpanTally.calls(rows: rows, in: 0..<8) == 4)
    }

    @Test("empty spans and stale indices stay harmless")
    func degenerate() {
        let rows = SessionChartModelTests.rows()
        // A prompt as the final row owns nothing but itself.
        let tail = [SessionEvent(id: 0, t: rows[0].t, kind: .prompt(preview: "p"))]
        #expect(SessionSpanTally.promptRange(at: 0, rows: tail) == 0..<1)
        #expect(SessionSpanTally.models(rows: tail, in: 0..<1).isEmpty)
        #expect(SessionSpanTally.calls(rows: tail, in: 0..<1) == 0)
        // Indices beyond the rows (they shrank under a live re-parse) clamp
        // instead of trapping.
        #expect(SessionSpanTally.promptRange(at: 12, rows: rows) == 12..<12)
        #expect(SessionSpanTally.models(rows: rows, in: 12..<12).isEmpty)
        #expect(SessionSpanTally.calls(rows: rows, in: 12..<12) == 0)
    }
}

@Suite("SessionDayGroup")
struct SessionDayGroupTests {
    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func summary(
        id: String, end: String, kind: SessionKind = .interactive
    ) -> SessionSummary {
        let endDate = FlexibleISO8601.date(from: end)!
        return SessionSummary(
            id: id, title: id, projectPath: nil, gitBranch: nil, agentVersion: nil,
            kind: kind, start: endDate.addingTimeInterval(-600), end: endDate,
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

@Suite("SessionShortlist")
struct SessionShortlistTests {
    @Test("caps at the limit, newest first, interactive only")
    func caps() {
        let sessions = [
            SessionDayGroupTests.summary(id: "e", end: "2026-08-16T10:00:00.000Z"),
            SessionDayGroupTests.summary(
                id: "d", end: "2026-08-16T09:00:00.000Z", kind: .background),
            SessionDayGroupTests.summary(id: "c", end: "2026-08-16T08:00:00.000Z"),
            SessionDayGroupTests.summary(id: "b", end: "2026-08-16T07:00:00.000Z"),
            SessionDayGroupTests.summary(id: "a", end: "2026-08-16T06:00:00.000Z"),
        ]
        let shortlist = SessionShortlist.build(sessions)
        #expect(shortlist.rows.map { $0.id } == ["e", "c", "b"])
        #expect(shortlist.hasMore)
    }

    @Test("exactly the limit of interactive sessions needs no more-button")
    func exact() {
        let sessions = [
            SessionDayGroupTests.summary(id: "c", end: "2026-08-16T08:00:00.000Z"),
            SessionDayGroupTests.summary(id: "b", end: "2026-08-16T07:00:00.000Z"),
            SessionDayGroupTests.summary(id: "a", end: "2026-08-16T06:00:00.000Z"),
        ]
        let shortlist = SessionShortlist.build(sessions)
        #expect(shortlist.rows.count == 3)
        #expect(!shortlist.hasMore)
    }

    @Test("background-only history: empty strip, but more points at it")
    func backgroundOnly() {
        let sessions = [
            SessionDayGroupTests.summary(
                id: "a", end: "2026-08-16T06:00:00.000Z", kind: .background),
        ]
        let shortlist = SessionShortlist.build(sessions)
        #expect(shortlist.rows.isEmpty)
        #expect(shortlist.hasMore)
    }

    @Test("no sessions: nothing to show, nothing more")
    func empty() {
        let shortlist = SessionShortlist.build([])
        #expect(shortlist.rows.isEmpty)
        #expect(!shortlist.hasMore)
    }
}
