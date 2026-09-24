import Foundation

/// The samples that belong to ONE limit window — chosen by their reset
/// stamp, never by time alone.
///
/// Time alone is wrong at exactly one moment, and it is the moment that
/// matters most: the poll that lands on the window boundary still reports
/// the OLD window's percent, often with its `resets_at` blanked. It sits at
/// or after the new window's start, so a `t >= windowStart` filter takes it
/// — and the new window then appears to open at the old one's height. Read
/// through `ModelCurves.windowPercentPerToken`, which prepends a zero so the
/// window's entry height counts as a gain, that stale height is counted as
/// spend: a 5h window whose first in-window poll read the previous window's
/// 79% priced its tokens 7× too high and drew every model's curve 7× too
/// tall over a percent line sitting at 13% (user-reported 2026-09-24). The
/// same pair, 79 → 0, read as a vendor grant to `ModelCurves.holdsGrant`
/// and lifted the cap that keeps a single window's curves inside one limit.
///
/// The stamp settles it: that poll names the window it is leaving, and this
/// window's own polls name this window (within `ResetStamp.tolerance`, since
/// the API restates the boundary with sub-second noise).
public enum WindowSamples {
    /// The samples of the window `start...end` whose end is `reset`, in time
    /// order. `reset` nil keeps every in-range sample — an unknown window
    /// classifies nothing.
    ///
    /// Stamps blanked by the API are carried forward first
    /// (`ResetCarry.fill(_ samples:)`), so a stampless poll inside a window
    /// inherits that window's stamp. The carry stops exactly ON the boundary
    /// — it only carries a stamp still AHEAD of the sample — so the boundary
    /// poll itself is attributed here instead: a sample with no stamp of its
    /// own, landing within `ResetStamp.tolerance` of the last stamp observed
    /// before it, belongs to the window that stamp names. That rule fires
    /// only where a stamp was actually seen, so legacy history (no stamps at
    /// all, from builds before samples carried them) is untouched and stays
    /// selected on time alone.
    ///
    /// The error is asymmetric by design. Dropping one sample at a window's
    /// start costs nothing — the anchor enters the window at zero anyway —
    /// while keeping the stale height costs a multiple.
    public static func own(
        _ samples: [UsageSample], label: String, start: Date, end: Date, reset: Date?
    ) -> [UsageSample] {
        // Sorted BEFORE the carry: `fill` walks the series in order, and
        // sorting after it would scatter the stamps it inherited.
        let ordered = ResetCarry.fill(samples.sorted { $0.t < $1.t })
        var lastStamp: Date?
        var kept: [UsageSample] = []
        for sample in ordered {
            let stamped = sample.resets?[label]
            let boundary = lastStamp.flatMap { previous -> Date? in
                abs(sample.t.timeIntervalSince(previous)) <= ResetStamp.tolerance
                    ? previous : nil
            }
            // Every sample updates the memory, in range or not: the poll
            // before the window opened is what names the window it closed.
            if let stamped { lastStamp = stamped }
            guard sample.t >= start, sample.t <= end,
                  sample.percents[label] != nil
            else { continue }
            if let stamp = stamped ?? boundary, let reset,
               ResetStamp.moved(stamp, reset) { continue }
            kept.append(sample)
        }
        return kept
    }

    /// `own(...)` reduced to the meter's percents, in time order — the shape
    /// `ModelCurves.windowPercentPerToken` and `ModelCurves.holdsGrant` take.
    public static func percents(
        _ samples: [UsageSample], label: String, start: Date, end: Date, reset: Date?
    ) -> [Int] {
        own(samples, label: label, start: start, end: end, reset: reset)
            .compactMap { $0.percents[label] }
    }
}
