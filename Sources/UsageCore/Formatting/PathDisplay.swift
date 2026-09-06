import Foundation

/// Tilde abbreviation with an injectable home, so every "~/…" the app
/// shows (privacy card rows, account homes, credential source names) is
/// spelled by one pure function that tests can pin against a synthetic
/// home directory.
public enum PathDisplay {
    /// "/Users/x/.claude-personal" → "~/.claude-personal"; the home itself →
    /// "~"; anything outside the home stays absolute.
    public static func abbreviated(
        _ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let path = trimmed(url.path)
        let homePath = trimmed(home.path)
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }

    /// A path without its trailing slashes (the root keeps its one).
    static func trimmed(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}
