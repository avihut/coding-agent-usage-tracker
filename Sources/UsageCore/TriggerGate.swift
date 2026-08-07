import Foundation

/// Enforces the never-poll-faster-than rule (spec §9) uniformly across every
/// trigger — timer, wake, network-restore, and manual refresh alike.
public struct TriggerGate: Sendable {
    public let minimumInterval: TimeInterval
    private var lastAllowed: Date?

    public init(minimumInterval: TimeInterval = 60) {
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
