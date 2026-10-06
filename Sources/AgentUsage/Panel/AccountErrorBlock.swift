import SwiftUI
import UsageCore

/// One account's failure and its hint — the panel leads with it, and the
/// main window shows it under the account it belongs to.
struct AccountErrorBlock: View {
    let store: UsageStore

    /// Failures lead the panel: with no title row above them anymore, an
    /// error and its hint are the first thing the eye lands on.
    var body: some View {
        if let error = store.state.error {
            VStack(alignment: .leading, spacing: 2) {
                Text(error.shortText(agent: store.provider.agentName))
                    .font(.caption)
                    .foregroundStyle(store.state.snapshot == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                if let hint = error.hint(agent: store.provider.agentName) {
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
