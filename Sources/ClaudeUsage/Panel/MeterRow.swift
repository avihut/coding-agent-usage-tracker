import SwiftUI
import UsageCore

struct MeterRow: View {
    let meter: Meter
    let stale: Bool
    let prediction: UsagePrediction?

    /// Panel-wide single-popover authority and hover tracker, owned by
    /// UsagePanelView — which also hosts the one shared popover.
    @Binding var openMeter: String?
    @Binding var hoveredMeter: String?
    /// Panel-owned leave grace (cursor on neither a row nor the popover).
    let onLeave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.label).font(.callout)
                Spacer()
                Text(meter.percent.map { "\($0)%" } ?? "—")
                    .font(.callout.monospacedDigit().bold())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let percent = meter.percent, percent > 0 {
                        Capsule()
                            .fill(barColor)
                            .frame(width: max(4, geo.size.width * CGFloat(percent) / 100))
                    }
                }
            }
            .frame(height: 5)
            captionLine.font(.caption2)
        }
        // The highlight bleeds a little past the content into the panel
        // padding, menu-item style; the negative padding hands the space
        // back so the panel layout doesn't shift.
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(lit ? 0.07 : 0)))
        .background(GeometryReader { geo in
            Color.clear.preference(
                key: MeterFramePreference.self,
                value: [meter.id: geo.frame(in: .named(UsagePanelView.panelSpace))])
        })
        .padding(.vertical, -5)
        .padding(.horizontal, -7)
        // Menu-style lifecycle: the first open waits out a brief dwell so a
        // cursor merely passing through never pops anything (a click skips
        // the dwell), but while any popover is up, hovering a sibling row
        // switches to it instantly. Hiding is the panel's leave grace.
        .onHover { inside in
            if inside {
                hoveredMeter = meter.id
                if openMeter != nil {
                    openMeter = meter.id
                } else {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(120))
                        if hoveredMeter == meter.id && openMeter == nil {
                            openMeter = meter.id
                        }
                    }
                }
            } else {
                if hoveredMeter == meter.id { hoveredMeter = nil }
                onLeave()
            }
        }
        .onTapGesture { openMeter = meter.id }
    }

    /// Hover indicator — also stays lit while this row's popover is up, so
    /// the open popover visibly belongs to its row.
    private var lit: Bool {
        hoveredMeter == meter.id || openMeter == meter.id
    }

    /// "resets in 3h 20m" — joined by "runs out in 1h 05m" ONLY when the
    /// forecast actually crosses the limit, in resetText's own tiers. An
    /// on-track forecast stays silent; the bar's tint carries the risk.
    /// No placeholder while the rate is still forming — measuring is the
    /// permanent background state, not news.
    private var captionLine: Text {
        var parts: [Text] = []
        if let resetsAt = meter.resetsAt {
            parts.append(
                Text(UsageFormatting.resetText(resetsAt, now: Date()))
                    .foregroundStyle(.secondary))
        }
        if let prediction, let exhaust = prediction.exhaustsAt {
            parts.append(
                Text(UsageFormatting.exhaustText(exhaust, now: Date()))
                    .foregroundStyle(riskColor(severity: prediction.severity) ?? .orange))
        }
        guard var line = parts.first else { return Text("") }
        for part in parts.dropFirst() {
            line = line + Text(" · ").foregroundStyle(.secondary) + part
        }
        return line
    }

    /// Exhaustion risk first — regular accent while the forecast is clean,
    /// the severity blend otherwise. Percent thresholds only stand in
    /// until a rate exists.
    private var barColor: Color {
        if stale { return Color(nsColor: .secondaryLabelColor) }
        if let prediction {
            return riskColor(severity: prediction.severity)
                ?? Color(nsColor: .controlAccentColor)
        }
        switch meter.level {
        case .normal: return Color(nsColor: .controlAccentColor)
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
