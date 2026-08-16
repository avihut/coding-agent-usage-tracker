import SwiftUI
import UsageCore

/// The Usage page: what the forecast engine is actually thinking — per-meter
/// rates, baselines and verdicts — plus the learned weekly rhythm and the
/// sample history feeding both. The panel shows conclusions; this page shows
/// the working.
struct UsageSettingsPane: View {
    var store: UsageStore

    /// What history.json weighs, measured on appearance.
    @State private var historyBytes: Int64?

    var body: some View {
        SettingsPaneScroll {
            forecastsCard
            rhythmCard
            historyCard
            explainerCard
        }
        .onAppear {
            let url = store.historyFileURL
            historyBytes = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        }
    }

    // MARK: - Forecasts

    private var meters: [Meter] { store.state.snapshot?.meters ?? [] }

    private var forecastsCard: some View {
        SettingsCard(
            "Forecasts",
            footer: "A hot session raises the forecast for about an hour, then it settles back onto the baseline — one intense sitting no longer projects across the whole week."
        ) {
            if meters.isEmpty {
                note("No live meters yet — forecasts appear once usage loads.")
            } else {
                ForEach(Array(meters.enumerated()), id: \.element.id) { index, meter in
                    if index > 0 { Divider() }
                    meterBlock(meter)
                }
            }
        }
    }

