import Foundation

/// One account whose consumption a scope can count: the harness it belongs
/// to (provider id) and the account's `ProfileKey` (`.key`, never the
/// storage id).
public struct ConsumptionMember: Hashable, Sendable {
    public let agent: String
    public let account: String

    public init(agent: String, account: String) {
        self.agent = agent
        self.account = account
    }
}

/// Whose CONSUMPTION — tokens and list-price cost — the Activity section
/// counts: every agent, one agent, or one account. Separate from focus,
/// which decides whose LIMITS lead the bar and the panel: limits never sum
/// (two accounts are two meters), consumption does. Persisted as a raw
/// string; a stored target that no longer exists reads as `.all` without
/// being written back, so a harness that comes back finds its scope again.
public enum ConsumptionScope: Hashable, Sendable {
    case all
    case agent(String)
    case account(String)

    public static let storageKey = "activityScope"

    public init(rawValue: String) {
        if rawValue.hasPrefix("agent:") {
            self = .agent(String(rawValue.dropFirst("agent:".count)))
        } else if rawValue.hasPrefix("account:") {
            self = .account(String(rawValue.dropFirst("account:".count)))
        } else {
            self = .all
        }
    }

    public var rawValue: String {
        switch self {
        case .all: "all"
        case .agent(let id): "agent:\(id)"
        case .account(let key): "account:\(key)"
        }
    }

    /// The members this scope counts, in the order given. A target that is
    /// gone (a hidden harness, a dismissed account) falls back to every
    /// member rather than to nothing.
    public func members(of all: [ConsumptionMember]) -> [ConsumptionMember] {
        let picked: [ConsumptionMember] = switch self {
        case .all: all
        case .agent(let id): all.filter { $0.agent == id }
        case .account(let key): all.filter { $0.account == key }
        }
        return picked.isEmpty ? all : picked
    }

    /// This scope, or `.all` when its target is no longer among `members`.
    public func resolved(in members: [ConsumptionMember]) -> ConsumptionScope {
        switch self {
        case .all: .all
        case .agent(let id): members.contains { $0.agent == id } ? self : .all
        case .account(let key): members.contains { $0.account == key } ? self : .all
        }
    }

    /// The scope menu's entries: everything, then each agent (only when
    /// there is more than one — with one agent "all" already is it), then
    /// each account of any agent that has several.
    public static func options(for members: [ConsumptionMember]) -> [ConsumptionScope] {
        let agents = members.map(\.agent).uniqued()
        var options: [ConsumptionScope] = [.all]
        for agent in agents {
            let accounts = members.filter { $0.agent == agent }
            if agents.count > 1 { options.append(.agent(agent)) }
            if accounts.count > 1 { options += accounts.map { .account($0.account) } }
        }
        return options
    }

    /// One account in all: there is nothing to choose, and the section is
    /// exactly what it always was.
    public static func showsMenu(_ members: [ConsumptionMember]) -> Bool {
        members.count > 1
    }
}

/// How a merged scope keys a model: the agent, the account and the raw model
/// id, joined by U+001F (which no model id or profile key contains). One key
/// per leaf of the consumption outline, so hovering any row isolates exactly
/// what that row counts, and two agents' same-named ids ("unknown") never
/// fold into one.
public enum ConsumptionKey {
    public static let separator: Character = "\u{1F}"

    public static func make(agent: String, account: String, model: String) -> String {
        "\(agent)\(separator)\(account)\(separator)\(model)"
    }

    public static func split(_ key: String) -> (agent: String, account: String, model: String)? {
        let parts = key.split(separator: separator, maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }

    /// The raw model id inside a composite key; a plain id passes through.
    public static func model(of key: String) -> String {
        split(key)?.model ?? key
    }

    public static func isComposite(_ key: String) -> Bool {
        key.contains(separator)
    }
}

extension Array where Element: Hashable {
    /// First occurrences, order kept.
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
