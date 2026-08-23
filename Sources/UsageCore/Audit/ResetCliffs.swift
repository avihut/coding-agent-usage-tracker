import Foundation

/// Where the usage line must fall off a cliff instead of sloping: a limit
/// window ending zeroes the meter in an instant, but sparse samples
/// straddling the reset used to draw a gradual decline across the gap.
/// Detects the drops between neighboring samples and places each cliff at
/// the old window's end.
public enum ResetCliffs {
    /// One percent sample, optionally stamped with the window end the API
    /// reported alongside it. Samples from builds before the stamp lack it.
    public struct Sample: Equatable, Sendable {
        public let t: Date
        public let percent: Int
        public let resetsAt: Date?

        public init(t: Date, percent: Int, resetsAt: Date? = nil) {
            self.t = t
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    /// A vertical drop: the line holds `from` until `at`, falls to zero
    /// there, then climbs toward the next sample.
    public struct Cliff: Equatable, Sendable {
        public let at: Date
        public let from: Int

        public init(at: Date, from: Int) {
            self.at = at
            self.from = from
        }
    }

    /// Unstamped legacy samples treat only a drop this large as a reset —
    /// percent jitter must not carve zero-cliffs into the line.
    static let legacyDropThreshold = 5

    /// The cliffs hiding between consecutive samples of a chronological
    /// series. `window` is the meter's limit-window length and
    /// `currentReset` its live window end — the schedule grid for placing
    /// cliffs that predate the reset stamps.
    public static func cliffs(
        between samples: [Sample], window: TimeInterval, currentReset: Date?
    ) -> [Cliff] {
        zip(samples, samples.dropFirst()).compactMap { a, b in
            guard isReset(from: a, to: b) else { return nil }
            return Cliff(
                at: cliffTime(after: a, before: b, window: window, currentReset: currentReset),
                from: a.percent)
        }
    }

    /// With both stamps present the window rolled iff the stamp moved
    /// beyond `ResetStamp` jitter — an in-window percent correction never
    /// cliffs. Legacy samples fall back to the drop-size heuristic.
    static func isReset(from a: Sample, to b: Sample) -> Bool {
        guard b.percent < a.percent else { return false }
        if let before = a.resetsAt, let after = b.resetsAt {
            return ResetStamp.moved(before, after)
        }
        return a.percent - b.percent >= legacyDropThreshold
    }

    /// The old window's end inside (a.t, b.t]: the earlier sample's stamp
    /// when it lands there, else the earliest reset-schedule grid line
    /// (currentReset − k·window) inside the gap — multiple windows may
    /// have elapsed unsampled, and the hold breaks at the first — else
    /// the gap's midpoint: approximate, but never a slope.
    static func cliffTime(
        after a: Sample, before b: Sample, window: TimeInterval, currentReset: Date?
    ) -> Date {
        if let stamp = a.resetsAt, stamp > a.t, stamp <= b.t { return stamp }
        if let currentReset, window > 0 {
            var k = 1.0
            var earliest: Date?
            while true {
                let boundary = currentReset.addingTimeInterval(-k * window)
                if boundary <= a.t { break }
                if boundary <= b.t { earliest = boundary }
                k += 1
            }
            if let earliest { return earliest }
        }
        return a.t.addingTimeInterval(b.t.timeIntervalSince(a.t) / 2)
    }
}
