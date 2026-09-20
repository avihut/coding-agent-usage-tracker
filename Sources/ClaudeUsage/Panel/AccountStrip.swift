import SwiftUI
import UsageCore

/// How the panel presents several accounts (decision D6, user-directed).
/// One account: none of this renders and the panel is exactly what it was.
enum PanelAccountForm: String, CaseIterable, Identifiable {
    /// A row per account above the meters — monogram, label, what's next,
    /// and its three meters in miniature. The row IS the selector.
    case stripRows
    /// The same selector folded to one line of monograms.
    case chips
    /// No selector: every account's meters listed one under the other.
    case stacked

    static let key = "panelAccountForm"
    static let standard: PanelAccountForm = .stripRows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stripRows: "Rows"
        case .chips: "Chips"
        case .stacked: "Stacked"
        }
    }

    var caption: String {
        switch self {
        case .stripRows: "One row per account above the meters, with its own miniature meters."
        case .chips: "A line of monograms; the panel shows the selected account."
        case .stacked: "Every account's meters, one under the other."
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> PanelAccountForm {
        defaults.string(forKey: key).flatMap(PanelAccountForm.init(rawValue:)) ?? standard
    }
}

/// The selector at the top of the panel: which accounts of which HARNESSES
/// are metered, which one the panel is showing, and one glance at where each
/// stands (v0.101.0 — the approved direction A, "one unified strip"). Absent
/// whenever fewer than two rows show — a one-account, one-harness Mac never
/// sees it — and in the stacked form, where the meters themselves carry
/// every account.
///
/// A harness with SEVERAL accounts gets a heading carrying its mark once and
/// its accounts under it as letters; a harness with one gets no heading and
/// its row wears the mark itself. Hidden harnesses are not here at all —
/// hiding is what "not interested" means — though they keep being metered.
struct AccountStrip: View {
    let registry: ProviderRegistry
    let form: PanelAccountForm
    /// Flips rows ↔ chips (the panel's own `auditToggle` idiom: one icon,
    /// since a third segmented control does not fit 360pt).
    let onSetForm: (PanelAccountForm) -> Void
    let onFocus: (String) -> Void
    /// Hands focus back to activity.
    var onAuto: () -> Void = {}

    private var profiles: [Profile] { registry.shownProfiles }

    /// The shown accounts grouped by harness, in the roster's order — the
    /// order the bar draws them in, so the strip reads top to bottom the way
    /// the bar reads left to right.
    private var groups: [(harness: HarnessStyle, name: String, profiles: [Profile])] {
        var seen: [String] = []
        for profile in profiles where !seen.contains(profile.providerID) {
            seen.append(profile.providerID)
        }
        return seen.compactMap { id in
            guard let provider = registry.providers.first(where: { $0.id == id }) else { return nil }
            let mine = profiles.filter { $0.providerID == id }
            guard !mine.isEmpty else { return nil }
            return (HarnessStyle(provider), provider.agentName, mine)
        }
    }

    var body: some View {
        if profiles.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                // The header stays in the stacked form too: it holds the
                // only in-panel way to another form (0.101.0 — it used to
                // vanish with the strip, leaving Settings as the way back).
                header
                switch form {
                case .chips: chips
                case .stripRows: rows
                case .stacked: EmptyView()
                }
            }
        }
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(groups, id: \.harness.providerID) { group in
                // The heading exists to say whose letters these are, so a
                // harness with one account — whose row carries the mark
                // itself — has none.
                if group.profiles.count > 1 {
                    HarnessHeading(style: group.harness, name: group.name)
                }
                ForEach(group.profiles, id: \.key) { profile in
                    AccountStripRow(
                        registry: registry, profile: profile,
                        lettered: group.profiles.count > 1,
                        focused: profile.key == registry.focusedID,
                        onFocus: { onFocus(profile.key) })
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            // Always "Accounts": a row is an account whatever agent it
            // belongs to, and the agent is said by its mark and its name.
            Text("Accounts")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            // A pick in the strip is for keeps (0.97.0); this is the way
            // back to focus following activity, present only while a pick
            // stands.
            if registry.pinnedID != nil {
                Button(action: onAuto) {
                    Text("Auto")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Follow activity again — the account this Mac has worked in most over the last two weeks")
            }
            Menu {
                ForEach(PanelAccountForm.allCases) { option in
                    Button {
                        onSetForm(option)
                    } label: {
                        if option == form { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                    }
                }
            } label: {
                Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerStyle(.link)
            .help("How the panel lists accounts: rows, chips, or every account's meters stacked")
        }
    }

    private var chips: some View {
        SegmentedPicker(
            title: "Account",
            selection: Binding(
                get: { registry.focusedID },
                set: { onFocus($0) }),
            options: profiles.map { profile in
                let nickname = profile.nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
                let named = !(nickname?.isEmpty ?? true)
                // A lone account of a harness is named by its vendor's mark
                // and short name ("⬡ Codex"); one of several keeps its own
                // nickname or letter (NSSegmentedControl draws one string
                // per segment, so the mark rides the label).
                let alone = profiles.filter { $0.providerID == profile.providerID }.count == 1
                let style = registry.store(for: profile.key)?.style
                    ?? registry.providers.first { $0.id == profile.providerID }
                        .map(HarnessStyle.init) ?? .bundled
                let base = named ? nickname! : registry.monogram(for: profile)
                let label = alone
                    ? "\(style.glyph) \(shortName(of: profile))" : base
                return (label, profile.key)
            })
    }

    /// The agent's first word — what a chip says when the mark stands for
    /// the whole harness ("Gemini", not "Gemini CLI", which wraps a chip).
    private func shortName(of profile: Profile) -> String {
        let agent = registry.providers.first { $0.id == profile.providerID }?.agentName ?? ""
        return agent.split(separator: " ").first.map(String.init) ?? agent
    }

    /// +1 = fingers left = the next account down the strip. The gesture
    /// itself is attached by the PANEL (an NSViewRepresentable inside this
    /// view would render as a placeholder in every headless snapshot); this
    /// is the step it performs.
    static func step(_ direction: Int, in profiles: [Profile], focusedID: String) -> String? {
        guard let index = profiles.firstIndex(where: { $0.key == focusedID }) else { return nil }
        let next = index + direction
        guard profiles.indices.contains(next) else { return nil }
        return profiles[next].id
    }
}

/// One account's row: who it is, what happens next, and its meters in
/// miniature. Clicking it focuses that account.
struct AccountStripRow: View {
    let registry: ProviderRegistry
    let profile: Profile
    /// Its harness has several accounts, so the row is identified by a
    /// LETTER under a heading that carries the mark; alone, it wears the mark
    /// itself.
    var lettered: Bool = true
    let focused: Bool
    let onFocus: () -> Void

    @State private var hovering = false

    private var store: UsageStore? { registry.store(for: profile.key) }
    /// This ROW's harness — with several metered, the mark beside an account
    /// is its own vendor's, not the focused one's (0.101.0).
    private var style: HarnessStyle {
        store?.style
            ?? registry.providers.first { $0.id == profile.providerID }
                .map(HarnessStyle.init) ?? .bundled
    }

    var body: some View {
        HStack(spacing: 8) {
            // The focused row wears the accent as a rule at its leading
            // edge — the panel's own "you are here" mark, and the one place
            // color says identity rather than risk.
            Capsule()
                .fill(focused ? AnyShapeStyle(style.accentColor) : AnyShapeStyle(.clear))
                .frame(width: 2, height: 22)
            if lettered {
                MonogramTile(monogram: registry.monogram(for: profile), focused: focused)
            } else {
                HarnessTile(style: style, focused: focused)
            }
            VStack(alignment: .leading, spacing: 1) {
                AccountRowTitle(registry: registry, profile: profile, focused: focused)
                caption
            }
            Spacer(minLength: 6)
            MiniMeterBars(
                segments: segments, stale: store?.state.isStale ?? true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(focused ? 0.07 : (hovering ? 0.04 : 0))))
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .onTapGesture(perform: onFocus)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(focused ? [.isSelected, .isButton] : .isButton)
    }

    /// "S resets in 2h · W runs out Sat" — phrased once in core, ticking
    /// every 30s like every other live caption in the panel.
    @ViewBuilder private var caption: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(captionText(now: context.date) ?? " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private func captionText(now: Date) -> String? {
        guard let store else { return nil }
        if store.isDormant { return "Dormant" }
        guard let meters = store.state.snapshot?.meters else { return "No data yet" }
        return UsageFormatting.accountStripCaption(
            meters: meters, predictions: store.predictions, now: now)
    }

    private var segments: [MenuBarSegment] {
        guard let store, let meters = store.state.snapshot?.meters else { return [] }
        return UsageFormatting.menuBarSegments(from: meters, predictions: store.predictions)
    }
}

/// The menu bar cell's three bars, in the panel — the same shape, so the
/// bar and the strip read as one vocabulary. Fills carry the risk ramp; an
/// absent meter draws no bar at all, never a zero one.
struct MiniMeterBars: View {
    let segments: [MenuBarSegment]
    var stale: Bool = false
    var barWidth: CGFloat = 22
    var barHeight: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { rank in
                if let percent = percent(rank) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(width: barWidth, height: barHeight)
                        Capsule()
                            .fill(fill(rank))
                            .frame(
                                width: max(barHeight, barWidth * CGFloat(percent) / 100),
                                height: barHeight)
                    }
                } else {
                    Color.clear.frame(width: barWidth, height: barHeight)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func percent(_ rank: Int) -> Int? {
        guard segments.indices.contains(rank) else { return nil }
        return segments[rank].percent
    }

    private func fill(_ rank: Int) -> AnyShapeStyle {
        guard !stale else { return AnyShapeStyle(.tertiary) }
        guard segments.indices.contains(rank) else { return AnyShapeStyle(.secondary) }
        let segment = segments[rank]
        if let severity = segment.severity, let color = riskColor(severity: severity) {
            return AnyShapeStyle(color)
        }
        switch segment.level {
        case .critical: return AnyShapeStyle(Color(nsColor: StatusItemRenderer.badgeRed))
        case .warning: return AnyShapeStyle(Color(nsColor: StatusItemRenderer.warningColor))
        case .normal: return AnyShapeStyle(.primary)
        }
    }
}

/// A row's name, by `registry.rowTitle`: the agent for a lone account (its
/// sign-in beside it when known), the account's own label under a heading.
struct AccountRowTitle: View {
    var registry: ProviderRegistry
    let profile: Profile
    let focused: Bool

    var body: some View {
        let name = registry.rowTitle(for: profile)
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(name.title)
                .font(.caption.weight(focused ? .semibold : .regular))
                .lineLimit(1)
                .layoutPriority(1)
            if let detail = name.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
