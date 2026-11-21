import SwiftUI
import UsageCore

/// How a merged Activity scope names and marks one agent.
struct ConsumptionAgentFace: Equatable {
    let name: String
    let style: HarnessStyle
}

/// How a merged Activity scope names one account.
struct ConsumptionAccountFace: Equatable {
    let label: String
    let monogram: String
}

/// What a merged consumption scope (more than one account) hands the
/// Activity section: each account's consumption for the outline, the same
/// days summed per day under composite keys for the existing charts, one
/// price table keyed alike, the chart colors, and how rows name things.
/// Arithmetic over scans every account already ran — no scan, file or
/// destination of its own.
struct ConsumptionInput: Equatable {
    let accounts: [AccountConsumption]
    let days: [DailyActivity]
    let pricing: PricingTable
    let colors: [String: Color]
    let agents: [String: ConsumptionAgentFace]
    let accountFaces: [String: ConsumptionAccountFace]
    /// More than one agent in scope — read per heatmap cell, so stored.
    let spansAgents: Bool

    /// "2 agents", "2 of 3 agents" (one reports no tokens), "2 accounts" —
    /// core's phrasing, the words the TUI and the CLI print too. One gap:
    /// the panel has no "scanning" state yet, so an account whose first
    /// scan hasn't landed counts (as nothing) here while the digest names
    /// it `scanning` and calls the total partial (follow-up, plan
    /// tui-unified-reading → Build notes).
    var countLabel: String {
        ConsumptionMembership.countLabel(accounts.map { ($0.agent, $0.reportsTokens) })
    }
}

/// The last merged input and what it was built from. A panel body
/// re-evaluates on every hover; rebuilding is only owed when an account's
/// days or prices (or how it is named) actually changed. Arrays compare by
/// buffer identity first, so an unchanged scope costs a few pointer checks.
@MainActor final class ConsumptionCache {
    private var key: (accounts: [AccountConsumption], faces: [ConsumptionAccountFace])?
    private var value: ConsumptionInput?

    func input(
        accounts: [AccountConsumption], faces: [ConsumptionAccountFace],
        build: () -> ConsumptionInput
    ) -> ConsumptionInput {
        if let key, let value, key.accounts == accounts, key.faces == faces {
            // Content-equal but maybe fresh buffers (every scan assigns a new
            // array): keep the new ones, so the next compare is identity-fast.
            self.key = (accounts, faces)
            return value
        }
        let built = build()
        key = (accounts, faces)
        value = built
        return built
    }
}

extension ProviderRegistry {
    /// Who "all" counts: exactly the accounts on the account strip (enrolled,
    /// enabled, awake), minus any whose harness the person hid. Dormant
    /// accounts stay out: while the app hosts they have no engine and so no
    /// activity in memory, and counting them would take a scan of its own
    /// and make the total depend on which process hosts.
    /// The rule is core's (`ConsumptionMembership`), shared with the digest's
    /// all-agents section and `usage-cli --all-agents`.
    var consumptionMembers: [ConsumptionMember] {
        let hidden = Set(harnesses.filter { !$0.shown }.map(\.id))
        let dormant = dormantIDs
        return ConsumptionMembership.members(
            profiles.map {
                ConsumptionMembership.Candidate(
                    key: $0.key, providerID: $0.providerID, enrolled: $0.isEnrolled,
                    enabled: $0.enabled, dormant: dormant.contains($0.key))
            },
            shown: Set(profiles.map(\.providerID)).subtracting(hidden))
    }

    /// The scope as chosen, resolved against today's members — a target
    /// that went away reads as everything, without being written back.
    var consumptionScope: ConsumptionScope {
        ConsumptionScope(rawValue: consumptionScopeRaw).resolved(in: consumptionMembers)
    }

    static func initialConsumptionScope(demo: Bool) -> String {
        let key = ConsumptionScope.storageKey
        let stored = demo
            ? UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
            : UserDefaults.standard.string(forKey: key)
        return stored ?? ConsumptionScope.all.rawValue
    }

    /// The stores a scope counts, in strip order.
    func consumptionStores(_ scope: ConsumptionScope) -> [UsageStore] {
        scope.members(of: consumptionMembers).compactMap { store(for: $0.account) }
    }

    /// The merged input for these stores (more than one).
    func consumptionInput(for stores: [UsageStore]) -> ConsumptionInput {
        let accounts = stores.map { store in
            AccountConsumption(
                agent: store.provider.id, account: store.profile.key, days: store.activity,
                pricing: store.pricing, reportsTokens: store.provider.reportsTokens)
        }
        let faces = stores.map { store in
            ConsumptionAccountFace(label: label(for: store.profile), monogram: monogram(for: store.profile))
        }
        return consumptionCache.input(accounts: accounts, faces: faces) {
            var agents: [String: ConsumptionAgentFace] = [:]
            var catalogs: [String: ModelCatalog] = [:]
            for store in stores where agents[store.provider.id] == nil {
                agents[store.provider.id] = ConsumptionAgentFace(
                    name: store.provider.agentName, style: store.style)
                catalogs[store.provider.id] = store.provider.modelCatalog
            }
            var accountFaces: [String: ConsumptionAccountFace] = [:]
            for (store, face) in zip(stores, faces) { accountFaces[store.profile.key] = face }
            return ConsumptionInput(
                accounts: accounts,
                days: ConsumptionMerge.days(accounts),
                pricing: ConsumptionMerge.pricing(accounts),
                colors: Self.consumptionColors(accounts, agents: agents, catalogs: catalogs),
                agents: agents, accountFaces: accountFaces, spansAgents: agents.count > 1)
        }
    }

    /// Composite key → color. One agent in scope keeps the colors its models
    /// wear everywhere; several agents each paint their models in their own
    /// accent's tones, so two vendors can never wear look-alikes. Either
    /// way each agent's ledger grows with its OWN raw ids only, heaviest
    /// first like the engine's seed. Families are read by the AGENT'S own
    /// catalog, as its engine seeded the ledger — the globally active catalog
    /// (`ModelNames`) would file another vendor's model under a family its
    /// engine never named, growing a stray slot and a different tone than
    /// the digest's.
    private static func consumptionColors(
        _ accounts: [AccountConsumption], agents: [String: ConsumptionAgentFace],
        catalogs: [String: ModelCatalog]
    ) -> [String: Color] {
        let spansAgents = agents.count > 1
        var colors: [String: Color] = [:]
        for (agent, face) in agents {
            let mine = accounts.filter { $0.agent == agent }
            var weight: [String: Int] = [:]
            for account in mine {
                for entry in account.days {
                    for (model, tally) in entry.models { weight[model, default: 0] += tally.total }
                }
            }
            let models = weight.keys.sorted { weight[$0]! != weight[$1]! ? weight[$0]! > weight[$1]! : $0 < $1 }
            let family = catalogs[agent]?.familyName ?? ModelFamily.familyName
            let raw = spansAgents
                ? ModelPalette.agentShades(for: models, style: face.style, family: family)
                : ModelPalette.assignment(for: models, style: face.style, family: family)
            for account in mine {
                for model in models {
                    colors[ConsumptionKey.make(agent: agent, account: account.account, model: model)] = raw[model]
                }
            }
        }
        return colors
    }
}
