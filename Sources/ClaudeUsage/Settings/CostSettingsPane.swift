import SwiftUI
import UsageCore

// MARK: - API Cost

/// The API-cost page: pricing feed status with a manual refresh, the list
/// rates behind the estimates, a plain-language explainer of the
/// arithmetic, and the what-if playground.
struct CostSettingsPane: View {
    var store: UsageStore

    var body: some View {
        SettingsPaneScroll {
            pricingDataCard
            ratesCard
            explainerCard
            playgroundCard
        }
        .onAppear { store.scanActivity() }
    }

    // MARK: Pricing data

    private var pricingDataCard: some View {
        SettingsCard(
            "Pricing data",
            footer: "No official pricing API exists, so list prices come from LiteLLM's community-maintained feed on raw.githubusercontent.com — a plain fetch with nothing about you attached, refreshed daily on its own."
        ) {
            infoRow("Source", sourceLabel)
            Divider()
            infoRow("Fetched", fetchedLabel)
            Divider()
            infoRow(
                "Models priced",
                "\(store.pricing.rates.count) \(store.provider.serviceName) models")
            HStack(spacing: 8) {
                Button("Refresh Now") { store.refreshPricingNow() }
                    .disabled(store.isRefreshingPricing)
                if store.isRefreshingPricing {
                    ProgressView().controlSize(.small)
                } else if let error = store.pricingRefreshError {
                    Text("Failed — \(error). Estimates keep the cached table.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private var sourceLabel: String {
        switch store.pricing.source {
        case .live: "LiteLLM community feed"
        case .bundled: "Snapshot bundled with the app"
        }
    }

    private var fetchedLabel: String {
        guard store.pricing.source == .live else { return "— (baked in at build time)" }
        let fetched = store.pricing.fetchedAt
        let absolute = fetched.formatted(date: .abbreviated, time: .shortened)
        let relative = fetched.formatted(.relative(presentation: .named))
        return "\(absolute) (\(relative))"
    }

    // MARK: Rates

    private var ratesCard: some View {
        SettingsCard(
            "List rates for your models",
            footer: "Subscription sessions cache with the 1-hour TTL, so their writes bill at the ×2 column. Models missing from the feed show — and sit out cost estimates."
        ) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Spacer()
                    Text("US$ per 1M tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                rateLine("model", ["input", "output", "cache read", "write 5m", "write 1h"], header: true)
                ForEach(ModelFamily.group(rateTableIDs)) { family in
                    ForEach(family.models, id: \.self) { model in
                        let rates = store.pricing.rates(for: model)
                        rateLine(ModelNames.display(model), [
                            perMTok(rates?.input),
                            perMTok(rates?.output),
                            perMTok(rates?.cacheRead ?? rates.map { $0.input * 0.1 }),
                            perMTok(rates?.cacheWrite ?? rates.map { $0.input * 1.25 }),
                            perMTok(rates?.cacheWrite1h ?? rates.map { $0.input * 2 }),
                        ])
                    }
                }
            }
        }
    }

    /// Every model the playground can price, plus anything seen locally
    /// even when unpriced — one table, same family order as the picker.
    private var rateTableIDs: [String] {
        var ids = seenModels
        let names = Set(ids.map(ModelNames.display))
        ids += store.pricing.rates.keys
            .filter { !Self.hasDateSuffix($0) && !names.contains(ModelNames.display($0)) }
            .sorted()
        return ids
    }

    /// One table line: the name column keeps its natural width (names never
    /// truncate), the five rate columns share the card's remaining width
    /// evenly — the table spans the card instead of hugging its left edge.
    private func rateLine(_ name: String, _ values: [String], header: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(header ? .caption2 : .callout)
                .foregroundStyle(header ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 96, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Text(value)
                    .font(header ? .caption2 : .callout.monospacedDigit())
                    .foregroundStyle(header ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func perMTok(_ perToken: Double?) -> String {
        perToken.map { String(format: "$%.2f", $0 * 1_000_000) } ?? "—"
    }

    /// Lifetime tokens per raw model id, from local transcripts.
    private var seenTotals: [String: Int] {
        var totals: [String: Int] = [:]
        for day in store.activity {
            for (model, tally) in day.models {
                totals[model, default: 0] += tally.total
            }
        }
        return totals
    }

    /// Models seen in local transcripts, heaviest lifetime usage first.
    private var seenModels: [String] {
        seenTotals
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }

    // MARK: Explainer

    private var explainerCard: some View {
        SettingsCard("How the estimate works") {
            explainer(
                "Four counters, straight from the transcripts",
                "\(store.provider.agentName) keeps a transcript of every session\(store.localActivity.map { " under \($0.displayPath)" } ?? ""), and each API response in it records four token counts. This app reads them — read-only, deduplicated per request, attributed per model and day — and multiplies by the list rates above. Nothing leaves this Mac.")
            tokenClassRows
            explainer(
                "One prompt is many requests",
                "Every tool call round-trips through the API, so a single \"fix this bug\" can be dozens of requests — and each one re-sends the entire conversation: system prompt, CLAUDE.md, history, tool results. Prompt caching is what makes that affordable. The unchanged prefix is read back at a tenth of the input price, and only what's new since the last request is written. Written once, read by every request after — which is why cache reads dwarf everything else\(readRatioText).")
            explainer(
                "Long sessions grow quadratically",
                "Each request re-reads the conversation so far, so a session's tokens scale with context size × request count — roughly the square of its length. A one-line question in a session that's been open all day still re-reads the whole day. Compaction or /clear resets the curve; a break longer than the cache TTL (an hour on a subscription, five minutes on API keys) means the next request re-writes the whole context at the write rate.")
            explainer(
                "Honest caveats",
                "These are counterfactuals — what the same usage would have billed at API list prices. A subscription doesn't bill per token, so read it as a value gauge, not an invoice. Output includes extended thinking you never see. Background housekeeping (session summaries for resume, usage checks) logs tokens too. And only local \(store.provider.agentName) sessions on this Mac are visible — web sessions and other devices aren't.")
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

    /// The four billing classes, priced relative to fresh input. Plain
    /// HStacks with fixed label columns: wrapped text gets honest heights.
    private var tokenClassRows: some View {
        VStack(alignment: .leading, spacing: 7) {
            tokenClassRow(
                "Fresh input", "×1",
                "the few tokens past the last cache breakpoint — single digits per request in practice")
            tokenClassRow(
                "Cache write", "×1.25 / ×2",
                "new context entering the cache: the previous reply plus fresh tool results (5-minute / 1-hour TTL)")
            tokenClassRow(
                "Cache read", "×0.1",
                "the whole cached conversation, re-read by every request; refreshing the TTL is free")
            tokenClassRow(
                "Output", "own rate",
                "the reply plus extended thinking — typically 5× the input rate")
        }
        .padding(.vertical, 2)
    }

    private func tokenClassRow(_ name: String, _ multiplier: String, _ meaning: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name)
                .font(.caption.weight(.medium))
                .frame(width: 82, alignment: .leading)
            Text(multiplier)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.orange)
                .frame(width: 70, alignment: .leading)
            Text(meaning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// " (about ×47 in your data)" — the live read-to-written ratio.
    private var readRatioText: String {
        var total = TokenTally()
        for day in store.activity {
            for tally in day.models.values { total.add(tally) }
        }
        guard total.uncachedInput > 0 else { return "" }
        let ratio = total.cacheRead / total.uncachedInput
        guard ratio >= 2 else { return "" }
        return " (about ×\(ratio) in your data)"
    }

    // MARK: Playground

    private var playgroundCard: some View {
        let families = playgroundFamilies
        return SettingsCard(
            "Session cost playground",
            footer: "The simulator runs the loop described above in closed form — every dial re-prices the whole session at the selected model's list rates."
        ) {
            CostPlaygroundView(
                pricing: store.pricing,
                families: families,
                initialModel: families.first?.models.first
                    ?? store.pricing.rates.keys.sorted().first ?? "")
        }
    }

    /// Priced models grouped per family for the picker — the models seen
    /// locally plus the rest of the table's base ids.
    private var playgroundFamilies: [ModelFamily] {
        var pricedIDs = seenModels.filter { store.pricing.rates(for: $0) != nil }
        let seenNames = Set(pricedIDs.map(ModelNames.display))
        pricedIDs += store.pricing.rates.keys
            .filter { !Self.hasDateSuffix($0) && !seenNames.contains(ModelNames.display($0)) }
            .sorted()
        return ModelFamily.group(pricedIDs)
    }

    /// "claude-haiku-4-5-20251001" — dated release aliases of a base id.
    private static func hasDateSuffix(_ id: String) -> Bool {
        guard let last = id.split(separator: "-").last else { return false }
        return last.count == 8 && last.allSatisfy(\.isNumber)
    }
}

/// One model family — "Opus" and its versions, newest first. Both the rates
/// table and the playground picker arrange models this way.
struct ModelFamily: Identifiable, Equatable {
    let name: String
    let models: [String]
    var id: String { name }

    /// Families ordered by model size — Fable/Mythos, Opus, Sonnet, Haiku,
    /// then everything else alphabetically; versions newest-first inside
    /// each family, unversioned previews last.
    static func group(_ ids: [String]) -> [ModelFamily] {
        var byFamily: [String: [String]] = [:]
        for id in ids {
            byFamily[familyName(id), default: []].append(id)
        }
        return byFamily
            .map { name, models in
                ModelFamily(name: name, models: models.sorted(by: versionDescending))
            }
            .sorted { a, b in
                let rankA = sizeRank(a.name)
                let rankB = sizeRank(b.name)
                return rankA != rankB ? rankA < rankB : a.name < b.name
            }
    }

    /// Larger models first — the tier ladder from the provider's catalog.
    private static func sizeRank(_ family: String) -> Int {
        ModelNames.familyRank(family)
    }

    /// "claude-opus-4-8" → "Opus". Also the model-color ledger's family key.
    static func familyName(_ id: String) -> String {
        ModelNames.family(id)
    }

    private static func versionDescending(_ a: String, _ b: String) -> Bool {
        let versionA = versionComponents(a)
        let versionB = versionComponents(b)
        if versionA == versionB { return ModelNames.display(a) < ModelNames.display(b) }
        return versionB.lexicographicallyPrecedes(versionA)
    }

    /// "Opus 4.8" → [4, 8]; "Mythos Preview" → [].
    private static func versionComponents(_ id: String) -> [Int] {
        ModelNames.display(id)
            .split(separator: " ")
            .dropFirst()
            .flatMap { $0.split(separator: ".").compactMap { Int($0) } }
    }
}
