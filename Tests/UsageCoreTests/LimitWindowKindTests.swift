import Foundation
import Testing

@testable import UsageCore

/// A limit's kind comes from its window (0.101.0): the rule that keeps a
/// week from being called a session because of the slot it arrived in.
@Suite("Limit window kind") struct LimitWindowKindTests {
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86400

    @Test("the windows vendors use land where a person would put them")
    func kinds() {
        #expect(LimitWindowKind(window: 5 * hour) == .session)
        #expect(LimitWindowKind(window: 6 * hour) == .session)
        #expect(LimitWindowKind(window: 24 * hour) == .daily)
        #expect(LimitWindowKind(window: 7 * day) == .weekly)
        #expect(LimitWindowKind(window: 8 * day) == .weekly)
        #expect(LimitWindowKind(window: 30 * day) == .monthly)
        // Only the short rolling window is rank 0; nothing bare is scoped.
        #expect(LimitWindowKind.allCases.map(\.rank) == [0, 1, 1, 1])
        #expect(LimitWindowKind.allCases.map(\.tag) == ["S", "D", "W", "M"])
    }

    @Test("a window reads in the largest unit that fits — a week is never 168h")
    func names() {
        #expect(UsageFormatting.windowName(45 * 60) == "45m")
        #expect(UsageFormatting.windowName(5 * hour) == "5h")
        #expect(UsageFormatting.windowName(90 * 60) == "1h 30m")
        #expect(UsageFormatting.windowName(24 * hour) == "24h")
        #expect(UsageFormatting.windowName(168 * hour) == "7d")
        #expect(UsageFormatting.windowName(60 * hour) == "2d 12h")
        #expect(UsageFormatting.windowName(30 * day) == "30d")
    }

    @Test("round windows take their everyday name, odd ones say their length")
    func labels() {
        #expect(LimitWindowKind.session.label(window: 5 * hour) == "Session (5h)")
        #expect(LimitWindowKind.daily.label(window: day) == "Daily")
        #expect(LimitWindowKind.weekly.label(window: 7 * day) == "Weekly")
        #expect(LimitWindowKind.monthly.label(window: 30 * day) == "Monthly")
        #expect(LimitWindowKind(window: 10 * day).label(window: 10 * day) == "Window (10d)")
    }

    private func meter(rank: Int, window: TimeInterval?, scoped: String? = nil) -> Meter {
        Meter(
            id: "m\(rank)", label: scoped.map { "Weekly · \($0)" } ?? "Limit \(rank)", percent: 10,
            resetsAt: nil, level: .normal, rank: rank, limitWindow: window,
            forcesWarning: false, scopedModelName: scoped)
    }

    @Test("the bar letter follows the window; scoped meters keep their model's initial")
    func tags() {
        #expect(UsageFormatting.tag(for: meter(rank: 0, window: 5 * hour)) == "S")
        #expect(UsageFormatting.tag(for: meter(rank: 1, window: 7 * day)) == "W")
        // A day-long limit at rank 0 (the locally counted daily meter).
        #expect(UsageFormatting.tag(for: meter(rank: 0, window: day)) == "D")
        // Unknown window: the rank's historical letter.
        #expect(UsageFormatting.tag(for: meter(rank: 0, window: nil)) == "S")
        #expect(UsageFormatting.tag(for: meter(rank: 1, window: nil)) == "W")
        #expect(UsageFormatting.tag(for: meter(rank: 2, window: 7 * day, scoped: "Fable")) == "F")
    }

    @Test("a meter with no number yet keeps its dash; a meter that doesn't exist draws nothing")
    func segmentsFollowMeters() {
        let pending = Meter(
            id: "s", label: "Session (5h)", percent: nil, resetsAt: nil, level: .normal,
            rank: 0, limitWindow: 5 * hour, forcesWarning: false, scopedModelName: nil)
        let segments = UsageFormatting.menuBarSegments(from: [pending])
        #expect(segments.map(\.tag) == ["S"])
        #expect(segments.map(\.percent) == [nil])
        #expect(UsageFormatting.menuBarSegments(from: []).isEmpty)
    }
}
