import Foundation

/// One local calendar day of Claude Code activity aggregated from transcripts.
public struct DailyActivity: Codable, Sendable, Equatable, Identifiable {
    public let day: Date
    public var tokens: Int
    public var messages: Int
    /// Prompt submissions from history.jsonl; can be nonzero while `tokens`
    /// is 0 when the day's transcripts were already cleaned up.
    public var prompts: Int
    /// The day's tokens attributed per raw model id; empty on prompt-only
    /// days. Sums to `tokens`.
    public var models: [String: TokenTally]

    public var id: Date { day }

    public init(
        day: Date, tokens: Int, messages: Int, prompts: Int = 0,
        models: [String: TokenTally] = [:]
    ) {
        self.day = day
        self.tokens = tokens
        self.messages = messages
        self.prompts = prompts
        self.models = models
    }
}

/// Everything one transcript scan yields: per-day totals for the heatmap plus
/// the recent per-minute, per-model timeline for limit-window breakdowns.
public struct TranscriptScan: Sendable, Equatable {
    public let daily: [DailyActivity]
    /// Sorted by minute; spans at most `TranscriptScanner.timelineRetention`.
    public let timeline: [TokenSlot]

    public init(daily: [DailyActivity], timeline: [TokenSlot]) {
        self.daily = daily
        self.timeline = timeline
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

    /// The panel's windows need at most 7 days back; a day of slack absorbs
    /// clock skew. Trimming to this bound is what keeps minute-granularity
    /// slots from growing the cache without limit.
    public static let timelineRetention: TimeInterval = 8 * 86400

    private struct DayCount: Codable {
        var tokens: Int
        var messages: Int
        var models: [String: TokenTally] = [:]
    }

    private struct FileEntry: Codable {
        let mtime: Double
        let size: Int
        let days: [String: DayCount]
        let slots: [TokenSlot]
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
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreation: CacheCreation?

            struct CacheCreation: Decodable {
                let ephemeral1h: Int?

                private enum CodingKeys: String, CodingKey {
                    case ephemeral1h = "ephemeral_1h_input_tokens"
                }
            }

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreation = "cache_creation"
            }

            var total: Int {
                (inputTokens ?? 0) + (outputTokens ?? 0)
                    + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
            }
        }
    }

    /// Synchronous and potentially slow on the first run — call off-main.
    public func scan(now: Date = Date()) -> TranscriptScan {
        let fileManager = FileManager.default
        let cache = loadCache()
        let cutoff = now.addingTimeInterval(-Self.timelineRetention)
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
            let entry: FileEntry
            if let cached = cache.files[path], cached.mtime == mtime, cached.size == size {
                entry = cached
            } else {
                let parsed = parse(item)
                entry = FileEntry(mtime: mtime, size: size, days: parsed.days, slots: parsed.slots)
            }
            // Every pass re-trims, so slots age out of unchanged files too.
            files[path] = FileEntry(
                mtime: entry.mtime, size: entry.size, days: entry.days,
                slots: entry.slots.filter { $0.t >= cutoff })
        }

        saveCache(CacheFile(version: 3, files: files))

        var totals: [String: DayCount] = [:]
        var slotTotals: [SlotKey: TokenTally] = [:]
        for entry in files.values {
            for (day, count) in entry.days {
                var total = totals[day] ?? DayCount(tokens: 0, messages: 0)
                total.tokens += count.tokens
                total.messages += count.messages
                for (model, tally) in count.models {
                    var merged = total.models[model] ?? TokenTally()
                    merged.add(tally)
                    total.models[model] = merged
                }
                totals[day] = total
            }
            // Concurrent sessions can land in the same minute — merge them.
            for slot in entry.slots {
                var tally = slotTotals[SlotKey(t: slot.t, model: slot.model)] ?? TokenTally()
                tally.add(slot.tally)
                slotTotals[SlotKey(t: slot.t, model: slot.model)] = tally
            }
        }

        let formatter = dayFormatter
        let daily = totals
            .compactMap { key, count -> DailyActivity? in
                guard let date = formatter.date(from: key) else { return nil }
                return DailyActivity(
                    day: date, tokens: count.tokens, messages: count.messages,
                    models: count.models)
            }
            .sorted { $0.day < $1.day }
        let timeline = slotTotals
            .map { TokenSlot(t: $0.key.t, model: $0.key.model, tally: $0.value) }
            .sorted { ($0.t, $0.model) < ($1.t, $1.model) }
        return TranscriptScan(daily: daily, timeline: timeline)
    }

    private struct SlotKey: Hashable {
        let t: Date
        let model: String
    }

    private func parse(_ url: URL) -> (days: [String: DayCount], slots: [TokenSlot]) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return ([:], []) }
        let decoder = JSONDecoder()
        let formatter = dayFormatter
        var days: [String: DayCount] = [:]
        var slots: [SlotKey: TokenTally] = [:]
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
            let model = line.message?.model ?? "unknown"
            let recordTally = TokenTally(
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheCreation: usage.cacheCreationInputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheCreation1h: usage.cacheCreation?.ephemeral1h ?? 0)

            let key = formatter.string(from: date)
            var count = days[key] ?? DayCount(tokens: 0, messages: 0)
            count.tokens += usage.total
            count.messages += 1
            var modelTally = count.models[model] ?? TokenTally()
            modelTally.add(recordTally)
            count.models[model] = modelTally
            days[key] = count

            let minute = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
            let slotKey = SlotKey(t: minute, model: model)
            var tally = slots[slotKey] ?? TokenTally()
            tally.add(recordTally)
            slots[slotKey] = tally
        }
        let sorted = slots
            .map { TokenSlot(t: $0.key.t, model: $0.key.model, tally: $0.value) }
            .sorted { ($0.t, $0.model) < ($1.t, $1.model) }
        return (days, sorted)
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
              cache.version == 3
        else { return CacheFile(version: 3, files: [:]) }
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
