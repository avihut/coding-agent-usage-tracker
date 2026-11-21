import Foundation

// MARK: - Local activity

/// Codex's on-disk traces: per-turn token deltas and the active model out
/// of the rollout JSONLs, aggregated exactly like Claude's transcripts —
/// per-minute timeline slots and per-day tallies. Strictly read-only; its
/// only artifact is an mtime/size-keyed parse cache in this app's own
/// scoped Application Support directory.
public struct CodexActivitySource: LocalActivitySource {
    private let root: URL
    private let cacheURL: URL
    private let calendar: Calendar

    public init(root: URL, cacheDirectory: URL, calendar: Calendar = .current) {
        self.root = root
        self.cacheURL = cacheDirectory.appending(path: "activity-cache.json")
        self.calendar = calendar
    }

    public var watchDirectories: [URL] { [root] }
    public var displayPath: String { "~/.codex/sessions" }

    public func scanTranscripts(now: Date) -> TranscriptScan {
        scan(now: now, persistCache: true)
    }

    public func scanTranscriptsReadOnly(now: Date) -> TranscriptScan {
        scan(now: now, persistCache: false)
    }

    private func scan(now: Date, persistCache: Bool) -> TranscriptScan {
        var cache = loadCache()
        var seen: Set<String> = []
        for url in CodexRollouts.rolloutFiles(root: root) {
            let path = url.path
            seen.insert(path)
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { continue }
            let mtime = values.contentModificationDate ?? .distantPast
            let size = values.fileSize ?? 0
            if let record = cache.files[path], record.mtime == mtime, record.size == size,
               record.undecodable.map({ $0 == ZstdDecoder.revision }) ?? true {
                continue
            }
            // Nil — the file couldn't be read (gone between the walk and the
            // open, permissions, I/O) — caches nothing: the next scan retries,
            // and a record already held stands until then rather than the
            // session vanishing for a scan. A file really gone leaves `seen`.
            if let record = parse(url: url, mtime: mtime, size: size) {
                cache.files[path] = record
            }
        }
        cache.files = cache.files.filter { seen.contains($0.key) }
        if persistCache { saveCache(cache) }

        let rollouts = Self.onePerRollout(cache.files)
        var byDay: [Date: DailyActivity] = [:]
        var slots: [SlotKey: TokenTally] = [:]
        let timelineCutoff = now.addingTimeInterval(-TranscriptScanner.timelineRetention)
        for record in rollouts.values {
            for day in record.days {
                var merged = byDay[day.day]
                    ?? DailyActivity(day: day.day, tokens: 0, messages: 0)
                merged.tokens += day.tokens
                merged.messages += day.messages
                merged.prompts += day.prompts
                for (model, tally) in day.models {
                    var sum = merged.models[model] ?? TokenTally()
                    sum.add(tally)
                    merged.models[model] = sum
                }
                byDay[day.day] = merged
            }
            for slot in record.slots where slot.t >= timelineCutoff {
                var sum = slots[SlotKey(t: slot.t, model: slot.model)] ?? TokenTally()
                sum.add(slot.tally)
                slots[SlotKey(t: slot.t, model: slot.model)] = sum
            }
        }
        let timeline = slots
            .map { TokenSlot(t: $0.key.t, model: $0.key.model, tally: $0.value) }
            .sorted { $0.t != $1.t ? $0.t < $1.t : $0.model < $1.model }
        let sessions = rollouts
            .compactMap { id, record in sessionSummary(id: id, record: record) }
            .sorted { $0.end > $1.end }
        return TranscriptScan(
            daily: byDay.values.sorted { $0.day < $1.day }, timeline: timeline,
            sessions: sessions)
    }

