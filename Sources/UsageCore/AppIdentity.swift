import Foundation

/// Identity this app presents to the network. Honest and attributable —
/// never impersonates Claude Code or the Claude app.
public enum AppIdentity {
    public static let name = "claude-usage-menubar"
    public static let version = "0.83.0"
    public static let userAgent = "\(name)/\(version)"
}
