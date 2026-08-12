import Foundation
import Testing
@testable import UsageCore

@Suite("HeatmapLayout")
struct HeatmapLayoutTests {
    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utcCalendar().date(from: DateComponents(year: year, month: month, day: day))!
    }

    static let now = day(2026, 8, 9)

    static func build(_ activity: [DailyActivity], dayCount: Int?) -> HeatmapLayout {
        HeatmapLayout.build(
            activity: activity, dayCount: dayCount, calendar: utcCalendar(), now: now,
            locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Every real day in the grid, ignoring the nils that pad partial weeks.
    static func days(_ layout: HeatmapLayout) -> [Date] {
        layout.weeks.flatMap { $0 }.compactMap { $0 }
    }

    static let sample = [
        DailyActivity(day: day(2026, 7, 1), tokens: 500, messages: 5),
        DailyActivity(day: day(2026, 8, 5), tokens: 100, messages: 2),
        DailyActivity(day: day(2026, 8, 6), tokens: 0, messages: 0, prompts: 7),
    ]

    @Test("fixed window covers exactly its trailing days, whole weeks")
    func fixedWindow() {
        let layout = Self.build(Self.sample, dayCount: 7)
        let days = Self.days(layout)

        #expect(days.count == 7)
        #expect(days.first == Self.day(2026, 8, 3))
        #expect(days.last == Self.now)
        #expect(layout.weeks.allSatisfy { $0.count == 7 })
    }

    @Test("totals count only in-window days; prompt-only days are active but add no tokens")
    func totals() {
        let layout = Self.build(Self.sample, dayCount: 7)

        // July 1 is outside the window; Aug 6 is prompt-only.
        #expect(layout.totalTokens == 100)
        #expect(layout.maxTokens == 100)
        #expect(layout.activeDays == 2)
        #expect(layout.byDay[Self.day(2026, 8, 6)]?.prompts == 7)
        #expect(layout.byDay[Self.day(2026, 7, 1)] == nil)
        #expect(!layout.isEmpty)
    }

    @Test("all period spans from the earliest active day, whatever the input order")
    func allPeriod() {
        let layout = Self.build(Self.sample.reversed(), dayCount: nil)
        let days = Self.days(layout)

        #expect(days.first == Self.day(2026, 7, 1))
        #expect(days.last == Self.now)
        #expect(days.count == 40) // Jul 1–31 + Aug 1–9
        #expect(layout.totalTokens == 600)
        #expect(layout.activeDays == 3)
    }

    @Test("a wild timestamp cannot blow the grid past the span cap")
    func spanCap() {
        let layout = Self.build(
            [DailyActivity(day: Date(timeIntervalSince1970: 0), tokens: 10, messages: 1)],
            dayCount: nil)
        let days = Self.days(layout)

        #expect(days.count == HeatmapLayout.maximumSpanInDays)
        #expect(days.last == Self.now)
        // The 1970 day falls outside the capped range, so nothing is plotted.
        #expect(layout.isEmpty)
    }

    @Test("no activity yields an empty layout rather than a crash")
    func noActivity() {
        let layout = Self.build([], dayCount: nil)

        #expect(layout.isEmpty)
        #expect(layout.totalTokens == 0)
        #expect(layout.maxTokens == 1) // safe intensity denominator
        #expect(Self.days(layout) == [Self.now])
    }

    @Test("month marks label the window start and each month change")
    func monthMarks() {
        // Jul 11 – Aug 9 2026: partial first week, then August enters at the
        // first week that begins inside it (Aug 2; Aug 1 is a Saturday).
        let layout = Self.build(Self.sample, dayCount: 30)

        #expect(layout.monthMarks == [
            HeatmapLayout.MonthMark(index: 0, label: "Jul"),
            HeatmapLayout.MonthMark(index: 4, label: "Aug"),
        ])
        #expect(layout.weeks[4].compactMap { $0 }.first == Self.day(2026, 8, 2))
    }

    @Test("a single-month window carries exactly one mark")
    func singleMonthMark() {
        let layout = Self.build(Self.sample, dayCount: 7)

        #expect(layout.monthMarks == [HeatmapLayout.MonthMark(index: 0, label: "Aug")])
    }

    @Test("years join the labels when the span crosses a year boundary")
    func yearMarks() {
        let activity = [DailyActivity(day: Self.day(2025, 11, 15), tokens: 10, messages: 1)]
        let layout = Self.build(activity, dayCount: nil)
        let labels = layout.monthMarks.map(\.label)

        #expect(labels.first == "Nov ’25")
        #expect(labels.contains("Jan ’26"))
        #expect(labels.last == "Aug") // years only where they change
        #expect(labels.count == 10) // Nov 2025 through Aug 2026
    }
}
