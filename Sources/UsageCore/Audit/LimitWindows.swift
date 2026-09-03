import Foundation

/// The limit windows a meter has been OBSERVED running through, newest
/// first — what the popover's Current span pages back over ("previous
/// session", "2 weeks ago"). Strictly observational, like the window
/// ledger: a window is known only through a reset stamp somebody actually
/// saw — a sample taken while it ran (`UsageSample.resets`) or a close the
/// ledger recorded — never inferred from cadence, so a week the app spent
/// switched off is a gap, not a fabricated page.
public enum LimitWindows {
    /// Past windows of the meter whose sample vocabulary is `label`, each
    /// `end − window ... end`, newest first. The live window (a stamp within
    /// `ResetStamp.tolerance` of `liveReset`) and stamps still ahead of
    /// `now` are excluded; stamps naming the same window through API jitter
    /// collapse to one entry.
    public static func observed(
        label: String, window: TimeInterval, liveReset: Date?,
        samples: [UsageSample], outcomes: [WindowOutcome], now: Date = Date()
    ) -> [DateInterval] {
        guard window > 0 else { return [] }
        var stamps: [Date] = []
        for sample in samples {
            if let stamp = sample.resets?[label] { stamps.append(stamp) }
        }
        for outcome in outcomes where outcome.label == label {
            stamps.append(outcome.end)
        }
        stamps = stamps.filter { stamp in
            guard stamp <= now else { return false }
            if let liveReset, !ResetStamp.moved(stamp, liveReset) { return false }
            return true
        }
        stamps.sort(by: >)
        var ends: [Date] = []
        for stamp in stamps {
            if let last = ends.last, !ResetStamp.moved(last, stamp) { continue }
            ends.append(stamp)
        }
        return ends.map { DateInterval(start: $0.addingTimeInterval(-window), end: $0) }
    }
}
