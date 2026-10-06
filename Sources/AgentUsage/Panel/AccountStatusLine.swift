import SwiftUI
import UsageCore

/// One account's pipeline state — fetch time, next-poll countdown, budget
/// gauge — with its plan (and, once a second identity was seen, who is
/// signed in). The panel shows it under the meters; the main window in its
/// status bar.
struct AccountStatusLine: View {
    let store: UsageStore

    /// Pipeline state right under the meters it describes — fetch time,
    /// next-poll countdown, budget gauge — with the plan label flushed to
    /// the opposite end.
    ///
    /// D9 (2026-08-25, user-directed): once a SECOND identity has ever been
    /// observed, the row splits into two baseline-aligned lines — left
    /// column pipeline time, right column identity, the plan tucked under
    /// the email it belongs to ("who / on what plan"). The full email gets
    /// a whole line; the bottom tier recedes to caption2·tertiary so the
    /// block reads as structure, not two dense lines. Single-account
    /// machines keep the original single line forever — the extra line is
    /// paid exactly when the information exists.
    var body: some View {
        if store.state.snapshot != nil || store.nextRefreshAt != nil {
            if let presence = store.accountPresence, presence.distinctAccounts >= 2 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            (statusLeadText(now: context.date) ?? Text(""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 12)
                            // Display-only with the full identity one hover
                            // away — the plan below keeps its disguised
                            // link, and two adjacent invisible links with
                            // different destinations would be a trap.
                            Text(presence.current?.label ?? "signed out")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(accountHelp(presence))
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            (statusDetailText(now: context.date) ?? Text(""))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 12)
                            planLabel(font: .caption2, style: .tertiary)
                        }
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        statusLine(now: context.date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    planLabel(font: .caption, style: .secondary)
                }
            }
        }
    }

    /// A working link dressed as a plain caption: Link's tint shouted over
    /// the header, so the hand cursor and help tag carry the affordance
    /// instead of color. Providers without an upgrade page get the caption,
    /// no link. Font and tier vary with the row's D9 shape.
    @ViewBuilder private func planLabel(font: Font, style: some ShapeStyle) -> some View {
        if let plan = store.state.snapshot?.plan?.displayLabel {
            if let upgrade = store.provider.links.planUpgrade {
                Button {
                    NSWorkspace.shared.open(upgrade)
                } label: {
                    Text(plan)
                        .font(font)
                        .foregroundStyle(style)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Choose your plan on \(upgrade.host() ?? store.provider.serviceName)")
            } else {
                Text(plan)
                    .font(font)
                    .foregroundStyle(style)
            }
        }
    }

    /// The full identity, one hover away: name · email · org · since. The
    /// plan is already the next line down, so it isn't repeated here.
    private func accountHelp(_ presence: AccountPresenceCard) -> String {
        guard let account = presence.current else {
            return "No account is signed in right now."
        }
        var parts: [String] = []
        if let name = account.displayName { parts.append(name) }
        parts.append(account.email ?? account.label)
        if let org = account.organizationName { parts.append(org) }
        if let since = presence.since {
            parts.append("since \(UsageFormatting.updatedStamp(since, now: Date()))")
        }
        return parts.joined(separator: " · ")
    }

    /// The freshness stamp alone — the two-line row's top-left cell.
    private func statusLeadText(now: Date) -> Text? {
        guard let fetchedAt = store.state.snapshot?.fetchedAt else { return nil }
        // Day-aware: a local provider's data is only as fresh as the
        // agent's last session, and a bare clock time would lie about
        // a days-old stamp.
        let stamp = UsageFormatting.updatedStamp(fetchedAt, now: now)
        // The stale badge lives here now that there's no header for it.
        return store.state.isStale
            ? Text("cached \(stamp)").foregroundStyle(.orange)
            : Text("Updated \(stamp)")
    }

    /// The operational tick-tock — countdown, idle multiplier, budget
    /// gauge — the two-line row's bottom-left cell.
    private func statusDetailText(now: Date) -> Text? {
        var parts: [Text] = []
        if let next = store.nextRefreshAt {
            parts.append(Text(UsageFormatting.countdownText(to: next, now: now)))
        }
        // Why "next in 20m" instead of 5: quiet decayed the cadence. Activity
        // (or usage moving) snaps it back — worth a word of transparency.
        let pace = store.paceMultiplier(now: now)
        if pace > 1 { parts.append(Text("idle ×\(pace)")) }
        // Surface the API budget only once it's half spent — quiet otherwise.
        // Local providers have no budget: nothing is requested from anyone.
        if !store.isLocalProvider {
            let budget = store.apiBudget(now: now)
            if budget.fraction >= 0.5 { parts.append(Text("API \(budget.used)/\(budget.ceiling)h")) }
        }
        guard var line = parts.first else { return nil }
        for part in parts.dropFirst() { line = line + Text(" · ") + part }
        return line
    }

    /// The single-line form: stamp and detail joined, as before D9.
    private func statusLine(now: Date) -> Text {
        let parts = [statusLeadText(now: now), statusDetailText(now: now)]
            .compactMap { $0 }
        guard var line = parts.first else { return Text("") }
        for part in parts.dropFirst() { line = line + Text(" · ") + part }
        return line
    }
}
