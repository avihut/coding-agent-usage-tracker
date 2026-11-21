import Foundation

// MARK: - Local activity

/// Antigravity CLI's on-disk traces: one `transcript.jsonl` per
/// conversation, under `brain/<id>/.system_generated/logs/`, one JSON row
/// per conversation step. Model-call rows carry the model (with its effort
/// suffix) and the call's own token counts — uncached input, cache read,
/// and output including thinking — which match the CLI's SQLite store call
/// for call (docs/plans/antigravity.md).
///
/// Strictly read-only (spec §10). Three rules keep it that way:
/// - Conversations are found by LISTING `conversations/` by name. The
///   `.db` files there are WAL-mode SQLite, and opening one that has no
///   `-shm` beside it creates one inside the agent home — so none is ever
///   opened.
/// - `brain/` is never walked: it also holds tool outputs, scratch space
///   and git worktrees. Each transcript path is built from a listed id.
/// - Only the timestamp, step type and source, step index, model and the
///   three token counts are decoded; message text, thinking and tool
///   arguments never become a value.
public struct AntigravityActivitySource: LocalActivitySource {
    let tree: AntigravityHome
    private let cacheURL: URL
    private let calendar: Calendar

    public init(home: URL, cacheDirectory: URL, calendar: Calendar = .current) {
        self.tree = AntigravityHome(root: home)
        self.cacheURL = cacheDirectory.appending(path: "activity-cache.json")
        self.calendar = calendar
    }

    /// The flat conversation folder: one file per conversation (and its
    /// `-wal` moving while one is live) — presence, FSEvents and the mtime
    /// probe all read it. Never `brain/`, whose step outputs and worktrees
    /// would swamp the probe.
    public var watchDirectories: [URL] { [tree.conversationsDirectory] }
    public var displayPath: String { "~/.gemini/antigravity-cli" }
    public var displayPaths: [String] {
        [
            "~/.gemini/antigravity-cli/conversations (file names only)",
            "~/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl",
        ]
    }

    public func scanTranscripts(now: Date) -> TranscriptScan {
        scan(now: now, persistCache: true)
    }

    public func scanTranscriptsReadOnly(now: Date) -> TranscriptScan {
        scan(now: now, persistCache: false)
    }

    /// Prompts ride the transcript scan (`USER_INPUT` rows).
    public func scanPromptDays() -> [Date: Int] { [:] }

    /// Nil on purpose: there is no retention setting to project, and a
    /// measure would have to walk `brain/` — worktrees and all.
    public func diskUsage(now: Date) -> TranscriptDiskUsage? { nil }

    // MARK: Scan

    private func scan(now: Date, persistCache: Bool) -> TranscriptScan {
        var cache = loadCache()
        var seen: Set<String> = []
        for id in tree.conversationIDs() {
            let url = tree.transcriptURL(for: id)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            else { continue }
            let path = url.path
            seen.insert(path)
            let mtime = attributes[.modificationDate] as? Date ?? .distantPast
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if let record = cache.files[path], record.mtime == mtime, record.size == size {
                continue
            }
            cache.files[path] = AntigravityTranscript.parse(url: url, mtime: mtime, size: size)
        }
        cache.files = cache.files.filter { seen.contains($0.key) }
        if persistCache { saveCache(cache) }
        return aggregate(cache.files, now: now)
    }

