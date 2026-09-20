import SwiftUI
import UsageCore

/// Every harness found on this Mac, what each has been doing lately, and the
/// one switch that decides whether it is DISPLAYED (v0.101.0, R2/R3 — "make
/// sure there's no active harness being selected, but offer an option to turn
/// off displaying of a harness that isn't interesting to me").
///
/// It replaces the Metering picker, which asked which single harness to read.
/// Nothing chooses any more: every one is metered, and Show is about the bar
/// and the panel alone.
struct HarnessesCard: View {
    var registry: ProviderRegistry

    var body: some View {
        SettingsCard("Harnesses") {
            ForEach(Array(registry.harnesses.enumerated()), id: \.element.id) { index, harness in
                if index > 0 { Divider() }
                row(harness)
            }
            note(
                "Every harness found on this Mac is metered all the time — there is no active one"
                    + " to choose. Unticking Show takes a harness out of the menu bar and the"
                    + " panel; it keeps being metered in the background, and its models stay under"
                    + " API Cost → Rates.")
        }
    }

    private func row(_ harness: HarnessState) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                Text(harness.glyph)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HarnessStyle(harness).accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(harness.agentName)
                    Text(activity(harness))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            // A checkbox with its word beside it, not a bare switch: "Show"
            // is the whole of what it does, and the note carries the rest.
            Toggle("Show", isOn: Binding(
                get: { harness.shown },
                set: { registry.setHarnessShown(id: harness.id, shown: $0) }))
                .toggleStyle(.checkbox)
                // The last shown harness can't be hidden — an empty bar is
                // not a state to be able to reach.
                .disabled(harness.shown && registry.harnesses.filter(\.shown).count < 2)
                .help(harness.shown
                    ? "Stop showing \(harness.agentName) in the menu bar and the panel"
                    : "Show \(harness.agentName) in the menu bar and the panel")
        }
    }

    /// What one harness has been doing lately, in the roster's own words. The
    /// account count appears only when there is more than one — a lone
    /// account is what every harness has, and saying so everywhere is noise.
    private func activity(_ harness: HarnessState) -> String {
        var parts: [String] = []
        if harness.accountCount > 1 { parts.append("\(harness.accountCount) accounts") }
        let days = Int(HarnessDetector.window / 86400)
        if let files = harness.recentFiles, files > 0 {
            parts.append("\(files) session files in the last \(days) days")
        } else if let newest = harness.newestActivityAt {
            parts.append(
                "quiet — last active \(newest.formatted(date: .abbreviated, time: .omitted))")
        } else {
            parts.append("no sessions found")
        }
        return parts.joined(separator: " · ")
    }
}
