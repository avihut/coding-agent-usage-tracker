import Charts
import Combine
import SwiftUI
import UsageCore

/// GitHub-style activity heatmap fed by Claude Code's local transcripts and
/// prompt history. Clicking a day pushes into a per-day drill-down (model
/// ring + that day's breakdown); the model rows double as a hover legend
/// that filters the chart to one model.
/// Which meter an audit surface renders: the label keys the samples and
/// ledger; the window length places legacy cliffs.
struct AuditMeterInfo: Equatable {
    let label: String
    let window: TimeInterval
}

struct HeatmapView: View {
    let activity: [DailyActivity]
    let pricing: PricingTable
    /// The learned weekly rhythm behind the 7D chart's typical-week overlay;
    /// nil until the app has recorded any sample history at all.
    let weeklyProfile: WeeklyProfile?
    /// Names whose traces these are ("Claude Code") in the empty state.
    let agentName: String
    /// Where the user has navigated: nil on the current default window, the
    /// visible span while paged into the past, the single day while drilled
    /// in. The panel scopes its Sessions strip by it.
    @Binding var focus: DateInterval?
    /// Audit inputs: percent samples, sessions (their stretches draw the
    /// nubs), and the closed-window ledger. The meter infos say which label
    /// and window length each audit surface reads; a nil info hides that
    /// surface's toggle.
    let samples: [UsageSample]
    /// Token moments behind the audit charts' per-model overlay curves.
    let timeline: [TokenSlot]
    let sessions: [SessionSummary]
    let windowOutcomes: [WindowOutcome]
    let sessionAuditMeter: AuditMeterInfo?
    let weeklyAuditMeter: AuditMeterInfo?

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

    /// What the charts measure: token volume or estimated cost. One selector
    /// picks the time span, this one picks the value dimension.
    enum Dimension: String, CaseIterable, Identifiable {
        case tokens = "Tokens"
        case cost = "Cost"

        var id: String { rawValue }
    }

    /// The chosen span, persisted — reopening the panel (or relaunching the
    /// app) lands on whatever span was last picked; fresh installs on 7D.
    @AppStorage("activityPeriod") private var period: Period = .week
    @State private var dimension: Dimension = .tokens
    /// Audit-view toggles, persisted: the day drill-down's ring↔timeline and
    /// the 7D chart's bars↔window presentations.
    @AppStorage("dayDetailStyle") private var dayStyleRaw = "totals"
    @AppStorage("weekChartStyle") private var weekStyleRaw = "bars"
    /// Whole windows stepped into the past on the fixed periods — 0 is the
    /// current trailing window. Always 0 for All, which shows everything.
    @State private var pageOffset = 0
    /// Bumped only by the pager arrows — the value that scopes the page-morph
    /// animation to the chart row. Live refreshes, period switches, and the
    /// close-reset leave it alone, so those rebuilds snap.
    @State private var pageTick = 0
    @State private var costIndex: CostIndex = .empty
    @State private var hoveredDay: Date?
    @State private var hoveredModel: String?
    @State private var selectedDay: Date?
    /// Mid-slide double buffer: the day just left behind, its prebuilt
    /// rows, and which way it exits.
    @State private var outgoingStep: (entry: DailyActivity, rows: [ModelTokenUsage], direction: Int)?
    /// The incoming day's render offset — parked at ±daySlideWidth on
    /// kickoff, animated to 0; the outgoing view derives its offset from
    /// the same value, so the pair always moves in lockstep.
    @State private var slideX: CGFloat = 0
    /// Model whose cost math is open from a ring-sector click; the grid's
    /// own row popover keeps its private state.
    @State private var ringCostModel: String?
    /// Invalidates a superseded slide's cleanup when the arrows are mashed.
    @State private var stepToken = 0
    /// The panel's content width — what a full slide traverses.
    private static let daySlideWidth: CGFloat = 332
    @State private var tipSize: CGSize = .zero
    /// Rebuilt only when the activity or the period changes — never per cell
    /// and never on hover. See `HeatmapLayout`.
    @State private var layout: HeatmapLayout = .empty

