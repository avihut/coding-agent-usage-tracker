import Foundation

/// Where a section's activity — `activity`, `models`, `sessions` — stands
/// (2026-11-21, additive). A starting host used to publish those as zeros
/// until its first full scan landed, minutes later on a loaded Mac ("0 tok ·
/// no sessions recorded yet"); absent ≠ zero, so now the digest says which
/// it is:
///
/// - `scanning`: nothing known yet — this run's first scan hasn't landed
///   and there was no previous scan to show. A profile SECTION carries its
///   activity, models and sessions as nil. The TOP LEVEL keeps its empty
///   rollup, because every pre-0.10x decoder requires the field; a reader
///   that knows this marker draws "scanning…" from it, never the zeros.
/// - `cached`: the previous run's last complete scan, exactly as its cache
///   saved it, while this run re-validates (`LocalActivitySource.cachedScan`).
///   `asOf` is when that scan finished — its real age.
/// - `scanned`: this run's own scan; `asOf` is when it landed.
///
/// Nil (the field absent) means a writer that predates the marker, or an
/// engine whose harness leaves nothing to scan: read the activity as always.
public struct ActivityStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case scanning, cached, scanned

        /// A state a newer writer adds reads as `scanned` — the activity is
        /// drawn as it is — exactly as the TUI's mirror reads it. A strict
        /// decode would fail the WHOLE digest on one unknown word, and the
        /// digest is additive-only forever.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .scanned
        }
    }

    public let state: State
    public let asOf: Date?

    public init(state: State, asOf: Date?) {
        self.state = state
        self.asOf = asOf
    }

    public static let scanning = ActivityStatus(state: .scanning, asOf: nil)

    public static func cached(asOf: Date) -> ActivityStatus {
        ActivityStatus(state: .cached, asOf: asOf)
    }

    public static func scanned(at: Date) -> ActivityStatus {
        ActivityStatus(state: .scanned, asOf: at)
    }

    /// True while there is nothing to show yet.
    public var isScanning: Bool { state == .scanning }

    private enum CodingKeys: String, CodingKey {
        case state, asOf
    }
}
