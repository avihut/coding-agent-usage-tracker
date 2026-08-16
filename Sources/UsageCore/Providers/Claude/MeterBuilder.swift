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
    /// Normalized semantics, not provider vocabulary: 0 = the fast
    /// session-style limit, 1 = the overall long window, 2 = scoped/other.
    /// Ordering and menu-bar slotting key on this.
    public let rank: Int
    /// Full length of the limit window (Claude: the session's 5 hours, a
    /// weekly's 7 days) — provider data, not a rank heuristic. Nil when the
    /// provider doesn't know; prediction then stays pure-linear.
    public let limitWindow: TimeInterval?
    /// How far back the burn-rate fit reaches for this meter.
    public let rateWindow: TimeInterval
    /// The API flagged this limit non-normal — floors the level at warning
    /// under any thresholds.
    public let forcesWarning: Bool
    /// For scoped limits: the model this meter covers, as the provider
    /// displays it ("Fable"). Data, so no UI ever parses it out of `label`.
    public let scopedModelName: String?

    public init(
        id: String, label: String, percent: Int?, resetsAt: Date?,
        level: DisplayLevel, rank: Int,
        limitWindow: TimeInterval? = nil, rateWindow: TimeInterval? = nil,
        forcesWarning: Bool = false, scopedModelName: String? = nil
    ) {
        self.id = id
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.level = level
        self.rank = rank
        self.limitWindow = limitWindow
        self.rateWindow = rateWindow ?? Self.defaultRateWindow(limitWindow: limitWindow)
        self.forcesWarning = forcesWarning
        self.scopedModelName = scopedModelName
    }

    /// Short windows move fast and need a tight fit; long ones should
    /// average across sittings: 45 minutes for windows up to ~6 hours,
    /// 4 hours beyond (and when the window is unknown). Providers inherit
    /// this unless they know better.
    public static func defaultRateWindow(limitWindow: TimeInterval?) -> TimeInterval {
        guard let limitWindow, limitWindow <= 6 * 3600 else { return 4 * 3600 }
        return 45 * 60
    }

    /// The same meter re-classified under different thresholds — what lets a
    /// threshold edit re-color the panel without re-fetching.
    public func releveled(thresholds: Thresholds) -> Meter {
        Meter(
            id: id, label: label, percent: percent, resetsAt: resetsAt,
            level: MeterBuilder.level(
                percent: percent, forcesWarning: forcesWarning, thresholds: thresholds),
            rank: rank, limitWindow: limitWindow, rateWindow: rateWindow,
            forcesWarning: forcesWarning, scopedModelName: scopedModelName)
    }
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

    /// Public so a client-mode app can rebuild the line from the digest.
    public init(usedMinor: Int, limitMinor: Int?, currency: String, exponent: Int) {
        self.usedMinor = usedMinor
        self.limitMinor = limitMinor
        self.currency = currency
        self.exponent = exponent
    }

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

/// Pure transformation: Anthropic's decoded response → normalized view
/// models. This is the Claude provider's adapter — the ONE place its limit
/// vocabulary ("session", "weekly_all") and window shapes (5h, 7d) become
/// `Meter` data. No UI, no I/O.
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

    /// The full normalized snapshot for one fetched payload.
    public static func snapshot(
        from response: UsageResponse, fetchedAt: Date, plan: PlanInfo? = nil,
        thresholds: Thresholds = .standard
    ) -> Snapshot {
        Snapshot(
            meters: meters(from: response, thresholds: thresholds),
            spendLine: spendLine(from: response),
            fetchedAt: fetchedAt,
            plan: plan)
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
        let shape = shape(for: limit)
        let percent = limit.percent.map { max(0, min(100, Int($0.rounded()))) }
        let forcesWarning = limit.severity != nil && limit.severity != "normal"
        let meter = Meter(
            id: "\(index)-\(limit.kind ?? "unknown")",
            label: shape.label,
            percent: percent,
            resetsAt: limit.resetsAt,
            level: level(percent: percent, forcesWarning: forcesWarning, thresholds: thresholds),
            rank: shape.rank,
            limitWindow: shape.limitWindow,
            forcesWarning: forcesWarning,
            scopedModelName: shape.scopedModel
        )
        return (meter, shape.rank, index)
    }

    /// Claude's limit vocabulary, translated once: kind → label, rank, and
    /// the window length the prediction engine works in.
    private static func shape(
        for limit: UsageLimit
    ) -> (label: String, rank: Int, limitWindow: TimeInterval?, scopedModel: String?) {
        switch limit.kind {
        case "session":
            return ("Session (5h)", 0, 5 * 3600, nil)
        case "weekly_all":
            return ("Weekly · all models", 1, 7 * 86400, nil)
        case "weekly_scoped":
            let model = limit.scope?.model?.displayName ?? "scoped"
            return ("Weekly · \(model)", 2, 7 * 86400, model)
        case let other?:
            return (titleCased(other), 2, nil, nil)
        case nil:
            return ("Unknown limit", 2, nil, nil)
        }
    }

    /// Percent thresholds, floored at warning when the API itself flagged
    /// the limit. Public because re-leveling on threshold edits reuses it.
    public static func level(
        percent: Int?, forcesWarning: Bool, thresholds: Thresholds
    ) -> DisplayLevel {
        let forced: DisplayLevel = forcesWarning ? .warning : .normal
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
