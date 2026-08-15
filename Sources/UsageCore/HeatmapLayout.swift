import Foundation

/// Pre-computed grid and totals for the activity heatmap.
///
/// Deriving these in SwiftUI computed properties re-ran the whole aggregation
/// once per cell per body pass — and because the range bounds were computed
/// properties referenced inside the filter closures, every element paid its
/// own calendar arithmetic. The view builds this once per activity/period
/// change instead, so hover redraws only read it.
public struct HeatmapLayout: Equatable, Sendable {
    /// A month boundary on the time axis: `index` is the week (column or row,
    /// depending on how the view lays weeks out) where that month first
    /// appears. The first week is always marked, so the axis states where the
    /// window begins; years join the label only when the span crosses one.
    public struct MonthMark: Equatable, Sendable {
        public let index: Int
        public let label: String

        public init(index: Int, label: String) {
            self.index = index
            self.label = label
        }
    }

    /// Columns of seven days, GitHub-style; `nil` pads partial weeks.
    public let weeks: [[Date?]]
    /// Activity keyed by local-midnight day, for O(1) cell lookup.
    public let byDay: [Date: DailyActivity]
    /// The busiest day's tokens — the denominator for cell intensity, never 0.
    public let maxTokens: Int
    public let totalTokens: Int
    public let activeDays: Int
    public let monthMarks: [MonthMark]
    /// The window's tokens attributed per raw model id, for the period's
    /// usage/cost summary.
    public let modelTotals: [String: TokenTally]
    /// Each model's busiest single day in the window — the intensity
    /// denominator when the heatmap is filtered to one model, so a light
    /// model still shows its own usage pattern at full contrast.
    public let modelMaxTokens: [String: Int]
    /// Whether any active day exists before this window — what enables the
    /// back-paging arrow on the fixed-window periods.
    public let hasOlder: Bool

    /// Longest span the "All" period renders. Not a retention policy: it
    /// stops one wild timestamp from expanding the grid to tens of thousands
    /// of cells.
    public static let maximumSpanInDays = 5 * 366

    public static let empty = HeatmapLayout(
        weeks: [], byDay: [:], maxTokens: 1, totalTokens: 0, activeDays: 0, monthMarks: [],
        modelTotals: [:], modelMaxTokens: [:], hasOlder: false)

    public init(
        weeks: [[Date?]], byDay: [Date: DailyActivity],
        maxTokens: Int, totalTokens: Int, activeDays: Int, monthMarks: [MonthMark],
        modelTotals: [String: TokenTally], modelMaxTokens: [String: Int],
        hasOlder: Bool
    ) {
        self.weeks = weeks
        self.byDay = byDay
        self.maxTokens = maxTokens
        self.totalTokens = totalTokens
        self.activeDays = activeDays
        self.monthMarks = monthMarks
        self.modelTotals = modelTotals
        self.modelMaxTokens = modelMaxTokens
        self.hasOlder = hasOlder
    }

    public var isEmpty: Bool { activeDays == 0 }

    /// - Parameters:
    ///   - dayCount: trailing window in days; `nil` covers all activity.
    ///   - pagesBack: whole windows to step into the past — page 1 of a 7-day
    ///     window ends the day before page 0 begins. Ignored for `nil`
    ///     dayCount (the All period already shows everything).
    public static func build(
        activity: [DailyActivity],
        dayCount: Int?,
        pagesBack: Int = 0,
        calendar: Calendar = .current,
        now: Date = Date(),
        locale: Locale = .current
    ) -> HeatmapLayout {
        let today = calendar.startOfDay(for: now)
        let active = activity.filter { $0.tokens > 0 || $0.prompts > 0 }
        let floorDay = calendar.date(
            byAdding: .day, value: -(maximumSpanInDays - 1), to: today) ?? today
        let rangeEnd = calendar.date(
            byAdding: .day, value: -pagesBack * (dayCount ?? 0), to: today) ?? today

        let requestedStart: Date
        if let dayCount {
            requestedStart = calendar.date(byAdding: .day, value: -(dayCount - 1), to: rangeEnd) ?? rangeEnd
        } else {
            requestedStart = active.map { calendar.startOfDay(for: $0.day) }.min() ?? rangeEnd
        }
        let rangeStart = min(max(requestedStart, floorDay), rangeEnd)

        let visible = active.filter { $0.day >= rangeStart && $0.day <= rangeEnd }
        let byDay = Dictionary(visible.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })

        // GitHub layout: each column is one week, rows are weekdays.
        var cells = [Date?](repeating: nil, count: calendar.component(.weekday, from: rangeStart) - 1)
        var day = rangeStart
        while day <= rangeEnd {
            cells.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        }
        while cells.count % 7 != 0 { cells.append(nil) }

        let weeks = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }

        var modelTotals: [String: TokenTally] = [:]
        var modelMaxTokens: [String: Int] = [:]
        for entry in visible {
            for (model, tally) in entry.models {
                var merged = modelTotals[model] ?? TokenTally()
                merged.add(tally)
                modelTotals[model] = merged
                modelMaxTokens[model] = max(modelMaxTokens[model] ?? 0, tally.total)
            }
        }

        return HeatmapLayout(
            weeks: weeks,
            byDay: byDay,
            maxTokens: max(1, visible.map(\.tokens).max() ?? 1),
            totalTokens: visible.reduce(0) { $0 + $1.tokens },
            activeDays: byDay.count,
            monthMarks: monthMarks(
                weeks: weeks, rangeStart: rangeStart, rangeEnd: rangeEnd,
                calendar: calendar, locale: locale),
            modelTotals: modelTotals, modelMaxTokens: modelMaxTokens,
            hasOlder: active.contains { $0.day < rangeStart && $0.day >= floorDay })
    }

    private static func monthMarks(
        weeks: [[Date?]], rangeStart: Date, rangeEnd: Date,
        calendar: Calendar, locale: Locale
    ) -> [MonthMark] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM"

        let spansYears = calendar.component(.year, from: rangeStart)
            != calendar.component(.year, from: rangeEnd)
        var marks: [MonthMark] = []
        var previousMonth = -1
        for (index, week) in weeks.enumerated() {
            guard let first = week.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: first)
            if month == previousMonth { continue }
            previousMonth = month
            var label = formatter.string(from: first)
            if spansYears, marks.isEmpty || month == 1 {
                label += " ’\(String(format: "%02d", calendar.component(.year, from: first) % 100))"
            }
            marks.append(MonthMark(index: index, label: label))
        }
        return marks
    }
}
