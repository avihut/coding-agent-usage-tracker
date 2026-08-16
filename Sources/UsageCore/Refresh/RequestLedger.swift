import Foundation

/// Rolling count of usage-endpoint requests against an estimated hourly
/// budget, so the panel can show how close polling plus manual refreshes are
/// getting to the API's undisclosed limit before a 429 does it the hard way.
///
/// The budget starts at the community-observed safe rate (one request per
/// 180s → 20/hour, anthropics/claude-code#31637) and tightens itself whenever
/// a 429 reveals the real ceiling was lower.
public struct RequestLedger: Sendable, Equatable {
    public static let window: TimeInterval = 3600
    public static let defaultCeiling = 20
    /// Learned ceilings never drop below this — a burst 429 right after
    /// launch shouldn't convince us the budget is two requests an hour.
    public static let minimumCeiling = 4

    public private(set) var ceiling: Int
    private var stamps: [Date] = []

    public init(ceiling: Int = RequestLedger.defaultCeiling) {
        self.ceiling = max(Self.minimumCeiling, ceiling)
    }

    public mutating func recordRequest(at now: Date) {
        trim(now: now)
        stamps.append(now)
    }

    /// A 429 means the requests already made this window were too many:
    /// adopt that count (less one) as the new ceiling when it's lower.
    public mutating func noteRateLimited(at now: Date) {
        trim(now: now)
        ceiling = max(Self.minimumCeiling, min(ceiling, stamps.count - 1))
    }

    public func used(at now: Date) -> Int {
        stamps.count { now.timeIntervalSince($0) < Self.window }
    }

    /// 0 = idle, 1 = at the estimated budget. Can exceed 1.
    public func pressure(at now: Date) -> Double {
        Double(used(at: now)) / Double(max(1, ceiling))
    }

    private mutating func trim(now: Date) {
        stamps.removeAll { now.timeIntervalSince($0) >= Self.window }
    }
}
