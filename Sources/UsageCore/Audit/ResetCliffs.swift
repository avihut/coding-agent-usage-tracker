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
        /// What emptied the meter.
        public enum Kind: Equatable, Sendable {
            /// The limit window ended and a new one began — the stamp moved.
            case windowEnd
            /// The meter fell to zero while its window end stood still: a
            /// reset granted mid-window (Anthropic's 2026-09-04 limit reset
            /// zeroed every weekly meter two days before the boundary). The
            /// window is the same one before and after, so nothing about it
            /// closed; the charts mark it apart from a boundary.
            case midWindow
        }

        public let at: Date
        public let from: Int
        public let kind: Kind

        public init(at: Date, from: Int, kind: Kind = .windowEnd) {
            self.at = at
            self.from = from
            self.kind = kind
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
            guard let kind = resetKind(from: a, to: b) else { return nil }
            switch kind {
            case .windowEnd:
                return Cliff(
                    at: cliffTime(after: a, before: b, window: window, currentReset: currentReset),
                    from: a.percent, kind: kind)
            case .midWindow:
                // No boundary to snap to — the window didn't end. The API
                // gives no moment for the grant, so the gap's midpoint is
                // the honest guess, and the readout says "~".
                return Cliff(at: midpoint(a, b), from: a.percent, kind: kind)
            }
        }
    }

    /// With both stamps present the window rolled iff the stamp moved
    /// beyond `ResetStamp` jitter; a fall to ZERO under an unmoved stamp is
    /// a reset granted inside the window, while any other in-window
    /// decrease is a correction and never cliffs. Legacy samples fall back
    /// to the drop-size heuristic and can only name a window end.
    static func resetKind(from a: Sample, to b: Sample) -> Cliff.Kind? {
        guard b.percent < a.percent else { return nil }
        if let before = a.resetsAt, let after = b.resetsAt {
            if ResetStamp.moved(before, after) { return .windowEnd }
            return b.percent == 0 ? .midWindow : nil
        }
        return a.percent - b.percent >= legacyDropThreshold ? .windowEnd : nil
    }

    static func isReset(from a: Sample, to b: Sample) -> Bool {
        resetKind(from: a, to: b) != nil
    }

    private static func midpoint(_ a: Sample, _ b: Sample) -> Date {
        a.t.addingTimeInterval(b.t.timeIntervalSince(a.t) / 2)
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
        return midpoint(a, b)
    }
}
