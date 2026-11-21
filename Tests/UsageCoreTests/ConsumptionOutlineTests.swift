import Foundation
import Testing
@testable import UsageCore

@Suite("Consumption outline")
struct ConsumptionOutlineTests {
    typealias M = ConsumptionMergeTests

    static func kinds(_ nodes: [ConsumptionOutline.Node]) -> [ConsumptionOutline.Kind] { nodes.map(\.kind) }

    @Test("two agents: agent rows, heaviest first, models under each, bars stack agent by agent")
    func twoAgents() {
        let outline = ConsumptionOutline.build([
            M.account("codex", "codex", pricing: M.unpriced, [M.entry(5, ["gpt-5.2-codex": 40])]),
            M.account("claude", "default", [M.entry(5, ["claude-fable-5": 100, "claude-haiku-4-5": 10])]),
        ], in: nil, foldFamilies: false)
        #expect(Self.kinds(outline.roots) == [.agent("claude"), .agent("codex")])
        #expect(outline.roots[0].children.count == 2)
        #expect(outline.modelOrder.map(ConsumptionKey.model(of:)) == ["claude-fable-5", "claude-haiku-4-5", "gpt-5.2-codex"])
        #expect(outline.tokens == 150)
        #expect(outline.agentsPresent == 2)
        #expect(outline.agentsCounted == 2)
    }

    @Test("unpriced models are counted, never valued: nil cost where nothing is priced")
    func absentCost() {
        let outline = ConsumptionOutline.build([
            M.account("claude", "default", [M.entry(5, ["claude-fable-5": 1_000_000])]),
            M.account("codex", "codex", pricing: M.unpriced, [M.entry(5, ["gpt-5.2-codex": 40])]),
        ], in: nil, foldFamilies: false)
        let codex = outline.roots.first { $0.kind == .agent("codex") }!
        #expect(codex.cost == nil)
        #expect(codex.unpriced == 1)
        #expect(outline.unpriced == 1)
        let fable = PricingTable.bundled.rates(for: "claude-fable-5")!.dollars(for: TokenTally(input: 1_000_000))
        #expect(outline.cost.map { abs($0 - fable) < 1e-9 } == true)
        let none = ConsumptionOutline.build(
            [M.account("codex", "codex", pricing: M.unpriced, [M.entry(5, ["gpt-5.2-codex": 40])])],
            in: nil, foldFamilies: false)
        #expect(none.cost == nil)
    }

