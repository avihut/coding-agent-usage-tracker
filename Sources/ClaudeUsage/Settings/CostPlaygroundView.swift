import SwiftUI
import UsageCore

/// Interactive what-if: dial a session's shape, watch the four counters and
/// the bill move. Pure UI over `CostSimulator` — every change re-prices the
/// whole session live.
struct CostPlaygroundView: View {
    let pricing: PricingTable
    let modelOptions: [String]

    @State private var model: String
    @State private var steps: Double = Self.defaults.steps
    @State private var startingContext: Double = Self.defaults.context
    @State private var growth: Double = Self.defaults.growth
    @State private var output: Double = Self.defaults.output
    @State private var oneHourTTL = true

    /// A medium agentic session: ~60 requests over an 18K-token base,
    /// growing 2.5K per step — the shape of real transcripts here.
    private static let defaults = (steps: 60.0, context: 18_000.0, growth: 2_500.0, output: 400.0)

    init(pricing: PricingTable, modelOptions: [String], initialModel: String) {
        self.pricing = pricing
        self.modelOptions = modelOptions
        _model = State(initialValue: initialModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Model", selection: $model) {
                    ForEach(modelOptions, id: \.self) { id in
                        Text(ModelNames.display(id)).tag(id)
                    }
                }
                .fixedSize()
                Spacer()
                Picker("Cache TTL", selection: $oneHourTTL) {
                    Text("1h · subscription").tag(true)
                    Text("5m · API key").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            dial(
                "Agent steps", value: $steps, range: 1...300, step: 1,
                display: "\(Int(steps)) requests",
                caption: "API requests in the session — every tool call is one.")
            dial(
                "Starting context", value: $startingContext, range: 1_000...60_000, step: 1_000,
                display: "\(TokenFormat.compact(Int(startingContext))) tokens",
                caption: "In place before the first request: system prompt, CLAUDE.md, tools.")
            dial(
                "Growth per step", value: $growth, range: 0...10_000, step: 250,
                display: "\(TokenFormat.compact(Int(growth))) tokens",
                caption: "What each request adds: tool results plus the model's reply.")
            dial(
                "Output per step", value: $output, range: 0...5_000, step: 100,
                display: "\(TokenFormat.compact(Int(output))) tokens",
                caption: "Generated per request — visible text and thinking both bill as output.")
            Divider()
            results
            HStack {
                Spacer()
                Button("Reset to a typical session") {
                    steps = Self.defaults.steps
                    startingContext = Self.defaults.context
                    growth = Self.defaults.growth
                    output = Self.defaults.output
                    oneHourTTL = true
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var session: CostSimulator.Session {
        .init(
            startingContext: Int(startingContext), steps: Int(steps),
            growthPerStep: Int(growth), outputPerStep: Int(output),
            oneHourTTL: oneHourTTL)
    }

    @ViewBuilder private var results: some View {
        if let rates = pricing.rates(for: model) {
            let outcome = CostSimulator.simulate(session, rates: rates)
            let pieces = rates.dollarBreakdown(for: outcome.tally)
            Grid(alignment: .trailingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text("tokens")
                    Text("est. cost")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                resultRow("Fresh input", outcome.tally.input, pieces.input)
                resultRow(
                    oneHourTTL ? "Cache writes · 1h" : "Cache writes · 5m",
                    outcome.tally.cacheCreation, pieces.cacheWrite)
                resultRow("Cache reads", outcome.tally.cacheRead, pieces.cacheRead)
                resultRow("Output", outcome.tally.output, pieces.output)
                resultRow("Total", outcome.tally.total, outcome.cost, emphasized: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(counterfactualText(outcome))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(finalContextText(outcome))
                    .font(.caption)
                    .foregroundStyle(outcome.finalContext > 150_000 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        } else {
            Text("No list rates for this model — pick another.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func resultRow(
        _ label: String, _ tokens: Int, _ dollars: Double, emphasized: Bool = false
    ) -> some View {
        GridRow {
            Text(label)
                .font(emphasized ? .callout.weight(.semibold) : .callout)
                .gridColumnAlignment(.leading)
            Text(TokenFormat.compact(tokens))
                .font(.callout.monospacedDigit())
                .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Text(UsageFormatting.money(dollars))
                .font(emphasized ? .callout.monospacedDigit().weight(.semibold) : .callout.monospacedDigit())
                .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
    }

    private func counterfactualText(_ outcome: CostSimulator.Outcome) -> String {
        guard outcome.uncachedCost > 0 else { return "Without caching: nothing to resend." }
        let saved = 1 - outcome.cost / outcome.uncachedCost
        let percent = Int((saved * 100).rounded())
        return "Without caching the same session would bill ≈ \(UsageFormatting.money(outcome.uncachedCost)) — caching saves \(percent)%."
    }

    private func finalContextText(_ outcome: CostSimulator.Outcome) -> String {
        var text = "Final context: \(TokenFormat.compact(outcome.finalContext)) tokens."
        if outcome.finalContext > 150_000 {
            text += " Claude Code would auto-compact before it grew this large."
        }
        return text
    }

    private func dial(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
        display: String, caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout)
                Spacer()
                Text(display)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
