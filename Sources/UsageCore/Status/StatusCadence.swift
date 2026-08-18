import Foundation

/// How often to ask the status page, given what the last answer said —
/// decision D1, and the reason the feature is polite by construction.
///
/// The numbers come from measuring the feed (2026-08-19): CloudFront serves
/// `summary.json` with `max-age=10`, so polling faster than 10s re-reads
/// identical bytes by construction, and every poll is conditional (ETag), so
/// the steady state costs a 304 with no body. Healthy is 5 minutes — the same
/// order as the app's own usage poll; an incident tightens to 60s so the
/// all-clear lands within a minute of the page saying so.
///
/// Pure and clock-free like `AdaptiveCadence`: callers pass `now`, tests pass
/// whatever they like, and the jitter generator is injectable so a test can
/// pin it. No IO, no timers — `StatusPoller` owns those.
public struct StatusCadence: Sendable, Equatable {
    /// Where the cadence currently sits. Only `poll(outcome:now:)` moves it.
    public enum Phase: String, Sendable, Equatable {
        /// Nothing unresolved: the slow lane.
        case healthy
        /// Something is open right now.
        case incident
        /// Just resolved — still watching closely for a reopen.
        case cooldown
        /// The feed itself is failing; interval doubles toward the ceiling.
        case unreachable
    }

    /// The one place every cadence number lives (decision D1).
    public static let healthyInterval: TimeInterval = 300
    public static let incidentInterval: TimeInterval = 60
    public static let cooldownInterval: TimeInterval = 120
    /// How long a resolution keeps the tighter cooldown pace.
    public static let cooldownSpan: TimeInterval = 600
    public static let failureFloor: TimeInterval = 60
    public static let failureCeiling: TimeInterval = 900
    /// ±10%, so a fleet of these apps never marches in lockstep on the feed.
    public static let jitterFraction = 0.1
    /// The CDN's own cache TTL — asking again inside it is guaranteed to
    /// return bytes we already have, so even a manual poke waits this long.
    public static let minimumSpacing: TimeInterval = 10
    /// Consecutive failures before the card admits it doesn't know (D3). Two
    /// is a blip; three is a pattern worth showing.
    public static let unknownAfterFailures = 3

    public private(set) var phase: Phase = .healthy
    /// Consecutive failed polls; reset by any success.
    public private(set) var failures = 0
    /// When the cooldown lane expires back to healthy.
    private var cooldownUntil: Date?
    /// Last poll attempt — the `minimumSpacing` floor measures from here.
    public private(set) var lastPollAt: Date?

    public init() {}

    /// What a completed poll found.
    public enum Outcome: Sendable, Equatable {
        /// A card landed (fresh body or a 304 confirming the old one).
        case observed(hasIncident: Bool)
        case failed
    }

    /// Folds one poll's result in and returns the phase now in force.
    @discardableResult
    public mutating func record(_ outcome: Outcome, now: Date) -> Phase {
        lastPollAt = now
        switch outcome {
        case .failed:
            failures += 1
            phase = .unreachable
        case .observed(let hasIncident):
            failures = 0
            if hasIncident {
                phase = .incident
                // A reopen must not inherit the old cooldown's expiry.
                cooldownUntil = nil
            } else if phase == .incident {
                // Just resolved: watch closely for a reopen (D4).
                phase = .cooldown
                cooldownUntil = now.addingTimeInterval(Self.cooldownSpan)
            } else if phase == .cooldown, let until = cooldownUntil, now >= until {
                phase = .healthy
                cooldownUntil = nil
            } else if phase == .unreachable {
                // Recovered from a failing feed straight into the slow lane.
                phase = .healthy
                cooldownUntil = nil
            }
        }
        return phase
    }

    /// The base interval the current phase asks for, before jitter.
    public var baseInterval: TimeInterval {
        switch phase {
        case .healthy: Self.healthyInterval
        case .incident: Self.incidentInterval
        case .cooldown: Self.cooldownInterval
        case .unreachable:
            // 60, 120, 240, 480, 900 (capped) — a feed that's down stays
            // asked-about, just not urgently.
            min(
                Self.failureCeiling,
                Self.failureFloor * pow(2, Double(max(0, failures - 1))))
        }
    }

    /// How long to wait before the next poll. `jitter` supplies a value in
    /// 0..<1 (tests pass a constant); the spread is ±10% around the base.
    public func nextDelay(jitter: () -> Double = { Double.random(in: 0..<1) }) -> TimeInterval {
        let base = baseInterval
        let spread = base * Self.jitterFraction
        let offset = (jitter() * 2 - 1) * spread
        return max(Self.minimumSpacing, base + offset)
    }

    /// Whether an out-of-band poke (wake, panel open, manual) may fetch now.
    /// The CDN floor applies to every caller — a poke inside it would spend a
    /// request to receive bytes we already hold.
    public func mayPollNow(_ now: Date) -> Bool {
        guard let lastPollAt else { return true }
        return now.timeIntervalSince(lastPollAt) >= Self.minimumSpacing
    }

    /// True once failures have piled up enough to stop claiming knowledge —
    /// the hollow grey dot (D3). Below the threshold the last good card
    /// stands, because a single missed poll says nothing about the service.
    public var isUnknown: Bool { failures >= Self.unknownAfterFailures }
}
