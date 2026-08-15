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

/// Everything one transcript scan yields: per-day totals for the heatmap,
/// the recent per-minute timeline for limit-window breakdowns, and the
/// per-session rollups for the sessions browser.
public struct TranscriptScan: Sendable, Equatable {
    public let daily: [DailyActivity]
    /// Sorted by minute; spans at most `TranscriptScanner.timelineRetention`.
    public let timeline: [TokenSlot]
    /// Sessions sorted by last activity, newest first. Empty for providers
    /// that don't reconstruct sessions.
    public let sessions: [SessionSummary]

    public init(
        daily: [DailyActivity], timeline: [TokenSlot],
        sessions: [SessionSummary] = []
    ) {
        self.daily = daily
        self.timeline = timeline
        self.sessions = sessions
    }
}

/// Read-only scanner over Claude Code's machine-local transcripts
/// (`~/.claude/projects/**/*.jsonl`), feeding the activity heatmap and the
/// sessions browser.
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

    /// v5 (0.53.0): April-era duplicate sibling prompts dedup at parse time —
    /// prompt counts persisted under v4 are inflated for those files. Bumping
    /// this discards older caches wholesale — one deliberate full reparse.
    private static let cacheVersion = 5

    /// Detail rows are bounded only defensively — the largest transcript on
    /// record yields ~1.4K rows; this cap exists for pathological files.
    static let detailRowCap = 20_000

    private struct DayCount: Codable {
        var tokens: Int
        var messages: Int
        var models: [String: TokenTally] = [:]
    }

    /// The per-file half of a session. Persisted in the cache, so every field
    /// is a deliberate materialization decision (spec §10): `firstPrompt` is
    /// the ONE place scrubbed prompt text (≤ `PromptPreview.maxLength`) may
    /// persist — full message text never leaves the parser.
    struct SessionFileSummary: Codable, Equatable {
        var title: String?
        var firstPrompt: String?
        var cwd: String?
        var gitBranch: String?
        var entrypoint: String?
        var version: String?
        var start: Date?
        var end: Date?
        /// Activity runs stitched at parse time with the DEFAULT grace —
        /// cards can't honor a user grace below it; the detail page reparses
        /// the main file and can.
        var stretches: [DateInterval] = []
        var prompts: Int = 0
        var toolCalls: Int = 0
        var compactions: Int = 0

        var isEmpty: Bool {
            self == SessionFileSummary()
        }
    }

    private struct FileEntry: Codable {
        let mtime: Double
        let size: Int
        let days: [String: DayCount]
        let slots: [TokenSlot]
        let session: SessionFileSummary?
    }

    private struct CacheFile: Codable {
        var version: Int
        var files: [String: FileEntry]
    }

    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let uuid: String?
        let parentUuid: String?
        let isSidechain: Bool?
        let isMeta: Bool?
        let isCompactSummary: Bool?
        let entrypoint: String?
        let cwd: String?
        let gitBranch: String?
        let version: String?
        let aiTitle: String?
        let summary: String?
        let promptSource: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
            let content: BlockList?
        }

        struct Block: Decodable {
            let type: String?
            let id: String?
        }

        /// `message.content` is a plain string on user lines and an array of
        /// blocks on assistant lines. A synthesized `[Block]?` would throw
        /// typeMismatch on the string form — and the parse loop's `try?`
        /// would silently drop the WHOLE line, losing every command record,
        /// compaction marker, and typed prompt. This type absorbs the
        /// mismatch itself, one decode pass, no per-line second decode.
        struct BlockList: Decodable {
            let blocks: [Block]

            init(from decoder: Decoder) throws {
                guard var container = try? decoder.unkeyedContainer() else {
                    blocks = []
                    return
                }
                var collected: [Block] = []
                while !container.isAtEnd {
                    if let block = try? container.decode(Block.self) {
                        collected.append(block)
                    } else {
                        // Non-object item; consume it so the loop advances.
                        _ = try? container.decode(Ignored.self)
                    }
                }
                blocks = collected
            }

            private struct Ignored: Decodable {}
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

    /// Second decode pass, run ONLY on non-sidechain, non-meta user lines:
    /// pulls the prompt text without materializing tool_result payloads on
    /// the assistant-dominated hot path.
    private struct UserLine: Decodable {
        let message: UserMessage?

        struct UserMessage: Decodable {
            let content: TextContent?
        }

        struct TextContent: Decodable {
            /// The string itself, or the first text-typed item of an array.
            let text: String?
            let hasToolResult: Bool

            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(),
                   let string = try? single.decode(String.self) {
                    text = string
                    hasToolResult = false
                    return
                }
                guard var container = try? decoder.unkeyedContainer() else {
                    text = nil
                    hasToolResult = false
                    return
                }
                var firstText: String?
                var sawToolResult = false
                while !container.isAtEnd {
                    if let item = try? container.decode(Item.self) {
                        if item.type == "text", firstText == nil { firstText = item.text }
                        if item.type == "tool_result" { sawToolResult = true }
                    } else {
                        _ = try? container.decode(Ignored.self)
                    }
                }
                text = firstText
                hasToolResult = sawToolResult
            }

            struct Item: Decodable {
                let type: String?
                let text: String?
            }

            private struct Ignored: Decodable {}
        }
    }

    /// Synchronous and potentially slow on the first run — call off-main.
    /// `persistCache: false` is for out-of-process readers (usage-cli): they
    /// borrow the warm cache but must never race the app's writes.
    public func scan(now: Date = Date(), persistCache: Bool = true) -> TranscriptScan {
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
                let parsed = parseFile(item, collectRows: false) ?? FileParse()
                entry = FileEntry(
                    mtime: mtime, size: size, days: parsed.days, slots: parsed.slots,
                    session: parsed.session)
            }
            // Every pass re-trims, so slots age out of unchanged files too.
            files[path] = FileEntry(
                mtime: entry.mtime, size: entry.size, days: entry.days,
                slots: entry.slots.filter { $0.t >= cutoff },
                session: entry.session)
        }

        if persistCache {
            saveCache(CacheFile(version: Self.cacheVersion, files: files))
        }

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
        return TranscriptScan(
            daily: daily, timeline: timeline, sessions: Self.mergeSessions(files: files))
    }

    /// Full parse of one listed session — the main file AND its subagent
    /// files, all fresh from disk (no cache involved, so nothing here can lag
    /// the sidebar's numbers). Subagent API calls join the rows flagged and
    /// time-interleaved: the running ledger must reach the session's whole
    /// spend, or the chart trails the card by exactly the subagents' cost.
    /// Nil when the id is unknown, the transcript left the disk, or the
    /// surrounding task was cancelled.
    /// Synchronous and slow on multi-MB sessions — call off-main.
    public func sessionDetail(id: String) -> SessionDetail? {
        guard let url = findTranscript(id: id) else { return nil }
        guard let parsed = parseFile(url, collectRows: true) else { return nil }
        let mainEntry = FileEntry(
            mtime: 0, size: 0, days: parsed.days, slots: [], session: parsed.session)

        // (source, ordinal) breaks timestamp ties deterministically: main
        // rows first, then parts in stable path order, each in file order.
        struct PendingRow {
            let t: Date
            let kind: SessionEvent.Kind
            let subagent: Bool
            let source: Int
            let ordinal: Int
        }
        var pending = parsed.rows.map {
            PendingRow(t: $0.t, kind: $0.kind, subagent: false, source: 0, ordinal: $0.id)
        }
        var truncated = parsed.truncated
        var partEntries: [FileEntry] = []
        for (index, partURL) in subagentFiles(of: url, id: id).enumerated() {
            if Task.isCancelled { return nil }
            guard let part = parseFile(partURL, collectRows: true) else {
                if Task.isCancelled { return nil }
                continue
            }
            partEntries.append(FileEntry(
                mtime: 0, size: 0, days: part.days, slots: [], session: part.session))
            truncated = truncated || part.truncated
            for row in part.rows {
                pending.append(PendingRow(
                    t: row.t, kind: row.kind, subagent: true,
                    source: index + 1, ordinal: row.id))
            }
        }
        guard let summary = Self.buildSummary(id: id, main: mainEntry, parts: partEntries)
        else { return nil }

        pending.sort { ($0.t, $0.source, $0.ordinal) < ($1.t, $1.source, $1.ordinal) }
        if pending.count > Self.detailRowCap {
            pending.removeLast(pending.count - Self.detailRowCap)
            truncated = true
        }
        var rows = pending.enumerated().map { index, row in
            SessionEvent(id: index, t: row.t, kind: row.kind, subagent: row.subagent)
        }
        if truncated {
            rows.append(SessionEvent(
                id: rows.count, t: summary.end,
                kind: .command(name: "… breakdown truncated")))
        }
        return SessionDetail(summary: summary, rows: rows)
    }

    /// The session's subagent transcripts on disk right now, in stable path
    /// order. Empty when the directory doesn't exist.
    private func subagentFiles(of mainURL: URL, id: String) -> [URL] {
        let directory = mainURL.deletingLastPathComponent()
            .appending(path: "\(id)/subagents")
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        var files: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if item.pathExtension == "jsonl" { files.append(item) }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// The transcript lives one level under a project directory, so ~80
    /// stats find it without a tree walk (cheaper than decoding the cache
    /// for its path keys).
    private func findTranscript(id: String) -> URL? {
        let fileManager = FileManager.default
        let direct = root.appending(path: "\(id).jsonl")
        if fileManager.fileExists(atPath: direct.path) { return direct }
        guard let projects = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        for directory in projects {
            let candidate = directory.appending(path: "\(id).jsonl")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Session merge

    /// Groups per-file cache entries into sessions. Classification is pure
    /// path math: everything under `<uuid>/subagents/` (including
    /// `subagents/workflows/wf_*/`) is a part of session `<uuid>`; top-level
    /// files ARE their session. Nothing role-related persists in the cache.
    private static func mergeSessions(files: [String: FileEntry]) -> [SessionSummary] {
        var mains: [String: FileEntry] = [:]
        var parts: [String: [FileEntry]] = [:]
        for (path, entry) in files {
            if let range = path.range(of: "/subagents/") {
                let parentDir = String(path[..<range.lowerBound])
                let id = URL(fileURLWithPath: parentDir).lastPathComponent
                parts[id, default: []].append(entry)
            } else {
                let id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                mains[id] = entry
            }
        }
        // Orphan part groups (main swept, directory lingering) have no
        // identity and are dropped with their mains-less keys.
        var sessions: [SessionSummary] = []
        for (id, main) in mains {
            if let summary = buildSummary(id: id, main: main, parts: parts[id] ?? []) {
                sessions.append(summary)
            }
        }
        return sessions.sorted { $0.end > $1.end }
    }

    private static func buildSummary(
        id: String, main: FileEntry, parts: [FileEntry]
    ) -> SessionSummary? {
        guard let mainMeta = main.session else { return nil }
        let group = [main] + parts

        var apiCalls = 0
        var models: [String: TokenTally] = [:]
        for entry in group {
            for count in entry.days.values {
                // DayCount.messages counts exactly the deduped kept lines —
                // the API-call count, derived instead of stored twice.
                apiCalls += count.messages
                for (model, tally) in count.models {
                    var merged = models[model] ?? TokenTally()
                    merged.add(tally)
                    models[model] = merged
                }
            }
        }

        let metas = group.compactMap(\.session)
        let prompts = metas.reduce(0) { $0 + $1.prompts }
        // Metadata-only stubs and husks don't list.
        guard apiCalls > 0 || prompts > 0 else { return nil }
        guard let start = metas.compactMap(\.start).min(),
              let end = metas.compactMap(\.end).max()
        else { return nil }

        let kind: SessionKind =
            (mainMeta.entrypoint == nil || mainMeta.entrypoint == "cli")
            ? .interactive : .background
        let stretches = unionIntervals(metas.flatMap(\.stretches))
        return SessionSummary(
            id: id,
            title: mainMeta.title ?? mainMeta.firstPrompt ?? String(id.prefix(8)),
            projectPath: mainMeta.cwd,
            gitBranch: mainMeta.gitBranch,
            agentVersion: mainMeta.version,
            kind: kind,
            start: start,
            end: end,
            activeSeconds: stretches.reduce(0) { $0 + $1.duration },
            prompts: prompts,
            apiCalls: apiCalls,
            toolCalls: metas.reduce(0) { $0 + $1.toolCalls },
            subagentCount: parts.count,
            compactions: metas.reduce(0) { $0 + $1.compactions },
            models: models,
            stretches: stretches)
    }

    /// Merges possibly-overlapping stretches into chronological disjoint
    /// runs. A sweep-union, NOT a stitch over the concatenation — subagents
    /// run concurrently with their parent, and summing (or stitching, which
    /// requires non-overlapping input) would double-count parallel bursts.
    /// The merged list is both the card's `activeSeconds` (summed) and the
    /// audit strip's nubs.
    private static func unionIntervals(_ stretches: [DateInterval]) -> [DateInterval] {
        guard !stretches.isEmpty else { return [] }
        let sorted = stretches.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        var runStart = sorted[0].start
        var runEnd = sorted[0].end
        for stretch in sorted.dropFirst() {
            if stretch.start <= runEnd {
                if stretch.end > runEnd { runEnd = stretch.end }
            } else {
                merged.append(DateInterval(start: runStart, end: runEnd))
                runStart = stretch.start
                runEnd = stretch.end
            }
        }
        merged.append(DateInterval(start: runStart, end: runEnd))
        return merged
    }

    private struct SlotKey: Hashable {
        let t: Date
        let model: String
    }

    // MARK: - Per-file parse

    private struct FileParse {
        var days: [String: DayCount] = [:]
        var slots: [TokenSlot] = []
        var session: SessionFileSummary?
        var rows: [SessionEvent] = []
        var truncated = false
    }

    /// A user prompt as first seen in the stream — countable only once the
    /// whole file's parent links are known (see `survivingPromptIndexes`).
    private struct PromptCandidate {
        let uuid: String?
        let parentUuid: String?
        let t: Date
        let preview: String
        let rowIndex: Int?
    }

    /// April-era transcripts hold duplicate sibling user records — same
    /// `parentUuid`, distinct `uuid`s: dead message-tree branches left by
    /// retries and edits. A sibling prompt with no descendants produced
    /// nothing and doesn't count. The LAST member of a group always counts
    /// (a just-submitted prompt at EOF legitimately has no reply yet), and
    /// prompts without tree ids can't be proven dead, so they count too.
    /// Dead branches' assistant calls are untouched: those tokens were
    /// billed, and cost must stay honest.
    private static func survivingPromptIndexes(
        candidates: [PromptCandidate], parents: Set<String>
    ) -> Set<Int> {
        var groupCounts: [String: Int] = [:]
        var lastOfGroup: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard let parent = candidate.parentUuid else { continue }
            groupCounts[parent, default: 0] += 1
            lastOfGroup[parent] = index
        }
        var survivors = Set<Int>()
        for (index, candidate) in candidates.enumerated() {
            guard let parent = candidate.parentUuid,
                  groupCounts[parent, default: 0] > 1,
                  lastOfGroup[parent] != index,
                  let uuid = candidate.uuid
            else {
                survivors.insert(index)
                continue
            }
            if parents.contains(uuid) { survivors.insert(index) }
        }
        return survivors
    }

    /// One pass over one transcript. Rules run in a deliberate order: the
    /// metadata/title/prompt rules must see every line BEFORE the usage
    /// keep-rule — `ai-title` records have no timestamp and user records no
    /// usage, so the guard that filters tally lines would eat them first.
    /// Returns nil only on task cancellation (checked when collecting rows).
    private func parseFile(_ url: URL, collectRows: Bool) -> FileParse? {
        guard let data = try? Data(contentsOf: url) else { return FileParse() }
        let decoder = JSONDecoder()
        let formatter = dayFormatter
        var result = FileParse()
        var days: [String: DayCount] = [:]
        var slots: [SlotKey: TokenTally] = [:]
        var seen = Set<String>()
        var meta = SessionFileSummary()
        var aiTitle: String?
        var legacyTitle: String?
        var toolUseIDs = Set<String>()
        var activeMinutes = Set<Date>()
        var rowIndexByKey: [String: Int] = [:]
        var promptCandidates: [PromptCandidate] = []
        var allParentUuids = Set<String>()
        var lineNumber = 0

        func touch(_ date: Date) {
            if meta.start.map({ date < $0 }) ?? true { meta.start = date }
            if meta.end.map({ date > $0 }) ?? true { meta.end = date }
        }

        func appendRow(_ t: Date, _ kind: SessionEvent.Kind) -> Int? {
            guard collectRows else { return nil }
            guard result.rows.count < Self.detailRowCap else {
                result.truncated = true
                return nil
            }
            let index = result.rows.count
            result.rows.append(SessionEvent(id: index, t: t, kind: kind))
            return index
        }

        for rawLine in data.split(separator: UInt8(ascii: "\n")) {
            lineNumber += 1
            if collectRows, lineNumber % 2048 == 0, Task.isCancelled { return nil }
            guard let line = try? decoder.decode(Line.self, from: Data(rawLine)) else {
                continue
            }

            // Every line's parent link feeds the descendant test that
            // resolves sibling prompt groups after the loop.
            if let parent = line.parentUuid { allParentUuids.insert(parent) }

            // Identity scalars: first non-nil sticks (cwd verifiably varies
            // mid-session; first-seen is the session's stable identity).
            if meta.cwd == nil { meta.cwd = line.cwd }
            if meta.gitBranch == nil { meta.gitBranch = line.gitBranch }
            if meta.entrypoint == nil { meta.entrypoint = line.entrypoint }
            if meta.version == nil { meta.version = line.version }

            // Titles: the file's LAST non-blank ai-title represents the
            // session (they repeat and change mid-file). `summary` records
            // are a legacy shape kept defensively.
            if line.type == "ai-title" {
                if let title = Self.nonBlank(line.aiTitle) { aiTitle = title }
                continue
            }
            if line.type == "summary" {
                if let title = Self.nonBlank(line.summary) { legacyTitle = title }
                continue
            }
            // Queue operations duplicate their content as a real user record
            // on dequeue — counting both would double prompts.
            if line.type == "queue-operation" { continue }

            let date = line.timestamp.flatMap { FlexibleISO8601.date(from: $0) }

            // Tool calls: streamed lines of one API call each carry DISTINCT
            // tool_use blocks while sharing usage — so this must see every
            // assistant line, not just dedup winners, and must not require a
            // timestamp or usage.
            var lineToolUses = 0
            if line.type == "assistant", let blocks = line.message?.content?.blocks {
                for block in blocks where block.type == "tool_use" {
                    lineToolUses += 1
                    if let blockID = block.id { toolUseIDs.insert(blockID) }
                }
            }

            // Prompts, commands, compactions — non-sidechain user lines only.
            if line.type == "user", line.isSidechain != true, line.isMeta != true {
                if line.isCompactSummary == true {
                    meta.compactions += 1
                    if let date {
                        touch(date)
                        _ = appendRow(date, .compaction)
                    }
                } else if let date,
                          let user = try? decoder.decode(UserLine.self, from: Data(rawLine)),
                          let content = user.message?.content,
                          !content.hasToolResult,
                          let text = content.text, !text.isEmpty {
                    if Self.isSkippableUserText(text) || line.promptSource == "system" {
                        // Command output, caveats, task notifications — noise.
                    } else if let command = PromptPreview.commandName(text) {
                        _ = appendRow(date, .command(name: command))
                    } else if let preview = PromptPreview.scrub(text) {
                        // Buffered, not counted: whether this prompt is real
                        // or a retry's dead sibling is only decidable once
                        // every parent link has been seen.
                        promptCandidates.append(PromptCandidate(
                            uuid: line.uuid, parentUuid: line.parentUuid,
                            t: date, preview: preview,
                            rowIndex: appendRow(date, .prompt(preview: preview))))
                    }
                }
            }

            // The original keep-rule, predicate unchanged: only timestamped
            // lines with net token movement count toward tallies.
            guard let usage = line.message?.usage,
                  let date,
                  usage.total > 0
            else { continue }
            // Retries/continuations repeat the same request — count it once.
            if let dedupKey = line.requestId ?? line.message?.id {
                guard seen.insert(dedupKey).inserted else {
                    // A later streamed line of an already-counted call: its
                    // tool_use blocks still belong on that call's row.
                    if collectRows, lineToolUses > 0, let index = rowIndexByKey[dedupKey],
                       case .apiCall(let model, let tally, let toolUses) = result.rows[index].kind {
                        result.rows[index] = SessionEvent(
                            id: index, t: result.rows[index].t,
                            kind: .apiCall(model: model, tally: tally, toolUses: toolUses + lineToolUses))
                    }
                    continue
                }
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

            touch(date)
            activeMinutes.insert(minute)
            if let index = appendRow(
                date, .apiCall(model: model, tally: recordTally, toolUses: lineToolUses)),
               let dedupKey = line.requestId ?? line.message?.id {
                rowIndexByKey[dedupKey] = index
            }
        }

        // Prompt candidates resolve now that every parent link is known:
        // dead retry siblings drop from counts, the first prompt, start/end
        // reach, and (when collecting) the rows themselves.
        let survivorIndexes = Self.survivingPromptIndexes(
            candidates: promptCandidates, parents: allParentUuids)
        let survivors = survivorIndexes.sorted().map { promptCandidates[$0] }
        meta.prompts = survivors.count
        meta.firstPrompt = survivors.first?.preview
        for candidate in survivors { touch(candidate.t) }
        if collectRows, survivors.count < promptCandidates.count {
            let deadRows = Set(promptCandidates.enumerated()
                .filter { !survivorIndexes.contains($0.offset) }
                .compactMap { $0.element.rowIndex })
            if !deadRows.isEmpty {
                // row.id == its index by construction; rebuild both.
                var kept: [SessionEvent] = []
                kept.reserveCapacity(result.rows.count - deadRows.count)
                for row in result.rows where !deadRows.contains(row.id) {
                    kept.append(SessionEvent(id: kept.count, t: row.t, kind: row.kind))
                }
                result.rows = kept
            }
        }

        meta.title = aiTitle ?? legacyTitle
        meta.toolCalls = toolUseIDs.count
        meta.stretches = Self.stitchedStretches(minutes: activeMinutes)

        result.days = days
        result.slots = slots
            .map { TokenSlot(t: $0.key.t, model: $0.key.model, tally: $0.value) }
            .sorted { ($0.t, $0.model) < ($1.t, $1.model) }
        result.session = meta.isEmpty ? nil : meta
        return result
    }

    /// Active minutes → chronological 60s runs → grace-stitched stretches.
    /// The sort is load-bearing: `ActivityGrace.stitch` requires
    /// chronological non-overlapping input and merges garbage silently
    /// otherwise.
    private static func stitchedStretches(minutes: Set<Date>) -> [DateInterval] {
        guard !minutes.isEmpty else { return [] }
        let runs = minutes.sorted().map { DateInterval(start: $0, duration: 60) }
        return ActivityGrace.stitch(runs, grace: ActivityGrace.defaultSeconds)
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Local-command output, caveat wrappers, and background-task
    /// notifications read as user records but aren't the user speaking.
    private static func isSkippableUserText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<local-command-stdout>")
            || trimmed.hasPrefix("<local-command-caveat>")
            || trimmed.hasPrefix("Caveat:")
            || trimmed.hasPrefix("[SYSTEM NOTIFICATION")
            || trimmed.contains("<task-notification>")
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
              cache.version == Self.cacheVersion
        else { return CacheFile(version: Self.cacheVersion, files: [:]) }
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
