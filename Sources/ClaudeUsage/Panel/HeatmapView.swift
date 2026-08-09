import SwiftUI
import UsageCore

/// GitHub-style activity heatmap fed by Claude Code's local transcripts.
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
    }

    @State private var period: Period = .month
    @State private var hoveredDay: Date?
    @State private var tipSize: CGSize = .zero

    private static let levelOpacities: [Double] = [0.3, 0.55, 0.78, 1.0]
    private var calendar: Calendar { .current }

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
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .labelsHidden()
                .frame(width: 150)
            }
            if visible.isEmpty {
                Text("No local Claude Code activity found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                grid
                HStack {
                    Text("\(TokenFormat.compact(totalTokens)) tokens · \(visible.count) active days")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    legend
                }
            }
        }
    }

    // MARK: - Data

    private var today: Date { calendar.startOfDay(for: Date()) }

    private var rangeStart: Date {
        if let days = period.dayCount {
            return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        }
        return activity.first.map { calendar.startOfDay(for: $0.day) } ?? today
    }

    private var visible: [DailyActivity] {
        activity.filter { $0.day >= rangeStart && $0.day <= today && ($0.tokens > 0 || $0.prompts > 0) }
    }

    private var totalTokens: Int { visible.reduce(0) { $0 + $1.tokens } }
    private var maxTokens: Int { max(1, visible.map(\.tokens).max() ?? 1) }

    private var byDay: [Date: DailyActivity] {
        Dictionary(visible.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// GitHub layout: each column is one week, rows are weekdays.
    private var weeks: [[Date?]] {
        var cells = [Date?](repeating: nil, count: calendar.component(.weekday, from: rangeStart) - 1)
        var day = rangeStart
        while day <= today {
            cells.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    private var cellSize: CGFloat {
        switch period {
        case .week: 16
        case .month: 12
        case .all: 9
        }
    }

    // MARK: - Views

    private var grid: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 2) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 2) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            cell(for: day)
                        }
                    }
                }
            }
        }
        // "All" now reaches back months; open it showing the recent end.
        .defaultScrollAnchor(period == .all ? .trailing : .topLeading)
        .id(period)
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
        // Text views in the popover leak I-beam cursor rects over the grid;
        // keep the arrow cursor while the pointer is anywhere on it.
        .onContinuousHover { phase in
            if case .active = phase { NSCursor.arrow.set() }
        }
    }

    @ViewBuilder
    private func cell(for day: Date?) -> some View {
        if let day {
            RoundedRectangle(cornerRadius: 2)
                .fill(color(for: byDay[day]))
                .frame(width: cellSize, height: cellSize)
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
            Color.clear.frame(width: cellSize, height: cellSize)
        }
    }

    /// Instant tooltip bubble — native `.help()` tags are too slow and
    /// unreliable inside popovers.
    private func tooltip(for day: Date) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        let date = formatter.string(from: day)
        let entry = byDay[day]
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
        let fraction = Double(entry.tokens) / Double(maxTokens)
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
