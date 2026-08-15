import Foundation

/// OpenAI's Codex CLI behind the provider seam — a LOCAL-FILES-ONLY
/// provider. Codex writes the server's own rate-limit snapshot (used
/// percent + reset per window) into every session's rollout JSONL, so
/// meters need no network and no credentials: `~/.codex/auth.json` is
/// deliberately never read, nothing is fetched, and `networkDestinations`
/// is empty (spec §10: the only new surface is a read-only walk of
/// `~/.codex/sessions`). The price of local-only: meters are as fresh as
/// the last Codex session — the day-aware "Updated" stamp says so.
public struct CodexProvider: UsageProvider {
    public let id = "codex"
    public let serviceName = "ChatGPT"
    public let agentName = "Codex"
    public let links = ProviderLinks(
        planUpgrade: URL(string: "https://openai.com/chatgpt/pricing"),
        usageSettings: nil)
    public let menuBarGlyph = "⬡"
    /// OpenAI green #10A37F.
    public let accent = ProviderAccent(red: 0.063, green: 0.639, blue: 0.498)
    public let networkDestinations: [String] = []
    public let credentials: CredentialChain
    let sessionsRoot: URL

    public init(sessionsRoot: URL? = nil) {
        self.sessionsRoot = sessionsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
        self.credentials = CredentialChain(sources: [
            StaticCredentialSource(name: "local Codex sessions")
        ])
    }

    /// Ignores the token — "fetching" is reading the newest rate-limit
    /// snapshot out of the rollout files, then serializing it so the
    /// offline cache can replay it like any provider's raw bytes.
    public func fetchRawUsage(accessToken: String) async throws -> Data {
        try CodexRollouts.latestUsagePayload(root: sessionsRoot)
    }

    public func snapshot(
        fromRawUsage body: Data, fetchedAt: Date, plan: PlanInfo?,
        thresholds: Thresholds
    ) throws -> Snapshot {
        try CodexMeterBuilder.snapshot(fromPayload: body, thresholds: thresholds)
    }

    public func makeLocalActivity(cacheDirectory: URL) -> (any LocalActivitySource)? {
        CodexActivitySource(root: sessionsRoot, cacheDirectory: cacheDirectory)
    }

    /// Codex has no sanctioned retention setting to mirror — the card hides.
    public var agentSettings: (any AgentSettingsStore)? { nil }

    public var modelCatalog: ModelCatalog { .codex }

    /// No bundled floor: OpenAI list prices arrive via the pricing feed's
    /// openai slice; until then codex models cost "—" rather than a stale
    /// hardcoded guess.
    public var bundledRates: PricingTable {
        PricingTable(rates: [:], fetchedAt: .distantPast, source: .bundled)
    }

    public var pricingSelector: PricingFeedSelector { .openAI }
}

// MARK: - Rollout reading

/// The serialized form of one captured rate-limit snapshot — the provider's
/// "raw usage" bytes. JSON so the usage cache replays it across launches.
struct CodexUsagePayload: Codable {
    struct Window: Codable {
        let usedPercent: Double
        let windowMinutes: Int
        let resetsAt: Date?
    }

    /// The token_count event's own timestamp — the snapshot's honest age.
    let capturedAt: Date
    let planType: String?
    let primary: Window?
    let secondary: Window?
}

