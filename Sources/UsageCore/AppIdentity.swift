import Foundation

/// Identity this app presents to the network. Honest and attributable —
/// never impersonates Claude Code or the Claude app.
public enum AppIdentity {
    /// The project's name on the wire — the `User-Agent`. The repository's
    /// name since 0.102.0 (it was `claude-usage-menubar` while that was the
    /// repo).
    public static let name = "coding-agent-usage-tracker"
    /// What a person reads as the app's name — window titles, the panel
    /// footer, the Quit item. `CFBundleName` in Support/Info.plist spells the
    /// same words; the bundle on disk is `AgentUsage.app`.
    public static let displayName = "Agent Usage"
    /// THE identity everything on disk hangs off: the defaults domain, the
    /// Application Support and Caches roots, the control socket, the login
    /// item. `CFBundleIdentifier` in Support/Info.plist must say the same
    /// (AppIdentityTests holds them together). Every face — app, usaged,
    /// usage-cli, the TUI's own constant — names this one, because usaged and
    /// the CLI are bare binaries whose `Bundle.main` has no identifier.
    public static let bundleID = "io.github.avihut.AgentUsage"
    /// The launch agent's label (`~/Library/LaunchAgents/<label>.plist`).
    public static let daemonLabel = "io.github.avihut.usaged"
    /// What both were through 0.101.0, when the app was ClaudeUsage under a
    /// personal prefix. Read ONLY by `IdentityMigration` and the installer's
    /// legacy cleanup — nothing else may name them.
    public static let legacyBundleID = "com.avihu.ClaudeUsage"
    public static let legacyDaemonLabel = "com.avihu.usaged"
    public static let version = "0.101.0"
    public static let userAgent = "\(name)/\(version)"
    /// Where releases are published — the self-updater's one feed.
    public static let repository = "avihut/coding-agent-usage-tracker"
    public static let releasesPage = "https://github.com/\(repository)/releases"
}
