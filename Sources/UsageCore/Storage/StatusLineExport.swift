import Darwin
import Foundation

/// A provider's status-line export (spec §10 amendment, the status-line
/// export): some agents hand a person-configured status-line command a JSON
/// payload on every redraw, and that payload is the only local place their
/// plan limits appear. `usage-cli export-statusline <provider>` is that
/// command. It REDUCES the payload to what the provider may keep — never an
/// email, a path, a title, a prompt — and leaves it in ONE file the provider
/// then reads like any local trace.
///
/// The provider owns what is kept (`reduce`, `differs`); this type owns how
/// it is written, the same way for every provider.
public struct StatusLineExport: Sendable {
    /// Where the reduced reading lives — `StorageScope.statusLineExportFile`
    /// in production; tests and `--to` point elsewhere.
    public let destination: URL
    /// The agent's status-line stdin → the bytes to keep; nil when the
    /// payload carries nothing worth keeping (no limits in it, or it doesn't
    /// parse). Pure.
    public let reduce: @Sendable (_ payload: Data, _ now: Date) -> Data?
    /// Whether a fresh reduction says something the stored one doesn't,
    /// beyond its capture time. Pure.
    public let differs: @Sendable (_ stored: Data, _ fresh: Data) -> Bool
    /// How long an unchanged reading may stand before it is rewritten, so
    /// its capture time keeps saying how fresh it is.
    public let refreshInterval: TimeInterval
    /// Where the person adds the status-line entry, as shown to them
    /// ("~/.gemini/antigravity-cli/settings.json").
    public let settingsPath: String
    /// The agent's settings fragment that runs `command` as its status line
    /// — the agent's own vocabulary, so the provider phrases it.
    public let settingsSnippet: @Sendable (_ command: String) -> String

    public init(
        destination: URL,
        refreshInterval: TimeInterval = 60,
        settingsPath: String,
        settingsSnippet: @escaping @Sendable (String) -> String,
        reduce: @escaping @Sendable (Data, Date) -> Data?,
        differs: @escaping @Sendable (Data, Data) -> Bool
    ) {
        self.destination = destination
        self.refreshInterval = refreshInterval
        self.settingsPath = settingsPath
        self.settingsSnippet = settingsSnippet
        self.reduce = reduce
        self.differs = differs
    }
}

/// `usage-cli export-statusline <provider> [--to <file>] [--print-config]`,
/// all of it but the process IO. A status line that fails 30 times in a row
/// is switched off by the agent, so the export itself ALWAYS exits 0 and
/// prints nothing to stdout; a misconfiguration is one stderr line.
/// `--print-config` is the person's setup step and the only part that
/// prints anything (and may fail).
public enum StatusLineExportCommand {
    public struct Result: Equatable, Sendable {
        public let stdout: String
        public let stderr: String
        public let code: Int32
    }

    public static func run(
        arguments: [String], stdin: () -> Data, executablePath: String,
        providers: [any UsageProvider] = HarnessResolution.standardProviders(),
        now: Date = Date()
    ) -> Result {
        let printConfig = arguments.contains("--print-config")
        let id = arguments.first { !$0.hasPrefix("--") && $0 != value(after: "--to", in: arguments) }
        guard let id, let export = providers.first(where: { $0.id == id })?.statusLineExport else {
            let known = providers.filter { $0.statusLineExport != nil }.map(\.id)
            let message = "export-statusline: no status-line export for '\(id ?? "")'"
                + " — known: \(known.joined(separator: ", "))\n"
            return Result(stdout: "", stderr: message, code: printConfig ? 19 : 0)
        }
        if printConfig {
            let command = "\(shellQuoted(executablePath)) export-statusline \(id) 2>/dev/null; exit 0"
            let text = "Add this to \(export.settingsPath), inside its top-level object:\n\n"
                + export.settingsSnippet(command) + "\n"
            return Result(stdout: text, stderr: "", code: 0)
        }
        let destination = value(after: "--to", in: arguments).map { URL(fileURLWithPath: $0) }
        let outcome = StatusLineExportWriter.run(
            export, stdin: stdin(), now: now, destination: destination)
        let stderr = outcome == .failed
            ? "export-statusline: could not write \((destination ?? export.destination).path)\n"
            : ""
        return Result(stdout: "", stderr: stderr, code: 0)
    }

    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    /// Single-quoted for `sh -c`, which is how agents run a status line.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The one writer of a status-line export file. A status line runs on
/// every redraw of the agent's prompt, so this does as little as possible:
/// one stdin read, one small file read, and a write only when the reading
/// changed or went stale.
public enum StatusLineExportWriter {
    /// Status-line payloads are a few KB; anything far bigger isn't one.
    public static let stdinCap = 256 * 1024

    public enum Outcome: Equatable, Sendable {
        case written
        case unchanged
        /// Nothing to keep: empty, oversized, unparseable, or no limits.
        case ignored
        /// The destination couldn't be written.
        case failed
    }

    public static func run(
        _ export: StatusLineExport, stdin: Data, now: Date = Date(),
        destination override: URL? = nil
    ) -> Outcome {
        guard !stdin.isEmpty, stdin.count <= stdinCap,
              let fresh = export.reduce(stdin, now)
        else { return .ignored }
        let destination = override ?? export.destination
        let manager = FileManager.default
        if let stored = try? Data(contentsOf: destination),
           !export.differs(stored, fresh),
           let attributes = try? manager.attributesOfItem(atPath: destination.path),
           let written = attributes[.modificationDate] as? Date,
           now.timeIntervalSince(written) < export.refreshInterval {
            return .unchanged
        }
        return write(fresh, to: destination) ? .written : .failed
    }

    /// Temp file + rename in the same folder, mode 0600: a reader sees the
    /// old reading or the new one, never half of either, and two agent
    /// sessions writing at once leave whichever landed last.
    static func write(_ data: Data, to destination: URL) -> Bool {
        let manager = FileManager.default
        let folder = destination.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let temporary = folder.appending(
            path: ".\(destination.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
        guard manager.createFile(
            atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { return false }
        guard rename(temporary.path, destination.path) == 0 else {
            try? manager.removeItem(at: temporary)
            return false
        }
        return true
    }
}
