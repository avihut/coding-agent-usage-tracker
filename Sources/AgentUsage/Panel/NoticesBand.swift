import SwiftUI
import UsageCore

/// Pending notifications (v0.93.0) for every shown harness, wired to where
/// each one leads. Absent entirely when nothing is pending.
struct NoticesBand: View {
    let registry: ProviderRegistry
    /// The face the band dismisses through and falls back to for style.
    let store: UsageStore
    /// A reset notice's click-through: the meter it names and the moment.
    let onOpenMeterHistory: (_ label: String?, _ at: Date) -> Void
    let onOpenAccounts: () -> Void

    /// Pending notifications (v0.93.0) — absent entirely when nothing is
    /// pending. A running outage's row here IS the incident banner with a
    /// lifecycle (same rail, same message, a running clock, no ×), so the
    /// banner below yields to it rather than saying the same thing twice.
    var body: some View {
        // Every SHOWN harness's pending notices, not just the focused one's:
        // what the list shows is exactly what "Dismiss all" dismisses, and
        // each row's rail wears its own vendor's accent.
        if let card = registry.pendingNotices, !card.items.isEmpty {
            NoticesSection(
                card: card, style: store.style,
                styleForNotice: { notice in
                    registry.stores[registry.harnessOfNotice(notice.id)].map(\.style)
                        ?? registry.providers
                            .first { $0.id == registry.harnessOfNotice(notice.id) }
                            .map(HarnessStyle.init) ?? store.style
                },
                onDismiss: { id in withAnimation { store.dismissNotice(id: id) } },
                onDismissAll: { withAnimation { store.dismissAllNotices() } },
                canOpen: { notice in
                    self.provider(ofNotice: notice).noticeDestination(for: notice) != nil
                },
                onOpen: openNotice)
        }
    }

    /// Which vendor a listed notice belongs to — its click-through is that
    /// provider's call, never the focused one's.
    private func provider(ofNotice notice: NoticeCard) -> any UsageProvider {
        let id = registry.harnessOfNotice(notice.id)
        return registry.providers.first { $0.id == id } ?? store.provider
    }

    /// A click on a notice goes where the provider says: an official record
    /// on the web (the incident's report), or — for events the vendor keeps
    /// no record of, like a limit reset — the meter card that saw it, lit at
    /// the moment (the host's call: a popover in the panel, the inline card
    /// in the window).
    private func openNotice(_ notice: NoticeCard) {
        guard let destination = provider(ofNotice: notice).noticeDestination(for: notice)
        else { return }
        switch destination {
        case .web(let url):
            NSWorkspace.shared.open(url)
        case .meterHistory(let label, let at):
            onOpenMeterHistory(label, at)
        case .accounts:
            onOpenAccounts()
        }
    }
}
