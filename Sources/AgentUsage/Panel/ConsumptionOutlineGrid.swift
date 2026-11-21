import SwiftUI
import UsageCore

/// The breakdown table of a merged consumption scope — `ModelBreakdownGrid`'s
/// columns and headline, its rows an outline: agent ▸ account ▸ (family ▸)
/// model, each level present only where it says something (see core
/// `ConsumptionOutline`). Agent and account rows start open — the rows are
/// the bars' legend; family rows start folded. Rows still act as the legend:
/// hovering any row highlights exactly the chart keys it counts, and a
/// model row's click opens its cost math, as in the per-model table.
///
/// Hover rides `HoverProbe`, not `.onHover`: a row that presents a popover
/// never gets SwiftUI hover back once it has (CLAUDE.md), and here the rows
/// ARE the chart's legend.
struct ConsumptionOutlineGrid: View {
    let outline: ConsumptionOutline
    let input: ConsumptionInput
    @Binding var hoveredNode: ConsumptionOutline.Node?
    /// A model key lit from elsewhere — the day ring's hovered sector — so
    /// ring and row light together, as with the per-model table.
    var litModel: String? = nil
    @State private var folded: Set<String> = []
    @State private var openFamilies: Set<String> = []
    @State private var costDetail: String?

    private static let indent: CGFloat = 8
    private static let tokenWidth = ModelBreakdownGrid.tokenColumnWidth
    private static let costWidth = ModelBreakdownGrid.costColumnWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headline
            columnHeader
            ForEach(visibleRows, id: \.node.id) { row in
                rowView(row.node, depth: row.depth)
                if !row.node.reportsTokens {
                    Text("\(row.node.prompts.formatted()) prompts · reports no tokens · not in the totals")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4 + CGFloat(row.depth + 1) * Self.indent + 12)
                }
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Headline and header

