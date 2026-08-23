import Foundation

/// The API restates each meter's `resets_at` with sub-second noise on every
/// poll: one fortnight of weekly stamps held no two byte-equal values —
/// the same boundary arrived as …999.857, …000.002, …000.325 on consecutive
/// reads (measured 2026-08-23). Every "did the window roll?" question must
/// therefore go through this predicate, never Date equality: exact equality
/// starved `WeeklyProfile` of 92% of its sample pairs (a flat typical-week
/// overlay and forecast baseline) and made `UsageMovement` read every poll
/// as activity, so quiet-time cadence decay never engaged.
public enum ResetStamp {
    /// A real rollover moves the stamp by at least the limit window — hours
    /// for the shortest (5h session) — while the observed noise spans
    /// ±0.5s. A minute sits comfortably between the two scales.
    public static let tolerance: TimeInterval = 60

    /// True when two reported stamps name different windows.
    public static func moved(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) > tolerance
    }

    /// Optional form: a stamp appearing or vanishing is a window change —
    /// a meter gaining its first reset has opened a window — while two
    /// absences are the same (unknown) window.
    public static func moved(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): false
        case let (a?, b?): moved(a, b)
        default: true
        }
    }

    /// True when `new` names a later window than `old` — the direction a
    /// window close rides on.
    public static func rolledForward(from old: Date, to new: Date) -> Bool {
        new.timeIntervalSince(old) > tolerance
    }
}
