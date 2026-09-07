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

/// The account selector at the top of the panel: which accounts are
/// metered, which one the panel is showing, and one glance at where each
/// stands. Absent whenever fewer than two accounts show — a one-account Mac
/// never sees it — and in the stacked form, where the meters themselves
/// carry every account.
struct AccountStrip: View {
    let registry: ProviderRegistry
    let form: PanelAccountForm
    /// Flips rows ↔ chips (the panel's own `auditToggle` idiom: one icon,
    /// since a third segmented control does not fit 360pt).
    let onToggleForm: () -> Void
    let onFocus: (String) -> Void

    private var profiles: [Profile] { registry.shownProfiles }

    var body: some View {
        if profiles.count > 1, form != .stacked {
            VStack(alignment: .leading, spacing: 6) {
                header
                if form == .chips {
                    chips
                } else {
                    VStack(spacing: 2) {
                        ForEach(profiles) { profile in
                            AccountStripRow(
                                registry: registry, profile: profile,
                                focused: profile.id == registry.focusedID,
                                onFocus: { onFocus(profile.id) })
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Accounts")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onToggleForm) {
                Image(systemName: form == .chips ? "list.bullet" : "square.grid.3x1.below.line.grid.1x2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(form == .chips ? "Show a row per account" : "Fold the accounts into chips")
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
                let label = (nickname?.isEmpty ?? true)
                    ? registry.monogram(for: profile) : nickname!
                return (label, profile.id)
            })
    }

    /// +1 = fingers left = the next account down the strip. The gesture
    /// itself is attached by the PANEL (an NSViewRepresentable inside this
    /// view would render as a placeholder in every headless snapshot); this
    /// is the step it performs.
    static func step(_ direction: Int, in profiles: [Profile], focusedID: String) -> String? {
        guard let index = profiles.firstIndex(where: { $0.id == focusedID }) else { return nil }
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
    let focused: Bool
    let onFocus: () -> Void

    @State private var hovering = false

    private var store: UsageStore? { registry.store(for: profile.id) }

    var body: some View {
        HStack(spacing: 8) {
            // The focused row wears the accent as a rule at its leading
            // edge — the panel's own "you are here" mark, and the one place
            // color says identity rather than risk.
            Capsule()
                .fill(focused ? AnyShapeStyle(Color(ProviderStyle.accent)) : AnyShapeStyle(.clear))
                .frame(width: 2, height: 22)
            MonogramTile(monogram: registry.monogram(for: profile), focused: focused)
            VStack(alignment: .leading, spacing: 1) {
                Text(registry.label(for: profile))
                    .font(.caption.weight(focused ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
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