/// Read-only walk of `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
/// Nothing inside the tree is ever written (spec §10); legacy 2025-era
/// `.json` rollouts are ignored. Every field decodes as optional — the
/// rollout schema drifted between observed CLI versions and will again.
enum CodexRollouts {
    /// Newest-first rollout files, ordered by mtime.
    static func rolloutFiles(root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        var dated: [(URL, Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }
            dated.append((url, values.contentModificationDate ?? .distantPast))
        }
        return dated.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The last rate-limit snapshot Codex recorded, searching newest
    /// sessions first. Sessions against local model providers carry
    /// token_count events with empty rate_limits — those are skipped, so
    /// the walk continues until a ChatGPT-backed session is found.
    static func latestUsagePayload(root: URL, fileLimit: Int = 20) throws -> Data {
        for url in rolloutFiles(root: root).prefix(fileLimit) {
            guard let payload = lastRateLimitSnapshot(in: url) else { continue }
            guard let data = try? JSONEncoder().encode(payload) else { continue }
            return data
        }
        throw UsageClientError.noLocalData
    }

    private static func lastRateLimitSnapshot(in url: URL) -> CodexUsagePayload? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var latest: CodexUsagePayload?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? JSONDecoder().decode(RolloutLine.self, from: Data(line)),
                  record.type == "event_msg",
                  let payload = record.payload, payload.type == "token_count",
                  let limits = payload.rateLimits,
                  limits.primary != nil || limits.secondary != nil,
                  let stamp = record.timestamp.flatMap(FlexibleISO8601.date(from:))
            else { continue }
            latest = CodexUsagePayload(
                capturedAt: stamp,
                planType: limits.planType,
                primary: limits.primary.map(window(from:)),
                secondary: limits.secondary.map(window(from:)))
        }
        return latest
    }

    private static func window(from limit: RolloutLine.RateWindow) -> CodexUsagePayload.Window {
        CodexUsagePayload.Window(
            usedPercent: limit.usedPercent ?? 0,
            windowMinutes: limit.windowMinutes ?? 0,
            resetsAt: limit.resetsAt.map { Date(timeIntervalSince1970: $0) })
    }

    /// One rollout line, decoded leniently. Only the fields this provider
    /// reads are named; unknown fields and record types pass through.
    struct RolloutLine: Decodable {
        struct Payload: Decodable {
            let type: String?
            let model: String?
            let info: TokenInfo?
            let rateLimits: RateLimits?

            enum CodingKeys: String, CodingKey {
                case type, model, info
                case rateLimits = "rate_limits"
            }
        }

        struct TokenInfo: Decodable {
            let lastTokenUsage: TokenUsage?

            enum CodingKeys: String, CodingKey {
                case lastTokenUsage = "last_token_usage"
            }
        }

        struct TokenUsage: Decodable {
            let inputTokens: Int?
            let cachedInputTokens: Int?
            let outputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case cachedInputTokens = "cached_input_tokens"
                case outputTokens = "output_tokens"
            }
        }

        struct RateLimits: Decodable {
            let primary: RateWindow?
            let secondary: RateWindow?
            let planType: String?

            enum CodingKeys: String, CodingKey {
                case primary, secondary
                case planType = "plan_type"
            }
        }

        struct RateWindow: Decodable {
            let usedPercent: Double?
            let windowMinutes: Int?
            let resetsAt: Double?

            enum CodingKeys: String, CodingKey {
                case usedPercent = "used_percent"
                case windowMinutes = "window_minutes"
                case resetsAt = "resets_at"
            }
        }

        let timestamp: String?
        let type: String?
        let payload: Payload?
    }
}

// MARK: - Meters

/// Codex payload → normalized meters. The one place its window vocabulary
/// (primary = rolling session, secondary = weekly) becomes `Meter` data.
enum CodexMeterBuilder {
    static func snapshot(
        fromPayload body: Data, thresholds: Thresholds, now: Date = Date()
    ) throws -> Snapshot {
        let payload = try JSONDecoder().decode(CodexUsagePayload.self, from: body)
        var meters: [Meter] = []
        if let primary = payload.primary {
            meters.append(meter(
                from: primary, id: "0-session", label: sessionLabel(minutes: primary.windowMinutes),
                rank: 0, thresholds: thresholds, now: now))
        }
        if let secondary = payload.secondary {
            meters.append(meter(
                from: secondary, id: "1-weekly", label: weeklyLabel(minutes: secondary.windowMinutes),
                rank: 1, thresholds: thresholds, now: now))
        }
        let plan = payload.planType.map {
            PlanInfo(subscriptionType: $0, rateLimitTier: nil)
        }
        return Snapshot(meters: meters, fetchedAt: payload.capturedAt, plan: plan)
    }

