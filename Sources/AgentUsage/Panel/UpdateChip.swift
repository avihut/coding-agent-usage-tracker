import SwiftUI
import UsageCore

/// The update chip that rides beside the version label (the panel's
/// footer, the window's status bar).
struct UpdateChip: View {
    let store: UsageStore
    /// Where a channel that only informs sends the click.
    let onOpenSettings: () -> Void
    /// A release the user chose not to hear about again — quiets the chip
    /// and menu item for exactly that version; the next one speaks.
    @AppStorage("updateSkippedVersion") private var skippedUpdateVersion = ""

    /// The update chip's card, or nil while there is nothing to whisper
    /// about: no card, nothing newer, a version the user skipped, or a
    /// release this build already IS (the daemon lags one relaunch behind
    /// right after an update, and its card must not re-offer it).
    static func visibleUpdate(_ store: UsageStore, skipped: String) -> AppUpdateCard? {
        guard let card = store.appUpdate, card.updateAvailable,
              card.latestVersion != AppIdentity.version,
              card.latestVersion != skipped
        else { return nil }
        return card
    }

    /// As quiet as an update can get: a small accent arrow riding beside
    /// the version label it would change. On a self-installing channel one
    /// click runs the whole install — spinner while it runs, amber with the
    /// reason on hover after a failure, clicking again retries. On a
    /// channel that only informs (a source checkout) the same arrow opens
    /// Settings, where the card says how updating works here.
    var body: some View {
        if let update = Self.visibleUpdate(store, skipped: skippedUpdateVersion) {
            if store.canSelfInstall(update) {
                installUpdateControl(update)
            } else {
                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(store.style.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Version \(update.latestVersion) is available — this build updates from its checkout; click for how")
            }
        }
    }

    @ViewBuilder private func installUpdateControl(_ update: AppUpdateCard) -> some View {
        let updater = AppUpdater.shared
        switch updater.phase {
            case .downloading, .installing, .relaunching:
                ProgressView()
                    .controlSize(.mini)
                    .help("Updating to \(update.latestVersion)…")
            case .failed(let message):
                Button {
                    updater.resetFailure()
                    updater.install(update)
                } label: {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("\(message) Click to try again.")
            case .idle:
                Button {
                    updater.install(update)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(store.style.accentColor)
                }
                .buttonStyle(.borderless)
                .help("Version \(update.latestVersion) is available — one click installs and relaunches")
        }
    }
}
