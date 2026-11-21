import SwiftUI
import UsageCore

/// The per-model usage table shared by the activity summary, the day
/// drill-down, and the meter popovers: a headline cost total over aligned
/// input/cached/output/cost columns. Rows double as a legend — each carries
/// its model's color, and hovering a row filters the chart above to that
/// model via the bound `hoveredModel`. Clicking a row opens the cost math:
/// every token class multiplied out at its list rate.
struct ModelBreakdownGrid: View {
    let rows: [ModelTokenUsage]
    let colors: [String: Color]
    let pricing: PricingTable
    /// The sessions detail promotes the cost into its own header KPI —
    /// it suppresses this centered copy so the number appears once.
    var showsHeadline = true
    @Binding var hoveredModel: String?
    @State private var costDetail: String?

    static let tokenColumnWidth: CGFloat = 44
    static let costColumnWidth: CGFloat = 54
    static let columnSpacing: CGFloat = 8
    /// The least room between a name and the first number column. Numbers
    /// sit right-aligned in 44pt columns, so the gap the eye sees stays
    /// ~20pt; the name gets the rest (it was 20pt here plus that).
    static let nameGap: CGFloat = 8
    /// Each row's inner horizontal padding — room for the hover highlight.
    /// A host that lines the table's TEXT up with its own edges takes it
    /// back with `.padding(.horizontal, -rowInset)`, so the highlight bleeds
    /// into the host's margin instead of insetting the text (the panel).
    static let rowInset: CGFloat = 4
    /// Headline caption → column header: the Activity section's own 8pt
    /// rhythm (2pt of the headline's padding, the grid's 2pt spacing, this).
    static let headlineGap: CGFloat = 4

    var body: some View {
        let priced = rows.map { row in (row: row, rates: pricing.rates(for: row.model)) }
        let total = priced.compactMap { $0.rates?.dollars(for: $0.row.tally) }.reduce(0, +)
        let unpricedCount = priced.count(where: { $0.rates == nil })
        VStack(alignment: .leading, spacing: 2) {
            if showsHeadline {
                // The headline number: what this window would have cost.
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
                .padding(.top, 2)
                .padding(.bottom, 2 + Self.headlineGap)
            }
            columnHeader
            ForEach(priced, id: \.row.id) { entry in
                modelRow(entry.row, rates: entry.rates)
            }
        }
        .padding(.top, 2)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("model")
            Spacer(minLength: Self.nameGap)
            HStack(spacing: Self.columnSpacing) {
                Text("input").frame(width: Self.tokenColumnWidth, alignment: .trailing)
                Text("cached").frame(width: Self.tokenColumnWidth, alignment: .trailing)
                Text("output").frame(width: Self.tokenColumnWidth, alignment: .trailing)
                Text("est. cost").frame(width: Self.costColumnWidth, alignment: .trailing)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Self.rowInset)
    }

    private func modelRow(_ row: ModelTokenUsage, rates: ModelRates?) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(colors[row.model] ?? Color.gray)
                    .frame(width: 7, height: 7)
                // Whole wherever the host has room (popovers size to fit);
                // in the fixed 360pt panel a long name gives way at the tail
                // rather than push the content wider (user-reported
                // 2026-11-21: it collapsed every section's margin).
                Text(row.displayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.displayName)
            }
            .layoutPriority(1)
            Spacer(minLength: Self.nameGap)
            HStack(spacing: Self.columnSpacing) {
                // "input" is what was processed anew; the conversation
                // history re-read from cache on every request stands apart
                // as "cached" — lumping them reads as absurd typed-prompt
                // volume.
                Text(TokenFormat.compact(row.tally.uncachedInput))
                    .frame(width: Self.tokenColumnWidth, alignment: .trailing)
                Text(TokenFormat.compact(row.tally.cacheRead))
                    .frame(width: Self.tokenColumnWidth, alignment: .trailing)
                Text(TokenFormat.compact(row.tally.output))
                    .frame(width: Self.tokenColumnWidth, alignment: .trailing)
                Text(rates.map { UsageFormatting.money($0.dollars(for: row.tally)) } ?? "—")
                    .frame(width: Self.costColumnWidth, alignment: .trailing)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, Self.rowInset)
        .padding(.vertical, 2)
        .background(
            // Lit while hovered — and held lit while the row's cost math is
            // open, so the popover keeps pointing at a marked row even
            // though the cursor left it.
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(
                    hoveredModel == row.model || costDetail == row.model ? 0.07 : 0)))
        // Hover targets tile the inter-row gaps: half the VStack spacing
        // added around the hit shape, then taken back from layout — the
        // cursor never crosses dead space between rows, so the chart's
        // focus can't flicker off mid-travel. Visuals are untouched (the
        // highlight background sits inside the extra padding).
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredModel = row.model
            } else if hoveredModel == row.model {
                hoveredModel = nil
            }
        }
        .pointerStyle(.link)
        .onTapGesture { costDetail = row.model }
        .popover(
            isPresented: Binding(
                get: { costDetail == row.model },
                set: { if !$0 { costDetail = nil } }),
            arrowEdge: .bottom
        ) {
            CostMathView(row: row, rates: rates)
        }
        .padding(.vertical, -1)
    }
}

/// The arithmetic behind one row's estimate — each token class multiplied
/// out at its list rate, summing to the est. cost column. The class labels
/// also decode the grid's vocabulary: its "input" column folds fresh input
/// and cache writes together, "cached" is the cache reads. Shared with the
/// day ring, whose sectors present the same popover on click.
struct CostMathView: View {
    let row: ModelTokenUsage
    let rates: ModelRates?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.displayName)
                .font(.callout.weight(.semibold))
            if let rates {
                let lines = rates.components(for: row.tally).filter { $0.tokens > 0 }
                Grid(alignment: .trailingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("tokens")
                        Text("× $ / MTok")
                        Text("")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    ForEach(lines) { line in
                        GridRow {
                            Text(Self.label(line.tokenClass))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.leading)
                            Text(TokenFormat.compact(line.tokens))
                                .monospacedDigit()
                            Text("× \(UsageFormatting.ratePerMTok(line.rate))\(line.listed ? "" : "*")")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(UsageFormatting.money(line.dollars))
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                    Divider()
                    // Both columns total up, so both get named: "total"
                    // owns the row, "est. cost" sits right before its
                    // number, echoing the grid column this popover explains.
                    GridRow {
                        Text("total")
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(TokenFormat.compact(row.tally.total))
                            .monospacedDigit()
                        Text("est. cost")
                            .foregroundStyle(.secondary)
                        Text(UsageFormatting.money(rates.dollars(for: row.tally)))
                            .monospacedDigit()
                    }
                    .font(.caption.weight(.semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    if lines.contains(where: { !$0.listed }) {
                        Text("* not in the price feed — the standard multiple stood in.")
                    }
                    Text("The input column above is fresh input + cache writes; cached is cache reads.")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 230, alignment: .leading)
            } else {
                // A merged scope's key is agent␟account␟model; the id is the
                // model's own.
                Text("No list price for \(ConsumptionKey.model(of: row.model))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The pricing feed has no entry for this model id, so its tokens aren't in the totals.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 200, alignment: .leading)
            }
        }
        .padding(12)
    }

    private static func label(_ tokenClass: CostComponent.TokenClass) -> String {
        switch tokenClass {
        case .freshInput: "fresh input"
        case .cacheWrite5m: "cache write · 5 min"
        case .cacheWrite1h: "cache write · 1 hr"
        case .cacheRead: "cache read"
        case .output: "output"
        }
    }
}
