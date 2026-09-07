import Foundation

/// Which limits a "Runs out" element in the menu bar speaks for (0.98.0,
/// user-directed). ONE element with a scope, never several copies: the
/// number a person wants from the bar is "when do I get cut off", and any
/// meter crossing cuts them off, so the earliest crossing is the answer
/// and the rest is a setting.
public enum RunsOutScope: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The earliest crossing across the account's meters — the default.
    case earliest
    /// One countdown per meter that is forecast to run out, in meter order.
    case each
    /// The session meter (rank 0) alone.
    case session
    /// The weekly meter (rank 1) alone.
    case weekly
    /// The scoped meter (rank 2) alone.
    case scoped

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .earliest: "Earliest limit"
        case .each: "Every limit"
        case .session: "Session"
        case .weekly: "Weekly"
        case .scoped: "Scoped model"
        }
    }

    public var caption: String {
        switch self {
        case .earliest: "The one limit that would cut you off first."
        case .each: "A countdown for every limit forecast to run out."
        case .session: "The session limit only."
        case .weekly: "The weekly limit only."
        case .scoped: "The scoped model's weekly limit only."
        }
    }

    /// The segment index a single-meter scope reads; nil for the
    /// combining scopes.
    public var rank: Int? {
        switch self {
        case .earliest, .each: nil
        case .session: 0
        case .weekly: 1
        case .scoped: 2
        }
    }
}

/// One thing an account's menu bar cell can hold, in the order the person
/// arranged them (0.98.0). The meters — drawn in the cell's `MenuBarForm`
/// — are always there exactly once; the rest is what was dragged in.
public enum MenuBarElement: Sendable, Equatable, Hashable, Identifiable {
    case meters
    /// The expected time until a limit is reached. CONDITIONAL: composes
    /// nothing at all while no limit is forecast to run out before it
    /// resets, and the person is told so where they place it.
    case runsOut(RunsOutScope)

    public var id: String { token }

    /// The stored spelling: "meters", "runsOut:earliest".
    public var token: String {
        switch self {
        case .meters: "meters"
        case .runsOut(let scope): "runsOut:\(scope.rawValue)"
        }
    }

    /// Nil for a token this build doesn't know (a newer writer's), so a
    /// list with one strange entry loses that entry, not the list.
    public init?(token: String) {
        if token == "meters" {
            self = .meters
        } else if token.hasPrefix("runsOut:"),
                  let scope = RunsOutScope(rawValue: String(token.dropFirst("runsOut:".count))) {
            self = .runsOut(scope)
        } else {
            return nil
        }
    }

    public var isRunsOut: Bool {
        if case .runsOut = self { return true }
        return false
    }

    public var title: String {
        switch self {
        case .meters: "Meters"
        case .runsOut: "Runs out"
        }
    }
}

extension MenuBarElement: Codable {
    public init(from decoder: any Decoder) throws {
        let token = try decoder.singleValueContainer().decode(String.self)
        guard let element = MenuBarElement(token: token) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath, debugDescription: "unknown menu bar element '\(token)'"))
        }
        self = element
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

/// The element list's invariants, applied at every edge it crosses.
public enum MenuBarLayout {
    /// What a fresh record holds: the meters, nothing else — which is why
    /// every bar drawn before 0.98.0 is unchanged.
    public static let standard: [MenuBarElement] = [.meters]

    /// Exactly one `.meters` (the first kept, one prepended when none), at
    /// most one runs-out element (the first kept — one element, scoped;
    /// duplicates would only differ by a setting).
    public static func normalized(_ elements: [MenuBarElement]) -> [MenuBarElement] {
        var result: [MenuBarElement] = []
        var sawMeters = false
        var sawRunsOut = false
        for element in elements {
            switch element {
            case .meters:
                if sawMeters { continue }
                sawMeters = true
            case .runsOut:
                if sawRunsOut { continue }
                sawRunsOut = true
            }
            result.append(element)
        }
        if !sawMeters { result.insert(.meters, at: 0) }
        return result
    }

    /// Tokens from storage — unknown ones dropped — normalized.
    public static func decode(tokens: [String]) -> [MenuBarElement] {
        normalized(tokens.compactMap(MenuBarElement.init(token:)))
    }

    public static func encode(_ elements: [MenuBarElement]) -> [String] {
        elements.map(\.token)
    }

    /// The runs-out element's scope when the list holds one.
    public static func runsOutScope(in elements: [MenuBarElement]) -> RunsOutScope? {
        for element in elements {
            if case .runsOut(let scope) = element { return scope }
        }
        return nil
    }

    /// The list with its runs-out element re-scoped, or added after the
    /// meters when there is none.
    public static func settingRunsOut(_ scope: RunsOutScope, in elements: [MenuBarElement]) -> [MenuBarElement] {
        var result = normalized(elements)
        if let index = result.firstIndex(where: \.isRunsOut) {
            result[index] = .runsOut(scope)
        } else {
            result.append(.runsOut(scope))
        }
        return result
    }

    /// The list without its runs-out element.
    public static func removingRunsOut(from elements: [MenuBarElement]) -> [MenuBarElement] {
        normalized(elements.filter { !$0.isRunsOut })
    }

    /// The list with `element` placed before or after the meters — a drop
    /// on the preview — keeping whatever scope it already had when the
    /// dropped one is a re-placement.
    public static func placing(
        _ element: MenuBarElement, beforeMeters: Bool, in elements: [MenuBarElement]
    ) -> [MenuBarElement] {
        var rest = normalized(elements)
        var placed = element
        if element.isRunsOut, let existing = runsOutScope(in: rest) {
            placed = .runsOut(existing)
            rest = removingRunsOut(from: rest)
        }
        guard let metersIndex = rest.firstIndex(of: .meters) else { return normalized([placed] + rest) }
        rest.insert(placed, at: beforeMeters ? metersIndex : metersIndex + 1)
        return normalized(rest)
    }
}
