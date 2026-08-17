import AppKit
import SwiftUI
import UsageCore

// MARK: - Sidebar row

/// One session's nutrition card: title + cost, place + when, models + counts.
/// One session's "nutrition card". Internal, not private: the panel's
/// shortlist presents the exact same card, so the two surfaces can never
/// drift apart. The rename affordance is opt-in per surface: the sessions
/// sidebar passes handlers and its titles become click-to-rename; the
/// shortlist passes none, because there the WHOLE row is click-to-open and
/// a title tap must not swallow that.
struct SessionRow: View {
    let session: SessionSummary
    let cost: (dollars: Double, unpricedModels: Int)
    let colors: [String: Color]
    /// The list's active sort axis. The card's top-right KPI presents it,
    /// so comparing along the sort never requires reading the fine print;
    /// surfaces without an ordering (the shortlist) default to cost.
    var sortKey: SessionSortKey = .recency
    var isEditingTitle = false
    var onBeginRename: (() -> Void)? = nil
    var onCommitRename: ((String) -> Void)? = nil
    var onCancelRename: (() -> Void)? = nil

    @State private var draft = ""
    @FocusState private var titleFocused: Bool
    @State private var titleHovered = false
    /// The rename click, window coordinates — the caret lands on the
    /// clicked character once the text field takes focus.
    @State private var clickPoint: CGPoint?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title
                Spacer(minLength: 4)
                keyValue
            }
            HStack(spacing: 6) {
                Text(place)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(when)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    ForEach(dotModels, id: \.self) { model in
                        Circle()
                            .fill(colors[model] ?? .secondary)
                            .frame(width: 7, height: 7)
                    }
                }
                Text(sortKey == .tokens
                    ? costText
                    : "\(TokenFormat.compact(session.totalTokens)) tokens")
                Text("\(plural(session.prompts, "prompt")) · \(plural(session.apiCalls, "call"))")
                Spacer(minLength: 0)
                if session.kind == .background {
                    Text("background")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .opacity(session.kind == .background ? 0.62 : 1)
    }

    @ViewBuilder
    private var title: some View {
        if isEditingTitle {
            TextField("Session name", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout.weight(.semibold))
                .focused($titleFocused)
                .onAppear {
                    draft = session.title
                    titleFocused = true
                }
                .onSubmit { onCommitRename?(draft) }
                // Escape cancels; the parent drops editing state first, so
                // the focus-loss commit below arrives stale and is ignored
                // there.
                .onExitCommand { onCancelRename?() }
                .onChange(of: titleFocused) { _, focused in
                    if focused {
                        FieldEditorCursor.place(near: clickPoint)
                    } else {
                        onCommitRename?(draft)
                    }
                }
        } else if let onBeginRename {
            Text(session.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(titleHovered ? 0.07 : 0))
                        .padding(-3))
                .pointerStyle(.link)
                .onHover { titleHovered = $0 }
                .onTapGesture {
                    clickPoint = NSApp.currentEvent?.locationInWindow
                    titleHovered = false
                    onBeginRename()
                }
                .help("Click to rename — an empty name restores the original title")
        } else {
            Text(session.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
    }

    /// The KPI slot: the sorted-by value when that value is a number
    /// (tokens, cost), cost otherwise — name and recency already own
    /// prominent fixed homes in the card. The demoted number moves to the
    /// caption line, so the swap never loses information.
    @ViewBuilder
    private var keyValue: some View {
        if sortKey == .tokens {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(TokenFormat.compact(session.totalTokens))
                    .font(.callout.weight(.bold))
                    .monospacedDigit()
                Text("tokens")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(costText)
                .font(.callout.weight(.bold))
                .monospacedDigit()
        }
    }

    private var costText: String {
        cost.unpricedModels > 0 && cost.dollars == 0
            ? "—" : UsageFormatting.money(cost.dollars)
    }

    /// Heaviest models first, capped at four dots.
    private var dotModels: [String] {
        session.models
            .sorted { $0.value.total > $1.value.total }
            .prefix(4)
            .map(\.key)
    }

    private var place: String {
        let path = (session.projectPath ?? "").replacingOccurrences(
            of: NSHomeDirectory(), with: "~")
        let repo = path.isEmpty ? "—" : (path as NSString).lastPathComponent
        if let branch = session.gitBranch { return "\(repo) · \(branch)" }
        return repo
    }

    private var when: String {
        let stamp = UsageFormatting.clockTime(session.start)
        let active = session.activeSeconds > 0
            ? UsageFormatting.duration(session.activeSeconds) : "—"
        return "\(stamp) · \(active)"
    }
}

private func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