    /// ONE CALL BELONGS TO ONE FILE: a forked conversation starts with a
    /// copy of the steps before its fork point, so the same call can sit in
    /// two transcripts. Files are visited smallest path first and a call
    /// (or prompt) already claimed is skipped — a total order every process
    /// agrees on, recomputed from the cache alone.
    func aggregate(_ files: [String: AntigravityTranscript.Record], now: Date) -> TranscriptScan {
        var claimedCalls: Set<AntigravityTranscript.Call> = []
        var claimedPrompts: Set<AntigravityTranscript.Prompt> = []
        var byDay: [Date: DailyActivity] = [:]
        var slots: [SlotKey: TokenTally] = [:]
        let timelineCutoff = now.addingTimeInterval(-TranscriptScanner.timelineRetention)

        func day(_ date: Date) -> Date { calendar.startOfDay(for: date) }

        for path in files.keys.sorted() {
            guard let record = files[path] else { continue }
            for call in record.calls where claimedCalls.insert(call).inserted {
                let key = day(call.t)
                var merged = byDay[key] ?? DailyActivity(day: key, tokens: 0, messages: 0)
                merged.tokens += call.tally.total
                merged.messages += 1
                var sum = merged.models[call.model] ?? TokenTally()
                sum.add(call.tally)
                merged.models[call.model] = sum
                byDay[key] = merged
                guard call.t >= timelineCutoff else { continue }
                let minute = Date(
                    timeIntervalSince1970: (call.t.timeIntervalSince1970 / 60).rounded(.down) * 60)
                var slot = slots[SlotKey(t: minute, model: call.model)] ?? TokenTally()
                slot.add(call.tally)
                slots[SlotKey(t: minute, model: call.model)] = slot
            }
            for prompt in record.prompts where claimedPrompts.insert(prompt).inserted {
                let key = day(prompt.t)
                var merged = byDay[key] ?? DailyActivity(day: key, tokens: 0, messages: 0)
                merged.prompts += 1
                byDay[key] = merged
            }
        }
        let timeline = slots
            .map { TokenSlot(t: $0.key.t, model: $0.key.model, tally: $0.value) }
            .sorted { $0.t != $1.t ? $0.t < $1.t : $0.model < $1.model }
        return TranscriptScan(daily: byDay.values.sorted { $0.day < $1.day }, timeline: timeline)
    }

    private struct SlotKey: Hashable {
        let t: Date
        let model: String
    }

    // MARK: Cache

    private struct CacheFile: Codable {
        var version: Int
        var files: [String: AntigravityTranscript.Record]
    }

    /// v1 (antigravity's first): per-file calls and prompts, kept whole so
    /// cross-file ownership recomputes from the cache.
    private static let cacheVersion = 1

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
            // Best-effort, like every cache here: next scan just re-parses.
        }
    }
}

// MARK: - The CLI's home

/// Where things are in `~/.gemini/antigravity-cli`, and the only questions
/// asked of it before a transcript is read — answered by directory listings
/// and stats, never by opening a conversation database.
struct AntigravityHome: Sendable {
    let root: URL

    var conversationsDirectory: URL { root.appending(path: "conversations") }

    /// Conversation ids, from the names in `conversations/` — no `.db` is
    /// ever opened. Ids are UUID-shaped; anything else is ignored rather
    /// than turned into a path.
    func conversationIDs() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: conversationsDirectory.path)
        else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".db") else { return nil }
            let id = String(name.dropLast(3))
            return Self.isConversationID(id) ? id : nil
        }.sorted()
    }

    static func isConversationID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
                || ("A"..."F").contains(scalar) || scalar == "-"
        }
    }

    func transcriptURL(for id: String) -> URL {
        root.appending(path: "brain").appending(path: id)
            .appending(path: ".system_generated/logs/transcript.jsonl")
    }

    /// Whether any listed conversation has a transcript — the provider's
    /// "is there local data at all" question.
    func hasTranscripts() -> Bool {
        conversationIDs().contains {
            FileManager.default.fileExists(atPath: transcriptURL(for: $0).path)
        }
    }

    /// The newest write among the conversation files — what tells a window
    /// that rolled while the CLI sat idle from one that was spent unseen.
    func newestConversationWrite() -> Date? {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: conversationsDirectory.path)
        else { return nil }
        return names.compactMap { name -> Date? in
            guard name.hasSuffix(".db") || name.hasSuffix(".db-wal") else { return nil }
            let attributes = try? manager.attributesOfItem(
                atPath: conversationsDirectory.appending(path: name).path)
            return attributes?[.modificationDate] as? Date
        }.max()
    }
}

