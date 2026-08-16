import Foundation

/// The activity strip's idle tolerance: Claude sitting quiet while the user
/// reads or types a reply is still the same working session, so gaps shorter
/// than the grace period are bridged into one stretch — and the newest
/// stretch gets the same courtesy against "now", held open while its idle
/// time could still turn out to be such a pause. Zero means raw truth —
/// only the moments Claude itself was producing tokens.
public enum ActivityGrace {
    public static let defaultSeconds: TimeInterval = 900
    public static let storageKey = "activityGraceSeconds"

    /// Bridges gaps of at most `grace` seconds between consecutive stretches.
    /// Input must be chronological and non-overlapping (the strip's runs are).
    public static func stitch(
        _ stretches: [DateInterval], grace: TimeInterval
    ) -> [DateInterval] {
        var merged: [DateInterval] = []
        for stretch in stretches {
            if let last = merged.last, stretch.start.timeIntervalSince(last.end) <= grace {
                merged[merged.count - 1] = DateInterval(
                    start: last.start, end: max(last.end, stretch.end))
            } else {
                merged.append(stretch)
            }
        }
        return merged
    }

    /// The true start of a session whose stretch is clipped at `boundary`
    /// (the frame's left edge): walks minute-grained activity moments
    /// backwards from the boundary, bridging idle gaps within the grace —
    /// plus 60s for each moment's own minute of activity. Returns nil when
    /// no moment before the boundary connects. `moments` must be
    /// chronological; the walk is best effort, reaching only as far back
    /// as the moments do.
    public static func clippedStart(
        before boundary: Date, moments: [Date], grace: TimeInterval
    ) -> Date? {
        var anchor = boundary
        var start: Date?
        for t in moments.reversed() where t < boundary {
            guard anchor.timeIntervalSince(t) <= grace + 60 else { break }
            start = t
            anchor = t
        }
        return start
    }

    /// The live tail: while the newest stretch's idle time is still within
    /// the grace period the session may yet continue, so it is held open to
    /// `now`. Once the gap outgrows the grace the hold releases and the
    /// stretch reverts to its true end. Never shrinks a stretch already
    /// reaching `now`.
    public static func holdOpen(
        _ stretches: [DateInterval], until now: Date, grace: TimeInterval
    ) -> [DateInterval] {
        guard let last = stretches.last, last.end < now,
              now.timeIntervalSince(last.end) <= grace
        else { return stretches }
        var held = stretches
        held[held.count - 1] = DateInterval(start: last.start, end: now)
        return held
    }
}

/// The grace slider's track: a hard "off" stop on the left, then a log scale
/// from 1 minute to 1 hour — same shape as `RefreshIntervalScale` except the
/// scale must reach an exact 0, which no log curve can. Pure math so the
/// zero stop and snapping are testable.
public enum ActivityGraceScale {
    public static let range: ClosedRange<Double> = 0...3600
    /// The log portion of the track; everything below its floor is "off".
    static let logRange: ClosedRange<Double> = 60...3600
    /// Fraction of the track the zero stop occupies before the log begins.
    static let zeroWidth = 0.08
    public static let marks: [Double] = [0, 60, 300, 900, 1800, 3600]
    /// Snap distance in normalized track space (~3% of the track).
    static let snapRadius = 0.03

    /// Seconds → 0...1 along the track (0 pins to the left stop).
    public static func position(of value: Double) -> Double {
        guard value >= logRange.lowerBound else { return 0 }
        let clamped = min(value, logRange.upperBound)
        let logFraction =
            log(clamped / logRange.lowerBound)
            / log(logRange.upperBound / logRange.lowerBound)
        return zeroWidth + (1 - zeroWidth) * logFraction
    }

    /// 0...1 → seconds: magnetic near a mark, dead-zone left of the log
    /// start collapses to 0, otherwise rounded to whole minutes.
    public static func value(at position: Double) -> Double {
        let p = min(max(position, 0), 1)
        for mark in marks where abs(Self.position(of: mark) - p) <= snapRadius {
            return mark
        }
        if p <= zeroWidth { return 0 }
        let t = (p - zeroWidth) / (1 - zeroWidth)
        let raw = logRange.lowerBound
            * exp(t * log(logRange.upperBound / logRange.lowerBound))
        return min(
            max((raw / 60).rounded() * 60, logRange.lowerBound), logRange.upperBound)
    }
}
