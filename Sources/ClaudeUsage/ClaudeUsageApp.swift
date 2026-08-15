import AppKit
import SwiftUI
import UsageCore

@main
struct ClaudeUsageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // No windows — StatusItemController owns all UI.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The one place a vendor is chosen. The catalog installs before any
        // UI renders or scan runs — display names read it from everywhere.
        let provider = ClaudeProvider()
        ModelNames.catalog = provider.modelCatalog
        controller = StatusItemController(store: UsageStore(provider: provider))
        // Verification hatch: `ClaudeUsage --settings [--pane-cost]` opens
        // the settings window straight away, since the ⋯ menu can't be
        // scripted — and AX row selection can't drive the sidebar either.
        if CommandLine.arguments.contains("--settings") {
            controller?.showSettings(
                pane: CommandLine.arguments.contains("--pane-cost") ? .apiCost : .general)
        } else if CommandLine.arguments.contains("--panel") {
            controller?.showPanel()
        }
    }
}