    @Test("an agent with several accounts gets an account level; one agent alone has no agent level")
    func levels() {
        let accounts = [
            M.account("claude", "default", [M.entry(5, ["claude-fable-5": 100])]),
            M.account("claude", "claude.ab12cd34", [M.entry(5, ["claude-fable-5": 30])]),
        ]
        let oneAgent = ConsumptionOutline.build(accounts, in: nil, foldFamilies: false)
        #expect(Self.kinds(oneAgent.roots) == [
            .account(agent: "claude", account: "default"),
            .account(agent: "claude", account: "claude.ab12cd34"),
        ])
        let withCodex = ConsumptionOutline.build(
            accounts + [M.account("codex", "codex", [M.entry(5, ["gpt-5.2-codex": 4])])],
            in: nil, foldFamilies: false)
        #expect(Self.kinds(withCodex.roots) == [.agent("claude"), .agent("codex")])
        #expect(withCodex.roots[0].children.count == 2)
        #expect(withCodex.roots[0].tokens == 130)
        #expect(withCodex.accounts == 3)
        // Codex's single account sits flat: its model is the agent's child.
        #expect(withCodex.roots[1].children.map(\.keys.count) == [1])
    }

    @Test("an account row's keys isolate exactly that account's models")
    func accountKeys() {
        let outline = ConsumptionOutline.build([
            M.account("claude", "default", [M.entry(5, ["claude-fable-5": 100])]),
            M.account("claude", "work", [M.entry(5, ["claude-fable-5": 30])]),
        ], in: nil, foldFamilies: false)
        #expect(outline.roots[0].keys == [ConsumptionKey.make(agent: "claude", account: "default", model: "claude-fable-5")])
        #expect(outline.roots[0].keys.isDisjoint(with: outline.roots[1].keys))
    }

    @Test("versions of one family fold under a family row; a family of one stays a model row")
    func familyFold() {
        let accounts = [
            M.account("claude", "default", [M.entry(5, ["claude-sonnet-5": 50, "claude-sonnet-4-5": 20, "claude-fable-5": 10])]),
            M.account("codex", "codex", [M.entry(5, ["gpt-5.2-codex": 4])]),
        ]
        let outline = ConsumptionOutline.build(accounts, in: nil, foldFamilies: true)
        let claude = outline.roots[0]
        let sonnet = ModelNames.family("claude-sonnet-5")
        #expect(claude.children.first?.kind == .family(sonnet))
        #expect(claude.children.first?.children.count == 2)
        #expect(claude.children.first?.tokens == 70)
        #expect(claude.children.count == 2)
        // Folding never changes what the bars stack.
        let flat = ConsumptionOutline.build(accounts, in: nil, foldFamilies: false)
        #expect(Set(outline.modelOrder) == Set(flat.modelOrder))
    }

    @Test("an agent that reports no tokens keeps a row with its prompts and stays out of every sum")
    func promptOnly() {
        let outline = ConsumptionOutline.build([
            M.account("claude", "default", [M.entry(5, ["claude-fable-5": 100])]),
            M.account("gemini", "gemini", reportsTokens: false,
                      [DailyActivity(day: M.day(5), tokens: 0, messages: 0, prompts: 12)]),
        ], in: nil, foldFamilies: false)
        let gemini = outline.roots.last!
        #expect(gemini.kind == .agent("gemini"))
        #expect(!gemini.reportsTokens)
        #expect(gemini.prompts == 12)
        #expect(gemini.cost == nil)
        #expect(gemini.keys.isEmpty)
        #expect(outline.tokens == 100)
        #expect(outline.agentsPresent == 2)
        #expect(outline.agentsCounted == 1)
    }

    @Test("an agent whose accounts are all idle in the span has no row")
    func idleAgentWithSeveralAccounts() {
        let outline = ConsumptionOutline.build([
            M.account("claude", "default", [M.entry(5, ["claude-fable-5": 100])]),
            M.account("codex", "codex", [M.entry(1, ["gpt-5.2-codex": 4])]),
            M.account("codex", "codex.ab12cd34", [M.entry(1, ["gpt-5.2-codex": 4])]),
        ], in: DateInterval(start: M.day(5), end: M.day(6)), foldFamilies: false)
        #expect(Self.kinds(outline.roots) == [.agent("claude")])
    }

    @Test("one unpriced model used from two accounts is one unpriced model")
    func distinctUnpriced() {
        let outline = ConsumptionOutline.build([
            M.account("codex", "codex", pricing: M.unpriced, [M.entry(5, ["gpt-5.2-codex": 4])]),
            M.account("codex", "codex.ab12cd34", pricing: M.unpriced, [M.entry(5, ["gpt-5.2-codex": 9])]),
            M.account("claude", "default", [M.entry(5, ["claude-fable-5": 100])]),
        ], in: nil, foldFamilies: false)
        #expect(outline.unpriced == 1)
        #expect(outline.roots.first { $0.kind == .agent("codex") }?.unpriced == 1)
        let codexNode = outline.roots.first { $0.kind == .agent("codex") }!
        #expect(outline.node(id: codexNode.children[0].id) == codexNode.children[0])
    }

    @Test("the span limits the outline to its days; idle accounts drop out")
    func span() {
        let accounts = [
            M.account("claude", "default", [M.entry(5, ["claude-fable-5": 100]), M.entry(6, ["claude-fable-5": 1])]),
            M.account("codex", "codex", [M.entry(5, ["gpt-5.2-codex": 4])]),
        ]
        let sixth = ConsumptionOutline.build(
            accounts, in: DateInterval(start: M.day(6), end: M.day(7)), foldFamilies: false)
        #expect(sixth.tokens == 1)
        #expect(Self.kinds(sixth.roots) == [.agent("claude")])
        #expect(ConsumptionOutline.build([], in: nil, foldFamilies: false) == .empty)
    }
}
