import Foundation

/// Color-classification of a meter. Percent thresholds apply, and a non-normal
/// API severity forces at least `.warning` regardless of percentage.
public enum DisplayLevel: Int, Sendable, Comparable {
    case normal
    case warning
    case critical

    public static func < (lhs: DisplayLevel, rhs: DisplayLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Percent cutoffs for the color classification. `.standard` carries the
/// spec defaults; Settings → Thresholds lets the user move them, and every
/// build of a snapshot re-reads whatever is current.
public struct Thresholds: Sendable, Equatable {
    public var warningPercent: Int
    public var criticalPercent: Int

    public init(warningPercent: Int = 70, criticalPercent: Int = 90) {
        self.warningPercent = warningPercent
        self.criticalPercent = criticalPercent
    }

    public static let standard = Thresholds()
}

public struct Meter: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// Clamped to 0...100. Nil when the API omitted it — shown as "—" in the
    /// panel and excluded from the menu bar summary.
    public let percent: Int?
    public let resetsAt: Date?
    public let level: DisplayLevel
    public let rank: Int
}

/// What the menu bar item renders: `✳︎ session·weeklyAll·scopedMax%`.
public struct MenuBarSummary: Sendable, Equatable {
    public let session: Int?
    public let weeklyAll: Int?
    public let scopedMax: Int?
    public let worstLevel: DisplayLevel
}

/// One enabled-credits line for the panel footer, e.g. "$0.00 of $50.00".
public struct SpendLine: Sendable, Equatable {
    public let usedMinor: Int
    public let limitMinor: Int?
    public let currency: String
    public let exponent: Int

    public var formatted: String {
        guard let limitMinor else { return Self.format(usedMinor, currency, exponent) }
        return "\(Self.format(usedMinor, currency, exponent)) of \(Self.format(limitMinor, currency, exponent))"
    }

    private static func format(_ minor: Int, _ currency: String, _ exponent: Int) -> String {
        let symbol = currency == "USD" ? "$" : "\(currency) "
        let amount = Double(minor) / pow(10, Double(exponent))
        return String(format: "%@%.\(max(0, exponent))f", symbol, amount)
    }
}

/// Pure transformation: decoded response → ordered view models. No UI, no I/O.
public enum MeterBuilder {
    public static func meters(
        from response: UsageResponse, thresholds: Thresholds = .standard
    ) -> [Meter] {
        let limits = response.limits ?? []
        return limits.enumerated()
            .map { index, limit in meter(from: limit, index: index, thresholds: thresholds) }
            .sorted { ($0.rank, $0.orderInResponse) < ($1.rank, $1.orderInResponse) }
            .map(\.meter)
    }

    public static func menuBarSummary(from meters: [Meter]) -> MenuBarSummary {
        MenuBarSummary(
            session: meters.first { $0.rank == 0 }?.percent,
            weeklyAll: meters.first { $0.rank == 1 }?.percent,
            scopedMax: meters.filter { $0.rank == 2 }.compactMap(\.percent).max(),
            worstLevel: meters.map(\.level).max() ?? .normal
        )
    }

    /// Nil unless the account has usage credits enabled — a permanently
    /// disabled "out of credits: $0.00" row is noise, not information.
    public static func spendLine(from response: UsageResponse) -> SpendLine? {
        guard let spend = response.spend,
              spend.enabled == true,
              let used = spend.used, let usedMinor = used.amountMinor
        else { return nil }
        return SpendLine(
            usedMinor: usedMinor,
            limitMinor: spend.limit?.amountMinor,
            currency: used.currency ?? "USD",
            exponent: used.exponent ?? 2
        )
    }

    private static func meter(
        from limit: UsageLimit, index: Int, thresholds: Thresholds
    ) -> (meter: Meter, rank: Int, orderInResponse: Int) {
        let (label, rank) = labelAndRank(for: limit)
        let percent = limit.percent.map { max(0, min(100, Int($0.rounded()))) }
        let meter = Meter(
            id: "\(index)-\(limit.kind ?? "unknown")",
            label: label,
            percent: percent,
            resetsAt: limit.resetsAt,
            level: level(percent: percent, severity: limit.severity, thresholds: thresholds),
            rank: rank
        )
        return (meter, rank, index)
    }

    private static func labelAndRank(for limit: UsageLimit) -> (String, Int) {
        switch limit.kind {
        case "session":
            return ("Session (5h)", 0)
        case "weekly_all":
            return ("Weekly · all models", 1)
        case "weekly_scoped":
            let model = limit.scope?.model?.displayName ?? "scoped"
            return ("Weekly · \(model)", 2)
        case let other?:
            return (titleCased(other), 2)
        case nil:
            return ("Unknown limit", 2)
        }
    }

    private static func level(
        percent: Int?, severity: String?, thresholds: Thresholds
    ) -> DisplayLevel {
        let forced: DisplayLevel = (severity != nil && severity != "normal") ? .warning : .normal
        guard let percent else { return forced }
        let byPercent: DisplayLevel =
            percent >= thresholds.criticalPercent ? .critical
            : percent >= thresholds.warningPercent ? .warning
            : .normal
        return max(forced, byPercent)
    }

    private static func titleCased(_ kind: String) -> String {
        kind.split(separator: "_").map(\.capitalized).joined(separator: " ")
    }
}
