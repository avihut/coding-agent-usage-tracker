import SwiftUI
import UsageCore

/// The Activity title row's scope control: whose CONSUMPTION the section
/// counts — every agent, one agent, or one account of an agent that has
/// several. Independent of focus, which keeps deciding whose limits lead.
/// It only exists while there is something to choose (more than one
/// account): one agent with one account sees the panel it always had.
///
/// Compact on purpose — the title row has ~85pt of slack beside the 7D
/// audit toggle, and a third segmented control never fit 360pt — so the
/// widest scope reads "All agents ▾" (the audit toggle is absent there),
/// and a narrowed one shrinks to the agent's mark, plus the account's
/// letter for one of several.
struct ActivityScopeMenu: View {
    let options: [ConsumptionScope]
    let selection: ConsumptionScope
    let onSelect: (ConsumptionScope) -> Void
    /// How a scope is named in the menu and drawn in the title row.
    let entries: [ConsumptionScope: Entry]

    struct Entry {
        let title: String
        let style: HarnessStyle?
        let monogram: String?
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    let title = entries[option]?.title ?? option.rawValue
                    if option == selection { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            label
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        // The system's own pull-down chevron: a borderless menu flattens a
        // custom label to one image and one string, so a drawn chevron
        // would land in front of the title.
        .menuIndicator(.visible)
        .fixedSize()
        .pointerStyle(.link)
        .help("Whose tokens and cost this section counts — limits above stay per account")
        .accessibilityLabel("Activity scope: \(entries[selection]?.title ?? "")")
    }

    @ViewBuilder private var label: some View {
        let entry = entries[selection]
        HStack(spacing: 3) {
            if selection == .all || entry?.style == nil {
                Text(entry?.title ?? "All agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let style = entry?.style {
                Image(nsImage: HarnessMark.image(glyph: style.glyph, color: style.nsAccent, ink: 10))
                if let monogram = entry?.monogram {
                    Text(monogram)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension ProviderRegistry {
    /// The menu's entries for these members: "All agents" (or "All accounts"
    /// when one agent holds them all), each agent by name and mark, each
    /// account of a several-account agent by its label and letter.
    func scopeMenuEntries(_ members: [ConsumptionMember]) -> [ConsumptionScope: ActivityScopeMenu.Entry] {
        let agents = Set(members.map(\.agent))
        var entries: [ConsumptionScope: ActivityScopeMenu.Entry] = [
            .all: .init(title: agents.count > 1 ? "All agents" : "All accounts", style: nil, monogram: nil),
        ]
        for member in members {
            guard let store = store(for: member.account) else { continue }
            entries[.agent(member.agent)] = .init(
                title: store.provider.agentName, style: store.style, monogram: nil)
            let several = members.filter { $0.agent == member.agent }.count > 1
            let label = label(for: store.profile)
            entries[.account(member.account)] = .init(
                title: agents.count > 1 ? "\(store.provider.agentName) · \(label)" : label,
                style: store.style, monogram: several ? monogram(for: store.profile) : nil)
        }
        return entries
    }
}