    @ViewBuilder
    private func meterBlock(_ meter: Meter) -> some View {
        let prediction = store.predictions[meter.label]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                if let prediction {
                    Circle()
                        .fill(verdictColor(prediction.verdict))
                        .frame(width: 8, height: 8)
                }
                Text(meter.label).font(.callout.weight(.semibold))
                Spacer()
                if let prediction {
                    Text(prediction.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let prediction {
                infoRow(
                    "Recent burn",
                    String(format: "%.1f%%/h · %@", prediction.ratePerHour, rateWindowLabel(meter)))
                infoRow("Baseline", baselineLabel(prediction))
                infoRow(
                    "Projected at reset",
                    prediction.projectedAtReset.map { "\($0)%" } ?? "—")
                if let exhaust = prediction.exhaustsAt {
                    // A crossing already behind us is a record, not a
                    // countdown — "in -3h" is the shape to avoid.
                    let now = Date()
                    if exhaust > now {
                        infoRow(
                            "Crosses the limit",
                            "in \(UsageFormatting.duration(exhaust.timeIntervalSince(now)))")
                    } else {
                        infoRow("Limit spent", "at \(UsageFormatting.stamp(exhaust, now: now))")
                    }
                }
                if prediction.rawVerdict != prediction.verdict {
                    Text("Latest reading says \(verdictName(prediction.rawVerdict)) — one more agreeing refresh flips the color.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("No forecast yet — the rate needs a few minutes of samples.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rateWindowLabel(_ meter: Meter) -> String {
        let minutes = Int((meter.rateWindow / 60).rounded())
        return minutes < 60 ? "last \(minutes) min" : "last \(minutes / 60) h"
    }

    private func baselineLabel(_ prediction: UsagePrediction) -> String {
        switch prediction.basis {
        case .recentOnly:
            return "— · window too young for an average pace"
        case .windowAverage:
            let rate = prediction.baselineRatePerHour ?? 0
            return String(format: "%.1f%%/h · this window's average pace", rate)
        case .weeklyProfile:
            let rate = prediction.baselineRatePerHour ?? 0
            let pace = prediction.paceFactor ?? 1
            return String(format: "%.1f%%/h · weekly rhythm, pace ×%.2f", rate, pace)
        }
    }

    private func verdictColor(_ verdict: UsagePrediction.Verdict) -> Color {
        switch verdict {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        }
    }

    private func verdictName(_ verdict: UsagePrediction.Verdict) -> String {
        switch verdict {
        case .green: "green"
        case .yellow: "yellow"
        case .red: "red"
        }
    }

    // MARK: - Weekly rhythm

    private var rhythmCard: some View {
        SettingsCard(
            "Weekly rhythm",
            footer: "Learned from this app's own sample history (not transcripts): consumption between polls, attributed to 4-hour blocks of the week. It becomes the forecast baseline and the 7D chart's typical-week overlay once two full weeks exist."
        ) {
            if let profile = store.weeklyProfile, profile.isReady {
                rhythmGrid(profile)
                Divider()
                rhythmInsights(profile)
            } else {
                // Concrete countdown from day one: the profile's own span
                // once it exists, the raw sample span before that.
                let collected = store.weeklyProfile?.historySpan ?? sampleSpan
                let remaining = max(0, WeeklyProfile.activationSpan - collected)
                infoRow(
                    "History collected",
                    "\(daysText(collected)) of \(daysText(WeeklyProfile.activationSpan))")
                ProgressView(value: min(1, collected / WeeklyProfile.activationSpan))
                    .controlSize(.small)
                note("Personalized forecast activates in \(daysText(remaining)) — until then forecasts lean on each window's own average pace.")
            }
        }
    }

    /// Oldest-to-newest span of the stored samples — the readiness clock
    /// before the profile itself has been built.
    private var sampleSpan: TimeInterval {
        guard let first = store.samples.first?.t, let last = store.samples.last?.t
        else { return 0 }
        return last.timeIntervalSince(first)
    }

    /// 7 weekday columns × six 4-hour rows, intensity = typical burn rate.
    private func rhythmGrid(_ profile: WeeklyProfile) -> some View {
        let peak = profile.rates.max() ?? 0
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow {
                Color.clear.frame(width: 44, height: 1)
                ForEach(0..<7, id: \.self) { day in
                    Text(symbols[day])
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<WeeklyProfile.blocksPerDay, id: \.self) { block in
                GridRow {
                    Text(blockLabel(block))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 44, alignment: .trailing)
                    ForEach(0..<7, id: \.self) { day in
                        let rate = profile.rates[day * WeeklyProfile.blocksPerDay + block]
                        RoundedRectangle(cornerRadius: 2)
                            .fill(cellColor(rate: rate, peak: peak))
                            .frame(height: 14)
                            .help(String(
                                format: "%@ %@ · ≈%.1f%%/h",
                                Calendar.current.weekdaySymbols[day], blockLabel(block), rate))
                    }
                }
            }
        }
    }

    private func blockLabel(_ block: Int) -> String {
        String(format: "%02d–%02d", block * 4, block * 4 + 4)
    }

    private func cellColor(rate: Double, peak: Double) -> Color {
        guard peak > 0, rate > 0 else { return Color.gray.opacity(0.15) }
        let orange = ProviderStyle.accentColor
        return orange.opacity(0.12 + 0.82 * rate / peak)
    }

    @ViewBuilder
    private func rhythmInsights(_ profile: WeeklyProfile) -> some View {
        let shares = profile.weekdayShares()
        let names = Calendar.current.weekdaySymbols
        infoRow(
            "Typical week",
            String(format: "≈%.0f%% of the weekly limit", profile.globalRatePerHour * 168))
        if let busiest = shares.indices.max(by: { shares[$0] < shares[$1] }) {
            infoRow(
                "Busiest day",
                "\(names[busiest])s · \(Int((shares[busiest] * 100).rounded()))% of the week")
        }
        if let quietest = shares.indices.min(by: { shares[$0] < shares[$1] }) {
            infoRow(
                "Quietest day",
                "\(names[quietest])s · \(Int((shares[quietest] * 100).rounded()))% of the week")
        }
        infoRow(
            "Based on",
            "\(daysText(profile.historySpan)) of history · \(profile.pairCount) sample pairs")
    }

    // MARK: - Sample history

    private var historyCard: some View {
        SettingsCard(
            "Sample history",
            footer: "Percentages and reset times only — no tokens, no account identifiers. It feeds the burn rates, the popover graphs, and the weekly rhythm, and never leaves this Mac."
        ) {
            infoRow("Samples stored", "\(store.samples.count)")
            if let oldest = store.samples.first?.t {
                Divider()
                infoRow("Reaches back", "\(daysText(Date().timeIntervalSince(oldest))) · since \(oldest.formatted(date: .abbreviated, time: .omitted))")
            }
            Divider()
            infoRow("Resolution", "every poll for 7 days · one per 15 min beyond")
            Divider()
            infoRow("Retention", "8 weeks")
            if let historyBytes {
                Divider()
                infoRow(
                    "On disk",
                    ByteCountFormatter.string(fromByteCount: historyBytes, countStyle: .file))
            }
        }
    }

    /// "9 days" / "1 day" / "6 hours" — spans at history scale.
    private func daysText(_ interval: TimeInterval) -> String {
        let days = interval / 86400
        if days >= 1.5 { return "\(Int(days.rounded())) days" }
        if days >= 0.75 { return "1 day" }
        let hours = Int((interval / 3600).rounded())
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    // MARK: - Explainer

    private var explainerCard: some View {
        SettingsCard("How the forecast works") {
            explainer(
                "Two rates, one curve",
                "The recent burn is a least-squares slope over the latest monotonic samples — 45 minutes of them for the session meter, 4 hours for the weeklies. The baseline is your typical pace. The forecast lets the burst's excess decay into the baseline with a one-hour half-life-style constant: a hot session raises the next hour of the projection, not the next five days.")
            explainer(
                "The baseline learns you",
                "Until two weeks of history exist, the baseline is the window's own average pace (percent used ÷ time elapsed). After that it's the weekly rhythm: typical burn per 4-hour block of the week, scaled by how this window is actually running (the pace factor). That's how the forecast knows a weekend is coming.")
            explainer(
                "Verdicts, gently",
                "Green projects under \(Int(PredictionEngine.yellowProjectionThreshold))% at reset, yellow presses on the limit, red crosses it before the reset saves it. A color change needs two consecutive refreshes agreeing, so a single odd reading never flips the panel.")
        }
    }

    private func explainer(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
