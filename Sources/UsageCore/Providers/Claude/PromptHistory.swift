import Foundation

/// Read-only scanner over Claude Code's prompt history
/// (`~/.claude/history.jsonl`) — one line per submitted prompt with an
/// epoch-milliseconds timestamp, but no token counts. Unlike transcripts,
/// history is not subject to `cleanupPeriodDays`, so it extends the heatmap
/// to days whose transcripts Claude Code has already deleted.
///
/// Same constraints as `TranscriptScanner`: never writes inside `~/.claude`,
/// never goes near credential files, nothing leaves the machine.
public struct PromptHistoryScanner: Sendable {
    let fileURL: URL
    let calendar: Calendar

    public init(fileURL: URL, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.calendar = calendar
    }

    public static func standard() -> PromptHistoryScanner {
        PromptHistoryScanner(
            fileURL: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".claude/history.jsonl"))
    }

    private struct Line: Decodable {
        let timestamp: Double?
    }

    /// Local-midnight day → prompts submitted that day. The file is a couple
    /// of MB at most, so a full parse per scan beats maintaining a cache.
    public func scan() -> [Date: Int] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        let decoder = JSONDecoder()
        var counts: [Date: Int] = [:]
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let line = try? decoder.decode(Line.self, from: Data(rawLine.utf8)),
                  var timestamp = line.timestamp
            else { continue }
            // Epoch milliseconds in every observed file; tolerate seconds.
            if timestamp > 100_000_000_000 { timestamp /= 1000 }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: timestamp))
            counts[day, default: 0] += 1
        }
        return counts
    }
}

/// Combines token-grade transcript days with prompt-history days. Days found
/// only in prompt history carry zero tokens and render as "no token data".
public enum ActivityMerge {
    public static func merge(transcripts: [DailyActivity], prompts: [Date: Int]) -> [DailyActivity] {
        var byDay = Dictionary(transcripts.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        for (day, count) in prompts {
            var entry = byDay[day] ?? DailyActivity(day: day, tokens: 0, messages: 0)
            entry.prompts = count
            byDay[day] = entry
        }
        return byDay.values.sorted { $0.day < $1.day }
    }
}
