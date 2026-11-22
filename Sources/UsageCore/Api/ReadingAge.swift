import Foundation

/// How old a limits reading may be before it reads as OLD — the age of the
/// SNAPSHOT, beside (not instead of) each window's own roll rule.
///
/// A provider's `Snapshot.fetchedAt` is when its numbers were actually read:
/// a fetch for a network provider, the `token_count` event's own time for
/// Codex, the probe run's finish for Antigravity, the cached fetch for a
/// cache served offline. Every poll used to hand the engine such a snapshot
/// as `.live`, so a three-day-old Codex reading drew white digits, named the
/// plan as current and was forecast from (2026-11-22, user-reported: an
/// account moved back to the free plan still read "Pro Lite plan", weekly
/// 75%, "runs out in 23h 19m · ≈64% over").
///
/// An OLD reading is shown as what it is — "as of <stamp>", the bar's stale
/// treatment — and no forecast is made from it (`PredictionEngine
/// .predictAll(…, readingAt:)`). Its windows still roll on their own resets.
///
/// THE HORIZON: the shortest limit window the reading carries, capped at
/// `cap`. (1) A reading older than its shortest window has outlived the
/// window it measured — that window has certainly reset since. (2) For long
/// windows the weekly forecast's measured part, the recent-rate fit, reaches
/// back 4 h (`Meter.rateWindow`); past it nothing measured is in the fit and
/// the forecast is the learned rhythm projected from a point the account has
/// left. The cap is that fit plus the slowest poll spacing a HEALTHY engine
/// produces (`AdaptiveCadence.ceiling`, 1 h, plus slack) — and stays above
/// the slowest chosen pace and the backoff ceiling (2 h each, pinned by a
/// test), as does every window the shipped providers report (5 h and
/// longer), so a slow-paced account never reads old between two good polls.
/// A window SHORTER than the poll spacing would: such a reading really has
/// outlived its window between polls, and saying so is the rule, not a
/// flicker to floor away.
/// It errs short on purpose: a false "old" costs a grey cell on an agent
/// untouched for hours; a false "current" is the report above.
///
/// No provider seam: Gemini's count is re-taken every poll (`fetchedAt` =
/// count time), so it never ages, by its data.
public enum ReadingAge {
    /// The longest a reading stays current, whatever its windows.
    public static let cap: TimeInterval = 6 * 3600

    /// How long a reading carrying these meters stays current.
    public static func horizon(meters: [Meter]) -> TimeInterval {
        let shortest = meters.compactMap(\.limitWindow).filter { $0 > 0 }.min()
        return min(shortest ?? cap, cap)
    }

    /// The instant a reading taken at `fetchedAt` turns old.
    public static func oldAt(fetchedAt: Date, meters: [Meter]) -> Date {
        fetchedAt.addingTimeInterval(horizon(meters: meters))
    }

    /// Strictly past the horizon. A `fetchedAt` in the future (the clock was
    /// set back) is never old here: its age can't be read, and "old" would
    /// be a guess — the CLI's `--max-data-age` refuses it on its own terms.
    public static func isOld(fetchedAt: Date, meters: [Meter], now: Date) -> Bool {
        now > oldAt(fetchedAt: fetchedAt, meters: meters)
    }
}

extension Snapshot {
    /// When this reading turns old (`ReadingAge`).
    public var oldAt: Date { ReadingAge.oldAt(fetchedAt: fetchedAt, meters: meters) }

    public func isOld(at now: Date) -> Bool {
        ReadingAge.isOld(fetchedAt: fetchedAt, meters: meters, now: now)
    }
}

extension DisplayState {
    /// The reading's own stamp while it is OLD — what the faces print as
    /// "as of …" — and nil while it is current or there is no reading.
    /// Independent of `isStale` (cache-served or errored): a reading can be
    /// either, both, or neither.
    public func asOf(at now: Date) -> Date? {
        guard let snapshot, snapshot.isOld(at: now) else { return nil }
        return snapshot.fetchedAt
    }
}
