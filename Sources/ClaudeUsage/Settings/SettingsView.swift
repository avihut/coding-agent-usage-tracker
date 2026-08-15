import ServiceManagement
import SwiftUI
import UsageCore

/// Bindings shared by the panel's ⋯ menu and the settings window — two
/// surfaces, one behavior.
enum SettingsBindings {
    /// The ⋯ menu's quick paces. No 1-minute option: sustained sub-3-minute
    /// polling trips the endpoint's rate limiter (anthropics/claude-code#31637).
    static let intervalPresets: [Double] = [180, 300, 900]

    /// A slider-chosen in-between pace joins the menu list as an extra
    /// entry, so the picker never shows an empty selection.
    static func menuIntervalChoices(current: Double) -> [Double] {
        intervalPresets.contains(current)
            ? intervalPresets
            : (intervalPresets + [current]).sorted()
    }

    @MainActor
    static func interval(_ store: UsageStore) -> Binding<Double> {
        Binding(
            get: { store.activeInterval },
            set: { store.setActiveInterval($0) }
        )
    }

    /// Registration happens only when the user flips this toggle (spec §10).
    @MainActor
    static func launchAtLogin() -> Binding<Bool> {
        Binding(
            get: { LoginItemState.shared.enabled },
            set: { enabled in
                if enabled {
                    try? SMAppService.mainApp.register()
                } else {
                    try? SMAppService.mainApp.unregister()
                }
                // Read back rather than trust the flip — registration can
                // land as .requiresApproval or fail quietly.
                LoginItemState.shared.refresh()
            }
        )
    }
}

/// Observable mirror of the login-item registration. SMAppService posts no
/// change notifications, and a Binding computed straight off it never
/// invalidates SwiftUI — the ⋯ menu's pre-built NSMenu kept rendering its
/// first read, so the checkmark never appeared. Only the mirror is new;
/// registration still happens exclusively on the user's flip.
@MainActor @Observable
final class LoginItemState {
    static let shared = LoginItemState()
    private(set) var enabled = SMAppService.mainApp.status == .enabled

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, usage, apiCost

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .usage: "Usage"
        case .apiCost: "API Cost"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .usage: "chart.xyaxis.line"
        case .apiCost: "dollarsign.circle"
        }
    }
}

/// The settings window: sidebar navigation on the left, one pane on the
/// right — general behavior, and the API-cost page (where the pricing data
/// comes from, how the estimate is computed, and a what-if playground).
struct SettingsView: View {
    var store: UsageStore
    var registry: ProviderRegistry

    @State private var section: SettingsSection?

    init(
        store: UsageStore, registry: ProviderRegistry,
        initialSection: SettingsSection = .general
    ) {
        self.store = store
        self.registry = registry
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(SettingsSection.allCases) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch section ?? .general {
            case .general: GeneralSettingsPane(store: store, registry: registry)
            case .usage: UsageSettingsPane(store: store)
            case .apiCost: CostSettingsPane(store: store)
            }
        }
        // A settings window's sidebar is permanent — no collapse toggle.
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 760, minHeight: 600)
    }
}

// MARK: - Card scaffolding

/// One settings section: header, rounded card, optional footnote. Hand-
/// rolled instead of `Form(.grouped)` because grouped forms column-align
/// bare controls (the slider got squeezed into the trailing half-column
/// while its mark labels spanned the row) and mis-measure wrapped text in
/// custom rows (the token-class grid overlapped its neighbors). A plain
/// VStack card gives every row the full width and honest heights.
/// Shared by every pane file, so internal rather than private.
struct SettingsCard<Content: View>: View {
    let title: String
    let footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Scrollable stack of cards, capped at a readable measure and centered.
struct SettingsPaneScroll<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }
    }
}

/// "Label ......... value" — the card version of LabeledContent.
func infoRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Text(label)
        Spacer(minLength: 16)
        Text(value)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }
}

