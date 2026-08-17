import Foundation

/// User-chosen session names, layered over the scanner's derived titles at
/// render time. This is app-side data in the app's own support directory —
/// the transcripts and everything under `~/.claude` stay untouched (spec
/// §10), and the engine/digest keep publishing derived titles: a rename is
/// a display preference of this install, not a fact about the session
/// (TUI/CLI parity for custom names is a deliberate follow-up, not an
/// accident).
///
/// Orphans — sessions whose transcripts the agent's retention has removed —
/// are kept on save: the file stays tiny, and pruning against a partial
/// scan could silently drop a live rename.
public struct SessionRenames: Sendable {
    let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appending(path: "session-renames.json")
    }

    /// Missing file → empty. Unparseable file → empty as well: a broken
    /// prefs file must not take the sessions window down, and the next
    /// save rewrites it whole.
    public func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Atomic replace; sorted keys so consecutive saves diff stably.
    public func save(_ names: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(names)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension SessionSummary {
    /// The same session wearing a user-chosen display name.
    public func renamed(_ title: String) -> SessionSummary {
        SessionSummary(
            id: id, title: title, projectPath: projectPath, gitBranch: gitBranch,
            agentVersion: agentVersion, kind: kind, start: start, end: end,
            activeSeconds: activeSeconds, prompts: prompts, apiCalls: apiCalls,
            toolCalls: toolCalls, subagentCount: subagentCount,
            compactions: compactions, models: models, stretches: stretches)
    }
}
