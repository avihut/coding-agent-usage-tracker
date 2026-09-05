import Charts
import SwiftUI
import UsageCore

/// Per-limit history and forecast: the meter's sampled percent overlaid with
/// every model's cumulative token curve (normalized to the plot height), in
/// either the History span's trailing window or the limit window start-to-reset — the
/// latter with a now-notch separating measured from predicted, and the
/// prediction engine's dashed trajectory to the reset. The breakdown table
/// doubles as a legend: hovering a curve or its row focuses the pair and
/// dims the rest — one `focusedModel` drives both surfaces, so they can
/// never disagree.
struct MeterHistoryView: View {
    let meter: Meter
    let samples: [UsageSample]
    let timeline: [TokenSlot]
    let pricing: PricingTable
    let prediction: UsagePrediction?
    /// Closed-window records — with the samples' reset stamps, the pages
    /// the Current span can turn back to.
    let outcomes: [WindowOutcome]
    /// Names whose local sessions feed the breakdown, in the footer note.
    let agentName: String

    /// One-word span choices: a trailing window ending now, or the limit
    /// window itself, start to reset.
    enum Span: String, CaseIterable {
        case history = "History"
        case current = "Current"

        /// Legacy tolerance: this popover's per-meter @AppStorage choice was
        /// persisted as "Sliding"/"Window" before the rename — accept both
        /// so an existing on-disk choice keeps meaning what it meant instead
        /// of silently resetting to the default. The compiler still
        /// synthesizes the `rawValue` getter from each case's literal, so
        /// new choices persist as "History"/"Current".
        init?(rawValue: String) {
            switch rawValue {
            case "History", "Sliding": self = .history
            case "Current", "Window": self = .current
            default: return nil
            }
        }
    }

    /// The History span's trailing frame. Week-to-date follows the
    /// calendar locale's first weekday (Sunday or Monday).
    enum HistoryFrame: String, CaseIterable {
        case h5 = "5h"
        case h12 = "12h"
        case h24 = "24h"
        case week = "wk"
        case d7 = "7d"
        case d30 = "30d"

        func length(now: Date) -> TimeInterval {
            switch self {
            case .h5: return 5 * 3600
            case .h12: return 12 * 3600
            case .h24: return 24 * 3600
            case .week:
                let start = Calendar.current.dateInterval(of: .weekOfYear, for: now)?.start
                // A week only seconds old still deserves a visible frame.
                return max(3600, now.timeIntervalSince(start ?? now))
            case .d7: return 7 * 86400
            case .d30: return 30 * 86400
            }
        }

        var label: String {
            switch self {
            case .h5: return "last 5h"
            case .h12: return "last 12h"
            case .h24: return "last 24h"
            case .week: return "this week"
            case .d7: return "last 7 days"
            case .d30: return "last 30 days"
            }
        }
    }

    /// The span choice, remembered per meter across popover dismissals and
    /// relaunches — the single shared popover would otherwise leak one
    /// meter's choice onto the next while sweeping rows.
    @AppStorage private var span: Span
    /// The History frame, remembered the same way; defaults to the
    /// meter's native window scale.
    @AppStorage private var historyFrame: HistoryFrame
    /// Idle tolerance for the activity strip — adjustable in Settings.
    @AppStorage(ActivityGrace.storageKey)
    private var graceSeconds = ActivityGrace.defaultSeconds
    @State private var hoverDate: Date?
    /// The focused model — set by hovering its curve or its legend row.
    @State private var focusedModel: String?
    /// The activity-strip nub under the cursor, if any.
    @State private var hoveredSegment: ActivitySegment?
    /// The reset line under the cursor — its whole ended window lights up.
    @State private var hoveredReset: Date?
    /// A mid-window reset line under the cursor — a grant that emptied
    /// the meter without closing its window. Held apart from
    /// `hoveredReset` because nothing about it lights a window.
    @State private var hoveredGrant: ResetCliffs.Cliff?
    /// Which limit window the Current span shows: 0 = the live one, k = the
    /// k-th observed window before it (`pastWindows[k - 1]`). Paged by the
    /// ‹ › arrows under the chart and by a two-finger horizontal swipe.
    @State private var windowOffset = 0
    /// Which way the last page turn went (-1 earlier, +1 later): an earlier
    /// window slides in from the left, the way a timeline reads.
    @State private var pageSlide = -1

    init(
        meter: Meter, samples: [UsageSample], timeline: [TokenSlot],
        pricing: PricingTable, prediction: UsagePrediction?,
        outcomes: [WindowOutcome] = [],
        agentName: String, providerID: String
    ) {
        self.meter = meter
        self.samples = samples
        self.timeline = timeline
        self.pricing = pricing
        self.prediction = prediction
        self.outcomes = outcomes
        self.agentName = agentName
        // Meter.id is positional within one provider's snapshot — the
        // provider prefix keeps two harnesses' "0-session" prefs apart.
        _span = AppStorage(
            wrappedValue: .history, "meterPopoverSpan-\(providerID).\(meter.id)")
        _historyFrame = AppStorage(
            wrappedValue: Self.defaultFrame(limitWindow: meter.limitWindow),
            "meterSlidingFrame-\(providerID).\(meter.id)")
    }

    /// A meter's native scale picks its default frame: 5h windows read at
    /// 5h, daily windows at 24h, weekly at 7d.
    private static func defaultFrame(limitWindow: TimeInterval?) -> HistoryFrame {
        let window = limitWindow ?? .infinity
        if window <= 6 * 3600 { return .h5 }
        if window <= 24 * 3600 { return .h24 }
        return .d7
    }

