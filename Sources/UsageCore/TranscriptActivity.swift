import Foundation

/// One local calendar day of Claude Code activity aggregated from transcripts.
public struct DailyActivity: Codable, Sendable, Equatable, Identifiable {
    public let day: Date
    public var tokens: Int
    public var messages: Int

    public var id: Date { day }

    public init(day: Date, tokens: Int, messages: Int) {
        self.day = day
        self.tokens = tokens
        self.messages = messages
    }
}

/// Read-only scanner over Claude Code's machine-local transcripts
/// (`~/.claude/projects/**/*.jsonl`), feeding the activity heatmap.
///
/// Constraints honored: never writes inside `~/.claude`, never touches
/// credential files, nothing leaves the machine. Its only artifact is an
/// mtime/size-keyed cache in this app's own Application Support directory so
/// unchanged transcript files aren't re-parsed on every scan.
public struct TranscriptScanner: Sendable {
    let root: URL
    let cacheURL: URL
    let calendar: Calendar

    public init(root: URL, cacheDirectory: URL, calendar: Calendar = .current) {
        self.root = root
        self.cacheURL = cacheDirectory.appending(path: "activity-cache.json")
        self.calendar = calendar
    }

    public static func standard(bundleID: String) -> TranscriptScanner {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return TranscriptScanner(
            root: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects"),
            cacheDirectory: base.appending(path: bundleID)
        )
    }

    private struct DayCount: Codable {
        var tokens: Int
        var messages: Int
    }

    private struct FileEntry: Codable {
        let mtime: Double
        let size: Int
        let days: [String: DayCount]
    }

    private struct CacheFile: Codable {
        var version: Int
        var files: [String: FileEntry]
    }

    private struct Line: Decodable {
        let timestamp: String?
        let requestId: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }

            var total: Int {
                (inputTokens ?? 0) + (outputTokens ?? 0)
                    + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
            }
        }
    }

    /// Synchronous and potentially slow on the first run — call off-main.
    public func scan() -> [DailyActivity] {
        let fileManager = FileManager.default
        let cache = loadCache()
        var files: [String: FileEntry] = [:]

        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: keys)
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension == "jsonl" else { continue }
            let path = item.path
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  let mtime = values.contentModificationDate?.timeIntervalSince1970,
                  let size = values.fileSize
            else { continue }
            if let cached = cache.files[path], cached.mtime == mtime, cached.size == size {
                files[path] = cached
            } else {
                files[path] = FileEntry(mtime: mtime, size: size, days: parse(item))
            }
        }

        saveCache(CacheFile(version: 1, files: files))

        var totals: [String: DayCount] = [:]
        for entry in files.values {
            for (day, count) in entry.days {
                var total = totals[day] ?? DayCount(tokens: 0, messages: 0)
                total.tokens += count.tokens
                total.messages += count.messages
                totals[day] = total
            }
        }

        let formatter = dayFormatter
        return totals
            .compactMap { key, count -> DailyActivity? in
                guard let date = formatter.date(from: key) else { return nil }
                return DailyActivity(day: date, tokens: count.tokens, messages: count.messages)
            }
            .sorted { $0.day < $1.day }
    }

    private func parse(_ url: URL) -> [String: DayCount] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        let decoder = JSONDecoder()
        let formatter = dayFormatter
        var days: [String: DayCount] = [:]
        var seen = Set<String>()

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let line = try? decoder.decode(Line.self, from: Data(rawLine.utf8)),
                  let usage = line.message?.usage,
                  let timestamp = line.timestamp,
                  let date = FlexibleISO8601.date(from: timestamp),
                  usage.total > 0
            else { continue }
            // Retries/continuations repeat the same request — count it once.
            if let dedupKey = line.requestId ?? line.message?.id {
                guard seen.insert(dedupKey).inserted else { continue }
            }
            let key = formatter.string(from: date)
            var count = days[key] ?? DayCount(tokens: 0, messages: 0)
            count.tokens += usage.total
            count.messages += 1
            days[key] = count
        }
        return days
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func loadCache() -> CacheFile {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              cache.version == 1
        else { return CacheFile(version: 1, files: [:]) }
        return cache
    }

    private func saveCache(_ cache: CacheFile) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Cache is an optimization; scanning still works without it.
        }
    }
}

/// "12.3K", "1.2M", "3B" — token counts at heatmap scale.
public enum TokenFormat {
    public static func compact(_ count: Int) -> String {
        let value = Double(count)
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return trimmed(value / 1000) + "K"
        case ..<1_000_000_000: return trimmed(value / 1_000_000) + "M"
        default: return trimmed(value / 1_000_000_000) + "B"
        }
    }

    private static func trimmed(_ value: Double) -> String {
        let text = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