// MARK: - Transcript rows

/// One `transcript.jsonl`, reduced to what the meter may know.
enum AntigravityTranscript {
    /// The decoded slice of a row. Everything else on the row — `content`,
    /// `thinking`, `tool_calls` — is skipped by the decoder, never read
    /// into a value.
    struct Row: Decodable {
        let createdAt: String?
        let type: String?
        let source: String?
        let model: String?
        let inputTokens: Int?
        let cacheReadTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case createdAt = "created_at"
            case type
            case source
            case model
            case inputTokens = "input_tokens"
            case cacheReadTokens = "cache_read_tokens"
            case outputTokens = "output_tokens"
        }
    }

    /// One model call, whole — its identity across forked files is its
    /// timestamp, model and three counts together.
    struct Call: Codable, Hashable {
        let t: Date
        let model: String
        let input: Int
        let cacheRead: Int
        let output: Int

        var tally: TokenTally { TokenTally(input: input, output: output, cacheRead: cacheRead) }
    }

    /// One typed (or handed-over) prompt.
    struct Prompt: Codable, Hashable {
        let t: Date
        let source: String
    }

    struct Record: Codable {
        let mtime: Date
        let size: Int
        let calls: [Call]
        let prompts: [Prompt]
    }

    static func parse(url: URL, mtime: Date, size: Int) -> Record {
        guard let data = try? Data(contentsOf: url) else {
            return Record(mtime: mtime, size: size, calls: [], prompts: [])
        }
        return parse(data: data, mtime: mtime, size: size)
    }

    /// A line that doesn't decode — the CLI's half-written last line, or a
    /// shape this build doesn't know — is skipped; a growing file changes
    /// its size, so the next pass reads it whole.
    static func parse(data: Data, mtime: Date, size: Int) -> Record {
        var calls: [Call] = []
        var prompts: [Prompt] = []
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let row = try? decoder.decode(Row.self, from: Data(line)),
                  let stamp = row.createdAt.flatMap(FlexibleISO8601.date(from:))
            else { continue }
            if row.type == "USER_INPUT", row.source == "USER_EXPLICIT" {
                prompts.append(Prompt(t: stamp, source: "USER_EXPLICIT"))
                continue
            }
            // A call needs both halves stated: a row missing one is not a
            // call with zero tokens. A missing cache read is 0 — the CLI
            // writes an explicit 0 when nothing was cached.
            guard let model = row.model, !model.isEmpty,
                  let input = row.inputTokens, let output = row.outputTokens
            else { continue }
            let call = Call(
                t: stamp, model: AntigravityModels.baseID(model), input: max(0, input),
                cacheRead: max(0, row.cacheReadTokens ?? 0), output: max(0, output))
            guard call.tally.total > 0 else { continue }
            calls.append(call)
        }
        return Record(mtime: mtime, size: size, calls: calls, prompts: prompts)
    }
}

// MARK: - Model ids

enum AntigravityModels {
    /// The thinking-effort words the CLI appends to a model id
    /// (`gemini-4-neon-xhigh`). An ALLOWLIST: a model's own name often ends
    /// in a word too (`-lite`, `-preview`, `-trial`), so anything not listed
    /// stays on the id — and goes unpriced — rather than being guessed away.
    static let effortWords: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max"]

    /// The id a call is tallied and priced under: effort stripped, since
    /// the effort's cost already shows as thinking tokens in output.
    static func baseID(_ raw: String) -> String {
        guard let dash = raw.lastIndex(of: "-") else { return raw }
        let suffix = raw[raw.index(after: dash)...].lowercased()
        let base = raw[..<dash]
        guard effortWords.contains(suffix), !base.isEmpty else { return raw }
        return String(base)
    }
}