    private static let chartWidth: CGFloat = 300
    private static let chartHeight: CGFloat = 124
    /// One width for Y-axis labels in both modes — sized for the widest
    /// token string TokenFormat.compact emits ("838.9M", six characters),
    /// so nothing wraps or truncates and the axis flipping between percent
    /// and tokens never resizes the plot.
    private static let axisLabelWidth: CGFloat = 42
    /// Vertical room (in domain percent units — the plot maps ~1 unit per
    /// point) a Y-axis label needs; standard marks closer than this to the
    /// projection mark are dropped instead of overlapped.
    private static let axisLabelClearance = 12.0
    /// X-axis eclipse reach, as a fraction of the visible domain: half the
    /// crossing label plus half a base tick label, in plot-relative width.
    private static let xAxisClearanceFraction = 0.15
    // The Y domain's ceiling is dynamic — dataCeiling × 1.15, headroom
    // where the now and session-duration labels live, atop the data
    // instead of on it and inside the chart instead of crashing into the
    // stats line. The same trick the activity strip plays below 0.
    // (chartPlotStyle top padding is NOT this — it shifts the plot
    // against its own axis marks.)
    private static let weekdayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()
    private static let dayName: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
    private static let monthDayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()
    /// "Tue Aug 26" — which day a past page belongs to, in the stats line.
    private static let weekdayDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        return formatter
    }()
    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// A past page's calendar identity, the stats line's lead: "Sun Aug 23 ·
    /// 13:30–18:30" for a window inside one day, "Aug 23 13:30 – Aug 24
    /// 01:30" across midnight, "Aug 23 – Aug 30" for a week.
    private var pageRange: String {
        let (start, end) = domain
        if window > 24 * 3600 {
            return "\(Self.monthDay.string(from: start)) – \(Self.monthDay.string(from: end))"
        }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(Self.weekdayDate.string(from: start)) · "
                + "\(UsageFormatting.clockTime(start))–\(UsageFormatting.clockTime(end))"
        }
        return "\(Self.monthDayTime.string(from: start)) – \(Self.monthDayTime.string(from: end))"
    }

    /// The limit window is provider data on the meter; the 7-day fallback
    /// only covers a meter whose provider didn't say (Claude always does).
    private var window: TimeInterval { meter.limitWindow ?? 7 * 86400 }
    private var orange: Color { ProviderStyle.accentColor }

    /// A live future reset unlocks the Current span; without one (stale data,
    /// missing reset) the picker hides and the view stays on History.
    private var liveReset: Date? {
        meter.resetsAt.flatMap { $0 > Date() ? $0 : nil }
    }

    private var effectiveSpan: Span { liveReset == nil ? .history : span }

    /// The windows this meter was seen running through before the live one,
    /// newest first — the Current span's pages. Observational only
    /// (`LimitWindows`): a stretch the app slept through is a gap, never a
    /// guessed page.
    private var pastWindows: [DateInterval] {
        LimitWindows.observed(
            label: meter.label, window: window, liveReset: liveReset,
            samples: samples, outcomes: outcomes)
    }

    /// The offset clamped to the pages that exist — a window closing while
    /// the popover is open, or a meter switch, must never strand it.
    private var pageIndex: Int { min(windowOffset, pastWindows.count) }

    /// True while the Current span shows the LIVE window — the only page
    /// with a now, a forecast, a crossing, and an open-ended session. Every
    /// past page is closed history and draws none of those.
    private var isLive: Bool { effectiveSpan == .current && pageIndex == 0 }

    private var domain: (start: Date, end: Date) {
        if effectiveSpan == .current, let reset = liveReset {
            if pageIndex > 0 {
                let page = pastWindows[pageIndex - 1]
                return (page.start, page.end)
            }
            return (reset.addingTimeInterval(-window), reset)
        }
        let now = Date()
        return (now.addingTimeInterval(-historyFrame.length(now: now)), now)
    }

    /// What one window of this meter is called: a session, a week, or a
    /// generic window — "this session" live, "previous session" one page
    /// back, "3 sessions ago" beyond.
    private var windowNoun: String {
        meter.rank == 0 ? "session" : window >= 6 * 86400 ? "week" : "window"
    }

    private var spanLabel: String {
        switch effectiveSpan {
        case .current:
            switch pageIndex {
            case 0: "this \(windowNoun)"
            case 1: "previous \(windowNoun)"
            default: "\(pageIndex) \(windowNoun)s ago"
            }
        case .history: historyFrame.label
        }
    }

    /// One page step, shared by the arrows and the swipe: direction < 0 =
    /// an earlier window, > 0 = later (the heatmap pager's convention).
    /// No-ops at either edge. Hover state is cleared — a nub or reset from
    /// the previous page has no meaning on the new one.
    private func pageStep(_ direction: Int) {
        guard effectiveSpan == .current else { return }
        // Magnitude = how many pages; the arrows and swipes pass ±1, the
        // back-to-live button the whole distance (clamped below).
        let next = min(max(pageIndex - direction, 0), pastWindows.count)
        guard next != pageIndex else { return }
        hoverDate = nil
        focusedModel = nil
        hoveredSegment = nil
        hoveredReset = nil
        hoveredGrant = nil
        // Two transactions, deliberately. A removed view exits with the
        // transition it was RENDERED with, not the one the removing render
        // computes — so the direction must land in the view graph first
        // (this render), and the page flip follow in the next one; in one
        // transaction the outgoing chart slid by the PREVIOUS turn's
        // direction while the incoming one obeyed the new, which read as
        // the two halves moving apart.
        pageSlide = direction < 0 ? -1 : 1
        Task { @MainActor in windowOffset = next }
    }

    /// Jumps a paged-back Current span straight to the live window — the
    /// arrows walk one window at a time, and eleven sessions back is a long
    /// walk. Reserved at zero opacity on the live page so the row is stable.
    private var backToLiveButton: some View {
        let available = effectiveSpan == .current && pageIndex > 0
        return Button {
            pageStep(pastWindows.count)
        } label: {
            Image(systemName: "forward.end.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(available ? 1 : 0)
        .disabled(!available)
        .help("Back to the current \(windowNoun)")
    }

    /// The ‹ / › page arrow flanking the domain labels. Unavailable
    /// directions — and the History span, which pages nothing — keep their
    /// slot at zero opacity so the row never reflows.
    private func pageArrow(direction: Int) -> some View {
        let available = effectiveSpan == .current
            && (direction < 0 ? pageIndex < pastWindows.count : pageIndex > 0)
        return Button {
            pageStep(direction)
        } label: {
            Image(systemName: direction < 0
                ? "chevron.left.circle.fill" : "chevron.right.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(available ? 1 : 0)
        .disabled(!available)
        .help(direction < 0 ? "Previous \(windowNoun)" : "Next \(windowNoun)")
    }

    /// The frame dropdown: current choice + chevron, menu of the long
    /// labels. Same bare-button dressing as the panel's ⋯ menu — the
    /// default menu style wraps it in a bordered pull-down pill.
    private var framePicker: some View {
        Menu {
            Picker("Frame", selection: $historyFrame) {
                ForEach(HistoryFrame.allCases, id: \.self) { frame in
                    Text(frame.label).tag(frame)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 2) {
                Text(historyFrame.rawValue)
                    .font(.caption2.weight(.semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private struct Point: Identifiable {
        let id: TimeInterval
        let t: Date
        let percent: Int
    }

    private var points: [Point] {
        let (start, end) = domain
        let measuredEnd = min(end, Date())
        return samples
            .filter { $0.t >= start && $0.t <= measuredEnd }
            .compactMap { sample in
                sample.percents[meter.label].map {
                    Point(id: sample.t.timeIntervalSince1970, t: sample.t, percent: $0)
                }
            }
    }

    private struct PercentSeries {
        let drawn: [Point]
        /// The reset moments inside the frame — where the drawn line
        /// cliffs, and where the vertical reset markers stand.
        let resets: [Date]
        /// Resets granted INSIDE a window in the frame: the line cliffs
        /// there too, but no window closed — drawn as their own mark.
        let midWindow: [ResetCliffs.Cliff]
    }

    /// The drawn percent series: the in-domain samples, the last sample
    /// before the frame (so the line enters at its true height), and a
    /// reset cliff wherever the percent dropped between neighbors — the
    /// line holds its level to the old window's end, falls to zero there,
    /// then climbs again. A limit reset is an instant, and sparse samples
    /// straddling it must not draw as a gradual decline. `points` alone
    /// keeps anchoring the token normalization: its first/last must stay
    /// in-domain.
    private var percentSeries: PercentSeries {
        let (start, end) = domain
        let measuredEnd = min(end, Date())
        var series: [ResetCliffs.Sample] = []
        var lastBefore: ResetCliffs.Sample?
        // Stamps carried across the polls that omitted them (`ResetCarry`),
        // so a grant that blanked the stamp classifies against the window
        // it happened inside instead of reading as a boundary.
        for sample in ResetCarry.fill(samples) where sample.t <= measuredEnd {
            guard let percent = sample.percents[meter.label] else { continue }
            let point = ResetCliffs.Sample(
                t: sample.t, percent: percent, resetsAt: sample.resets?[meter.label])
            if sample.t < start { lastBefore = point } else { series.append(point) }
        }
        if let lastBefore { series.insert(lastBefore, at: 0) }
        let cliffs = ResetCliffs.cliffs(
            between: series, window: window, currentReset: meter.resetsAt)
        var drawn = series.map {
            Point(id: $0.t.timeIntervalSince1970, t: $0.t, percent: $0.percent)
        }
        for cliff in cliffs {
            drawn.append(Point(
                id: cliff.at.timeIntervalSince1970 + 0.25, t: cliff.at, percent: cliff.from))
            drawn.append(Point(
                id: cliff.at.timeIntervalSince1970 + 0.75,
                t: cliff.at.addingTimeInterval(1), percent: 0))
        }
        let inFrame = cliffs.filter { $0.at >= start }
        return PercentSeries(
            drawn: drawn.sorted { $0.t < $1.t },
            resets: inFrame.filter { $0.kind == .windowEnd }.map(\.at),
            midWindow: inFrame.filter { $0.kind == .midWindow })
    }

    /// This window's per-model usage, scoped for scoped meters — the rows of
    /// the shared table and the curves the chart overlays.
    private var windowRows: [ModelTokenUsage] {
        // Bounded by the page's own end: a past window's table must not
        // keep summing to now (a week page and a 5h page read identical).
        let all = WindowTokens.breakdown(
            timeline: timeline, from: domain.start, to: min(domain.end, Date()))
        return scopeName.map { WindowTokens.scoped(all, name: $0) } ?? all
    }

    /// The grid's rows: the whole frame normally; while an active nub is
    /// hovered, the same models re-tallied over just that session — and
    /// while a reset line is hovered, over the limit window that ended
    /// there (the true window, even the part outside the frame). The row
    /// set and order stay fixed — hover must never reflow the popover — so
    /// models silent during the slice read zero.
    private func sessionRows(base: [ModelTokenUsage]) -> [ModelTokenUsage] {
        if let reset = hoveredReset {
            return scopedRows(base: base, from: reset.addingTimeInterval(-window), to: reset)
        }
        guard let session = hoveredSegment, session.kind == .active else { return base }
        return scopedRows(base: base, from: session.sessionStart, to: session.end)
    }

    private func scopedRows(
        base: [ModelTokenUsage], from: Date, to: Date
    ) -> [ModelTokenUsage] {
        let slice = WindowTokens.breakdown(timeline: timeline, from: from, to: to)
        let byModel = Dictionary(uniqueKeysWithValues: slice.map { ($0.model, $0.tally) })
        return base.map {
            ModelTokenUsage(model: $0.model, tally: byModel[$0.model] ?? TokenTally())
        }
    }

    /// One model's cumulative curve, normalized so the busiest model's total
    /// spans the plot — magnitudes stay comparable between models while
    /// sharing the percent chart's 0...100 canvas.
    private struct ModelCurve {
        let model: String
        let color: Color
        let points: [(t: Date, normalized: Double)]
    }

    var body: some View {
        let rows = windowRows
        let colors = ModelPalette.assignment(for: rows.map(\.model))
        let scale = percentPerToken(rows: rows)
        let curves = modelCurves(rows: rows, colors: colors, percentPerToken: scale)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(.caption.bold())
                Spacer()
                // The History span picks its trailing frame from a compact
                // dropdown beside the span picker; the Current span's frame
                // IS the limit window, so the dropdown hides there.
                if effectiveSpan == .history {
                    framePicker
                }
                if liveReset != nil {
                    SegmentedPicker(
                        title: "Span", selection: $span,
                        options: Span.allCases.map { ($0.rawValue, $0) })
                } else {
                    Text(spanLabel).font(.caption2).foregroundStyle(.secondary)
                }
            }
            // Fixed-height stats line: window totals normally, the focused
            // model's share while a curve/row pair is lit. Never reflows.
            // On a past page this line is the window's TITLE — "Sun Aug 23 ·
            // 13:30–18:30 · 10 sessions ago" — in primary weight, so which
            // window is on screen is the first thing read; the header above
            // stays identical to the live page's, and the height is fixed.
            HStack(spacing: 5) {
                if let focusedModel {
                    Circle()
                        .fill(colors[focusedModel] ?? .gray)
                        .frame(width: 6, height: 6)
                }
                Text(statsText(rows: rows))
                    .font(.caption2.weight(isPageTitle ? .semibold : .regular))
                    .foregroundStyle(isPageTitle ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: 14)
            if points.count < 2 && curves.isEmpty {
                Text(isLive || effectiveSpan == .history
                    ? "Collecting samples — this fills in as refreshes accumulate."
                    : "No samples retained for this \(windowNoun).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.chartWidth, height: Self.chartHeight)
            } else {
                // The 30s tick keeps the now-notch sliding and the sliding
                // domain honest while the popover stays open.
                // A page turn slides the chart the way the timeline reads —
                // an earlier window arrives from the left — clipped to the
                // chart's own fixed frame. Scoped to THIS subtree via the
                // value-keyed animation: the labels and the breakdown grid
                // below step discretely, so the popover resizes once,
                // natively, instead of chasing an animated height.
                ZStack {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        chart(curves: curves, now: context.date, percentPerToken: scale)
                    }
                    .id(pageIndex)
                    // Push: the incoming chart arrives from `edge` while the
                    // outgoing one leaves through the opposite edge, in
                    // lockstep — one transition for both halves, so they
                    // can't drift apart. Earlier windows arrive from the
                    // left, the way the timeline reads; a swipe to the
                    // right (fingers right = earlier) moves the chart right.
                    .transition(.push(from: pageSlide < 0 ? .leading : .trailing))
                }
                .frame(width: Self.chartWidth, height: Self.chartHeight)
                .clipped()
                .animation(.easeInOut(duration: 0.28), value: pageIndex)
                // Two-finger horizontal swipes page windows like the arrows
                // below. Inert on History, whose frame is a trailing one.
                .background(HorizontalSwipeCatcher(enabled: effectiveSpan == .current) {
                    direction in pageStep(direction)
                })
            }
            domainLabels
            Text(resetReadout ?? grantReadout ?? segmentReadout ?? readout.map(readoutText) ?? hoverHint)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(readout == nil && segmentReadout == nil && resetReadout == nil
                    && grantReadout == nil
                    ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
            Divider()
            if rows.isEmpty {
                Text("No local token data in this window.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ModelBreakdownGrid(
                    rows: sessionRows(base: rows), colors: colors, pricing: pricing,
                    hoveredModel: $focusedModel)
            }
            Text("Local \(agentName) sessions on this Mac only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        // Meter switches reuse this view (single shared popover) — hover
        // state must not leak across.
        .onChange(of: meter.id) {
            hoverDate = nil
            focusedModel = nil
            hoveredSegment = nil
            hoveredReset = nil
            hoveredGrant = nil
            windowOffset = 0
        }
        // Flipping to History and back lands on the live window again.
        .onChange(of: span) { windowOffset = 0 }
    }

    /// Grabbing distance is measured against this chart's pinned width —
    /// the audit chart passes its live plot width to the same helper.
    private func nearestReset(
        to date: Date, in resets: [Date], start: Date, end: Date
    ) -> Date? {
        WindowPlot.nearestReset(
            to: date, in: resets, span: end.timeIntervalSince(start),
            trackWidth: Self.chartWidth)
    }

    // MARK: - Chart

    private func chart(
        curves: [ModelCurve], now: Date, percentPerToken: Double?
    ) -> some View {
        let (start, end) = domain
        let measuredEnd = min(end, now)
        let series = percentSeries
        let spent = spentStretches(series)
        let segments = activitySegments(now: now, spent: spent)
        let drawnPercent = series.drawn
        // Y geometry scales from the tallest curve: the headroom band that
        // hosts the top labels is always 15% of the data ceiling, so the
        // Current span keeps its familiar 100→115 shape and a History frame
        // holding 2.6 limits gets 260→299 — labels never land on data.
        let ceiling = dataCeiling(curves)
        let plotTop = ceiling * 1.15
        // The stored hover re-anchored onto this render's freshly built
        // segments — see liveNub for why no direct comparison can do it.
        let hovered = hoveredSegment.flatMap { liveNub(for: $0, in: segments) }
        let focusedCurve = focusedModel.flatMap { model in curves.first { $0.model == model } }
        let nowLabelShown = hovered == nil
            && !nowEclipsed(by: focusedCurve, now: now, start: start, end: end)
        return Chart {
            // Activity strip, iStat-style: a band under the plot floor —
            // orange where transcripts logged tokens, a faint track where
            // they didn't. Future (right of now) stays empty.
            RectangleMark(
                xStart: .value("Time", start), xEnd: .value("Time", measuredEnd),
                yStart: .value("Usage", Self.stripBottom),
                yEnd: .value("Usage", Self.stripTop))
            .foregroundStyle(Color.primary.opacity(0.08))
            ForEach(segments, id: \.start) { segment in
                RectangleMark(
                    xStart: .value("Time", segment.start), xEnd: .value("Time", segment.end),
                    yStart: .value("Usage", Self.stripBottom),
                    yEnd: .value("Usage", Self.stripTop))
                .foregroundStyle(nubColor(segment).opacity(nubOpacity(segment, hovered: hovered)))
            }
            // Scaffolding under the data: a muted dashed vertical at each
            // reset that happened inside the frame, and — when the frame
            // holds more than one limit — a dashed horizontal pinning where
            // a single limit tops out. The percent line can never cross
            // that line; the token curves honestly can.
            // Conspicuous on purpose — the same lesson as the now rule:
            // anything softer vanishes against the dark material. The
            // hovered line goes full primary and its whole ended window
            // lights via the curtains below.
            WindowPlot.resets(series.resets, hovered: hoveredReset, ceiling: ceiling)
            WindowPlot.midWindowResets(
                series.midWindow.map(\.at), hovered: hoveredGrant?.at, ceiling: ceiling)
            // Reset hover: curtain-dim everything outside the limit window
            // that ended at this line — the undimmed stretch IS the window
            // — with a solid twin marking where that window began. The
            // summary below re-tallies to the same window.
            if let hoveredReset {
                WindowPlot.resetCurtain(
                    hoveredReset, window: window,
                    start: start, end: end, ceiling: ceiling)
            }
            if effectiveSpan == .history,
               ceiling > 100 || end.timeIntervalSince(start) > window * 1.01 {
                RuleMark(y: .value("Usage", 100))
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            // Model curves underlay the percent line; the focused one draws
            // last so its full-opacity line sits on top of its dimmed peers.
            ForEach(drawOrder(curves), id: \.model) { curve in
                if focusedModel == curve.model {
                    ForEach(curve.points, id: \.t) { point in
                        AreaMark(
                            x: .value("Time", point.t),
                            yStart: .value("Usage", 0),
                            yEnd: .value("Usage", point.normalized))
                        .foregroundStyle(curve.color.opacity(0.15))
                        .interpolationMethod(.monotone)
                    }
                }
                ForEach(curve.points, id: \.t) { point in
                    LineMark(
                        x: .value("Time", point.t),
                        y: .value("Usage", point.normalized),
                        series: .value("Series", curve.model))
                    .foregroundStyle(curve.color.opacity(lineOpacity(curve.model)))
                    .interpolationMethod(.monotone)
                }
            }
            if focusedModel == nil {
                ForEach(drawnPercent) { point in
                    AreaMark(
                        x: .value("Time", point.t),
                        yStart: .value("Usage", 0),
                        yEnd: .value("Usage", Double(point.percent)))
                    .foregroundStyle(orange.opacity(0.18))
                    .interpolationMethod(.monotone)
                }
            }
            ForEach(drawnPercent) { point in
                LineMark(
                    x: .value("Time", point.t),
                    y: .value("Usage", Double(point.percent)),
                    series: .value("Series", "percent"))
                .foregroundStyle(orange.opacity(focusedModel == nil ? 1 : 0.3))
                .interpolationMethod(.monotone)
            }
            if isLive {
                // The prediction engine's trajectory: dashed, measured side
                // of the notch left alone. It speaks the risk ramp — accent
                // while the forecast is clean, yellow-to-red as the
                // projection climbs past the warning threshold.
                if let prediction, prediction.curve.count >= 2 {
                    let trajectory = riskColor(severity: prediction.severity) ?? orange
                    ForEach(prediction.curve, id: \.t) { point in
                        LineMark(
                            x: .value("Time", point.t),
                            y: .value("Usage", point.percent),
                            series: .value("Series", "prediction"))
                        .foregroundStyle(trajectory.opacity(focusedModel == nil ? 0.8 : 0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                // The now separator: everything left is measured, right is
                // ahead. Full primary — anything softer (.tertiary, then
                // .secondary) got lost against the chart. The rule stops at
                // 100 so its label sits in the headroom band above the data;
                // while a nub is hovered it yields the band to the
                // session-duration label.
                RuleMark(
                    x: .value("Now", now),
                    yStart: .value("Usage", Self.stripBottom),
                    yEnd: .value("Usage", 100))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top, alignment: .center, spacing: 2,
                        overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                    ) {
                        if nowLabelShown {
                            // Frame-aware like every timestamp here: clock
                            // within a day, weekday + clock across days,
                            // date + clock past a week.
                            Text(timeLabel(now))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                // Where the current pace hits the limit; the hatched region
                // beyond it is unusable. The crossing's timestamp lives in
                // the X axis row (always on), not up here — as an annotation
                // it landed on the strip's red nub and vanished into it.
                if let exhaust = exhaustDate {
                    RuleMark(
                        x: .value("Exhausted", exhaust),
                        yStart: .value("Usage", Self.stripBottom),
                        yEnd: .value("Usage", 100))
                        .foregroundStyle(.red.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            // Nub hover: dimming curtains cover the graph outside the
            // hovered slice — the slice keeps full strength, which IS the
            // highlight. Nubs dim via their own opacity (curtains stop at
            // the plot floor).
            if let hovered {
                WindowPlot.nubCurtain(hovered, start: start, end: end, ceiling: ceiling)
                // The session's duration, highlighted in the headroom band
                // and centered over its nub — the at-a-glance answer while
                // the readout line below spells out the range.
                PointMark(
                    x: .value("Time", hovered.start.addingTimeInterval(
                        hovered.end.timeIntervalSince(hovered.start) / 2)),
                    y: .value("Usage", ceiling))
                .symbolSize(0)
                .annotation(
                    position: .top, alignment: .center, spacing: 2,
                    overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                ) {
                    Text(UsageFormatting.duration(
                        hovered.end.timeIntervalSince(hovered.sessionStart)))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(
                            hovered.kind == .exhausted
                                ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                }
            }
            // The focused model's name rides above its curve's tip — the
            // chart-side echo of the legend row. Labels are layered: this
            // outranks the now label (which yields on overlap) and the
            // strip's duration label can't coexist with a curve focus.
            if let focusedCurve, let tip = focusedCurve.points.last {
                PointMark(
                    x: .value("Time", tip.t),
                    y: .value("Usage", tip.normalized))
                .symbolSize(0)
                .annotation(
                    position: .top, alignment: .center, spacing: 2,
                    overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                ) {
                    Text(ModelNames.display(focusedCurve.model))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(focusedCurve.color)
                }
            }
            if let readout {
                RuleMark(
                    x: .value("Time", readout.t),
                    yStart: .value("Usage", Self.stripBottom),
                    yEnd: .value("Usage", ceiling))
                    .foregroundStyle(.quaternary)
                PointMark(
                    x: .value("Time", readout.t),
                    y: .value("Usage", Double(readout.percent)))
                .foregroundStyle(orange.opacity(readout.predicted ? 0.8 : 1))
                .symbolSize(30)
            }
        }
        .chartYScale(domain: Self.stripBottom - 1...plotTop)
        // While a model is focused the axis speaks its language: the
        // gridlines re-labeled as tokens through the shared conversion,
        // climbing in steps of half a limit as far as the curves reach.
        // Both modes render labels at one fixed width — token strings are
        // wider than "100", and a mode flip must never resize the plot.
        .chartYAxis {
            if focusedModel != nil, let percentPerToken {
                AxisMarks(values: Array(stride(from: 0.0, through: ceiling, by: 50))) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let percent = value.as(Double.self) {
                            Text(TokenFormat.compact(Int(percent / percentPerToken)))
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .frame(width: Self.axisLabelWidth, alignment: .leading)
                        }
                    }
                }
            } else {
                // The projected-finish height gets its own labeled mark; a
                // standard label it would eclipse steps aside rather than
                // overlap (the projection is the one worth reading). Only
                // the LABEL steps aside — its gridline stays.
                let projection = axisProjection
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let percent = value.as(Double.self),
                           projection.map({ abs(Double(percent) - $0)
                               >= Self.axisLabelClearance }) ?? true {
                            Text("\(Int(percent))%")
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .frame(width: Self.axisLabelWidth, alignment: .leading)
                        }
                    }
                }
                if let projection {
                    AxisMarks(values: [projection]) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel {
                            Text("\(Int(projection))%")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(
                                    riskColor(severity: prediction?.severity ?? 0) ?? orange)
                                .lineLimit(1)
                                .frame(width: Self.axisLabelWidth, alignment: .leading)
                        }
                    }
                }
            }
        }
        .chartXScale(domain: start...end)
        // A frame of several days labels its axis with day names at the
        // day boundaries — dates mean less than weekdays at that zoom.
        // Beyond ~a week the names would repeat, so the month scale keeps
        // the default date ticks; under two days, explicit whole-hour
        // clock ticks. When the forecast crosses the limit, the crossing's
        // timestamp joins the axis row in red — always on — and any base
        // tick whose label it would overlap steps aside (the Y axis
        // projection's eclipse rule, applied to time).
        .chartXAxis {
            let length = end.timeIntervalSince(start)
            if length >= 48 * 3600, length <= 8 * 86400 {
                AxisMarks(values: dayTicks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let day = value.as(Date.self), !tickLabelEclipsed(day) {
                            Text(Self.dayName.string(from: day))
                                .fontWeight(.semibold)
                        }
                    }
                }
            } else if length < 48 * 3600 {
                // Always explicit at this zoom: automatic marks can't be
                // eclipsed by the crossing label, and once the window spans
                // midnight they grow date-bearing labels ("16 Aug at 00")
                // that collide. Whole-hour ticks stay clock-only.
                AxisMarks(values: hourTicks) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let date = value.as(Date.self), !tickLabelEclipsed(date) {
                            Text(UsageFormatting.clockTime(date))
                                .fontWeight(.semibold)
                        }
                    }
                }
            } else {
                AxisMarks { _ in
                    AxisGridLine()
                    AxisValueLabel()
                        .font(.caption2.weight(.semibold))
                }
            }
            if let exhaust = exhaustDate {
                AxisMarks(values: [exhaust]) { _ in
                    // fixedSize + an edge-aware anchor: centered on its tick
                    // the label truncated against the plot edge whenever the
                    // crossing sat near the reset.
                    AxisValueLabel(anchor: exhaustLabelAnchor) {
                        Text(timeLabel(exhaust))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .fixedSize()
                    }
                }
            }
        }
        // Diagonal hatching over the unreachable region — the limit is spent
        // before the window ends, so everything past the crossing is dead
        // time. Drawn behind the marks so curves stay crisp over it.
        .chartBackground { proxy in
            GeometryReader { geo in
                // The forecast's dead zone and the windows that already ran
                // out hatch identically — one list, one painter.
                WindowPlot.unusableHatching(
                    unusableSpans(spent: spent), proxy: proxy, geometry: geo)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let origin = geo[plotFrame].origin
                            let date = proxy.value(atX: location.x - origin.x, as: Date.self)
                            let yValue = proxy.value(atY: location.y - origin.y, as: Double.self)
                            hoverDate = date
                            // Below the plot floor the cursor is on the
                            // activity strip: nubs take the hover there,
                            // curves let go.
                            if let yValue, yValue < 0 {
                                let hit = date.flatMap { d in
                                    segments.first { $0.start <= d && d <= $0.end }
                                }
                                if hoveredSegment != hit { hoveredSegment = hit }
                                if focusedModel != nil { focusedModel = nil }
                                if hoveredReset != nil { hoveredReset = nil }
                                if hoveredGrant != nil { hoveredGrant = nil }
                            } else {
                                if hoveredSegment != nil { hoveredSegment = nil }
                                // A reset line within reach takes the hover
                                // before curve focus — its ended window
                                // lights up instead.
                                let hit = date.flatMap { d in
                                    nearestReset(
                                        to: d, in: series.resets + series.midWindow.map(\.at),
                                        start: start, end: end)
                                }
                                let grant = hit.flatMap { h in series.midWindow.first { $0.at == h } }
                                let reset = grant == nil ? hit : nil
                                if hoveredReset != reset { hoveredReset = reset }
                                if hoveredGrant != grant { hoveredGrant = grant }
                                if hit != nil {
                                    if focusedModel != nil { focusedModel = nil }
                                } else {
                                    updateFocus(at: date, yValue: yValue, curves: curves)
                                }
                            }
                        case .ended:
                            hoverDate = nil
                            focusedModel = nil
                            hoveredSegment = nil
                            hoveredReset = nil
                            hoveredGrant = nil
                        }
                    }
            }
        }
        .frame(width: Self.chartWidth, height: Self.chartHeight)
    }

    /// The activity strip's band, in chart-Y units below the plot floor.
    private static let stripBottom: Double = -7
    private static let stripTop: Double = -2

    /// The projected limit-crossing inside the Current span, if the current
    /// pace spends the meter before the window resets.
    private var exhaustDate: Date? {
        guard isLive,
              let exhaust = prediction?.exhaustsAt,
              exhaust > domain.start, exhaust < domain.end
        else { return nil }
        return exhaust
    }

    /// The Current span's projected finish height for the Y axis — only
    /// while the forecast stays within the limit (an exhausting one is the
    /// red rule's story) and the axis still speaks percent.
    private var axisProjection: Double? {
        guard isLive, focusedModel == nil,
              let prediction, prediction.exhaustsAt == nil,
              let projected = prediction.projectedAtReset, projected < 100
        else { return nil }
        return Double(projected)
    }

    /// Day-boundary X ticks, explicit (rather than `.stride(by: .day)`) so
    /// the exhaustion label can eclipse the ones it would overlap.
    private var dayTicks: [Date] {
        let (start, end) = domain
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: start)
        if day < start { day = calendar.date(byAdding: .day, value: 1, to: day) ?? end }
        var ticks: [Date] = []
        while day <= end {
            ticks.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return ticks
    }

    /// Whole-hour X ticks for sub-two-day frames, strided to land a handful
    /// of labels — clock-only, so a window spanning midnight never grows
    /// the wide date labels the automatic marks would use.
    private var hourTicks: [Date] {
        let (start, end) = domain
        let length = end.timeIntervalSince(start)
        let strideHours = length <= 6 * 3600 ? 1 : length <= 12 * 3600 ? 2 : 6
        let calendar = Calendar.current
        guard var tick = calendar.nextDate(
            after: start, matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime)
        else { return [] }
        var ticks: [Date] = []
        while tick <= end {
            ticks.append(tick)
            guard let next = calendar.date(byAdding: .hour, value: strideHours, to: tick)
            else { break }
            tick = next
        }
        return ticks
    }

    /// Near a plot edge the crossing's label hangs inward from its tick
    /// instead of centering on it — centered, the edge clipped it to "Sat…".
    private var exhaustLabelAnchor: UnitPoint {
        guard let exhaust = exhaustDate else { return .top }
        let (start, end) = domain
        let fraction = exhaust.timeIntervalSince(start) / end.timeIntervalSince(start)
        if fraction > 0.88 { return .topTrailing }
        if fraction < 0.12 { return .topLeading }
        return .top
    }

    /// The crossing's timestamp owns its stretch of the axis row: base
    /// ticks whose labels would crowd it go silent — the LABEL only, the
    /// tick's gridline stays on the chart. The reach follows the anchor —
    /// a trailing-anchored label lies almost entirely left of its tick,
    /// so the eclipse shifts with it.
    private func tickLabelEclipsed(_ tick: Date) -> Bool {
        guard let exhaust = exhaustDate else { return false }
        let (start, end) = domain
        let clearance = end.timeIntervalSince(start) * Self.xAxisClearanceFraction
        let anchor = exhaustLabelAnchor
        let (leftReach, rightReach): (Double, Double) = anchor == .topTrailing
            ? (1.7, 0.4)
            : anchor == .topLeading ? (0.4, 1.7) : (1, 1)
        let offset = tick.timeIntervalSince(exhaust)
        return offset >= -clearance * leftReach && offset <= clearance * rightReach
    }

    /// The strip's stretches are `WindowPlot.Nub` — the same type the audit
    /// chart draws — so the exhausted colouring and the hover curtains have
    /// one definition between the two charts.
    private typealias ActivitySegment = WindowPlot.Nub

    private func nubColor(_ segment: ActivitySegment) -> Color {
        WindowPlot.nubColor(segment.kind, accent: orange)
    }

    /// The stored hover re-anchored onto freshly built segments. No date
    /// field survives a rebuild — the sliding domain re-anchors at Date()
    /// every render, shifting every bucket boundary, and the trailing end /
    /// exhausted start move with time — so equality on any of them orphans
    /// the hover. The stored nub's midpoint finding the same-kind segment
    /// that contains it is drift-proof (drift is micro/30s-scale, nubs are
    /// minutes wide) — and it must be containment, not "the first
    /// exhausted": a remembered spent sliver peeping in at the domain's
    /// left edge once hijacked the forecast nub's hover, pinning a "1 min"
    /// readout to the far corner (v0.82.0). Only the exhausted hover then
    /// hunts for the nearest peer: its forecast boundary swings with every
    /// pace re-estimate (54 minutes in under a wall-clock minute,
    /// observed), far enough to orphan containment mid-hover. An orphaned
    /// active nub just drops the hover.
    private func liveNub(
        for stored: ActivitySegment, in segments: [ActivitySegment]
    ) -> ActivitySegment? {
        let mid = stored.start.addingTimeInterval(
            stored.end.timeIntervalSince(stored.start) / 2)
        let peers = segments.filter { $0.kind == stored.kind }
        if let held = peers.first(where: { $0.contains(mid) }) { return held }
        guard stored.kind == .exhausted else { return nil }
        return peers.min { gap($0, to: mid) < gap($1, to: mid) }
    }

    /// How far a moment sits outside a segment (0 inside it).
    private func gap(_ segment: ActivitySegment, to moment: Date) -> TimeInterval {
        min(abs(segment.start.timeIntervalSince(moment)),
            abs(segment.end.timeIntervalSince(moment)))
    }

    /// `hovered` is the live-resolved nub, an element of the same array being
    /// drawn, so the equality inside `WindowPlot.nubOpacity` is exact.
    private func nubOpacity(_ segment: ActivitySegment, hovered: ActivitySegment?) -> Double {
        WindowPlot.nubOpacity(segment, hovered: hovered)
    }

    /// "Wed 09:15 – Wed 14:15 · window 5 hr" while a reset line is
    /// hovered — the bounds and length of the limit window being lit.
    private var resetReadout: String? {
        hoveredReset.map { reset in
            let windowStart = reset.addingTimeInterval(-window)
            return "\(timeLabel(windowStart)) – \(timeLabel(reset)) · window "
                + UsageFormatting.duration(window)
        }
    }

    /// "Limit reset · ~Thu 21:10 · from 30%" while a mid-window reset line
    /// is hovered: the meter was emptied without its window closing. The
    /// tilde is honest — the API gives no moment for a grant, only the two
    /// polls it fell between.
    private var grantReadout: String? {
        hoveredGrant.map { grant in
            "Limit reset · ~\(timeLabel(grant.at)) · from \(grant.from)%"
        }
    }

    /// "Wed 09:15 – Wed 11:30 · active 2 hr 15 min" while a nub is hovered;
    /// the exhausted nub reads "unreachable" instead. A frame-clipped
    /// session reads from its true start, before the domain.
    private var segmentReadout: String? {
        hoveredSegment.map { segment in
            let verb = segment.kind == .exhausted ? "unreachable" : "active"
            return "\(timeLabel(segment.sessionStart)) – \(timeLabel(segment.end)) · \(verb) "
                + UsageFormatting.duration(
                    segment.end.timeIntervalSince(segment.sessionStart))
        }
    }

    /// The scoped activity moments before `boundary`, walked backwards with
    /// the strip's grace bridging — the true start of a session whose nub
    /// the frame clips. Only computed for a first segment touching the
    /// domain's left edge.
    private func clippedSessionStart(before boundary: Date) -> Date? {
        let needle = scopeName?.lowercased()
        let moments = timeline.compactMap { slot -> Date? in
            if let needle, !slot.model.lowercased().contains(needle) { return nil }
            return slot.t
        }
        return ActivityGrace.clippedStart(
            before: boundary, moments: moments, grace: graceSeconds)
    }

    /// Contiguous stretches of the measured domain where transcripts logged
    /// tokens (scoped meters count only their own model), bucketed so a week
    /// of minute slots collapses to a handful of marks.
    /// Spans in this frame the limit was already spent through, recalled
    /// from the samples by the same rule the "spent at 15:04" caption uses.
    /// Closed windows only — the live window's dead zone comes from the
    /// prediction's own crossing, drawn as the hatched region.
    ///
    /// Takes the already-built series rather than reaching for
    /// `percentSeries`: the render needs this twice (the ground region and
    /// the strip's colouring) and that property rebuilds the whole cliff
    /// walk each time it is touched.
    private func spentStretches(_ series: PercentSeries) -> [DateInterval] {
        let (start, end) = domain
        return ExhaustedStretches.build(
            resets: series.resets, grants: series.midWindow.map(\.at), window: window,
            meterLabel: meter.label, samples: samples,
            domain: DateInterval(start: start, end: end))
    }

    /// Every span in this frame nothing could land in: the windows that
    /// already ran out, plus the live window's dead zone from the projected
    /// crossing to the frame's end. One list so the hatching can't drift
    /// between a remembered exhaustion and a forecast one.
    private func unusableSpans(spent: [DateInterval]) -> [DateInterval] {
        let (_, end) = domain
        guard let exhaust = exhaustDate, exhaust < end else { return spent }
        return spent + [DateInterval(start: exhaust, end: end)]
    }

    private func activitySegments(now: Date, spent: [DateInterval]) -> [ActivitySegment] {
        // Month scale: sessions are minutes-to-hours wide — sub-pixel
        // slivers or misleading bucket-wide blobs at this zoom. The strip
        // goes quiet rather than cluttered; the heatmap owns that scale.
        if effectiveSpan == .history, historyFrame == .d30 { return [] }
        let start = domain.start
        let end = min(domain.end, now)
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return [] }
        let bucket = max(60, span / 120)
        let needle = scopeName?.lowercased()
        var active = Array(repeating: false, count: Int(span / bucket) + 1)
        for slot in timeline where slot.t >= start && slot.t <= end {
            if let needle, !slot.model.lowercased().contains(needle) { continue }
            let index = Int(slot.t.timeIntervalSince(start) / bucket)
            if active.indices.contains(index) { active[index] = true }
        }
        var segments: [ActivitySegment] = []
        var runStart: Int?
        for (index, isActive) in active.enumerated() {
            if isActive, runStart == nil { runStart = index }
            if !isActive, let run = runStart {
                segments.append(ActivitySegment(
                    start: start.addingTimeInterval(Double(run) * bucket),
                    end: start.addingTimeInterval(Double(index) * bucket)))
                runStart = nil
            }
        }
        if let run = runStart {
            segments.append(ActivitySegment(
                start: start.addingTimeInterval(Double(run) * bucket), end: end))
        }
        // Human-scale pauses — reading, typing a reply — are still the same
        // session: gaps within the grace period get bridged (0 = raw Claude
        // activity only), and the newest stretch is held open to now while
        // its idle time could still turn out to be such a pause; once the
        // gap outgrows the grace, the nub snaps back to the session's true
        // end. The hold caps at the exhausted boundary — a session can't
        // run into the unreachable region.
        let stitched = ActivityGrace.stitch(
            segments.map { DateInterval(start: $0.start, end: $0.end) },
            grace: graceSeconds)
        // A closed page's last session ended when it ended — only the live
        // window has a session that may still be going.
        segments = (isLive
            ? ActivityGrace.holdOpen(
                stitched, until: min(end, exhaustDate ?? end), grace: graceSeconds)
            : stitched
        ).map { ActivitySegment(start: $0.start, end: $0.end) }
        // Windows that already CLOSED spent-out: the stretch between the
        // crossing and the reset reads red, so a frame holding several
        // windows shows every one it ran out of, not just the live one.
        segments = WindowPlot.marking(segments, exhausted: spent)
        // A session the frame clips at its left edge is longer than its
        // nub: walk the timeline before the domain (same grace bridging)
        // for its true start, so hover reports the whole session.
        if let first = segments.first, first.kind == .active,
           first.start.timeIntervalSince(start) < 1 {
            segments[0].fullStart = clippedSessionStart(before: first.start)
        }
        // The dead stretch gets its own nub at the strip's end, so the
        // unreachable region reads from the strip too.
        if let exhaust = exhaustDate {
            segments.append(ActivitySegment(
                start: exhaust, end: domain.end, kind: .exhausted))
        }
        return segments
    }

    /// Unfocused curves first, the focused one last (drawn on top).
    private func drawOrder(_ curves: [ModelCurve]) -> [ModelCurve] {
        guard let focusedModel else { return curves }
        return curves.filter { $0.model != focusedModel }
            + curves.filter { $0.model == focusedModel }
    }

    private func lineOpacity(_ model: String) -> Double {
        guard let focusedModel else { return 0.55 }
        return model == focusedModel ? 1 : 0.15
    }

    /// Graph-side focus: the curve whose value at the cursor's time sits
    /// nearest the cursor's height wins, within a grab distance — otherwise
    /// the hover is about the percent line/whitespace and nothing focuses.
    private func updateFocus(at date: Date?, yValue: Double?, curves: [ModelCurve]) {
        guard let date, let yValue else { return }
        var best: (model: String, distance: Double)?
        for curve in curves {
            guard let value = interpolate(curve.points, at: date) else { continue }
            let distance = abs(value - yValue)
            if best == nil || distance < best!.distance {
                best = (curve.model, distance)
            }
        }
        let hit = (best?.distance ?? .infinity) <= 8 ? best?.model : nil
        if focusedModel != hit { focusedModel = hit }
    }

    private func interpolate(
        _ pts: [(t: Date, normalized: Double)], at date: Date
    ) -> Double? {
        guard let first = pts.first, let last = pts.last else { return nil }
        // A curve begins where its model's usage begins — before that
        // there is no line to grab, so nothing focuses.
        if date < first.t { return nil }
        if date == first.t { return first.normalized }
        if date >= last.t { return last.normalized }
        for (p0, p1) in zip(pts, pts.dropFirst()) where date <= p1.t {
            let span = p1.t.timeIntervalSince(p0.t)
            guard span > 0 else { return p1.normalized }
            let fraction = date.timeIntervalSince(p0.t) / span
            return p0.normalized + fraction * (p1.normalized - p0.normalized)
        }
        return last.normalized
    }

    /// The chart's one tokens→percent conversion: the percent the meter
    /// gained over the visible window, divided by the tokens spent in it.
    /// Under this scale the models' combined spend meets the percent
    /// curve's growth exactly, so every token curve stays perceptually
    /// contained inside the usage it fed — and the Y axis can speak tokens
    /// by dividing back. Nil when percent data is missing, flat, or dipped
    /// through a reset — curves then fall back to busiest-model scaling
    /// and the axis stays percent.
    private func percentPerToken(rows: [ModelTokenUsage]) -> Double? {
        if effectiveSpan == .history {
            return historyPercentPerToken ?? frameGainsPercentPerToken(rows: rows)
        }
        let total = WindowTokens.total(rows).total
        guard total > 0, let first = points.first, let last = points.last else { return nil }
        let delta = Double(last.percent - first.percent)
        guard delta >= 1 else { return nil }
        return delta / Double(total)
    }

    /// The History span's anchor. Its frame can straddle resets, where
    /// percent deltas lie, so one limit's worth of tokens is measured on
    /// the CURRENT live window instead: the live percent over the tokens
    /// spent since that window began. Curves normalized by it read as
    /// fractions of a single limit — and may honestly exceed it across a
    /// frame longer than one window.
    private var historyPercentPerToken: Double? {
        guard let reset = liveReset, let percent = meter.percent, percent >= 1
        else { return nil }
        let windowStart = reset.addingTimeInterval(-window)
        let all = WindowTokens.breakdown(timeline: timeline, from: windowStart, to: Date())
        let scoped = scopeName.map { WindowTokens.scoped(all, name: $0) } ?? all
        let total = WindowTokens.total(scoped).total
        guard total > 0 else { return nil }
        return Double(percent) / Double(total)
    }

    /// Fallback anchor for frames the live window can't price: a young 5h
    /// window whose local tokens haven't landed yet (the activity scan is
    /// ~1/min behind the transcript), usage spent on another surface, a
    /// percent still at 0, or an expired meter with no live reset at all.
    /// The percent GAINED across the visible frame — drops at resets
    /// excluded, so a sawtooth doesn't cancel itself — over the tokens
    /// spent in it. Coarser than the live-window anchor, but it keeps the
    /// axis speaking tokens whenever the frame holds any growth at all;
    /// nil only when even that is missing.
    private func frameGainsPercentPerToken(rows: [ModelTokenUsage]) -> Double? {
        let total = WindowTokens.total(rows).total
        guard total > 0 else { return nil }
        return ModelCurves.gainsPercentPerToken(
            percents: points.map(\.percent), tokens: total)
    }

    /// Layered labels: when the focused model's name and the now label
    /// would collide, the now label (the lower layer) disappears for the
    /// moment. Extents are estimated in track space — close enough for a
    /// yield decision.
    private func nowEclipsed(
        by curve: ModelCurve?, now: Date, start: Date, end: Date
    ) -> Bool {
        guard let curve, let tip = curve.points.last else { return false }
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return false }
        let xNow = now.timeIntervalSince(start) / span * Self.chartWidth
        let xLabel = tip.t.timeIntervalSince(start) / span * Self.chartWidth
        let labelWidth = Double(ModelNames.display(curve.model).count) * 4.5 + 4
        return abs(xLabel - xNow) < (labelWidth + 18) / 2
    }

    /// Colours the curves core built. The Current span is one window —
    /// nothing can honestly exceed one limit there, so the cap is a safety
    /// net; a History frame can span several windows and the overshoot IS
    /// the information.
    private func modelCurves(
        rows: [ModelTokenUsage], colors: [String: Color], percentPerToken: Double?
    ) -> [ModelCurve] {
        let end = min(domain.end, Date())
        return ModelCurves.build(
            models: rows.map(\.model),
            moments: timeline.map {
                ModelCurves.Moment(model: $0.model, t: $0.t, amount: $0.tally.total)
            },
            start: domain.start, end: end,
            percentPerToken: percentPerToken, cap: effectiveSpan == .current
        ).map { curve in
            ModelCurve(
                model: curve.model,
                color: colors[curve.model] ?? .gray,
                points: curve.points.map { ($0.t, $0.value) })
        }
    }

    /// The tallest drawn value: 100 in the Current span (curves cap there),
    /// beyond it when a History frame holds more than one limit's worth.
    /// The plot top and the label headroom band scale from it.
    private func dataCeiling(_ curves: [ModelCurve]) -> Double {
        max(100, curves.flatMap { $0.points }.map { $0.normalized }.max() ?? 100)
    }

    // MARK: - Text lines

    /// "89.2M tokens this session", or the focused model's slice of it.
    private func statsText(rows: [ModelTokenUsage]) -> String {
        if effectiveSpan == .current, pageIndex > 0 {
            if let focusedModel, let row = rows.first(where: { $0.model == focusedModel }) {
                return "\(row.displayName) · \(TokenFormat.compact(row.tally.total)) tokens · \(pageRange)"
            }
            return "\(pageRange) · \(spanLabel)"
        }
        if let focusedModel, let row = rows.first(where: { $0.model == focusedModel }) {
            return "\(row.displayName) · \(TokenFormat.compact(row.tally.total)) tokens \(spanLabel)"
        }
        return "\(TokenFormat.compact(WindowTokens.total(rows).total)) tokens \(spanLabel)"
    }

    /// The stats line reads as the page's title — primary, semibold — on a
    /// past page while no model is focused (a focus turns it back into the
    /// model's share, in the usual secondary voice).
    private var isPageTitle: Bool {
        effectiveSpan == .current && pageIndex > 0 && focusedModel == nil
    }

    private var hoverHint: String {
        focusedModel.map { "\(ModelNames.display($0)) focused" }
            ?? "Hover the graph for point details"
    }

    /// Start and end of the visible domain under the chart — in Current span
    /// the end is the reset itself.
    private var domainLabels: some View {
        let (start, end) = domain
        // A past page's bounds carry their day (timeLabel does that for
        // every non-live page); the end repeats it only across midnight.
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        return HStack(spacing: 4) {
            pageArrow(direction: -1)
            Text(timeLabel(start))
            Spacer()
            Text(effectiveSpan == .history ? "now"
                : isLive ? "resets \(timeLabel(end))"
                : "reset \(sameDay ? UsageFormatting.clockTime(end) : timeLabel(end))")
            pageArrow(direction: 1)
            backToLiveButton
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(width: Self.chartWidth)
    }

    /// Frame-aware timestamps: hours within a day, weekday + time across
    /// several days, month + day once weekday names would repeat.
    private func timeLabel(_ date: Date) -> String {
        let (start, end) = domain
        let length = end.timeIntervalSince(start)
        // A past page is some other day, or some other week — a bare clock
        // time or a weekday name can't say which. Month + day always.
        if effectiveSpan == .current, !isLive { return Self.monthDayTime.string(from: date) }
        if length > 8 * 86400 { return Self.monthDayTime.string(from: date) }
        if length > 24 * 3600 { return Self.weekdayTime.string(from: date) }
        return UsageFormatting.clockTime(date)
    }

    // MARK: - Hover readout

    /// A continuously-hoverable reading: measured percent is interpolated
    /// between the surrounding samples; right of the now-notch the value
    /// comes off the prediction curve and says so. Tokens attribute to the
    /// enclosing poll interval (measured side only).
    private struct Readout {
        let t: Date
        let percent: Int
        let from: Date?
        let to: Date?
        let predicted: Bool
    }

    private var readout: Readout? {
        // Point readouts belong to the percent/prediction lines; in focus
        // mode the stats line carries the numbers, and on the activity
        // strip the segment readout does.
        guard focusedModel == nil, hoveredSegment == nil, let hoverDate else { return nil }
        let now = Date()
        let (domainStart, domainEnd) = domain
        let t = min(max(hoverDate, domainStart), domainEnd)
        if isLive, t > now {
            guard let prediction,
                  let projected = PredictionEngine.percent(onCurve: prediction.curve, at: t)
            else { return nil }
            return Readout(
                t: t, percent: Int(projected.rounded()), from: nil, to: nil, predicted: true)
        }
        // Interpolate on the drawn series — the reset cliffs included, so
        // the readout steps where the line steps.
        let all = percentSeries.drawn
        guard let first = all.first, let last = all.last else { return nil }
        if t <= first.t {
            return Readout(t: t, percent: first.percent, from: nil, to: nil, predicted: false)
        }
        if t >= last.t {
            return Readout(t: t, percent: last.percent, from: last.t, to: t, predicted: false)
        }
        let index = all.lastIndex { $0.t <= t } ?? 0
        let p0 = all[index]
        let p1 = all[index + 1]
        let span = p1.t.timeIntervalSince(p0.t)
        let fraction = span > 0 ? t.timeIntervalSince(p0.t) / span : 0
        let percent = Double(p0.percent) + fraction * Double(p1.percent - p0.percent)
        return Readout(
            t: t, percent: Int(percent.rounded()), from: p0.t, to: p1.t, predicted: false)
    }

    /// "14:32 · 34% · 1.2M tokens · $3.40" measured; "16:05 · proj. 41%"
    /// beyond the notch.
    private func readoutText(_ readout: Readout) -> String {
        var parts = [UsageFormatting.clockTime(readout.t)]
        if readout.predicted {
            parts.append("proj. \(readout.percent)%")
            return parts.joined(separator: " · ")
        }
        parts.append("\(readout.percent)%")
        if let from = readout.from, let to = readout.to {
            let rows = WindowTokens.breakdown(
                timeline: timeline, from: from.addingTimeInterval(1), to: to)
            let total = WindowTokens.total(rows)
            if total.total > 0 {
                parts.append("\(TokenFormat.compact(total.total)) tokens")
                let dollars = rows
                    .compactMap { pricing.rates(for: $0.model)?.dollars(for: $0.tally) }
                    .reduce(0, +)
                if dollars > 0 { parts.append(UsageFormatting.money(dollars)) }
            }
        }
        return parts.joined(separator: " · ")
    }

    /// A scoped meter's breakdown shows only its own model's usage, never
    /// the whole timeline. The model name is meter data from the provider —
    /// no label parsing.
    private var scopeName: String? { meter.scopedModelName }
}