func note(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - General

private struct GeneralSettingsPane: View {
    var store: UsageStore
    var registry: ProviderRegistry
    /// Idle tolerance for the popover activity strips.
    @AppStorage(ActivityGrace.storageKey)
    private var graceSeconds = ActivityGrace.defaultSeconds
    /// Claude Code's own transcript retention, mirrored from — and
    /// written back to — ~/.claude/settings.json.
    // Placeholder until onAppear mirrors the agent's own stored value.
    @State private var retentionDays = 30
    @State private var retentionWriteFailed = false
    /// What the transcripts weigh on disk, measured once per appearance
    /// off the main thread.
    @State private var diskUsage: TranscriptDiskUsage?
    /// The percent cutoffs behind DisplayLevel, seeded from defaults on
    /// appearance; edits write through and re-classify the live snapshot.
    @State private var warningPercent = Thresholds.standard.warningPercent
    @State private var criticalPercent = Thresholds.standard.criticalPercent

    private var meteringSelection: Binding<String> {
        Binding(
            get: { registry.selection },
            set: { registry.select($0) })
    }

    private func harnessName(_ id: String) -> String {
        registry.presentChoices.first { $0.id == id }?.name ?? id
    }

    private func signalText(_ signal: HarnessSignal) -> String {
        if signal.recentFiles > 0 {
            return "\(signal.recentFiles) session files in the last 14 days"
        }
        if let newest = signal.newestActivity {
            return "quiet — last active \(newest.formatted(date: .abbreviated, time: .omitted))"
        }
        return "no sessions found"
    }

    var body: some View {
        SettingsPaneScroll {
            SettingsCard("Metering") {
                HStack(alignment: .firstTextBaseline) {
                    Text("Harness")
                    Spacer()
                    Picker("Harness", selection: meteringSelection) {
                        Text(registry.automaticLabel).tag(ProviderRegistry.automatic)
                        ForEach(registry.presentChoices) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                ForEach(registry.signals.filter(\.present), id: \.id) { signal in
                    infoRow(harnessName(signal.id), signalText(signal))
                }
                note("Automatic follows whichever agent actually ran on this Mac recently — scored on session files, since background daemons touch state files long after real use stops. One harness is metered at a time; switching re-reads everything from the other harness's own data.")
            }
            SettingsCard("Refresh") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Refresh when active")
                        Spacer()
                        Text(UsageFormatting.duration(store.activeInterval))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    MarkedSlider(
                        seconds: SettingsBindings.interval(store),
                        marks: RefreshIntervalScale.marks,
                        position: RefreshIntervalScale.position(of:),
                        value: RefreshIntervalScale.value(at:))
                }
                note("The pace while the agent is in use — the slider snaps to the marked stops, or lands anywhere between. Quiet stretches slow polling down on their own (to one poll per hour, or your chosen pace when that's slower) and fresh activity snaps it back. Nothing polls faster than once per 3 minutes — the usage endpoint rate-limits harder polling.")
            }
            SettingsCard("Thresholds") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Warning at")
                        Spacer()
                        Text("\(warningPercent)%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                    Slider(value: warningBinding, in: 30...95, step: 5)
                        .controlSize(.small)
                    HStack(alignment: .firstTextBaseline) {
                        Text("Error at")
                        Spacer()
                        Text("\(criticalPercent)%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                    Slider(value: criticalBinding, in: 35...100, step: 5)
                        .controlSize(.small)
                }
                note("Where the percent scale itself turns worrying: meters and the menu bar wear the warning color from the first cutoff and the error color from the second. The exhaustion forecast colors on its own yellow→red ramp and isn't affected. The two keep at least 5% apart.")
            }
            SettingsCard("Activity") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Session grace period")
                        Spacer()
                        Text(graceSeconds == 0 ? "Off" : UsageFormatting.duration(graceSeconds))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    MarkedSlider(
                        seconds: $graceSeconds,
                        marks: ActivityGraceScale.marks,
                        position: ActivityGraceScale.position(of:),
                        value: ActivityGraceScale.value(at:),
                        label: { $0 == 0 ? "off" : UsageFormatting.duration($0) })
                }
                note("The activity strips under the popover charts bridge idle gaps shorter than this — the agent waiting while you read or type a reply still counts as the same working session. Slide to off to mark only the moments it was producing tokens.")
            }
            if let agentSettings = store.provider.agentSettings {
                SettingsCard(store.provider.agentName) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Transcript retention")
                            Spacer()
                            Picker("Transcript retention", selection: retentionBinding) {
                                ForEach(retentionChoices, id: \.self) { days in
                                    Text(retentionLabel(days)).tag(days)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        if retentionWriteFailed {
                            Text("Couldn't update \(agentSettings.displayPath) — its current content didn't parse, so it was left untouched.")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        if let diskUsage {
                            Divider()
                            infoRow(
                                "On disk now",
                                "\(Self.byteText(diskUsage.bytes)) · \(diskUsage.days) days of transcripts")
                            infoRow(
                                "Projected at \(retentionLabel(retentionDays))",
                                "≈ \(Self.byteText(diskUsage.projectedBytes(forDays: retentionDays)))")
                        }
                    }
                    note("How long \(store.provider.agentName) keeps local transcripts (its \(agentSettings.retentionKeyName) setting — this control reads and writes \(agentSettings.displayPath) directly, the app's one write there). The heatmap and per-model history come from those transcripts, so longer retention keeps more history — and more disk: the projection scales what today's holdings weigh per day to the chosen window. Takes effect when \(store.provider.agentName) next runs.")
                }
            }
            SettingsCard("Startup") {
                Toggle("Launch at login", isOn: SettingsBindings.launchAtLogin())
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            SettingsCard("About") {
                infoRow("Version", "v\(AppIdentity.version)")
                Divider()
                infoRow(
                    "Network destinations",
                    (store.provider.networkDestinations + ["raw.githubusercontent.com"])
                        .joined(separator: " · "))
                note("Usage comes from \(store.provider.serviceName)'s own usage endpoint; activity and tokens from this Mac's local \(store.provider.agentName) transcripts, read-only. No analytics, no telemetry.")
            }
        }
        .onAppear {
            LoginItemState.shared.refresh()
            let thresholds = UsageStore.currentThresholds()
            warningPercent = thresholds.warningPercent
            criticalPercent = thresholds.criticalPercent
            if let agentSettings = store.provider.agentSettings {
                retentionDays = agentSettings.readRetentionDays()
                    ?? agentSettings.defaultRetentionDays
            }
            if let source = store.localActivity {
                Task.detached(priority: .utility) {
                    let usage = source.diskUsage(now: Date())
                    await MainActor.run { diskUsage = usage }
                }
            }
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static func byteText(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    /// Both sliders write through and keep a 5-point gap by pushing the
    /// other cutoff along rather than colliding with it.
    private var warningBinding: Binding<Double> {
        Binding(
            get: { Double(warningPercent) },
            set: { newValue in
                warningPercent = Int(newValue.rounded())
                criticalPercent = max(criticalPercent, warningPercent + 5)
                persistThresholds()
            })
    }

    private var criticalBinding: Binding<Double> {
        Binding(
            get: { Double(criticalPercent) },
            set: { newValue in
                criticalPercent = Int(newValue.rounded())
                warningPercent = min(warningPercent, criticalPercent - 5)
                persistThresholds()
            })
    }

    private func persistThresholds() {
        UserDefaults.standard.set(warningPercent, forKey: UsageStore.warningThresholdKey)
        UserDefaults.standard.set(criticalPercent, forKey: UsageStore.criticalThresholdKey)
        store.thresholdsChanged()
    }

    /// Selection writes straight through to the agent's settings file —
    /// binding-set, not onChange, so the onAppear mirror never triggers a
    /// write.
    private var retentionBinding: Binding<Int> {
        Binding(
            get: { retentionDays },
            set: { days in
                retentionDays = days
                retentionWriteFailed =
                    !(store.provider.agentSettings?.writeRetentionDays(days) ?? false)
            })
    }

    /// The stock ladder, plus whatever custom value the file already
    /// holds so the picker never misrepresents it.
    private var retentionChoices: [Int] {
        let standard = [30, 60, 90, 180, 365, 730]
        return standard.contains(retentionDays)
            ? standard : (standard + [retentionDays]).sorted()
    }

    private func retentionLabel(_ days: Int) -> String {
        switch days {
        case 365: return "1 year"
        case 730: return "2 years"
        default: return "\(days) days"
        }
    }
}

// MARK: - API Cost

/// The API-cost page: pricing feed status with a manual refresh, the list
/// rates behind the estimates, a plain-language explainer of the
/// arithmetic, and the what-if playground.
private struct CostSettingsPane: View {
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

// MARK: - Marked slider

/// A native slider over a marked scale's track — the refresh pace and the
/// activity grace period both draw through this, wired to their own scale's
/// position/value math. Mark labels sit at their true track positions
/// (compensating for the knob's end insets so labels line up with where the
/// thumb actually stops).
private struct MarkedSlider: View {
    @Binding var seconds: Double
    let marks: [Double]
    let position: (Double) -> Double
    let value: (Double) -> Double
    var label: (Double) -> String = { UsageFormatting.duration($0) }

    /// Half the NSSlider knob: the track is inset this much per side.
    private static let thumbInset: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            Slider(value: positionBinding, in: 0...1)
            // Notches: taller at the magnetic stops; each span between stops
            // subdivided evenly so the minor ticks keep one steady rhythm
            // across the whole track (they're ruler marks, not values).
            Canvas { context, size in
                let usable = size.width - 2 * Self.thumbInset
                let majors = marks.map(position)
                let targetStep = 0.0375
                for (p0, p1) in zip(majors, majors.dropFirst()) {
                    let count = max(1, Int(((p1 - p0) / targetStep).rounded()))
                    for i in 1..<count {
                        let p = p0 + (p1 - p0) * Double(i) / Double(count)
                        let x = Self.thumbInset + p * usable
                        context.fill(
                            Path(CGRect(x: x - 0.5, y: 2, width: 1, height: 4)),
                            with: .color(.primary.opacity(0.18)))
                    }
                }
                for p in majors {
                    let x = Self.thumbInset + p * usable
                    context.fill(
                        Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: 7)),
                        with: .color(.primary.opacity(0.38)))
                }
            }
            .frame(height: 8)
            GeometryReader { geo in
                let usable = geo.size.width - 2 * Self.thumbInset
                ForEach(marks, id: \.self) { mark in
                    let x = Self.thumbInset + position(mark) * usable
                    Text(label(mark))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .position(x: min(max(x, 16), geo.size.width - 14), y: 7)
                }
            }
            .frame(height: 14)
        }
    }

    /// The slider drags in normalized track space; the binding round-trips
    /// through the scale so the thumb visibly snaps onto a mark.
    private var positionBinding: Binding<Double> {
        Binding(
            get: { position(seconds) },
            set: { seconds = value($0) }
        )
    }
}
