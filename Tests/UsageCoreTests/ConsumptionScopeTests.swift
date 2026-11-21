import Foundation
import Testing
@testable import UsageCore

@Suite("Consumption scope")
struct ConsumptionScopeTests {
    static let claude = ConsumptionMember(agent: "claude", account: "default")
    static let claudeWork = ConsumptionMember(agent: "claude", account: "claude.ab12cd34")
    static let codex = ConsumptionMember(agent: "codex", account: "codex")

    @Test("raw values round-trip, and anything unknown reads as all")
    func rawValues() {
        for scope in [ConsumptionScope.all, .agent("codex"), .account("claude.ab12cd34")] {
            #expect(ConsumptionScope(rawValue: scope.rawValue) == scope)
        }
        #expect(ConsumptionScope(rawValue: "") == .all)
        #expect(ConsumptionScope(rawValue: "focused") == .all)
    }

    @Test("an agent scope counts every account of that agent")
    func agentMembers() {
        let members = [Self.claude, Self.claudeWork, Self.codex]
        #expect(ConsumptionScope.agent("claude").members(of: members) == [Self.claude, Self.claudeWork])
        #expect(ConsumptionScope.account("codex").members(of: members) == [Self.codex])
        #expect(ConsumptionScope.all.members(of: members) == members)
    }

    @Test("a target that is gone falls back to everything, never to nothing")
    func goneTarget() {
        let members = [Self.claude, Self.codex]
        #expect(ConsumptionScope.agent("gemini").members(of: members) == members)
        #expect(ConsumptionScope.agent("gemini").resolved(in: members) == .all)
        #expect(ConsumptionScope.account("claude.ab12cd34").resolved(in: members) == .all)
        #expect(ConsumptionScope.agent("codex").resolved(in: members) == .agent("codex"))
    }

    @Test("the menu offers agents only when there are several, accounts only under an agent with several")
    func options() {
        #expect(ConsumptionScope.options(for: [Self.claude, Self.codex])
            == [.all, .agent("claude"), .agent("codex")])
        #expect(ConsumptionScope.options(for: [Self.claude, Self.claudeWork])
            == [.all, .account("default"), .account("claude.ab12cd34")])
        #expect(ConsumptionScope.options(for: [Self.claude, Self.claudeWork, Self.codex])
            == [.all, .agent("claude"), .account("default"), .account("claude.ab12cd34"), .agent("codex")])
    }

    @Test("one account shows no menu at all")
    func menuVisibility() {
        #expect(!ConsumptionScope.showsMenu([Self.claude]))
        #expect(!ConsumptionScope.showsMenu([]))
        #expect(ConsumptionScope.showsMenu([Self.claude, Self.codex]))
    }

    @Test("composite keys carry agent, account and model, and a plain id passes through")
    func keys() {
        let key = ConsumptionKey.make(agent: "codex", account: "codex", model: "gpt-5.2-codex")
        #expect(ConsumptionKey.isComposite(key))
        #expect(ConsumptionKey.split(key)?.agent == "codex")
        #expect(ConsumptionKey.model(of: key) == "gpt-5.2-codex")
        #expect(ConsumptionKey.model(of: "claude-fable-5") == "claude-fable-5")
        #expect(ConsumptionKey.split("claude-fable-5") == nil)
        #expect(!ConsumptionKey.isComposite("claude-fable-5"))
    }

    @Test("a composite key is named and grouped by its model")
    func namesDecode() {
        let key = ConsumptionKey.make(agent: "claude", account: "default", model: "claude-fable-5")
        #expect(ModelNames.display(key) == ModelNames.display("claude-fable-5"))
        #expect(ModelNames.family(key) == ModelNames.family("claude-fable-5"))
    }
}
