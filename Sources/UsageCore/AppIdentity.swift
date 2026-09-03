import Foundation

/// Identity this app presents to the network. Honest and attributable —
/// never impersonates Claude Code or the Claude app.
public enum AppIdentity {
    public static let name = "claude-usage-menubar"
    public static let version = "0.91.0"
    public static let userAgent = "\(name)/\(version)"
    /// Where releases are published — the self-updater's one feed.
    public static let repository = "avihut/coding-agent-usage-tracker"
    public static let releasesPage = "https://github.com/\(repository)/releases"
}
