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

    /// `lastAllowed` seeds the gate with a fetch that happened in ANOTHER
    /// process — an app taking over from a dead daemon reads the digest's
    /// fetch stamp so the handover can never double-poll inside the floor.
    public init(
        minimumInterval: TimeInterval = TriggerGate.floor, lastAllowed: Date? = nil
    ) {
        self.minimumInterval = minimumInterval
        self.lastAllowed = lastAllowed
    }

    public mutating func shouldAllow(at now: Date) -> Bool {
        if let lastAllowed, now.timeIntervalSince(lastAllowed) < minimumInterval {
            return false
        }
        lastAllowed = now
        return true
    }
}
