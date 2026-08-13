import Foundation

/// Enforces the never-poll-faster-than rule (spec §9) uniformly across every
/// trigger — timer, wake, network-restore, and manual refresh alike.
///
/// The floor is 180s: community testing of the undocumented endpoint found
/// sustained sub-3-minute polling reliably trips sticky 429s
/// (anthropics/claude-code#31637), and this app observed the same at 60s.
public struct TriggerGate: Sendable {
    public static let floor: TimeInterval = 180

    public let minimumInterval: TimeInterval
    private var lastAllowed: Date?

    public init(minimumInterval: TimeInterval = TriggerGate.floor) {
        self.minimumInterval = minimumInterval
    }

    public mutating func shouldAllow(at now: Date) -> Bool {
        if let lastAllowed, now.timeIntervalSince(lastAllowed) < minimumInterval {
            return false
        }
        lastAllowed = now
        return true
    }
}
