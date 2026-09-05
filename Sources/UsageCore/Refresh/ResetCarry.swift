import Foundation

/// Carries a meter's window end across polls that report none.
///
/// Observed 2026-09-04: Anthropic zeroed the weekly meters mid-window (a
/// limit reset granted to everyone, not a window roll) and, until the next
/// token was spent, the API omitted `resets_at` entirely. When usage resumed
/// the SAME stamp came back — the window had never ended. Without this, the
/// stamp's absence read as "no live window": the popover fell back to
/// History, the forecast went dark, and every face lost its reset line for
/// sixteen hours of a window that was in fact still running.
///
/// The inference is safe by construction: a stamp still ahead of now names
/// a window that has not ended, so nothing has replaced it; if the API later
/// restates a DIFFERENT stamp, `ResetStamp.moved` catches the roll exactly
/// as before. A 5h session whose window ended while idle carries nothing —
/// its stamp is in the past. `history.json` keeps what the API said; the
/// carry is applied where the stamp is READ (the live snapshot the engine
/// publishes, and the sample series the charts draw from).
public enum ResetCarry {
    /// The last stamp observed for `label`, while it still lies ahead of
    /// `now`; nil once it has passed or when none was ever seen.
    public static func carried(label: String, samples: [UsageSample], now: Date) -> Date? {
        for sample in samples.reversed() {
            if let stamp = sample.resets?[label] {
                return stamp > now ? stamp : nil
            }
        }
        return nil
    }

    /// The snapshot with each stampless meter inheriting its carried stamp.
    /// Meters that reported a stamp are untouched — the API's word wins
    /// whenever it gives one.
    public static func fill(_ snapshot: Snapshot, samples: [UsageSample], now: Date) -> Snapshot {
        var changed = false
        let meters = snapshot.meters.map { meter -> Meter in
            guard meter.resetsAt == nil,
                  let stamp = carried(label: meter.label, samples: samples, now: now)
            else { return meter }
            changed = true
            return Meter(
                id: meter.id, label: meter.label, percent: meter.percent, resetsAt: stamp,
                level: meter.level, rank: meter.rank, limitWindow: meter.limitWindow,
                rateWindow: meter.rateWindow, forcesWarning: meter.forcesWarning,
                scopedModelName: meter.scopedModelName)
        }
        guard changed else { return snapshot }
        return Snapshot(
            meters: meters, spendLine: snapshot.spendLine,
            fetchedAt: snapshot.fetchedAt, plan: snapshot.plan)
    }

    /// The chronological series with every stampless sample inheriting, per
    /// label, the last stamp seen before it — while that stamp is still
    /// ahead of the sample's own time. Percents are untouched; a sample
    /// without a percent for a label gains no stamp for it either.
    public static func fill(_ samples: [UsageSample]) -> [UsageSample] {
        var remembered: [String: Date] = [:]
        return samples.map { sample in
            var resets = sample.resets ?? [:]
            for (label, stamp) in resets { remembered[label] = stamp }
            var changed = false
            for label in sample.percents.keys where resets[label] == nil {
                if let stamp = remembered[label], stamp > sample.t {
                    resets[label] = stamp
                    changed = true
                }
            }
            guard changed else { return sample }
            return UsageSample(t: sample.t, percents: sample.percents, resets: resets)
        }
    }
}
