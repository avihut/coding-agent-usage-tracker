import SwiftUI
import UsageCore

/// List rates, one group per harness found on this Mac (v0.101.0, R4:
/// "allows seeing a list of the model costs of the different providers
/// according to the detected harnesses"). A harness the person HID keeps its
/// group — hiding is about the bar and the panel, and the user said so
/// explicitly: "No — keep all detected harnesses in the Rates list."
///
/// Each group is one vendor's own slice of the feed, priced by that vendor's
/// own table, named in that vendor's own grammar. The column set is shared,
/// and a class a vendor does not bill (OpenAI and Google write no cache)
/// reads "—" — absent, never $0.
struct CostRatesCard: View {
    var registry: ProviderRegistry

    /// Which harnesses the person has unfolded. A vendor's slice of the feed
    /// is not its agent's model list — OpenAI's holds ~180 entries, audio and
    /// embeddings included — so the models this Mac has actually RUN are
    /// always listed and the rest fold away until asked for.
    @State private var unfolded: Set<String> = []
    /// Beyond this many unseen models, the tail folds.
    private static let foldBeyond = 12

    var body: some View {
        SettingsCard(
            "List rates by harness",
            footer: "One group per harness found on this Mac — a harness hidden from display keeps its group. Claude subscription sessions cache with the 1-hour TTL, so their writes bill at the ×2 column; OpenAI and Google bill no cache-write class. Models missing from the feed show — and sit out cost estimates."
        ) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Spacer()
                    Text("US$ per 1M tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { Divider() }
                    header(group)
                    RateLine("model", ["input", "output", "cache read", "write 5m", "write 1h"], header: true)
                    ForEach(rows(of: group), id: \.self) { model in
                        let rates = group.pricing.rates(for: model)
                        RateLine(ModelNames.display(model), [
                            Self.perMTok(rates?.input),
                            Self.perMTok(rates?.output),
                            Self.perMTok(rates?.cacheRead),
                            Self.perMTok(rates?.cacheWrite),
                            Self.perMTok(rates?.cacheWrite1h),
                        ])
                    }
                    if let hidden = folded(group) {
                        Button {
                            unfolded.insert(group.id)
                        } label: {
                            Text("Show all \(group.models.count) priced models")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .pointerStyle(.link)
                        .help("\(hidden) more \(group.serviceName) models the feed prices")
                    }
                }
            }
        }
    }

    private func header(_ group: HarnessRates) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(group.style.glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(group.style.accentColor)
                .frame(width: 16)
            Text(group.agentName)
                .font(.caption.weight(.semibold))
            Text(group.serviceName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 6)
            if !group.shown {
                Text("hidden from the bar and panel")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// One harness's rates, in the order its own catalog ranks them.
    struct HarnessRates: Identifiable {
        let id: String
        let style: HarnessStyle
        let agentName: String
        /// The vendor behind the agent — "Anthropic" for Claude Code.
        let serviceName: String
        let shown: Bool
        let pricing: PricingTable
        /// Every priced model, in its vendor's own tier order.
        let models: [String]
        /// How many of them this Mac has actually run — always listed.
        let seen: Int
    }

    /// The rows drawn for a group: the models it has run, plus the rest once
    /// the tail is short enough not to bury them, or once it is unfolded.
    private func rows(of group: HarnessRates) -> [String] {
        guard folded(group) != nil else { return group.models }
        return Array(group.models.prefix(max(group.seen, 1)))
    }

    /// How many models a group is hiding, or nil when it hides none.
    private func folded(_ group: HarnessRates) -> Int? {
        guard !unfolded.contains(group.id) else { return nil }
        let hidden = group.models.count - max(group.seen, 1)
        return hidden > Self.foldBeyond ? hidden : nil
    }

    /// EVERY detected harness, in the roster's order, each with the models it
    /// has actually seen first and the rest of its priced table after them.
    private var groups: [HarnessRates] {
        registry.providers.compactMap { provider in
            let store = registry.store(ofHarness: provider.id)
            guard let listed = registry.harnesses.first(where: { $0.id == provider.id }) else {
                // Before the first digest lands, this process can speak only
                // for a harness it already has a face for.
                guard let store else { return nil }
                return rates(provider: provider, shown: true, store: store)
            }
            return rates(provider: provider, shown: listed.shown, store: store)
        }
    }

    private func rates(
        provider: any UsageProvider, shown: Bool, store: UsageStore?
    ) -> HarnessRates {
        let pricing = store?.pricing ?? provider.bundledRates
        let seen = store.map(Self.seenModels) ?? []
        let ids = Self.tableIDs(store: store, pricing: pricing)
        // Seen models keep their heaviest-first order at the front; the rest
        // follow in the vendor's tier order.
        let tail = ModelFamily.group(ids.filter { !seen.contains($0) })
            .flatMap(\.models)
        return HarnessRates(
            id: provider.id, style: HarnessStyle(provider), agentName: provider.agentName,
            serviceName: provider.serviceName, shown: shown, pricing: pricing,
            models: seen.filter(ids.contains) + tail, seen: seen.filter(ids.contains).count)
    }

    /// The models this harness has actually run, heaviest first, then the
    /// rest of its priced table — minus the dated aliases of ids already
    /// listed, which would double every row.
    static func tableIDs(store: UsageStore?, pricing: PricingTable) -> [String] {
        var ids = store.map(seenModels) ?? []
        let names = Set(ids.map(ModelNames.display))
        ids += pricing.rates.keys
            .filter { !hasDateSuffix($0) && !names.contains(ModelNames.display($0)) }
            .sorted()
        return ids
    }

    private static func seenModels(_ store: UsageStore) -> [String] {
        var totals: [String: Int] = [:]
        for day in store.activity {
            for (model, usage) in day.models { totals[model, default: 0] += usage.total }
        }
        return totals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }

    /// "claude-haiku-4-5-20251001" — a dated release alias of a base id.
    static func hasDateSuffix(_ id: String) -> Bool {
        guard let last = id.split(separator: "-").last else { return false }
        return last.count == 8 && last.allSatisfy(\.isNumber)
    }

    /// Every detected harness's PRICED models for the search picker, in the
    /// roster's order and each harness's own tier order — the same order the
    /// rates table lists them in, so the two read alike.
    @MainActor
    static func pricedModels(registry: ProviderRegistry) -> [PricedModel] {
        registry.providers.flatMap { provider -> [PricedModel] in
            let store = registry.store(ofHarness: provider.id)
            let pricing = store?.pricing ?? provider.bundledRates
            let style = HarnessStyle(provider)
            return ModelFamily.group(tableIDs(store: store, pricing: pricing))
                .flatMap { family in
                    family.models.compactMap { id -> PricedModel? in
                        // A model the feed does not price has nothing for the
                        // simulator to work with, so it is not offered.
                        guard pricing.rates(for: id) != nil else { return nil }
                        return PricedModel(
                            id: id, display: ModelNames.display(id), family: family.name,
                            harnessID: provider.id, harnessName: provider.agentName, style: style)
                    }
                }
        }
    }

    /// Feed rates are per token; the table is per million, two decimals, and
    /// a class the vendor does not bill is ABSENT — never $0.00.
    static func perMTok(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        return "$\(String(format: "%.2f", rate * 1_000_000))"
    }
}

/// One table line: the name column keeps its natural width (names never
/// truncate), the five rate columns share the rest.
struct RateLine: View {
    let name: String
    let values: [String]
    var header = false

    init(_ name: String, _ values: [String], header: Bool = false) {
        self.name = name
        self.values = values
        self.header = header
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(header ? .caption2 : .caption)
                .foregroundStyle(header ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(header ? .caption2 : .caption)
                    .monospacedDigit()
                    .foregroundStyle(header ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    // Rates are short and of known shape, so they take a
                    // fixed column and the NAME keeps the rest: a model's
                    // name is the one thing here that must not truncate.
                    .frame(width: 74, alignment: .trailing)
            }
        }
    }
}