    private static let levelOpacities: [Double] = [0.3, 0.55, 0.78, 1.0]
    /// Push/pop feel for the day drill-down.
    private static let drillAnimation = Animation.snappy(duration: 0.28)

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
        Group {
            // The bare fallback ONLY when there is nothing to navigate to:
            // page 0, no activity in the window, none older. A paged-to
            // empty window must keep periodContent — arrows included —
            // because swapping to this view stranded the user with no way
            // back (and collapsed the section's height mid-animation).
            if pageOffset == 0, layout.isEmpty, !layout.hasOlder {
                VStack(alignment: .leading, spacing: 8) {
                    titleRow
                    Text("No local \(agentName) activity found")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                // The slide animates via transition-attached animations, NOT
                // withAnimation on the state change: the panel host sizes the
                // popover from the preferred content size, and an animated
                // container height streams per-frame size updates into
                // NSPopover, each restarting its own implicit resize
                // animation — the window crawls behind the content and the
                // whole drill reads sluggish. With the height changing
                // discretely, AppKit animates the window resize once,
                // natively, while the contents slide.
                ZStack(alignment: .topLeading) {
                    if let entry = selectedEntry {
                        dayContent(entry)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity))
                                .animation(Self.drillAnimation))
                    } else {
                        periodContent
                            .transition(.asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity))
                                .animation(Self.drillAnimation))
                    }
                }
                .clipped()
            }
        }
        .onChange(of: activity, initial: true) { rebuildLayout(for: period) }
        .onChange(of: layout) {
            // A rebuild can drop the drilled day (aged out of the window);
            // pop back rather than point at nothing.
            if selectedDay != nil, selectedEntry == nil { selectedDay = nil }
            publishFocus()
        }
        .onChange(of: selectedDay) { publishFocus() }
        .onChange(of: pageOffset) { publishFocus() }
        // Closing the panel pops any drill-down (no animation — offscreen):
        // reopening should always land on the period totals. The panel's
        // hosting view is created once and never leaves the hierarchy on
        // close, so .onDisappear can't catch this — the status item
        // controller posts .panelDidClose on every close path instead.
        .onReceive(NotificationCenter.default.publisher(for: .panelDidClose)) { _ in
            selectedDay = nil
            hoveredModel = nil
            hoveredDay = nil
            outgoingStep = nil
            slideX = 0
            ringCostModel = nil
            // Reopening always lands on the current window, like the drill.
            if pageOffset != 0 {
                pageOffset = 0
                rebuildLayout(for: period)
            }
        }
    }

    /// The drilled day's entry — synthesized empty for a quiet day still
    /// inside the shown span, so stepping renders every calendar day
    /// honestly instead of skipping the silent ones. Nil only when the day
    /// left the span entirely (aged out), which pops the drill.
    private var selectedEntry: DailyActivity? {
        guard let day = selectedDay else { return nil }
        if let entry = layout.byDay[day] { return entry }
        guard spanContains(day) else { return nil }
        return DailyActivity(day: day, tokens: 0, messages: 0)
    }

    /// Whether the shown period's cell range covers `day` — the layout
    /// builds every date cell, so its first and last bound the span.
    private func spanContains(_ day: Date) -> Bool {
        let cells = layout.weeks.flatMap { $0 }.compactMap { $0 }
        guard let first = cells.first, let last = cells.last else { return false }
        return day >= first && day <= last
    }

    /// The period's models, heaviest first — the row order of the summary
    /// grid and the rank that assigns legend colors.
    private var summaryRows: [ModelTokenUsage] {
        WindowTokens.rows(from: layout.modelTotals)
    }

    private var modelColors: [String: Color] {
        ModelPalette.assignment(for: summaryRows.map(\.model))
    }

    // MARK: - Period mode

    /// One gap for every header control row, so the Activity header and the
    /// day drill's header breathe identically.
    private static let headerSpacing: CGFloat = 10

    /// Both pickers sit flush against the content's right edge — `fixedSize`
    /// instead of a fixed frame, which centered the control and left a
    /// phantom right inset. The gap is wider than the default so the audit
    /// toggle reads as its own control rather than a segment of the picker
    /// beside it; the Spacer holds ~85pt of slack, so the row still fits.
    private var titleRow: some View {
        HStack(spacing: Self.headerSpacing) {
            Text("Activity").font(.caption.bold())
            Spacer()
            if period == .week, weeklyAuditMeter != nil {
                auditToggle(
                    isOn: weekStyleRaw == "window",
                    help: weekStyleRaw == "window"
                        ? "Show daily bars"
                        : "Show this week as its limit-window timeline"
                ) {
                    weekStyleRaw = weekStyleRaw == "window" ? "bars" : "window"
                }
            }
            dimensionPicker
            SegmentedPicker(
                title: "Period", selection: periodBinding,
                options: Period.allCases.map { ($0.rawValue, $0) })
        }
    }

    /// One-icon toggle into the audit timeline — a third segmented control
    /// would not fit the 360pt header rows.
    private func auditToggle(
        isOn: Bool, help: String, flip: @escaping () -> Void
    ) -> some View {
        Button(action: flip) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? AnyShapeStyle(Self.accent) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(help)
    }

    /// Drill-down-style pager flanking the 7D/30D charts: ‹ steps a whole
    /// window into the past, › returns. Unlike the day drill's slide, the
    /// chart morphs IN PLACE — bars glide to the new window's heights and
    /// cells re-tint where they stand — so an unavailable direction keeps
    /// its reserved width at zero opacity rather than vanishing, and the
    /// chart never changes size between pages. All shows everything and
    /// renders no arrows at all.
    /// One pager step, shared by the arrows and the two-finger swipe:
    /// direction < 0 = an earlier window, > 0 = later. No-ops at the edges,
    /// so a swipe on the current window simply does nothing.
    private func pageStep(_ direction: Int) {
        guard period != .all else { return }
        guard direction < 0 ? layout.hasOlder : pageOffset > 0 else { return }
        pageTick += 1
        pageOffset += direction < 0 ? 1 : -1
        rebuildLayout(for: period)
    }

    @ViewBuilder
    private func periodStepArrow(direction: Int) -> some View {
        if period != .all {
            let available = direction < 0 ? layout.hasOlder : pageOffset > 0
            Button {
                pageStep(direction)
            } label: {
                Image(systemName: direction < 0
                    ? "chevron.left.circle.fill" : "chevron.right.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(width: 17)
            .opacity(available ? 1 : 0)
            .disabled(!available)
            .help(direction < 0 ? "Earlier \(period.rawValue)" : "Later \(period.rawValue)")
        }
    }

    /// Shared by the period header and the day drill-down, so the
    /// tokens-or-cost lens survives the drill.
    private var dimensionPicker: some View {
        SegmentedPicker(
            title: "Dimension", selection: animatedDimension,
            options: Dimension.allCases.map { ($0.rawValue, $0) })
    }

    /// Dimension flips animate, so the day ring's sectors sweep to their
    /// new angles (and bars/cells re-scale) instead of jumping.
    private var animatedDimension: Binding<Dimension> {
        Binding(
            get: { dimension },
            set: { newValue in
                withAnimation(Self.drillAnimation) { dimension = newValue }
            }
        )
    }

    private var periodContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            // Fixed height so hover swaps can never reflow the layout —
            // wrapping stats used to shift the legend rows mid-hover.
            HStack(spacing: 5) {
                if let hoveredModel {
                    Circle()
                        .fill(modelColors[hoveredModel] ?? Self.accent)
                        .frame(width: 6, height: 6)
                }
                Text(footerStats)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                // The less→more ramp explains calendar-cell tinting; the 7D
                // bars say magnitude with height, so there it's just noise.
                if period != .week {
                    legend
                }
            }
            .frame(height: 14)
            HStack(spacing: 3) {
                periodStepArrow(direction: -1)
                chart
                periodStepArrow(direction: 1)
            }
            // The page morph is scoped HERE — value-keyed, not withAnimation
            // around the state change: the summary grid below has a
            // different row count per window and must step discretely, so
            // the popover resizes once, natively, instead of chasing an
            // animated height per frame (the drill-down lesson). Chart
            // heights themselves are page-invariant: the bars sit in a
            // fixed frame and the 30D calendar pads to six week rows.
            .animation(Self.drillAnimation, value: pageTick)
            // Two-finger swipes page like the arrows do (the value-keyed
            // animation above morphs either way). The All grid's own
            // horizontal scroller sits deeper and keeps its events;
            // pageStep guards All anyway.
            .background(HorizontalSwipeCatcher { direction in
                pageStep(direction)
            })
            if period == .week {
                weeklyTrendCaption
            }
            ModelBreakdownGrid(
                rows: summaryRows, colors: modelColors, pricing: pricing,
                hoveredModel: $hoveredModel)
        }
    }

    /// Centered over an empty window's chart. The chart itself still renders
    /// at full height — date labels, empty stubs/cells, working pager arrows —
    /// so paging onto a quiet week neither traps the user nor moves a single
    /// pixel of layout; this note just says why there's nothing to see.
    @ViewBuilder
    private var emptyWindowNote: some View {
        if layout.activeDays == 0 {
            Text("No activity in this window")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Right under the 7D bars: the typical-week overlay's legend once the
    /// profile is live, or how long until the personalized forecast exists.
    private var weeklyTrendCaption: some View {
        Group {
            if let weeklyProfile, weeklyProfile.isReady {
                Text("– – typical week · learned from your usage history")
            } else {
                let remaining = weeklyProfile?.remainingUntilReady
                    ?? WeeklyProfile.activationSpan
                // One sentence, one place: the digest publishes this same
                // string so the terminal pane counts down identically.
                Text(UsageFormatting.forecastActivation(remaining: remaining))
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "7.3B tokens · 24 active days" (or "≈ $6,860 · …" in cost mode) —
    /// scoped to the hovered model while the legend is filtering the chart.
    private var footerStats: String {
        if let hoveredModel, let tally = layout.modelTotals[hoveredModel] {
            let days = layout.byDay.values.count(
                where: { ($0.models[hoveredModel]?.total ?? 0) > 0 })
            let value = switch dimension {
            case .tokens:
                "\(TokenFormat.compact(tally.total)) tokens"
            case .cost:
                "≈ \(UsageFormatting.money(pricing.rates(for: hoveredModel)?.dollars(for: tally) ?? 0))"
            }
            return "\(ModelNames.display(hoveredModel)) · \(value) · \(days) active days"
        }
        let value = switch dimension {
        case .tokens: "\(TokenFormat.compact(layout.totalTokens)) tokens"
        case .cost: "≈ \(UsageFormatting.money(costIndex.total))"
        }
        let base = "\(value) · \(layout.activeDays) active days"
        // Paged into the past, the stats line owns saying WHICH window.
        return rangeText.map { "\($0) · \(base)" } ?? base
    }

    /// "Jul 27 – Aug 2" while paged off the current window; nil at page 0,
    /// where "the last 7/30 days" needs no spelling out.
    private var rangeText: String? {
        guard pageOffset > 0 else { return nil }
        let days = layout.weeks.flatMap { $0 }.compactMap { $0 }
        guard let first = days.first, let last = days.last else { return nil }
        return "\(Self.rangeFormatter.string(from: first)) – \(Self.rangeFormatter.string(from: last))"
    }

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// Reports the navigated span to the panel. Deliberately derived in one
    /// place from the three navigation states rather than set at each
    /// mutation site — the close-reset and layout rebuilds then can't drift.
    private func publishFocus() {
        let updated: DateInterval?
        if let day = selectedDay {
            let next = Calendar.current.date(byAdding: .day, value: 1, to: day)
                ?? day.addingTimeInterval(86400)
            updated = DateInterval(start: day, end: next)
        } else if pageOffset > 0 {
            let days = layout.weeks.flatMap { $0 }.compactMap { $0 }
            if let first = days.first, let last = days.last,
               let end = Calendar.current.date(byAdding: .day, value: 1, to: last) {
                updated = DateInterval(start: first, end: end)
            } else {
                updated = nil
            }
        } else {
            updated = nil
        }
        if focus != updated { focus = updated }
    }

    private func rebuildLayout(for period: Period) {
        layout = HeatmapLayout.build(
            activity: activity, dayCount: period.dayCount, pagesBack: pageOffset)
        costIndex = CostIndex.build(days: layout.byDay, pricing: pricing)
    }

    // MARK: - Dimension values

    private func dayValue(_ entry: DailyActivity) -> Double {
        switch dimension {
        case .tokens: Double(entry.tokens)
        case .cost: costIndex.byDay[entry.day] ?? 0
        }
    }

    private var maxDayValue: Double {
        switch dimension {
        case .tokens: Double(layout.maxTokens)
        case .cost: costIndex.maxByDay
        }
    }

    private func modelDayValue(_ entry: DailyActivity, model: String) -> Double {
        guard let tally = entry.models[model] else { return 0 }
        switch dimension {
        case .tokens: return Double(tally.total)
        case .cost: return pricing.rates(for: model)?.dollars(for: tally) ?? 0
        }
    }

    private func modelMaxValue(_ model: String) -> Double {
        switch dimension {
        case .tokens: Double(layout.modelMaxTokens[model] ?? 1)
        case .cost: costIndex.modelMax[model] ?? 1
        }
    }

    private func formatted(_ value: Double) -> String {
        switch dimension {
        case .tokens: TokenFormat.compact(Int(value))
        case .cost: UsageFormatting.money(value)
        }
    }

    /// Switches period and grid in one update — staging them separately shows
    /// the old grid for a frame inside the newly-identified scroll view.
    private var periodBinding: Binding<Period> {
        Binding(
            get: { period },
            set: { newPeriod in
                period = newPeriod
                pageOffset = 0 // pages don't translate between window sizes
                rebuildLayout(for: newPeriod)
            }
        )
    }

    // MARK: - Day drill-down

    /// Only days with recorded activity drill. Plain assignment — the
    /// slide animation rides on the transitions themselves so the
    /// container height (and with it the popover window) never animates
    /// per frame.
    private func drill(into day: Date) {
        guard spanContains(day) else { return }
        hoveredModel = nil
        hoveredDay = nil
        selectedDay = day
    }

    /// The adjacent CALENDAR day within the shown period — quiet days step
    /// through with an empty state rather than being skipped (they used to
    /// walk only byDay's keys, silently jumping the gaps). Nil at the span's
    /// edge, which hides that arrow.
    private func neighborDay(of day: Date, direction: Int) -> Date? {
        guard let target = Calendar.current.date(byAdding: .day, value: direction, to: day),
              spanContains(target)
        else { return nil }
        return target
    }

    /// Flanks the ring flush at the container edge, vertically centered on
    /// the ring zone (or the shorter no-data note). Kickoff and glide are
    /// separate transactions: the plain sets mount the incoming day
    /// offscreen and park the outgoing at rest, then withAnimation moves
    /// only `slideX` — pressing ‹ sends the current chart out to the
    /// right while the earlier day arrives from the left.
    @ViewBuilder
    private func dayStepArrow(
        for entry: DailyActivity, rows: [ModelTokenUsage], direction: Int
    ) -> some View {
        if neighborDay(of: entry.day, direction: direction) != nil {
            Button {
                stepDay(from: entry, rows: rows, direction: direction)
            } label: {
                Image(systemName: direction < 0
                    ? "chevron.left.circle.fill" : "chevron.right.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Always the ring zone's height: stepping across quiet days must
            // not contract the popover or move the arrow out from under the
            // cursor mid-click-streak.
            .frame(height: 132)
        }
    }

    /// One day step, shared by the arrows and the two-finger swipe. Kickoff
    /// and glide stay separate transactions (the double-buffered offset
    /// slide); no-ops at the span's edge.
    private func stepDay(from entry: DailyActivity, rows: [ModelTokenUsage], direction: Int) {
        guard let target = neighborDay(of: entry.day, direction: direction) else { return }
        outgoingStep = (entry, rows, direction)
        slideX = CGFloat(direction) * Self.daySlideWidth
        drill(into: target)
        stepToken += 1
        let token = stepToken
        withAnimation(Self.drillAnimation) {
            slideX = 0
        } completion: {
            if token == stepToken { outgoingStep = nil }
        }
    }

    private func dayContent(_ entry: DailyActivity) -> some View {
        let rows = WindowTokens.rows(from: entry.models)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Self.headerSpacing) {
                Button {
                    hoveredModel = nil
                    selectedDay = nil
                    outgoingStep = nil
                    slideX = 0
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                        Text(Self.dayTitleFormatter.string(from: entry.day))
                            .font(.caption.bold())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if sessionAuditMeter != nil {
                    auditToggle(
                        isOn: dayStyleRaw == "timeline",
                        help: dayStyleRaw == "timeline"
                            ? "Show the day's totals ring"
                            : "Show the day as a 24h limit-window timeline"
                    ) {
                        dayStyleRaw = dayStyleRaw == "timeline" ? "totals" : "timeline"
                    }
                }
                dimensionPicker
            }
            // The day's detail slides sideways between days while the
            // header and arrows hold still. A double-buffered OFFSET
            // slide, not a transition: id-swap transitions animated only
            // their opacity here (geometry needs an animated transaction),
            // and offsets are render transforms — withAnimation can drive
            // them without ever animating the popover's height, which
            // still steps discretely. The arrows ride overlays flush at
            // the container edges, centered on the ring.
            ZStack(alignment: .topLeading) {
                if let outgoing = outgoingStep {
                    // The outgoing frame is scenery — its ring must not
                    // co-present the cost popover the live copy owns.
                    dayDetail(outgoing.entry, rows: outgoing.rows, live: false)
                        .offset(x: slideX - CGFloat(outgoing.direction) * Self.daySlideWidth)
                }
                dayDetail(entry, rows: rows)
                    .offset(x: slideX)
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                dayStepArrow(for: entry, rows: rows, direction: -1)
            }
            .overlay(alignment: .topTrailing) {
                dayStepArrow(for: entry, rows: rows, direction: 1)
            }
            // Two-finger swipes ride the same double-buffered slide as the
            // arrows.
            .background(HorizontalSwipeCatcher { direction in
                stepDay(from: entry, rows: rows, direction: direction)
            })
        }
    }

    /// Why a day's ring zone is empty, honestly tiered: swept transcripts
    /// (prompt-only), a genuinely silent day (steppable now, not skipped),
    /// or token data without model attribution.
    private static func emptyDayNote(_ entry: DailyActivity) -> String {
        if entry.prompts > 0 && entry.tokens == 0 {
            return "\(entry.prompts) prompts · no token data — the transcripts were already cleaned up"
        }
        if entry.tokens == 0 && entry.messages == 0 {
            return "No activity on this day"
        }
        return "No per-model data for this day"
    }

    private func dayDetail(
        _ entry: DailyActivity, rows: [ModelTokenUsage], live: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if dayStyleRaw == "timeline", let meter = sessionAuditMeter {
                dayAuditChart(entry, meter: meter)
                if !rows.isEmpty {
                    ModelBreakdownGrid(
                        rows: rows, colors: modelColors, pricing: pricing,
                        hoveredModel: $hoveredModel)
                }
            } else if rows.isEmpty {
                Text(Self.emptyDayNote(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    // Ring-zone height, like the arrows: an empty day holds
                    // the same silhouette as a full one.
                    .frame(maxWidth: .infinity, minHeight: 132)
            } else {
                dayRing(rows: rows, entry: entry, live: live)
                ModelBreakdownGrid(
                    rows: rows, colors: modelColors, pricing: pricing,
                    hoveredModel: $hoveredModel)
            }
        }
    }

    /// The drilled day as a 24h session-meter timeline: its 5h windows'
    /// percent sawtooth, reset cliffs, and session nubs — the day replayed
    /// in the limit-window vocabulary. Sized to the ring zone so the toggle
    /// and day-stepping never move the arrows.
    private func dayAuditChart(_ entry: DailyActivity, meter: AuditMeterInfo) -> some View {
        let start = entry.day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(86400)
        let span = DateInterval(start: start, end: end)
        return AuditWindowChart(
            model: AuditWindow.build(
                domain: span, meterLabel: meter.label, window: meter.window,
                samples: samples, sessions: sessions, outcomes: windowOutcomes),
            domain: span,
            window: meter.window,
            accent: Self.accent,
            timeline: timeline,
            modelColors: modelColors,
            plotHeight: 114)
    }

    /// Donut of the day's tokens per model in the legend's colors; the center
    /// restates the day's totals. Clicking a sector opens the same cost-math
    /// popover as clicking that model's grid row.
    private func dayRing(
        rows: [ModelTokenUsage], entry: DailyActivity, live: Bool
    ) -> some View {
        Chart(rows) { row in
            SectorMark(
                angle: .value(dimension == .cost ? "Cost" : "Tokens", ringValue(row)),
                innerRadius: .ratio(0.62),
                angularInset: 1.5)
                .foregroundStyle(modelColors[row.model] ?? Self.accent)
                .opacity(hoveredModel == nil || hoveredModel == row.model ? 1 : 0.25)
                .cornerRadius(2)
        }
        .chartLegend(.hidden)
        .frame(height: 132)
        .frame(maxWidth: .infinity)
        // Ring → legend: the sector under the cursor takes the shared
        // hoveredModel, so ring and legend rows light together — the same
        // two-way sync the meter chart has with its legend.
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            hoveredModel = ringHit(
                                at: location, in: geo[plotFrame], rows: rows)
                        case .ended:
                            hoveredModel = nil
                        }
                    }
                    .onTapGesture { location in
                        guard let plotFrame = proxy.plotFrame else { return }
                        ringCostModel = ringHit(
                            at: location, in: geo[plotFrame], rows: rows)
                    }
            }
        }
        .popover(
            isPresented: Binding(
                get: { live && rows.contains { $0.model == ringCostModel } },
                set: { if !$0 { ringCostModel = nil } }),
            arrowEdge: .bottom
        ) {
            if let row = rows.first(where: { $0.model == ringCostModel }) {
                CostMathView(row: row, rates: pricing.rates(for: row.model))
            }
        }
        .chartBackground { proxy in
            GeometryReader { geo in
                if let plotFrame = proxy.plotFrame {
                    let frame = geo[plotFrame]
                    VStack(spacing: 0) {
                        switch dimension {
                        case .tokens:
                            Text(TokenFormat.compact(entry.tokens))
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            Text("tokens")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        case .cost:
                            Text("≈ \(UsageFormatting.money(costIndex.byDay[entry.day] ?? 0))")
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            Text("est. cost")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text("\(entry.messages) msgs")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
    }

    /// The model whose sector the cursor is in: radius must land on the
    /// ring's band (with a little forgiveness either side), then the
    /// clockwise angle from 12 o'clock walks the rows' cumulative shares —
    /// the same order and values SectorMark laid them out with.
    private func ringHit(
        at point: CGPoint, in frame: CGRect, rows: [ModelTokenUsage]
    ) -> String? {
        let dx = point.x - frame.midX
        let dy = point.y - frame.midY
        let radius = (dx * dx + dy * dy).squareRoot()
        let outer = min(frame.width, frame.height) / 2
        guard radius >= outer * 0.55, radius <= outer * 1.05 else { return nil }
        let total = rows.reduce(0.0) { $0 + ringValue($1) }
        guard total > 0 else { return nil }
        var angle = atan2(Double(dx), Double(-dy))
        if angle < 0 { angle += 2 * .pi }
        var cumulative = 0.0
        for row in rows {
            cumulative += ringValue(row) / total * 2 * .pi
            if angle <= cumulative { return row.model }
        }
        return rows.last?.model
    }

    private func ringValue(_ row: ModelTokenUsage) -> Double {
        switch dimension {
        case .tokens: Double(row.tally.total)
        case .cost: pricing.rates(for: row.model)?.dollars(for: row.tally) ?? 0
        }
    }

    // MARK: - Chart shells

    /// Each period gets the rendering its span reads best in: day bars for a
    /// week, a full-width calendar for a month, the scrolling GitHub grid for
    /// everything. All three share the tooltip overlay and hover machinery.
    private var chart: some View {
        Group {
            switch period {
            case .week:
                if weekStyleRaw == "window", let meter = weeklyAuditMeter {
                    weekAuditChart(meter)
                } else {
                    barChart
                }
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
    /// A 30-day window spans 5 week rows or 6 depending on the weekday it
    /// starts on; the grid always reserves 6 so paging never changes the
    /// chart's height.
    private static let monthRowCount = 6

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
            ForEach(
                layout.weeks.count..<max(layout.weeks.count, Self.monthRowCount),
                id: \.self
            ) { _ in
                Color.clear.frame(height: Self.calendarRowHeight)
            }
        }
        .overlay { emptyWindowNote }
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

    private static let barPlotHeight: CGFloat = 76
    /// Space above the tallest bar for its value label.
    private static let barLabelHeadroom: CGFloat = 12

    /// The shown week as its weekly limit-window timeline — page-aware (the
    /// audited span is whatever seven days the pager shows), sized to sit
    /// where the bars sit so the toggle never moves the layout below.
    private func weekAuditChart(_ meter: AuditMeterInfo) -> some View {
        let cells = layout.weeks.flatMap { $0 }.compactMap { $0 }
        let start = cells.first ?? Self.today
        let end = Calendar.current.date(byAdding: .day, value: 1, to: cells.last ?? start)
            ?? start
        let span = DateInterval(start: start, end: end)
        return AuditWindowChart(
            model: AuditWindow.build(
                domain: span, meterLabel: meter.label, window: meter.window,
                samples: samples, sessions: sessions, outcomes: windowOutcomes),
            domain: span,
            window: meter.window,
            accent: Self.accent,
            timeline: timeline,
            modelColors: modelColors,
            plotHeight: 88)
    }

    private var barChart: some View {
        let days = layout.weeks.flatMap { $0 }.compactMap { $0 }
        return VStack(spacing: 3) {
            // Positional identity, not day identity: bar N is the same view
            // on every page, so stepping windows animates each bar to its
            // new height instead of tearing the row down and rebuilding it —
            // that reuse is what the pager's scoped animation morphs through.
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days.indices, id: \.self) { index in
                    bar(for: days[index])
                }
            }
            .frame(height: Self.barPlotHeight)
            .overlay { trendOverlay(days: days) }
            .overlay { emptyWindowNote }
            Rectangle().fill(.quaternary).frame(height: 1)
            HStack(spacing: 4) {
                ForEach(days.indices, id: \.self) { index in
                    let day = days[index]
                    VStack(spacing: 0) {
                        Text(Self.weekdayFormatter.string(from: day))
                            .font(day == Self.today ? .caption2.bold() : .caption2)
                            .foregroundStyle(day == Self.today
                                ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        Text(Self.dayOfMonthFormatter.string(from: day))
                            .font(.caption2)
                            .foregroundStyle(day == Self.today
                                ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// The learned typical-week shape stretched over this week's own total —
    /// "had these 7 days followed your rhythm, the bars would trace this
    /// line." Shares come from the weekly meter's percent history, so the
    /// overlay works in whatever dimension the bars currently show.
    @ViewBuilder
    private func trendOverlay(days: [Date]) -> some View {
        if let weeklyProfile, weeklyProfile.isReady, days.count > 1 {
            let shares = weeklyProfile.weekdayShares()
            let calendar = Calendar.current
            let total = days.reduce(0.0) { sum, day in
                sum + (layout.byDay[day].map(dayValue) ?? 0)
            }
            if total > 0 {
                TrendLine(
                    values: days.map { day in
                        shares[(calendar.component(.weekday, from: day) - 1) % 7] * total
                    },
                    maxValue: maxDayValue,
                    usableHeight: Self.barPlotHeight - Self.barLabelHeadroom)
            }
        }
    }

    private func bar(for day: Date) -> some View {
        let entry = layout.byDay[day]
        return ZStack(alignment: .bottom) {
            Color.clear
            // The day's total rides just above its bar.
            if let entry {
                let value = dayValue(entry)
                if value > 0 {
                    Text(formatted(value))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .fixedSize()
                        .padding(.bottom, barHeight(for: entry) + 2)
                }
            }
            barFill(for: entry)
                .frame(height: barHeight(for: entry))
                // Today needs no ring here — the bold weekday label below
                // already marks it; the grids keep their ring because their
                // cells have no labels.
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
        .onTapGesture { drill(into: day) }
    }

    /// A day's bar, segmented per model when attribution exists; days without
    /// it (prompt-only, empty) keep their single-color stub.
    @ViewBuilder
    private func barFill(for entry: DailyActivity?) -> some View {
        let segments = barSegments(for: entry)
        if segments.isEmpty {
            RoundedRectangle(cornerRadius: 2).fill(color(for: entry))
        } else {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    ForEach(segments, id: \.model) { segment in
                        (modelColors[segment.model] ?? Self.accent)
                            .opacity(segmentOpacity(for: segment.model))
                            .frame(height: geo.size.height * segment.fraction)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    /// While the legend filters, only the hovered model's band stays lit.
    private func segmentOpacity(for model: String) -> Double {
        guard let hoveredModel else { return 1 }
        return hoveredModel == model ? 1 : 0.2
    }

    /// Render order is top→bottom, so the period's heaviest model sits at
    /// the bottom of every bar and bands align across days. Segments carry
    /// the selected dimension — in cost mode unpriced models drop out.
    private func barSegments(for entry: DailyActivity?) -> [(model: String, fraction: CGFloat)] {
        guard let entry, entry.tokens > 0, !entry.models.isEmpty else { return [] }
        let ordered = summaryRows.compactMap { row -> (model: String, value: Double)? in
            let value = modelDayValue(entry, model: row.model)
            guard value > 0 else { return nil }
            return (row.model, value)
        }
        let sum = ordered.reduce(0) { $0 + $1.value }
        guard sum > 0 else { return [] }
        return ordered.reversed().map {
            (model: $0.model, fraction: CGFloat($0.value / sum))
        }
    }

    /// Height carries the magnitude; color keeps the heatmap's intensity
    /// ramp. Stubs keep empty and prompt-only days (magnitude unknown)
    /// visible, and the headroom leaves space for the value label on top.
    private func barHeight(for entry: DailyActivity?) -> CGFloat {
        guard let entry, entry.tokens > 0 || entry.prompts > 0 else { return 2 }
        let value = dayValue(entry)
        guard value > 0 else { return 5 }
        let fraction = value / max(.leastNonzeroMagnitude, maxDayValue)
        return max(4, (Self.barPlotHeight - Self.barLabelHeadroom) * fraction)
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

    private static let dayTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
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

    /// One heat square/stripe — fill, hover ring, tooltip anchor, drill tap.
    /// Callers give it its frame.
    private func heatCell(for day: Date) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color(for: layout.byDay[day]))
            .overlay {
                if day == Self.today {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(.secondary, lineWidth: 1)
                }
                if hoveredDay == day {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(.primary.opacity(0.9), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredDay = day
                } else if hoveredDay == day {
                    hoveredDay = nil
                }
            }
            .onTapGesture { drill(into: day) }
            .anchorPreference(key: TipKey.self, value: .bounds) { anchor in
                hoveredDay == day ? TipValue(anchor: anchor, day: day) : nil
            }
    }

    /// Instant tooltip bubble — native `.help()` tags are too slow and
    /// unreliable inside popovers.
    private func tooltip(for day: Date) -> some View {
        let date = Self.dayTitleFormatter.string(from: day)
        let entry = layout.byDay[day]
        let text = if let entry, entry.tokens > 0 {
            "\(date) · \(tooltipValue(entry)) · \(entry.messages) msgs"
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

    private func tooltipValue(_ entry: DailyActivity) -> String {
        switch dimension {
        case .tokens: "\(TokenFormat.compact(entry.tokens)) tokens"
        case .cost: "≈ \(UsageFormatting.money(costIndex.byDay[entry.day] ?? 0))"
        }
    }

    // MARK: - Coloring

    /// Local-midnight today, matching the layout's day keys. Computed per
    /// access so a panel left open across midnight doesn't mark yesterday.
    private static var today: Date { Calendar.current.startOfDay(for: Date()) }

    private static var accent: Color { ProviderStyle.accentColor }
    private static let emptyColor = Color.gray.opacity(0.18)
    /// Days known only from prompt history — Claude Code already deleted the
    /// transcripts, so activity is certain but its magnitude isn't.
    private static var promptOnlyColor: Color { accent.opacity(0.15) }

    private func color(for entry: DailyActivity?) -> Color {
        guard let entry, entry.tokens > 0 || entry.prompts > 0 else { return Self.emptyColor }
        if let hoveredModel {
            // Legend filter: paint only this model's share, on its own
            // scale, so a light model still shows its pattern.
            let value = modelDayValue(entry, model: hoveredModel)
            guard value > 0 else { return Self.emptyColor }
            let maxValue = max(.leastNonzeroMagnitude, modelMaxValue(hoveredModel))
            return ramp(modelColors[hoveredModel] ?? Self.accent,
                        fraction: value / maxValue)
        }
        guard entry.tokens > 0 else { return Self.promptOnlyColor }
        let value = dayValue(entry)
        // Cost mode: a day whose models are all unpriced is worth nothing.
        guard value > 0 else { return Self.emptyColor }
        return ramp(Self.accent, fraction: value / max(.leastNonzeroMagnitude, maxDayValue))
    }

    private func ramp(_ base: Color, fraction: Double) -> Color {
        let level = min(4, max(1, Int((fraction * 4).rounded(.up))))
        return base.opacity(Self.levelOpacities[level - 1])
    }

    private var legend: some View {
        let base = hoveredModel.flatMap { modelColors[$0] } ?? Self.accent
        return HStack(spacing: 2) {
            Text("less").font(.caption2).foregroundStyle(.tertiary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level == 0
                        ? Self.emptyColor
                        : base.opacity(Self.levelOpacities[level - 1]))
                    .frame(width: 7, height: 7)
            }
            Text("more").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// The typical-week polyline over the 7D bars: one dot per day at the height
/// the day would reach if the week followed the learned rhythm, connected by
/// a dashed line. Geometry mirrors the bar row exactly — seven equal columns
/// with the same 4-point spacing and the same value→height mapping — so dots
/// land centered over their bars. Built from animatable shapes, not a
/// Canvas: paging between weeks (and flipping tokens↔cost) bends the line
/// to the new values in the same gesture the bars glide with, where a
/// Canvas would snap to the finished frame. Hit testing is off: hover and
/// drill-down stay the bars' business.
private struct TrendLine: View {
    let values: [Double]
    let maxValue: Double
    /// Bar-height scale: the plot height minus the value-label headroom.
    let usableHeight: CGFloat

    var body: some View {
        if values.count > 1, maxValue > 0 {
            let fractions = AnimatableVector(values: values.map { $0 / maxValue })
            ZStack {
                TrendGeometry(fractions: fractions, usableHeight: usableHeight, form: .line)
                    .stroke(
                        Color.primary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 2.5]))
                TrendGeometry(fractions: fractions, usableHeight: usableHeight, form: .dots)
                    .fill(Color.primary.opacity(0.55))
            }
            .allowsHitTesting(false)
        }
    }
}

/// The trend's polyline and dot markers as one parameterized Shape whose
/// animatable data is the per-day height fractions — that's what lets
/// SwiftUI interpolate the line between two weeks' values.
private struct TrendGeometry: Shape {
    enum Form { case line, dots }

    var fractions: AnimatableVector
    let usableHeight: CGFloat
    let form: Form

    var animatableData: AnimatableVector {
        get { fractions }
        set { fractions = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let values = fractions.values
        guard values.count > 1 else { return Path() }
        let spacing: CGFloat = 4
        let columnWidth = (rect.width - spacing * CGFloat(values.count - 1))
            / CGFloat(values.count)
        let points = values.enumerated().map { index, fraction in
            CGPoint(
                x: rect.minX + CGFloat(index) * (columnWidth + spacing) + columnWidth / 2,
                y: rect.maxY - min(rect.height, usableHeight * CGFloat(fraction)))
        }
        var path = Path()
        switch form {
        case .line:
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
        case .dots:
            for point in points {
                path.addEllipse(in: CGRect(
                    x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3))
            }
        }
        return path
    }
}

/// `[Double]` with the vector arithmetic SwiftUI's interpolation needs.
/// Mismatched lengths zero-pad so a mid-flight retarget never traps.
private struct AnimatableVector: VectorArithmetic {
    var values: [Double]

    static var zero: AnimatableVector { AnimatableVector(values: []) }

    static func + (lhs: Self, rhs: Self) -> Self { combined(lhs, rhs, +) }
    static func - (lhs: Self, rhs: Self) -> Self { combined(lhs, rhs, -) }

    private static func combined(
        _ lhs: Self, _ rhs: Self, _ op: (Double, Double) -> Double
    ) -> Self {
        AnimatableVector(
            values: (0..<max(lhs.values.count, rhs.values.count)).map { index in
                op(index < lhs.values.count ? lhs.values[index] : 0,
                   index < rhs.values.count ? rhs.values[index] : 0)
            })
    }

    mutating func scale(by rhs: Double) {
        for index in values.indices { values[index] *= rhs }
    }

    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}
