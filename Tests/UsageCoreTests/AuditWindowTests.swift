import Foundation
import Testing
@testable import UsageCore

@Suite("AuditWindow")
struct AuditWindowTests {
    private func date(_ iso: String) -> Date {
        FlexibleISO8601.date(from: iso)!
    }

    private var day: DateInterval {
        DateInterval(
            start: date("2026-08-10T00:00:00.000Z"),
            end: date("2026-08-11T00:00:00.000Z"))
    }

    private func session(
        id: String, stretches: [(String, String)]
    ) -> SessionSummary {
        let intervals = stretches.map {
            DateInterval(start: date($0.0), end: date($0.1))
        }
        return SessionSummary(
            id: id, title: id, projectPath: nil, gitBranch: nil, agentVersion: nil,
            kind: .interactive,
            start: intervals.first?.start ?? day.start,
            end: intervals.last?.end ?? day.end,
            activeSeconds: intervals.reduce(0) { $0 + $1.duration },
            prompts: 1, apiCalls: 1, toolCalls: 0, subagentCount: 0,
            compactions: 0, models: [:], stretches: intervals)
    }

    @Test("percent line scopes to the label, enters at height, cliffs on rolls")
    func percentAssembly() {
        let label = "Session (5h)"
        let samples = [
            // Before the day: becomes the entry point, keeps its height.
            UsageSample(
                t: date("2026-08-09T23:30:00.000Z"), percents: [label: 41],
                resets: [label: date("2026-08-10T02:00:00.000Z")]),
            UsageSample(
                t: date("2026-08-10T01:00:00.000Z"), percents: [label: 70],
                resets: [label: date("2026-08-10T02:00:00.000Z")]),
            // Stamp moved → the window rolled between the neighbors.
            UsageSample(
                t: date("2026-08-10T03:00:00.000Z"), percents: [label: 10],
                resets: [label: date("2026-08-10T07:00:00.000Z")]),
            // A different meter's percents must not leak in.
            UsageSample(
                t: date("2026-08-10T04:00:00.000Z"), percents: ["Weekly (all)": 90]),
        ]
        let model = AuditWindow.build(
            domain: day, meterLabel: label, window: 5 * 3600,
            samples: samples, sessions: [], outcomes: [],
            now: date("2026-08-16T00:00:00.000Z"))
        // 3 label samples + the cliff's hold/fall pair.
        #expect(model.percent.count == 5)
        #expect(model.percent.first?.percent == 41)
        #expect(model.resets.count == 1)
        // The cliff lands at the old window's stamped end.
        #expect(model.resets.first == date("2026-08-10T02:00:00.000Z"))
        // Peak counts only in-domain points: 70, the cliff hold, 10 — not
        // yesterday's 41 entry point.
        #expect(model.peakPercent == 70)
    }

    @Test("a fall to zero under one window end is a mid-window reset, not a boundary")
    func midWindowReset() {
        let label = "week"
        let end = date("2026-08-14T00:00:00.000Z")
        let samples = [
            UsageSample(
                t: date("2026-08-10T06:00:00.000Z"), percents: [label: 30],
                resets: [label: end]),
            // The stampless zeroed poll history.json actually holds.
            UsageSample(t: date("2026-08-10T10:00:00.000Z"), percents: [label: 0], resets: nil),
            UsageSample(
                t: date("2026-08-10T12:00:00.000Z"), percents: [label: 2],
                resets: [label: end]),
        ]
        let model = AuditWindow.build(
            domain: day, meterLabel: label, window: 7 * 86400,
            samples: samples, sessions: [], outcomes: [],
            now: date("2026-08-12T00:00:00.000Z"))

        #expect(model.resets.isEmpty)
        #expect(model.midWindowResets.count == 1)
        #expect(model.midWindowResets.first?.kind == .midWindow)
        #expect(model.midWindowResets.first?.from == 30)
        #expect(model.midWindowResets.first?.at == date("2026-08-10T08:00:00.000Z"))
        // The drawn line still falls off a cliff there.
        #expect(model.percent.contains { $0.t == date("2026-08-10T08:00:00.000Z") && $0.percent == 30 })
    }

    @Test("nubs clip to the span and merge concurrent sessions")
    func nubClipping() {
        let sessions = [
            // Runs across the day's start; clipped to it.
            session(id: "early", stretches: [
                ("2026-08-09T23:00:00.000Z", "2026-08-10T01:00:00.000Z"),
            ]),
            // Overlapping pair mid-day merges into one nub.
            session(id: "a", stretches: [
                ("2026-08-10T10:00:00.000Z", "2026-08-10T11:00:00.000Z"),
            ]),
            session(id: "b", stretches: [
                ("2026-08-10T10:30:00.000Z", "2026-08-10T12:00:00.000Z"),
            ]),
            // Entirely outside the day: contributes nothing.
            session(id: "later", stretches: [
                ("2026-08-12T09:00:00.000Z", "2026-08-12T10:00:00.000Z"),
            ]),
        ]
        let model = AuditWindow.build(
            domain: day, meterLabel: "Session (5h)", window: 5 * 3600,
            samples: [], sessions: sessions, outcomes: [],
            now: date("2026-08-16T00:00:00.000Z"))
        #expect(model.nubs == [
            DateInterval(
                start: date("2026-08-10T00:00:00.000Z"),
                end: date("2026-08-10T01:00:00.000Z")),
            DateInterval(
                start: date("2026-08-10T10:00:00.000Z"),
                end: date("2026-08-10T12:00:00.000Z")),
        ])
    }

    @Test("outcomes filter by label and in-span end, oldest first")
    func outcomeScope() {
        let label = "Weekly (all)"
        let inSpan = WindowOutcome(
            meterID: "1-weekly_all", label: label,
            end: date("2026-08-10T14:00:00.000Z"), start: nil,
            lastPercent: 87, peakPercent: 91,
            recordedAt: date("2026-08-10T14:05:00.000Z"))
        let otherMeter = WindowOutcome(
            meterID: "0-session", label: "Session (5h)",
            end: date("2026-08-10T15:00:00.000Z"), start: nil,
            lastPercent: 50, peakPercent: 50,
            recordedAt: date("2026-08-10T15:05:00.000Z"))
        let outside = WindowOutcome(
            meterID: "1-weekly_all", label: label,
            end: date("2026-08-12T14:00:00.000Z"), start: nil,
            lastPercent: 10, peakPercent: 10,
            recordedAt: date("2026-08-12T14:05:00.000Z"))
        let model = AuditWindow.build(
            domain: day, meterLabel: label, window: 7 * 86400,
            samples: [], sessions: [], outcomes: [outside, inSpan, otherMeter],
            now: date("2026-08-16T00:00:00.000Z"))
        #expect(model.outcomes == [inSpan])
        #expect(model.isEmpty == false)
    }

    @Test("an unrecorded span is empty across the board")
    func emptySpan() {
        let model = AuditWindow.build(
            domain: day, meterLabel: "Session (5h)", window: 5 * 3600,
            samples: [], sessions: [], outcomes: [],
            now: date("2026-08-16T00:00:00.000Z"))
        #expect(model.isEmpty)
        #expect(model.peakPercent == nil)
    }
}
