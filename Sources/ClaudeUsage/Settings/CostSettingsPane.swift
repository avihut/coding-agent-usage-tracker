import SwiftUI
import UsageCore

// MARK: - API Cost

/// The API-cost page: pricing feed status with a manual refresh, the list
/// rates behind the estimates, a plain-language explainer of the
/// arithmetic, and the what-if playground.
struct CostSettingsPane: View {
    var store: UsageStore
    /// Rates are listed per HARNESS (0.101.0, R4), so this pane needs every
    /// detected one — not just the account it opened for.
    var registry: ProviderRegistry

    var body: some View {
        SettingsPaneScroll {
            pricingDataCard
            CostRatesCard(registry: registry)
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
            // Counted per vendor slice: one feed, several tables.
            infoRow("Models priced", pricedCounts)
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

    /// "28 Anthropic · 156 OpenAI · 70 Google" — each harness's own slice of
    /// the one feed.
    private var pricedCounts: String {
        let counts = registry.providers.compactMap { provider -> String? in
            guard let table = registry.store(ofHarness: provider.id)?.pricing,
                  !table.rates.isEmpty
            else { return nil }
            return "\(table.rates.count) \(provider.serviceName)"
        }
        return counts.isEmpty ? "—" : counts.joined(separator: " · ")
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
        SettingsCard(
            "Session cost playground",
            footer: "The simulator runs the loop described above in closed form — every dial re-prices the whole session at the selected model's list rates."
        ) {
            CostPlaygroundView(
                pricing: pricingAcrossHarnesses,
                models: playgroundModels,
                initialModel: playgroundModels.first?.id ?? "")
        }
    }

    /// Every detected harness's PRICED models, that harness's own tier
    /// order within each group — what the search picker ranks over.
    private var playgroundModels: [PricedModel] {
        CostRatesCard.pricedModels(registry: registry)
    }

    /// One table spanning every harness, so the simulator can price whatever
    /// the picker offers. Ids are vendor-unique, so the union cannot collide.
    private var pricingAcrossHarnesses: PricingTable {
        var rates: [String: ModelRates] = [:]
        for provider in registry.providers {
            let table = registry.store(ofHarness: provider.id)?.pricing ?? provider.bundledRates
            rates.merge(table.rates) { first, _ in first }
        }
        return PricingTable(
            rates: rates, fetchedAt: store.pricing.fetchedAt, source: store.pricing.source)
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
