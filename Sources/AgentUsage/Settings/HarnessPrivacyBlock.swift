import SwiftUI
import UsageCore

/// One metered harness's block of the privacy inventory (0.101.0): the hosts
/// it talks to, the local files it reads, and one line per account of it.
/// Every metered harness gets one — the app reads them all, so naming only
/// the focused one would make the card a partial truth.
struct HarnessPrivacyBlock: View {
    var registry: ProviderRegistry

    let provider: any UsageProvider
    /// With one harness the rows keep their pre-0.101 titles; with several
    /// each is prefixed by its agent, or the rows would be ambiguous.
    let several: Bool

    private var accounts: [Profile] {
        registry.profiles(ofHarness: provider.id).filter { $0.isEnrolled && $0.enabled }
    }

    private func title(_ name: String) -> String {
        several ? "\(provider.agentName) · \(name)" : name
    }

    var body: some View {
        if several {
            HStack(spacing: 6) {
                Text(provider.menuBarGlyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HarnessStyle(provider).accentColor)
                Text(provider.agentName)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
            }
        }
        infoRow(
            title("Network destinations"),
            provider.networkDestinations.isEmpty
                // A local harness reads files and nothing else; saying
                // "none" is the honest row, not an empty one.
                ? "none — local files only"
                : provider.networkDestinations.joined(separator: " · "))
        // Declared on its own line, never folded into the list above: the
        // status feed sits outside `networkDestinations` so a zero-network
        // provider keeps its local-provider semantics (amendment 2026-08-19).
        if let statusFeed = provider.statusFeed {
            infoRow(title("Status feed"), statusFeed.host)
        }
        // The identity read is local and passive, but it is a read all the
        // same (amendment 2026-08-25), and so is the credential chain — per
        // ACCOUNT, since v0.96.0 each home carries its own.
        ForEach(accounts, id: \.key) { account in
            let name = accounts.count > 1 ? registry.label(for: account) : provider.agentName
            if let identity = registry.provider(for: account).accountIdentity {
                infoRow(
                    several || accounts.count > 1 ? "\(name) identity" : "Account identity",
                    "\(identity.displayPath) (read-only)")
            }
            let chain = registry.provider(for: account).credentials.sources.map(\.name)
            if !chain.isEmpty {
                infoRow(
                    several || accounts.count > 1 ? "\(name) credential" : "Credential",
                    chain.joined(separator: " → ") + " (read-only)")
            }
            // One row per kind of file the source reads (`displayPaths`) —
            // a harness that lists conversations AND reads transcripts names
            // both.
            let paths = registry.provider(for: account)
                .makeLocalActivity(cacheDirectory: StorageScope.supportDirectory(
                    bundleID: registry.bundleID, providerID: account.providerID,
                    profileID: account.id))?.displayPaths ?? []
            ForEach(Array(paths.enumerated()), id: \.offset) { _, path in
                infoRow(
                    several || accounts.count > 1 ? "\(name) sessions" : "Transcripts",
                    "\(path) (read-only)")
            }
            // The agent's own tool, run for the plan's limits — its own lines,
            // in the provider's words (spec §10 amendment 2026-11-21, second).
            let probeLines = registry.provider(for: account).quotaCommand?.privacyLines ?? []
            ForEach(Array(probeLines.enumerated()), id: \.offset) { index, line in
                infoRow(
                    index > 0 ? "" : several || accounts.count > 1 ? "\(name) limits" : "Plan limits",
                    line)
            }
        }
    }
}
