import Foundation

/// One historical span rendered the way the meter popover renders its live
/// window: the percent line with reset cliffs, session nubs along the floor,
/// and the closed-window outcomes that say what the span actually reached.
/// Data degrades honestly with age — percent needs retained samples (~56
/// days), nubs need the sessions' transcripts to still exist, outcomes are
/// kept forever from the day the ledger started recording.
public struct AuditWindowModel: Sendable, Equatable {
    public struct PercentPoint: Sendable, Equatable, Identifiable {
        public let id: Double
        public let t: Date
        public let percent: Int

        public init(id: Double, t: Date, percent: Int) {
            self.id = id
            self.t = t
            self.percent = percent
        }
    }

    /// The drawn line: in-domain samples, the last sample before the span
    /// (so the line enters at its true height), and hold-then-fall pairs at
    /// every reset cliff.
    public let percent: [PercentPoint]
    /// Cliff instants inside the span — the vertical reset markers.
    public let resets: [Date]
    /// Session activity clipped to the span and merged across sessions.
    public let nubs: [DateInterval]
    /// Closed windows of this meter that ENDED inside the span, oldest
    /// first — the audit verdicts.
    public let outcomes: [WindowOutcome]
    /// Highest in-span drawn percent; nil when no samples cover the span.
    public let peakPercent: Int?

    /// Spans this meter spent already exhausted, waiting out a reset it
    /// had no way to hurry — recalled, never projected. See
    /// `ExhaustedStretches`.
    public let exhausted: [DateInterval]

    public init(
        percent: [PercentPoint], resets: [Date], nubs: [DateInterval],
        outcomes: [WindowOutcome], peakPercent: Int?,
        exhausted: [DateInterval] = []
    ) {
        self.percent = percent
        self.resets = resets
        self.nubs = nubs
        self.outcomes = outcomes
        self.peakPercent = peakPercent
        self.exhausted = exhausted
    }

    public var isEmpty: Bool {
        percent.isEmpty && nubs.isEmpty && outcomes.isEmpty
    }
}

public enum AuditWindow {
    /// Assembles the audit model for `domain`. `meterLabel` is the sample
    /// vocabulary (percents key by label); `window` is that meter's limit
    /// length, used only to place legacy cliffs. The percent assembly is the
    /// meter popover's, with no live reset to anchor a schedule grid —
    /// historical samples carry their own stamps.
    public static func build(
        domain: DateInterval,
        meterLabel: String,
        window: TimeInterval,
        samples: [UsageSample],
        sessions: [SessionSummary],
        outcomes: [WindowOutcome],
        now: Date = Date()
    ) -> AuditWindowModel {
        let measuredEnd = min(domain.end, now)
        var series: [ResetCliffs.Sample] = []
        var lastBefore: ResetCliffs.Sample?
        for sample in samples where sample.t <= measuredEnd {
            guard let percent = sample.percents[meterLabel] else { continue }
            let point = ResetCliffs.Sample(
                t: sample.t, percent: percent, resetsAt: sample.resets?[meterLabel])
            if sample.t < domain.start { lastBefore = point } else { series.append(point) }
        }
        if let lastBefore { series.insert(lastBefore, at: 0) }
        let cliffs = ResetCliffs.cliffs(between: series, window: window, currentReset: nil)
        var drawn = series.map {
            AuditWindowModel.PercentPoint(id: $0.t.timeIntervalSince1970, t: $0.t, percent: $0.percent)
        }
        for cliff in cliffs {
            drawn.append(AuditWindowModel.PercentPoint(
                id: cliff.at.timeIntervalSince1970 + 0.25, t: cliff.at, percent: cliff.from))
            drawn.append(AuditWindowModel.PercentPoint(
                id: cliff.at.timeIntervalSince1970 + 0.75,
                t: cliff.at.addingTimeInterval(1), percent: 0))
        }
        drawn.sort { $0.t < $1.t }

        var clipped: [DateInterval] = []
        for session in sessions where session.end >= domain.start && session.start < domain.end {
            for stretch in session.stretches {
                let start = max(stretch.start, domain.start)
                let end = min(stretch.end, domain.end)
                if start < end { clipped.append(DateInterval(start: start, end: end)) }
            }
        }

        let closed = outcomes
            .filter { $0.label == meterLabel && $0.end > domain.start && $0.end <= domain.end }
            .sorted { $0.end < $1.end }

        let resets = cliffs.map(\.at).filter { $0 >= domain.start }
        return AuditWindowModel(
            percent: drawn,
            resets: resets,
            nubs: merged(clipped),
            outcomes: closed,
            peakPercent: drawn.filter { $0.t >= domain.start }.map(\.percent).max(),
            exhausted: ExhaustedStretches.build(
                resets: resets, window: window, meterLabel: meterLabel,
                samples: samples, domain: domain))
    }

    /// Sweep-union of possibly-overlapping intervals (concurrent sessions
    /// share strip space) into chronological disjoint nubs.
    private static func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        var runStart = sorted[0].start
        var runEnd = sorted[0].end
        for interval in sorted.dropFirst() {
            if interval.start <= runEnd {
                if interval.end > runEnd { runEnd = interval.end }
            } else {
                merged.append(DateInterval(start: runStart, end: runEnd))
                runStart = interval.start
                runEnd = interval.end
            }
        }
        merged.append(DateInterval(start: runStart, end: runEnd))
        return merged
    }
}
