import SwiftUI
import UsageCore

/// The per-model usage table shared by the activity summary, the day
/// drill-down, and the meter popovers: a headline cost total over aligned
/// input/cached/output/cost columns. Rows double as a legend — each carries
/// its model's color, and hovering a row filters the chart above to that
/// model via the bound `hoveredModel`.
struct ModelBreakdownGrid: View {
    let rows: [ModelTokenUsage]
    let colors: [String: Color]
    let pricing: PricingTable
    @Binding var hoveredModel: String?

    private static let tokenColumnWidth: CGFloat = 44
    private static let costColumnWidth: CGFloat = 54

    var body: some View {
        let priced = rows.map { row in (row: row, rates: pricing.rates(for: row.model)) }
        let total = priced.compactMap { $0.rates?.dollars(for: $0.row.tally) }.reduce(0, +)
        let unpricedCount = priced.count(where: { $0.rates == nil })
        VStack(alignment: .leading, spacing: 2) {
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
            .padding(.vertical, 2)
            columnHeader
            ForEach(priced, id: \.row.id) { entry in
                modelRow(entry.row, rates: entry.rates)
            }
        }
        .padding(.top, 2)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("model")
            Spacer(minLength: 8)
            Text("input").frame(width: Self.tokenColumnWidth, alignment: .trailing)
            Text("cached").frame(width: Self.tokenColumnWidth, alignment: .trailing)
            Text("output").frame(width: Self.tokenColumnWidth, alignment: .trailing)
            Text("est. cost").frame(width: Self.costColumnWidth, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    private func modelRow(_ row: ModelTokenUsage, rates: ModelRates?) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(colors[row.model] ?? Color.gray)
                    .frame(width: 7, height: 7)
                // Names never truncate — the host surface is sized to fit.
                Text(row.displayName)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Spacer(minLength: 8)
            // "input" is what was processed anew; the conversation history
            // re-read from cache on every request stands apart as "cached" —
            // lumping them reads as absurd typed-prompt volume.
            Text(TokenFormat.compact(row.tally.uncachedInput))
                .frame(width: Self.tokenColumnWidth, alignment: .trailing)
            Text(TokenFormat.compact(row.tally.cacheRead))
                .frame(width: Self.tokenColumnWidth, alignment: .trailing)
            Text(TokenFormat.compact(row.tally.output))
                .frame(width: Self.tokenColumnWidth, alignment: .trailing)
            Text(rates.map { UsageFormatting.money($0.dollars(for: row.tally)) } ?? "—")
                .frame(width: Self.costColumnWidth, alignment: .trailing)
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(hoveredModel == row.model ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hoveredModel = row.model
            } else if hoveredModel == row.model {
                hoveredModel = nil
            }
        }
    }
}
