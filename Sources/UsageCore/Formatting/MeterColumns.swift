import Foundation

/// Several accounts' meters laid out as one table (the main window's Home):
/// a row per account, and a column per KIND of limit, so the eye can run
/// down "every session window" or "every weekly one" across accounts and
/// harnesses.
///
/// Column 0 holds an account's first short-window meter (rank 0: session,
/// daily), column 1 its first long-window one (rank 1: weekly); whatever it
/// has beyond those follows in the menu bar's order — more unscoped meters
/// by rank and window length, then the scoped ones. A slot an account has
/// no meter for is a BLANK cell, never a 0% one (absent ≠ zero), and a
/// column that is blank for every account is dropped.
public enum MeterColumns {
    public static func arrange(_ accounts: [[Meter]]) -> [[Meter?]] {
        let rows: [[Meter?]] = accounts.map { meters in
            let ordered = menuBarOrder(meters)
            let short = ordered.first { $0.rank == 0 }
            let long = ordered.first { $0.rank == 1 }
            let rest = ordered.filter { $0.id != short?.id && $0.id != long?.id }
            return [short, long] + rest.map(Optional.some)
        }
        let width = rows.map(\.count).max() ?? 0
        let padded = rows.map { $0 + Array(repeating: nil, count: width - $0.count) }
        let kept = (0..<width).filter { column in padded.contains { $0[column] != nil } }
        return padded.map { row in kept.map { row[$0] } }
    }

    /// Unscoped first (by rank, then window length, then the provider's
    /// order), then scoped in the provider's order — `menuBarSegments`'s.
    static func menuBarOrder(_ meters: [Meter]) -> [Meter] {
        let unscoped = meters.enumerated()
            .filter { $0.element.rank < 2 }
            .sorted {
                let (a, b) = ($0.element, $1.element)
                if a.rank != b.rank { return a.rank < b.rank }
                let (aWindow, bWindow) = (a.limitWindow ?? .infinity, b.limitWindow ?? .infinity)
                return aWindow != bWindow ? aWindow < bWindow : $0.offset < $1.offset
            }
            .map(\.element)
        return unscoped + meters.filter { $0.rank >= 2 }
    }
}
