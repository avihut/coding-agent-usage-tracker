import SwiftUI
import UsageCore

/// The line above the Activity section that says where its numbers stand
/// while a host is starting (2026-11-21): an account whose first scan
/// hasn't landed is NAMED — its activity is absent, not zero, and a merged
/// total without it is partial — and activity served from the previous
/// run's cached scan says how old it is. Nothing at all once every account
/// in scope has its own scan.
struct ActivityProvenanceCaption: View {
    struct Entry: Equatable {
        let name: String
        let status: ActivityStatus
    }

    let entries: [Entry]

    /// What the line says, or nil when there is nothing to say. Pure, so the
    /// copy is pinned without a view.
    static func text(_ entries: [Entry], now: Date) -> String? {
        let scanning = entries.filter { $0.status.isScanning }.map(\.name)
        let cached = entries.compactMap { entry -> Date? in
            entry.status.state == .cached ? entry.status.asOf : nil
        }
        var parts: [String] = []
        if !scanning.isEmpty {
            parts.append("\(ListFormatter.localizedString(byJoining: scanning)): scanning…")
        }
        if let oldest = cached.min() {
            parts.append("as of \(UsageFormatting.updatedStamp(oldest, now: now)) · rescanning")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let text = Self.text(entries, now: context.date) {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Activity: \(text)")
            }
        }
    }
}
