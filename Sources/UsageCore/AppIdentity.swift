import Foundation

/// Identity this app presents to the network. Honest and attributable —
/// never impersonates Claude Code or the Claude app.
public enum AppIdentity {
    public static let name = "claude-usage-menubar"
    /// What a person reads as the app's name — window titles, the panel
    /// footer, the Quit item (0.101.0, user-directed: it has metered every
    /// coding agent for a while, not one vendor's). `CFBundleName` in
    /// Support/Info.plist spells the same words. The wire `name`, the bundle
    /// id and the bundle's file name are identities, not labels, and stay.
    public static let displayName = "Agent Usage"
    public static let version = "0.101.0"
    public static let userAgent = "\(name)/\(version)"
    /// Where releases are published — the self-updater's one feed.
    public static let repository = "avihut/coding-agent-usage-tracker"
    public static let releasesPage = "https://github.com/\(repository)/releases"
}
