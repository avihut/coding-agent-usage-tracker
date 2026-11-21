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

    private static let tokenWidth = ModelBreakdownGrid.tokenColumnWidth
    private static let costWidth = ModelBreakdownGrid.costColumnWidth

    // MARK: - Outline geometry
    //
    // Every row is [chevron slot][mark][name], the chevron slot reserved even
    // where there is nothing to fold, so marks stand in columns (a prompt-only
    // agent's glyph under the others'). A child's mark sits under its
    // parent's NAME: its leading edge is the parent's plus the parent's mark
    // and one gap. A name gets what the number columns and the minimum gap
    // leave of the row (114pt at 360pt, docs/UI.md) less its own offset.

    private static let chevronSlot: CGFloat = 8
    private static let leadSpacing: CGFloat = 4
    private static let swatchSide: CGFloat = 7
    private static let agentInk: CGFloat = 9
    private static let monogramSide: CGFloat = 12

    private static func markWidth(_ node: ConsumptionOutline.Node) -> CGFloat {
        switch node.kind {
        case .agent: HarnessMark.side(ink: agentInk)
        case .account: monogramSide
        case .family, .model: swatchSide
        }
    }

    /// Where a row's name starts, from the row's own leading edge.
    private static func nameOffset(_ node: ConsumptionOutline.Node, leading: CGFloat) -> CGFloat {
        leading + chevronSlot + leadSpacing + markWidth(node) + leadSpacing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            headline
            columnHeader
            ForEach(visibleRows, id: \.node.id) { row in
                rowView(row.node, leading: row.leading, underFamily: row.underFamily)
                if !row.node.reportsTokens {
                    // Under the row's name, which sits inside the row's inset.
                    Text("\(row.node.prompts.formatted()) prompts · reports no tokens · not in the totals")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.leading, ModelBreakdownGrid.rowInset + Self.nameOffset(row.node, leading: row.leading))
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
        .padding(.top, 2)
        .padding(.bottom, 2 + ModelBreakdownGrid.headlineGap)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text(input.spansAgents ? "agent · model" : "account · model")
            Spacer(minLength: ModelBreakdownGrid.nameGap)
            HStack(spacing: ModelBreakdownGrid.columnSpacing) {
                Text("input").frame(width: Self.tokenWidth, alignment: .trailing)
                Text("cached").frame(width: Self.tokenWidth, alignment: .trailing)
                Text("output").frame(width: Self.tokenWidth, alignment: .trailing)
                Text("est. cost").frame(width: Self.costWidth, alignment: .trailing)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, ModelBreakdownGrid.rowInset)
    }

    // MARK: - Rows

    /// The open part of the tree, depth-first, each row with its leading
    /// edge (a child's mark under its parent's name) and whether its parent
    /// is a family — whose members differ only by version.
    private var visibleRows: [(node: ConsumptionOutline.Node, leading: CGFloat, underFamily: Bool)] {
        var rows: [(ConsumptionOutline.Node, CGFloat, Bool)] = []
        func walk(_ nodes: [ConsumptionOutline.Node], leading: CGFloat, underFamily: Bool) {
            for node in nodes {
                rows.append((node, leading, underFamily))
                if isOpen(node) {
                    walk(
                        node.children,
                        leading: Self.nameOffset(node, leading: leading) - Self.chevronSlot - Self.leadSpacing,
                        underFamily: isFamily(node))
                }
            }
        }
        walk(outline.roots, leading: 0, underFamily: false)
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

    private func rowView(
        _ node: ConsumptionOutline.Node, leading: CGFloat, underFamily: Bool
    ) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: Self.leadSpacing) {
                lead(node)
                nameText(node, underFamily: underFamily)
                if case .family = node.kind {
                    Text("\(node.children.count)")
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
            }
            .padding(.leading, leading)
            .layoutPriority(1)
            Spacer(minLength: ModelBreakdownGrid.nameGap)
            HStack(spacing: ModelBreakdownGrid.columnSpacing) {
                cells(node)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, ModelBreakdownGrid.rowInset)
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

    /// A name gives way rather than widen the panel: a name that insisted
    /// on its width ("Codex Auto Review" is 92.7pt) pushed the content past
    /// 360pt and collapsed EVERY section's margin (user-reported
    /// 2026-11-21). An account label (a sign-in can be long) gives way in the
    /// middle, and so does a model inside an opened family — its siblings
    /// differ only by the version at the end ("Son…4.5"), and that row is
    /// the deepest, with ~48pt for a name. Everything else gives way at the
    /// tail. Each carries its full name as a tooltip; a host with room still
    /// shows it whole.
    @ViewBuilder private func nameText(_ node: ConsumptionOutline.Node, underFamily: Bool) -> some View {
        let name = title(node)
        Text(name)
            .foregroundStyle(isGroup(node) && !isFamily(node) ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(isAccount(node) || underFamily ? .middle : .tail)
            .help(name)
    }

    private func isAccount(_ node: ConsumptionOutline.Node) -> Bool {
        if case .account = node.kind { return true }
        return false
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
        Group {
            if isGroup(node) {
                Image(systemName: isOpen(node) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            } else {
                Color.clear
            }
        }
        .frame(width: Self.chevronSlot)
        switch node.kind {
        case .agent(let agent):
            if let style = input.agents[agent]?.style {
                HarnessMark(style: style, ink: Self.agentInk)
            } else {
                Color.clear.frame(width: Self.markWidth(node), height: 1)
            }
        case .account(_, let account):
            MonogramTile(monogram: input.accountFaces[account]?.monogram ?? "?", size: Self.monogramSide)
        case .family:
            swatch(node.children.first.flatMap(firstKey))
        case .model(let key, _):
            swatch(key)
        }
    }

    private func swatch(_ key: String?) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(key.flatMap { input.colors[$0] } ?? Color.gray)
            .frame(width: Self.swatchSide, height: Self.swatchSide)
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
