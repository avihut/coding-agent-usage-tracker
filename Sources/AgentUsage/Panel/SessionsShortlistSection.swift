import SwiftUI
import UsageCore

/// The last few interactive sessions of one account, one quiet line each —
/// a shortcut into the Sessions browser.
struct SessionsShortlistSection: View {
    let store: UsageStore
    /// Where the activity section is navigated to (paged window or drilled
    /// day); the shortlist follows it.
    let activityFocus: DateInterval?
    let onOpenSessions: () -> Void
    /// Opens the Sessions window landed on the clicked session.
    let onOpenSession: (String) -> Void
    /// The shortlist row under the cursor, if any.
    @State private var hoveredSession: String?

    /// The last few interactive sessions, one quiet line each — a shortcut
    /// into the Sessions browser. Background runs stay out of the strip;
    /// "Show more" covers them and anything past the cap. While the activity
    /// section is navigated (paged window or drilled day) the strip follows
    /// it, labels the span, and states emptiness rather than vanishing.
    var body: some View {
        let shortlist = SessionShortlist.build(store.sessions, in: activityFocus)
        if store.providesSessions,
           !shortlist.rows.isEmpty || shortlist.hasMore || activityFocus != nil {
            let colors = shortlistColors
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sessions")
                        .font(.caption.bold())
                    if let focus = activityFocus {
                        Spacer(minLength: 8)
                        Text(Self.focusLabel(focus))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 2)
                if shortlist.rows.isEmpty {
                    Text("No sessions in this period")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
                ForEach(shortlist.rows) { session in
                    shortlistRow(session, colors: colors)
                }
                if shortlist.hasMore {
                    Button {
                        onOpenSessions()
                    } label: {
                        Text("Show more…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
            }
        }
    }

    /// "Aug 5" for a drilled day, "Jul 27 – Aug 2" for a paged window — the
    /// heatmap's own range vocabulary.
    private static func focusLabel(_ interval: DateInterval) -> String {
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: interval.start)
        // The interval is half-open; its last DAY sits just before the end.
        let lastDay = calendar.startOfDay(for: interval.end.addingTimeInterval(-1))
        if firstDay == lastDay { return focusFormatter.string(from: firstDay) }
        return "\(focusFormatter.string(from: firstDay)) – \(focusFormatter.string(from: lastDay))"
    }

    private static let focusFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// The same palette input as the sessions window — the union over every
    /// session's models — so a model's dot color matches across surfaces.
    private var shortlistColors: [String: Color] {
        var models: Set<String> = []
        for session in store.sessions { models.formUnion(session.models.keys) }
        return ModelPalette.assignment(for: models.sorted(), style: store.style)
    }

    /// One shortlist entry: the sidebar's full session card, wrapped in the
    /// panel's hover/click chrome.
    private func shortlistRow(_ session: SessionSummary, colors: [String: Color]) -> some View {
        SessionRow(
            session: session,
            cost: SessionsView.cost(of: session, pricing: store.pricing),
            colors: colors,
            // Same auto-show rule as the sidebar (D4).
            accounts: (store.accountPresence?.distinctAccounts ?? 0) >= 2
                ? store.sessionAccountLabels(session) : nil)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(hoveredSession == session.id ? 0.07 : 0)))
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredSession = session.id
                } else if hoveredSession == session.id {
                    hoveredSession = nil
                }
            }
            .pointerStyle(.link)
            .onTapGesture { onOpenSession(session.id) }
    }
}