    private var headline: some View {
        VStack(spacing: 0) {
            Text(outline.cost.map { "≈ \(UsageFormatting.money($0))" } ?? "—")
                .font(.system(size: 18, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(outline.unpriced > 0
                ? "at API list prices · \(outline.unpriced) unpriced"
                : "at API list prices")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text(input.spansAgents ? "agent · model" : "account · model")
            Spacer(minLength: 8)
            Text("input").frame(width: Self.tokenWidth, alignment: .trailing)
            Text("cached").frame(width: Self.tokenWidth, alignment: .trailing)
            Text("output").frame(width: Self.tokenWidth, alignment: .trailing)
            Text("est. cost").frame(width: Self.costWidth, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    // MARK: - Rows

    /// The open part of the tree, depth-first.
    private var visibleRows: [(node: ConsumptionOutline.Node, depth: Int)] {
        var rows: [(ConsumptionOutline.Node, Int)] = []
        func walk(_ nodes: [ConsumptionOutline.Node], depth: Int) {
            for node in nodes {
                rows.append((node, depth))
                if isOpen(node) { walk(node.children, depth: depth + 1) }
            }
        }
        walk(outline.roots, depth: 0)
        return rows
    }

    private func isOpen(_ node: ConsumptionOutline.Node) -> Bool {
        if case .family = node.kind { return openFamilies.contains(node.id) }
        return !folded.contains(node.id)
    }

    private func toggle(_ node: ConsumptionOutline.Node) {
        if case .family = node.kind {
            if openFamilies.contains(node.id) { openFamilies.remove(node.id) } else { openFamilies.insert(node.id) }
        } else if folded.contains(node.id) {
            folded.remove(node.id)
        } else {
            folded.insert(node.id)
        }
    }

    private func rowView(_ node: ConsumptionOutline.Node, depth: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                lead(node)
                nameText(node, depth: depth)
                if case .family = node.kind {
                    Text("\(node.children.count)")
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, CGFloat(depth) * Self.indent)
            .layoutPriority(1)
            Spacer(minLength: 4)
            cells(node)
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(isLit(node) ? 0.07 : 0)))
        // The per-model table's hit-tiling: half the row gap added around
        // the hit shape and taken back from layout, so the chart's focus
        // never flickers off between rows.
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .background(HoverProbe { inside in
            if inside {
                hoveredNode = node
            } else if hoveredNode?.id == node.id {
                hoveredNode = nil
            }
        })
        // Only rows that do something on a click say so: a group folds, a
        // model opens its cost math; a row with neither (an agent that
        // reports no tokens) is information only.
        .pointerStyle(isGroup(node) || isModel(node) ? .link : nil)
        .onTapGesture {
            if isGroup(node) {
                toggle(node)
            } else if isModel(node) {
                costDetail = node.id
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isGroup(node) || isModel(node) ? .isButton : [])
        .accessibilityValue(isGroup(node) ? (isOpen(node) ? "expanded" : "collapsed") : "")
        .popover(
            isPresented: Binding(
                get: { costDetail == node.id },
                set: { if !$0 { costDetail = nil } }),
            arrowEdge: .bottom
        ) {
            if case .model(let key, _) = node.kind {
                CostMathView(
                    row: ModelTokenUsage(model: key, tally: node.tally),
                    rates: input.pricing.rates(for: key))
            }
        }
        .padding(.vertical, -1)
    }

    /// Names at the outline's first two levels never truncate — the
    /// per-model table's rule. An account label (a sign-in can be long) gives
    /// way in the middle, and a model name nested under an account at the
    /// tail, rather than shove the number columns out of the 360pt panel;
    /// either carries its full name as a tooltip.
    @ViewBuilder private func nameText(_ node: ConsumptionOutline.Node, depth: Int) -> some View {
        let name = title(node)
        let text = Text(name)
            .foregroundStyle(isGroup(node) && !isFamily(node) ? .primary : .secondary)
        switch node.kind {
        case .account:
            text.lineLimit(1).truncationMode(.middle).help(name)
        case .model, .family:
            if depth >= 2 {
                text.lineLimit(1).truncationMode(.tail).help(name)
            } else {
                text.fixedSize(horizontal: true, vertical: false)
            }
        case .agent:
            text.fixedSize(horizontal: true, vertical: false)
        }
    }

    private func isLit(_ node: ConsumptionOutline.Node) -> Bool {
        if hoveredNode?.id == node.id || costDetail == node.id { return true }
        if let litModel, case .model(let key, _) = node.kind { return key == litModel }
        return false
    }

    private func isModel(_ node: ConsumptionOutline.Node) -> Bool {
        if case .model = node.kind { return true }
        return false
    }

    @ViewBuilder private func lead(_ node: ConsumptionOutline.Node) -> some View {
        if isGroup(node) {
            Image(systemName: isOpen(node) ? "chevron.down" : "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.tertiary)
                .frame(width: 8)
        }
        switch node.kind {
        case .agent(let agent):
            if let style = input.agents[agent]?.style {
                HarnessMark(style: style, ink: 9)
            }
        case .account(_, let account):
            MonogramTile(monogram: input.accountFaces[account]?.monogram ?? "?", size: 12)
        case .family:
            swatch(node.children.first.flatMap(firstKey))
        case .model(let key, _):
            swatch(key)
        }
    }

    private func swatch(_ key: String?) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(key.flatMap { input.colors[$0] } ?? Color.gray)
            .frame(width: 7, height: 7)
    }

    private func firstKey(_ node: ConsumptionOutline.Node) -> String? {
        if case .model(let key, _) = node.kind { return key }
        return node.children.first.flatMap(firstKey)
    }

    @ViewBuilder private func cells(_ node: ConsumptionOutline.Node) -> some View {
        if node.reportsTokens {
            Text(TokenFormat.compact(node.tally.uncachedInput))
                .frame(width: Self.tokenWidth, alignment: .trailing)
            Text(TokenFormat.compact(node.tally.cacheRead))
                .frame(width: Self.tokenWidth, alignment: .trailing)
            Text(TokenFormat.compact(node.tally.output))
                .frame(width: Self.tokenWidth, alignment: .trailing)
        } else {
            ForEach(0..<3, id: \.self) { _ in
                Text("—").frame(width: Self.tokenWidth, alignment: .trailing)
            }
        }
        // Absent ≠ zero: a node with nothing priced under it reads "—".
        Text(node.cost.map { UsageFormatting.money($0) } ?? "—")
            .frame(width: Self.costWidth, alignment: .trailing)
    }

    private func isGroup(_ node: ConsumptionOutline.Node) -> Bool {
        if case .model = node.kind { return false }
        return !node.children.isEmpty
    }

    private func isFamily(_ node: ConsumptionOutline.Node) -> Bool {
        if case .family = node.kind { return true }
        return false
    }

    private func title(_ node: ConsumptionOutline.Node) -> String {
        input.title(for: node)
    }
}

extension ConsumptionInput {
    /// What a row (or the hover stats line) calls a node.
    func title(for node: ConsumptionOutline.Node) -> String {
        switch node.kind {
        case .agent(let agent): agents[agent]?.name ?? agent
        case .account(_, let account): accountFaces[account]?.label ?? account
        case .family(let family): family
        case .model(_, let model): ModelNames.display(model)
        }
    }
}
