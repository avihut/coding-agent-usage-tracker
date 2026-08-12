import SwiftUI
import UsageCore

/// GitHub-style activity heatmap fed by Claude Code's local transcripts and
/// prompt history.
struct HeatmapView: View {
    let activity: [DailyActivity]

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

        var cellSize: CGFloat {
            switch self {
            case .week: 16
            case .month: 12
            case .all: 9
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
            }
        }
        .onChange(of: activity, initial: true) { rebuildLayout(for: period) }
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

    /// 7D reads better as day bars with labels; the longer periods keep the
    /// GitHub grid. Both share the tooltip overlay and hover machinery.
    private var chart: some View {
        Group {
            if period == .week {
                barChart
            } else {
                grid
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

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
        // "All" reaches back months; open it showing the recent end.
        .defaultScrollAnchor(period == .all ? .trailing : .topLeading)
        .id(period)
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
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: layout.byDay[day]))
                .frame(width: period.cellSize, height: period.cellSize)
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
        } else {
            Color.clear.frame(width: period.cellSize, height: period.cellSize)
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
