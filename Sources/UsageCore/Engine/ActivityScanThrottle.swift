import Foundation

/// When an engine re-scans its transcripts: at most once per `spacing`,
/// and never by dropping the last write of a burst.
///
/// A transcript write inside the spacing used to be skipped outright, with
/// nothing scheduled — so the final write of a turn, landing seconds after
/// a scan, stayed unscanned until something else in the tree changed
/// (observed 2026-10-23: a live transcript written 21 s after a scan was
/// still unscanned five minutes later). Now such a write is OWED: one
/// catch-up scan runs when the spacing has elapsed, or right after the
/// scan in flight lands, whichever is later. Pure, so the decisions are
/// unit-tested; the engine owns the timer.
struct ActivityScanThrottle: Equatable {
    static let spacing: TimeInterval = 60

    enum Step: Equatable {
        /// Start a scan now.
        case scan
        /// Run `catchUpDue(at:)` at this moment.
        case schedule(Date)
        case nothing
    }

    private(set) var lastStart: Date?
    private(set) var isScanning = false
    /// A reason to scan arrived that no started scan has seen.
    private(set) var owed = false
    /// The owed reason was a forced one (the socket's `scanNow`): its
    /// catch-up doesn't wait out the spacing.
    private(set) var owedForce = false
    /// The pending catch-up, so a burst schedules exactly one.
    private(set) var catchUpAt: Date?

    /// A reason to scan: a transcript write, the launch, a forced rescan.
    mutating func request(at now: Date, force: Bool = false) -> Step {
        if isScanning {
            owed = true
            owedForce = owedForce || force
            return .nothing
        }
        let spaced = lastStart.map { now.timeIntervalSince($0) >= Self.spacing } ?? true
        if force || spaced {
            lastStart = now
            isScanning = true
            owed = false
            owedForce = false
            catchUpAt = nil
            return .scan
        }
        owed = true
        guard catchUpAt == nil, let lastStart else { return .nothing }
        let due = lastStart.addingTimeInterval(Self.spacing)
        catchUpAt = due
        return .schedule(due)
    }

    /// The scan in flight landed. Anything that arrived while it ran may
    /// postdate its directory walk, so it gets one catch-up.
    mutating func finish(at now: Date) -> Step {
        isScanning = false
        guard owed, catchUpAt == nil else { return .nothing }
        let spacedFrom = (lastStart ?? now).addingTimeInterval(Self.spacing)
        let due = owedForce ? now : max(now, spacedFrom)
        catchUpAt = due
        return .schedule(due)
    }

    /// The scheduled catch-up's moment came.
    mutating func catchUpDue(at now: Date) -> Step {
        catchUpAt = nil
        guard owed else { return .nothing }
        return request(at: now, force: owedForce)
    }
}
