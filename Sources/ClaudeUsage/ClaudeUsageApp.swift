import SwiftUI
import UsageCore

@main
struct ClaudeUsageApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsagePanelView(store: store)
        } label: {
            StatusItemLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