    /// ONE record per rollout, keyed by its id: the same rollout can sit
    /// under both names for a moment (Codex compressing it, or re-inflating
    /// it to resume), and counting both would double it. A readable record
    /// beats an undecodable one; then plain beats compressed — Codex's own
    /// rule, since the plain copy is the original or the live, resumed one.
    private static func onePerRollout(_ files: [String: FileRecord]) -> [String: FileRecord] {
        func rank(_ path: String, _ record: FileRecord) -> Int {
            (record.undecodable == nil ? 2 : 0)
                + (CodexRollouts.isCompressed(URL(fileURLWithPath: path)) ? 0 : 1)
        }
        var chosen: [String: (path: String, record: FileRecord)] = [:]
        for (path, record) in files {
            let id = CodexRollouts.rolloutID(of: URL(fileURLWithPath: path))
            if let current = chosen[id] {
                let mine = rank(path, record)
                let theirs = rank(current.path, current.record)
                // A tie falls to the path, so every scan picks the same file.
                guard mine != theirs ? mine > theirs : path < current.path else { continue }
            }
            chosen[id] = (path, record)
        }
        return chosen.mapValues(\.record)
    }

    /// Prompt days ride the transcript scan itself (user_message events);
    /// Codex keeps no separate prompt log that outlives its rollouts.
    public func scanPromptDays() -> [Date: Int] { [:] }

    public func diskUsage(now: Date) -> TranscriptDiskUsage? {
        TranscriptDiskUsage.measure(root: root, now: now)
    }

    // MARK: Sessions

    public var providesSessions: Bool { true }

    /// One rollout = one session; there is no subagent join and no
    /// headless marker (all Codex sessions read as interactive).
    public func sessionDetail(id: String) -> SessionDetail? {
        guard let (record, lines) = readableRollout(id: id),
              let summary = sessionSummary(id: id, record: record)
        else { return nil }

        var rows: [SessionEvent] = []
        var currentModel = "unknown"
        var truncated = false
        var lineNumber = 0
        for line in lines {
            lineNumber += 1
            if lineNumber % 2048 == 0, Task.isCancelled { return nil }
            guard let record = try? JSONDecoder().decode(
                CodexRollouts.RolloutLine.self, from: Data(line))
            else { continue }
            if record.type == "turn_context", let model = record.payload?.model {
                currentModel = model
                continue
            }
            guard record.type == "event_msg", let payload = record.payload,
                  let stamp = record.timestamp.flatMap(FlexibleISO8601.date(from:))
            else { continue }
            guard rows.count < TranscriptScanner.detailRowCap else {
                truncated = true
                break
            }
            switch payload.type {
            case "user_message":
                if let text = payload.message, let preview = PromptPreview.scrub(text) {
                    rows.append(SessionEvent(
                        id: rows.count, t: stamp, kind: .prompt(preview: preview)))
                }
            case "token_count":
                guard let usage = payload.info?.lastTokenUsage else { continue }
                let cached = usage.cachedInputTokens ?? 0
                let delta = TokenTally(
                    input: max(0, (usage.inputTokens ?? 0) - cached),
                    output: usage.outputTokens ?? 0,
                    cacheRead: cached)
                guard delta.total > 0 else { continue }
                rows.append(SessionEvent(
                    id: rows.count, t: stamp,
                    kind: .apiCall(model: currentModel, tally: delta, toolUses: 0)))
            default:
                continue
            }
        }
        // The file changed under us between the two reads.
        if lines.failure != nil { return nil }
        if truncated {
            rows.append(SessionEvent(
                id: rows.count, t: summary.end,
                kind: .command(name: "… breakdown truncated")))
        }
        return SessionDetail(summary: summary, rows: rows)
    }

