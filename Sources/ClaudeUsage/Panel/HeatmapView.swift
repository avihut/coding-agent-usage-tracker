import SwiftUI
import UsageCore

/// GitHub-style activity heatmap fed by Claude Code's local transcripts and
/// prompt history.
struct HeatmapView: View {
    let activity: [DailyActivity]
    let pricing: PricingTable

    enum Period: String, CaseIterable, Identifiable {
        case week = "7D"
        case month = "30D"
        case all = "All"

        var id: String { rawValue }

        var dayCount: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .all: nil
            }
        }
    }

    @State private var period: Period = .month
    @State private var hoveredDay: Date?
    @State private var tipSize: CGSize = .zero
    /// Rebuilt only when the activity or the period changes — never per cell
    /// and never on hover. See `HeatmapLayout`.
    @State private var layout: HeatmapLayout = .empty

    private static let levelOpacities: [Double] = [0.3, 0.55, 0.78, 1.0]

    /// Anchor of the hovered cell, so the tooltip can follow it.
    private struct TipValue {
        let anchor: Anchor<CGRect>
        let day: Date
    }

    private struct TipKey: PreferenceKey {
        static var defaultValue: TipValue? { nil }
        static func reduce(value: inout TipValue?, nextValue: () -> TipValue?) {
            value = nextValue() ?? value
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity").font(.caption.bold())
                Spacer()
                Picker("Period", selection: periodBinding) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .frame(width: 150)
            }
            if layout.isEmpty {
                Text("No local Claude Code activity found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                chart
                HStack {
                    Text("\(TokenFormat.compact(layout.totalTokens)) tokens · \(layout.activeDays) active days")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    legend
                }
                modelSummary
            }
        }
        .onChange(of: activity, initial: true) { rebuildLayout(for: period) }
    }

    /// The period's usage per model, each row priced, with what the whole
    /// window would have cost at API list prices.
    @ViewBuilder private var modelSummary: some View {
        let rows = WindowTokens.rows(from: layout.modelTotals)
        if !rows.isEmpty {
            let priced = rows.map { row in (row: row, rates: pricing.rates(for: row.model)) }
            let total = priced.compactMap { $0.rates?.dollars(for: $0.row.tally) }.reduce(0, +)
            let unpricedCount = priced.count(where: { $0.rates == nil })
            VStack(alignment: .leading, spacing: 3) {
                // The headline number: what this period would have cost.
                VStack(spacing: 0) {
                    Text("≈ \(UsageFormatting.money(total))")
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(unpricedCount > 0
                        ? "at API list prices · \(unpricedCount) unpriced"
                        : "at API list prices")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 2)
                ForEach(priced, id: \.row.id) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.row.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(modelRowText(entry.row.tally, rates: entry.rates))
                            .font(.caption2.monospacedDigit())
                            .layoutPriority(1)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func modelRowText(_ tally: TokenTally, rates: ModelRates?) -> String {
        var text = UsageFormatting.tallyText(tally, cachedShare: false)
        if let rates {
            text += " · \(UsageFormatting.money(rates.dollars(for: tally)))"
        }
        return text
    }

    private func rebuildLayout(for period: Period) {
        layout = HeatmapLayout.build(activity: activity, dayCount: period.dayCount)
    }

    /// Switches period and grid in one update — staging them separately shows
    /// the old grid for a frame inside the newly-identified scroll view.
    private var periodBinding: Binding<Period> {
        Binding(
            get: { period },
            set: { newPeriod in
                period = newPeriod
                rebuildLayout(for: newPeriod)
            }
        )
    }

    // MARK: - Views

    /// Each period gets the rendering its span reads best in: day bars for a
    /// week, a full-width calendar for a month, the scrolling GitHub grid for
    /// everything. All three share the tooltip overlay and hover machinery.
    private var chart: some View {
        Group {
            switch period {
            case .week: barChart
            case .month: calendarGrid
            case .all: grid
            }
        }
        .overlayPreferenceValue(TipKey.self) { tip in
            GeometryReader { geo in
                if let tip {
                    // Clamp with the measured bubble size so it never slides
                    // under the popover's edges.
                    let rect = geo[tip.anchor]
                    let half = max(30, tipSize.width / 2) + 2
                    tooltip(for: tip.day)
                        .onGeometryChange(for: CGSize.self, of: \.size) { tipSize = $0 }
                        .position(
                            x: min(max(half, rect.midX), geo.size.width - half),
                            y: rect.minY - 16)
                }
            }
            .allowsHitTesting(false)
        }
        // Text views in the popover leak I-beam cursor rects over the chart;
        // keep the arrow cursor while the pointer is anywhere on it.
        .onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }

    private static let gridCellSize: CGFloat = 9
    private static let monthHeaderHeight: CGFloat = 10

    private var grid: some View {
        HStack(alignment: .top, spacing: 4) {
            weekdayGutter
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    monthHeader
                    HStack(alignment: .top, spacing: 2) {
                        ForEach(layout.weeks.indices, id: \.self) { column in
                            VStack(spacing: 2) {
                                ForEach(layout.weeks[column].indices, id: \.self) { row in
                                    cell(for: layout.weeks[column][row])
                                }
                            }
                        }
                    }
                }
            }
            // "All" reaches back months; open it showing the recent end.
            .defaultScrollAnchor(.trailing)
        }
    }

    /// Month labels across the top of the grid, each at the column where the
    /// month first appears; a label that would crowd its predecessor is
    /// dropped rather than overlapped.
    private var monthHeader: some View {
        let step = Self.gridCellSize + 2
        let minGap = Int((34 / step).rounded(.up))
        // Seed so the first mark always qualifies; Int.min here would
        // overflow the subtraction below.
        var lastShown = -minGap
        let visible = layout.monthMarks.filter { mark in
            guard mark.index - lastShown >= minGap else { return false }
            lastShown = mark.index
            return true
        }
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: max(1, CGFloat(layout.weeks.count) * step - 2),
                       height: Self.monthHeaderHeight)
            ForEach(visible, id: \.index) { mark in
                Text(mark.label)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: CGFloat(mark.index) * step)
            }
        }
    }

    /// Sun-first to match the grid rows (weeks pad by absolute weekday);
    /// alternate rows only, GitHub-style.
    private var weekdayGutter: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return VStack(spacing: 2) {
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? symbols[row] : "")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10, height: Self.gridCellSize)
            }
        }
        .padding(.top, Self.monthHeaderHeight + 2)
    }

    // MARK: - 30D calendar grid

    private static let calendarRowHeight: CGFloat = 16
    private static let monthGutterWidth: CGFloat = 34

    /// Weeks as full-width rows: seven weekday columns stretch across the
    /// panel, and months are named in a side gutter where they begin.
    private var calendarGrid: some View {
        let labels = Dictionary(
            layout.monthMarks.map { ($0.index, $0.label) },
            uniquingKeysWith: { first, _ in first })
        return VStack(spacing: 2) {
            HStack(spacing: 2) {
                Color.clear.frame(width: Self.monthGutterWidth, height: 12)
                ForEach(0..<7, id: \.self) { column in
                    Text(Calendar.current.veryShortWeekdaySymbols[column])
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(layout.weeks.indices, id: \.self) { row in
                HStack(spacing: 2) {
                    monthGutterLabel(labels[row])
                    ForEach(layout.weeks[row].indices, id: \.self) { column in
                        calendarCell(for: layout.weeks[row][column])
                    }
                }
            }
        }
    }

    private func monthGutterLabel(_ label: String?) -> some View {
        HStack(spacing: 3) {
            Spacer(minLength: 0)
            if let label {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 4, height: 1)
            }
        }
        .frame(width: Self.monthGutterWidth, height: Self.calendarRowHeight)
    }

    @ViewBuilder
    private func calendarCell(for day: Date?) -> some View {
        if let day {
            heatCell(for: day)
                .frame(maxWidth: .infinity)
                .frame(height: Self.calendarRowHeight)
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.calendarRowHeight)
        }
    }

    // MARK: - 7D bar chart

    private static let barPlotHeight: CGFloat = 64

    private var barChart: some View {
        let days = layout.weeks.flatMap { $0 }.compactMap { $0 }
        return VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days, id: \.self) { day in
                    bar(for: day)
                }
            }
            .frame(height: Self.barPlotHeight)
            Rectangle().fill(.quaternary).frame(height: 1)
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 0) {
                        Text(Self.weekdayFormatter.string(from: day))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(Self.dayOfMonthFormatter.string(from: day))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func bar(for day: Date) -> some View {
        let entry = layout.byDay[day]
        return ZStack(alignment: .bottom) {
            Color.clear
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: entry))
                .frame(height: barHeight(for: entry))
                .overlay {
                    if hoveredDay == day {
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(.primary.opacity(0.9), lineWidth: 1)
                    }
                }
                .anchorPreference(key: TipKey.self, value: .bounds) { anchor in
                    hoveredDay == day ? TipValue(anchor: anchor, day: day) : nil
                }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredDay = day
            } else if hoveredDay == day {
                hoveredDay = nil
            }
        }
    }

    /// Height carries the magnitude; color keeps the heatmap's intensity ramp.
    /// Stubs keep empty and prompt-only days (magnitude unknown) visible.
    private func barHeight(for entry: DailyActivity?) -> CGFloat {
        guard let entry, entry.tokens > 0 || entry.prompts > 0 else { return 2 }
        guard entry.tokens > 0 else { return 5 }
        let fraction = Double(entry.tokens) / Double(layout.maxTokens)
        return max(4, Self.barPlotHeight * fraction)
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let dayOfMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    @ViewBuilder
    private func cell(for day: Date?) -> some View {
        if let day {
            heatCell(for: day)
                .frame(width: Self.gridCellSize, height: Self.gridCellSize)
        } else {
            Color.clear.frame(width: Self.gridCellSize, height: Self.gridCellSize)
        }
    }

    /// One heat square/stripe — fill, hover ring, tooltip anchor. Callers
    /// give it its frame.
    private func heatCell(for day: Date) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color(for: layout.byDay[day]))
            .overlay {
                if hoveredDay == day {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(.primary.opacity(0.9), lineWidth: 1)
                }
            }
            .onHover { inside in
                if inside {
                    hoveredDay = day
                } else if hoveredDay == day {
                    hoveredDay = nil
                }
            }
            .anchorPreference(key: TipKey.self, value: .bounds) { anchor in
                hoveredDay == day ? TipValue(anchor: anchor, day: day) : nil
            }
    }

    /// Instant tooltip bubble — native `.help()` tags are too slow and
    /// unreliable inside popovers.
    private func tooltip(for day: Date) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        let date = formatter.string(from: day)
        let entry = layout.byDay[day]
        let text = if let entry, entry.tokens > 0 {
            "\(date) · \(TokenFormat.compact(entry.tokens)) tokens · \(entry.messages) msgs"
        } else if let entry, entry.prompts > 0 {
            "\(date) · \(entry.prompts) prompts · no token data"
        } else {
            "\(date) · no activity"
        }
        return Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .fixedSize()
    }

    private static let claudeOrange = Color(nsColor: StatusItemRenderer.claudeOrange)
    private static let emptyColor = Color.gray.opacity(0.18)
    /// Days known only from prompt history — Claude Code already deleted the
    /// transcripts, so activity is certain but its magnitude isn't.
    private static let promptOnlyColor = claudeOrange.opacity(0.15)

    private func color(for entry: DailyActivity?) -> Color {
        guard let entry, entry.tokens > 0 || entry.prompts > 0 else { return Self.emptyColor }
        guard entry.tokens > 0 else { return Self.promptOnlyColor }
        let fraction = Double(entry.tokens) / Double(layout.maxTokens)
        let level = min(4, max(1, Int((fraction * 4).rounded(.up))))
        return Self.claudeOrange.opacity(Self.levelOpacities[level - 1])
    }

    private var legend: some View {
        HStack(spacing: 2) {
            Text("less").font(.caption2).foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level == 0
                        ? Self.emptyColor
                        : Self.claudeOrange.opacity(Self.levelOpacities[level - 1]))
                    .frame(width: 7, height: 7)
            }
            Text("more").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
