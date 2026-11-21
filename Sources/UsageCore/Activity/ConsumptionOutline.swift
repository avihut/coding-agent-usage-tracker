import Foundation

/// The breakdown table of a merged consumption scope: agent ▸ account ▸
/// model, each level only where it tells something — an agent level when
/// the scope spans more than one agent, an account level only under an
/// agent with several accounts in scope. Optionally, versions of one model
/// family fold under a family row ("Sonnet ▸ 2").
///
/// Cost is honest about absence: a node's cost is the sum of its priced
/// models, nil when none is priced; an unpriced model is counted, never
/// valued at zero. An agent whose traces carry no tokens keeps a row with
/// its prompts and stays out of every sum.
public struct ConsumptionOutline: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case agent(String)
        case account(agent: String, account: String)
        case family(String)
        /// A leaf: the composite key and the raw model id it carries.
        case model(key: String, model: String)
    }

    public struct Node: Sendable, Equatable, Identifiable {
        public let id: String
        public let kind: Kind
        public let tally: TokenTally
        public let cost: Double?
        /// The distinct unpriced models under this node, as agent␟model —
        /// one model used from two accounts is ONE unpriced model.
        public let unpricedModels: Set<String>
        public let prompts: Int
        public let reportsTokens: Bool
        /// Every composite model key under this node — what hovering it
        /// highlights in the chart.
        public let keys: Set<String>
        public let children: [Node]

        public var tokens: Int { tally.total }
        public var unpriced: Int { unpricedModels.count }

        /// This node or the descendant with `id`.
        public func node(id: String) -> Node? {
            if self.id == id { return self }
            for child in children {
                if let found = child.node(id: id) { return found }
            }
            return nil
        }
    }

    /// The node with `id` anywhere in the outline.
    public func node(id: String) -> Node? {
        for root in roots {
            if let found = root.node(id: id) { return found }
        }
        return nil
    }

    public let roots: [Node]
    /// Leaf keys depth-first in row order — the bars' stacking order, so
    /// they stack agent by agent, heaviest at the bottom.
    public let modelOrder: [String]
    public let tokens: Int
    public let cost: Double?
    public let unpriced: Int
    /// Agents in the scope, and those whose traces carry tokens.
    public let agentsPresent: Int
    public let agentsCounted: Int
    public let accounts: Int

    public static let empty = ConsumptionOutline(
        roots: [], modelOrder: [], tokens: 0, cost: nil, unpriced: 0,
        agentsPresent: 0, agentsCounted: 0, accounts: 0)

    /// The outline of `accounts` over `span` (half-open; nil = every day).
    /// Rows without activity in the span are left out, like the per-model
    /// table leaves out idle models; heaviest first at every level.
    public static func build(
        _ accounts: [AccountConsumption], in span: DateInterval?, foldFamilies: Bool
    ) -> ConsumptionOutline {
        let agents = accounts.map(\.agent).uniqued()
        let showsAgents = agents.count > 1
        var roots: [Node] = []
        for agent in agents {
            let mine = accounts.filter { $0.agent == agent }
            let accountNodes = mine.compactMap {
                accountNode($0, in: span, foldFamilies: foldFamilies)
            }
            if mine.count > 1 {
                // Every account idle in the span: no row, like an idle model.
                guard !accountNodes.isEmpty else { continue }
                let node = group(id: "a:\(agent)", kind: .agent(agent), children: accountNodes,
                                 reportsTokens: mine.contains(where: \.reportsTokens))
                if showsAgents { roots.append(node) } else { roots += node.children }
            } else if let only = accountNodes.first {
                // One account: its models sit straight under the agent — or
                // ARE the roots when the scope holds only this account.
                let node = group(id: "a:\(agent)", kind: .agent(agent), children: only.children,
                                 reportsTokens: only.reportsTokens, prompts: only.prompts)
                if showsAgents { roots.append(node) } else { roots += node.children }
            }
        }
        roots = ordered(roots)
        return ConsumptionOutline(
            roots: roots,
            modelOrder: roots.flatMap(leafKeys),
            tokens: roots.reduce(0) { $0 + $1.tokens },
            cost: sumCosts(roots),
            unpriced: roots.reduce(into: Set<String>()) { $0.formUnion($1.unpricedModels) }.count,
            agentsPresent: agents.count,
            agentsCounted: agents.filter { agent in
                accounts.contains { $0.agent == agent && $0.reportsTokens }
            }.count,
            accounts: accounts.count)
    }

    // MARK: - Building

    private static func accountNode(
        _ account: AccountConsumption, in span: DateInterval?, foldFamilies: Bool
    ) -> Node? {
        var tallies: [String: TokenTally] = [:]
        var prompts = 0
        for entry in account.days where span.map({ $0.start <= entry.day && entry.day < $0.end }) ?? true {
            prompts += entry.prompts
            guard account.reportsTokens else { continue }
            for (model, tally) in entry.models {
                tallies[model, default: TokenTally()].add(tally)
            }
        }
        let path = "a:\(account.agent)/u:\(account.account)"
        let leaves: [Node] = tallies.compactMap { model, tally in
            guard tally.total > 0 else { return nil }
            let key = ConsumptionKey.make(agent: account.agent, account: account.account, model: model)
            let cost = account.pricing.rates(for: model)?.dollars(for: tally)
            return Node(
                id: "\(path)/m:\(model)", kind: .model(key: key, model: model), tally: tally,
                cost: cost,
                unpricedModels: cost == nil ? ["\(account.agent)\(ConsumptionKey.separator)\(model)"] : [],
                prompts: 0, reportsTokens: true,
                keys: [key], children: [])
        }
        guard !leaves.isEmpty || prompts > 0 else { return nil }
        let children = foldFamilies ? folded(leaves, path: path) : leaves
        return group(
            id: path, kind: .account(agent: account.agent, account: account.account),
            children: children, reportsTokens: account.reportsTokens, prompts: prompts)
    }

    /// Versions of one family under a family row; a family of one stays a
    /// plain model row.
    private static func folded(_ leaves: [Node], path: String) -> [Node] {
        var byFamily: [String: [Node]] = [:]
        for leaf in leaves {
            guard case .model(_, let model) = leaf.kind else { continue }
            byFamily[ModelNames.family(model), default: []].append(leaf)
        }
        return byFamily.flatMap { family, members -> [Node] in
            guard members.count > 1 else { return members }
            return [group(id: "\(path)/f:\(family)", kind: .family(family), children: members,
                          reportsTokens: true)]
        }
    }

    private static func group(
        id: String, kind: Kind, children: [Node], reportsTokens: Bool, prompts: Int? = nil
    ) -> Node {
        var tally = TokenTally()
        for child in children { tally.add(child.tally) }
        let ordered = ordered(children)
        return Node(
            id: id, kind: kind, tally: tally, cost: sumCosts(children),
            unpricedModels: children.reduce(into: Set<String>()) { $0.formUnion($1.unpricedModels) },
            prompts: prompts ?? children.reduce(0) { $0 + $1.prompts },
            reportsTokens: reportsTokens,
            keys: children.reduce(into: Set<String>()) { $0.formUnion($1.keys) },
            children: ordered)
    }

    /// Nil when nothing underneath is priced — absent, never zero.
    private static func sumCosts(_ nodes: [Node]) -> Double? {
        let priced = nodes.compactMap(\.cost)
        return priced.isEmpty ? nil : priced.reduce(0, +)
    }

    /// Heaviest first; agents with no tokens (prompt-only) after every
    /// counted one; ties by id so the order never flickers.
    private static func ordered(_ nodes: [Node]) -> [Node] {
        nodes.sorted { a, b in
            if a.reportsTokens != b.reportsTokens { return a.reportsTokens }
            if a.tokens != b.tokens { return a.tokens > b.tokens }
            if a.prompts != b.prompts { return a.prompts > b.prompts }
            return a.id < b.id
        }
    }

    private static func leafKeys(_ node: Node) -> [String] {
        if case .model(let key, _) = node.kind { return [key] }
        return node.children.flatMap(leafKeys)
    }
}