    /// The rollout behind a session id, parsed, and its lines opened again
    /// for the rows: the plain file first, its compressed twin if the plain
    /// one is gone, unreadable or vanishes between the two opens. Both reads
    /// stop on cancellation — a click through the sidebar must not queue
    /// whole-file decodes nobody will see.
    private func readableRollout(id: String) -> (FileRecord, LineReader)? {
        let candidates = CodexRollouts.rolloutFiles(root: root)
            .filter { CodexRollouts.rolloutID(of: $0) == id }
            .sorted { !CodexRollouts.isCompressed($0) && CodexRollouts.isCompressed($1) }
        for url in candidates {
            guard !Task.isCancelled else { return nil }
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]),
                let record = parse(
                    url: url, mtime: values.contentModificationDate ?? .distantPast,
                    size: values.fileSize ?? 0, stopsWhenCancelled: true),
                record.undecodable == nil,
                let lines = CodexRollouts.lines(of: url, stopsWhenCancelled: true)
            else { continue }
            return (record, lines)
        }
        return nil
    }

    private func sessionSummary(id: String, record: FileRecord) -> SessionSummary? {
        guard let meta = record.session else { return nil }
        var apiCalls = 0
        var prompts = 0
        var models: [String: TokenTally] = [:]
        for day in record.days {
            apiCalls += day.messages
            prompts += day.prompts
            for (model, tally) in day.models {
                var sum = models[model] ?? TokenTally()
                sum.add(tally)
                models[model] = sum
            }
        }
        guard apiCalls > 0 || prompts > 0,
              let start = meta.start, let end = meta.end
        else { return nil }
        // Per-file stretches are already stitched and non-overlapping, so
        // their plain sum IS the union (no subagents to overlap with).
        let active = meta.stretches.reduce(0.0) { $0 + $1.duration }
        return SessionSummary(
            id: id,
            title: meta.title ?? Self.fallbackTitle(for: start),
            projectPath: meta.cwd,
            gitBranch: nil,
            agentVersion: meta.cliVersion,
            kind: .interactive,
            start: start,
            end: end,
            activeSeconds: active,
            prompts: prompts,
            apiCalls: apiCalls,
            toolCalls: 0,
            subagentCount: 0,
            compactions: 0,
            models: models)
    }

    private static func fallbackTitle(for start: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return "Session · \(formatter.string(from: start))"
    }

    // MARK: Parsing

    private struct SlotKey: Hashable {
        let t: Date
        let model: String
    }

    private struct CacheFile: Codable {
        var version: Int
        var files: [String: FileRecord]
    }

    private struct FileRecord: Codable {
        let mtime: Date
        let size: Int
        let slots: [TokenSlot]
        let days: [DayTally]
        let session: SessionMeta?
        /// Set when the file's compressed bytes didn't decode: the decoder
        /// revision that refused them. The record is then empty and counts
        /// for nothing; a newer revision retries it (a compressed rollout
        /// never changes, so a verdict without one would be permanent).
        /// Optional, so every cache entry written before it still decodes —
        /// which is why reading compressed rollouts (2026-11-21) needed no
        /// `cacheVersion` bump: it changed no record a plain file produces, a
        /// `.jsonl.zst` path is simply new, and a bump costs a whole-corpus
        /// re-parse. A decoder fix that changes the OUTPUT of a frame it
        /// already accepted does need one: only `undecodable` is retried.
        var undecodable: Int? = nil

        enum CodingKeys: String, CodingKey {
            case mtime, size, slots, days, session, undecodable
        }
    }

    private struct DayTally: Codable {
        let day: Date
        var tokens: Int
        var messages: Int
        var prompts: Int
        var models: [String: TokenTally]
    }

    /// The per-file session half (cache v2). `title` holds the scrubbed
    /// first-prompt preview — the one sanctioned prompt-text persistence,
    /// mirroring the Claude scanner's contract (spec §10). Calls, prompts,
    /// and models stay derived from `days`, never stored twice.
    private struct SessionMeta: Codable {
        var title: String?
        var cwd: String?
        var cliVersion: String?
        var start: Date?
        var end: Date?
        var stretches: [DateInterval] = []
    }

    /// v2 (0.31.0): per-file session summaries joined the cache.
    private static let cacheVersion = 2

    /// Nil when the file couldn't be read at all (gone, permissions, I/O) —
    /// not cached, so the next scan retries it.
    private func parse(
        url: URL, mtime: Date, size: Int, stopsWhenCancelled: Bool = false
    ) -> FileRecord? {
        var slots: [SlotKey: TokenTally] = [:]
        var days: [Date: DayTally] = [:]
        var currentModel = "unknown"
        var meta = SessionMeta()
        var activeMinutes: Set<Date> = []

        func touch(_ date: Date) {
            if meta.start.map({ date < $0 }) ?? true { meta.start = date }
            if meta.end.map({ date > $0 }) ?? true { meta.end = date }
        }

        if let lines = CodexRollouts.lines(of: url, stopsWhenCancelled: stopsWhenCancelled) {
            for line in lines {
                guard let record = try? JSONDecoder().decode(
                    CodexRollouts.RolloutLine.self, from: Data(line))
                else { continue }
                if record.type == "turn_context", let model = record.payload?.model {
                    currentModel = model
                    continue
                }
                if record.type == "session_meta", let payload = record.payload {
                    if meta.cwd == nil { meta.cwd = payload.cwd }
                    if meta.cliVersion == nil { meta.cliVersion = payload.cliVersion }
                    continue
                }
                guard record.type == "event_msg", let payload = record.payload,
                      let stamp = record.timestamp.flatMap(FlexibleISO8601.date(from:))
                else { continue }
                let day = calendar.startOfDay(for: stamp)
                switch payload.type {
                case "user_message":
                    var tally = days[day] ?? DayTally(
                        day: day, tokens: 0, messages: 0, prompts: 0, models: [:])
                    tally.prompts += 1
                    days[day] = tally
                    touch(stamp)
                    if meta.title == nil, let text = payload.message {
                        meta.title = PromptPreview.scrub(text)
                    }
                case "token_count":
                    guard let usage = payload.info?.lastTokenUsage else { continue }
                    let cached = usage.cachedInputTokens ?? 0
                    let delta = TokenTally(
                        input: max(0, (usage.inputTokens ?? 0) - cached),
                        output: usage.outputTokens ?? 0,
                        cacheRead: cached)
                    guard delta.total > 0 else { continue }
                    let minute = Date(
                        timeIntervalSince1970: (stamp.timeIntervalSince1970 / 60)
                            .rounded(.down) * 60)
                    var slot = slots[SlotKey(t: minute, model: currentModel)] ?? TokenTally()
                    slot.add(delta)
                    slots[SlotKey(t: minute, model: currentModel)] = slot
                    var tally = days[day] ?? DayTally(
                        day: day, tokens: 0, messages: 0, prompts: 0, models: [:])
                    tally.tokens += delta.total
                    tally.messages += 1
                    var model = tally.models[currentModel] ?? TokenTally()
                    model.add(delta)
                    tally.models[currentModel] = model
                    days[day] = tally
                    touch(stamp)
                    activeMinutes.insert(minute)
                default:
                    continue
                }
            }
            // A stream that failed part-way counts for nothing — never half a
            // file. Bad bytes are remembered (by decoder revision); a read
            // error is retried.
            if let failure = lines.failure {
                guard failure.isFormatError else { return nil }
                return FileRecord(
                    mtime: mtime, size: size, slots: [], days: [], session: nil,
                    undecodable: ZstdDecoder.revision)
            }
        } else {
            return nil
        }
        if !activeMinutes.isEmpty {
            // Chronological before stitching — stitch merges garbage silently
            // on unsorted input.
            let runs = activeMinutes.sorted().map { DateInterval(start: $0, duration: 60) }
            meta.stretches = ActivityGrace.stitch(runs, grace: ActivityGrace.defaultSeconds)
        }
        return FileRecord(
            mtime: mtime, size: size,
            slots: slots
                .map { TokenSlot(t: $0.key.t, model: $0.key.model, tally: $0.value) }
                .sorted { $0.t < $1.t },
            days: days.values.sorted { $0.day < $1.day },
            session: meta.start == nil && meta.title == nil ? nil : meta)
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
            // Best-effort, like every cache here: next scan just re-parses.
        }
    }
}