    /// A window whose reset already passed has rolled over since the last
    /// session: the recorded percent describes a spent window, so it reads
    /// as 0 with no reset shown (the next boundary is server-side state a
    /// local provider can't know).
    private static func meter(
        from window: CodexUsagePayload.Window, id: String, label: String, rank: Int,
        thresholds: Thresholds, now: Date
    ) -> Meter {
        let expired = window.resetsAt.map { $0 < now } ?? false
        let percent = expired ? 0 : Int(window.usedPercent.rounded()).clamped(to: 0...100)
        return Meter(
            id: id,
            label: label,
            percent: percent,
            resetsAt: expired ? nil : window.resetsAt,
            level: MeterBuilder.level(
                percent: percent, forcesWarning: false, thresholds: thresholds),
            rank: rank,
            limitWindow: window.windowMinutes > 0
                ? TimeInterval(window.windowMinutes * 60) : nil,
            forcesWarning: false,
            scopedModelName: nil)
    }

    private static func sessionLabel(minutes: Int) -> String {
        minutes > 0 ? "Session (\(minutes / 60)h)" : "Session"
    }

    private static func weeklyLabel(minutes: Int) -> String {
        minutes == 10080 || minutes == 0 ? "Weekly" : "Window (\(minutes / 1440)d)"
    }
}

extension Int {
    fileprivate func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

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
            if let record = cache.files[path], record.mtime == mtime, record.size == size {
                continue
            }
            cache.files[path] = parse(url: url, mtime: mtime, size: size)
        }
        cache.files = cache.files.filter { seen.contains($0.key) }
        saveCache(cache)

        var byDay: [Date: DailyActivity] = [:]
        var slots: [SlotKey: TokenTally] = [:]
        let timelineCutoff = now.addingTimeInterval(-TranscriptScanner.timelineRetention)
        for record in cache.files.values {
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
        return TranscriptScan(
            daily: byDay.values.sorted { $0.day < $1.day }, timeline: timeline)
    }

    /// Prompt days ride the transcript scan itself (user_message events);
    /// Codex keeps no separate prompt log that outlives its rollouts.
    public func scanPromptDays() -> [Date: Int] { [:] }

    public func diskUsage(now: Date) -> TranscriptDiskUsage? {
        TranscriptDiskUsage.measure(root: root, now: now)
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
    }

    private struct DayTally: Codable {
        let day: Date
        var tokens: Int
        var messages: Int
        var prompts: Int
        var models: [String: TokenTally]
    }

    private static let cacheVersion = 1

    private func parse(url: URL, mtime: Date, size: Int) -> FileRecord {
        var slots: [SlotKey: TokenTally] = [:]
        var days: [Date: DayTally] = [:]
        var currentModel = "unknown"
        if let data = try? Data(contentsOf: url) {
            for line in data.split(separator: UInt8(ascii: "\n")) {
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
                let day = calendar.startOfDay(for: stamp)
                switch payload.type {
                case "user_message":
                    var tally = days[day] ?? DayTally(
                        day: day, tokens: 0, messages: 0, prompts: 0, models: [:])
                    tally.prompts += 1
                    days[day] = tally
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
                default:
                    continue
                }
            }
        }
        return FileRecord(
            mtime: mtime, size: size,
            slots: slots
                .map { TokenSlot(t: $0.key.t, model: $0.key.model, tally: $0.value) }
                .sorted { $0.t < $1.t },
            days: days.values.sorted { $0.day < $1.day })
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

// MARK: - Catalog

extension ModelCatalog {
    /// Codex id grammar: "gpt-5.2-codex" → "GPT 5.2 Codex". Codex-tuned
    /// models family together ahead of general GPT ids; unknowns last.
    public static let codex = ModelCatalog(
        displayName: { codexDisplayName($0) },
        familyName: { id in
            guard id != "unknown" else { return "Other" }
            return id.lowercased().contains("codex")
                ? "Codex"
                : codexDisplayName(id).split(separator: " ").first.map(String.init) ?? id
        },
        familyRank: { family in
            switch family.lowercased() {
            case "codex": 0
            case "gpt": 1
            case "other": 3
            default: 2
            }
        }
    )
}

private func codexDisplayName(_ id: String) -> String {
    guard id != "unknown" else { return "Other" }
    return id.split(separator: "-").map { token in
        let text = String(token)
        if text.lowercased() == "gpt" { return "GPT" }
        if text.allSatisfy({ $0.isNumber || $0 == "." }) { return text }
        return text.capitalized
    }.joined(separator: " ")
}
