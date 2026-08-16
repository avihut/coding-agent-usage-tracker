import Foundation

/// The ONE sanctioned write into `~/.claude`: Claude Code's transcript
/// retention (`cleanupPeriodDays` in settings.json), exposed as an app
/// setting at the user's explicit request — everything else under
/// `~/.claude` stays strictly read-only. Read-modify-write preserves
/// every other key; a file whose content doesn't parse is never
/// clobbered; the write is atomic; failures report false rather than
/// throwing through the UI.
public struct ClaudeCodeSettings: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func standard() -> ClaudeCodeSettings {
        ClaudeCodeSettings(
            fileURL: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".claude/settings.json"))
    }

    /// Claude Code's own default when the key is absent.
    public static let defaultDays = 30

    public func readCleanupPeriodDays() -> Int? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return nil }
        return dict["cleanupPeriodDays"] as? Int
    }

    /// Rewrites only this one key, keeping every other setting intact
    /// (JSONSerialization re-serializes, so formatting and key order may
    /// change; content never does). Creates the file when missing.
    /// Refuses — untouched — when existing content doesn't parse as a
    /// JSON object.
    @discardableResult
    public func writeCleanupPeriodDays(_ days: Int) -> Bool {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: fileURL) {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let existing = object as? [String: Any]
            else { return false }
            dict = existing
        }
        dict["cleanupPeriodDays"] = days
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
