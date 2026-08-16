import Foundation

/// Google's Gemini CLI behind the provider seam — the thinnest harness, and
/// honestly so. Google serves no limit percentages anywhere a local app can
/// read; the CLI itself counts requests locally. So the one meter here is a
/// LOCAL COUNT: prompts recorded today under `~/.gemini/tmp` against a
/// user-configurable daily cap (Google's quota grammar is requests/day,
/// reset midnight Pacific). Local-files-only like Codex: zero network, zero
/// credentials, `oauth_creds.json`/`google_accounts.json` never read
/// (spec §10). Unlike Codex there is no token data at all — activity paints
/// the heatmap's faint prompt-only days.
public struct GeminiProvider: UsageProvider {
    public let id = "gemini"
    public let serviceName = "Google AI"
    public let agentName = "Gemini CLI"
    public let links = ProviderLinks(
        planUpgrade: URL(string: "https://one.google.com/about/google-ai-plans"),
        usageSettings: nil)
    public let menuBarGlyph = "✦"
    /// Gemini blue #4285F4.
    public let accent = ProviderAccent(red: 0.259, green: 0.522, blue: 0.957)
    public let networkDestinations: [String] = []
    public let credentials: CredentialChain
    let tmpRoot: URL
    /// Test injection; the app path reads the preference key.
    let dailyCapOverride: Int?

    /// The assumed requests/day quota, adjustable in Settings (free tier
    /// 1,000; AI Pro 1,500; Ultra 2,000 as of 2026).
    public static let dailyCapKey = "gemini.dailyRequestCap"
    public static let defaultDailyCap = 1000

    public init(tmpRoot: URL? = nil, dailyCap: Int? = nil) {
        self.tmpRoot = tmpRoot
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gemini/tmp")
        self.dailyCapOverride = dailyCap
        self.credentials = CredentialChain(sources: [
            StaticCredentialSource(name: "local Gemini CLI files")
        ])
    }

    public func fetchRawUsage(accessToken: String) async throws -> Data {
        try GeminiTraces.usagePayload(root: tmpRoot, cap: dailyCap, now: Date())
    }

    public func snapshot(
        fromRawUsage body: Data, fetchedAt: Date, plan: PlanInfo?,
        thresholds: Thresholds
    ) throws -> Snapshot {
        try GeminiMeterBuilder.snapshot(fromPayload: body, thresholds: thresholds)
    }

    public func makeLocalActivity(cacheDirectory: URL) -> (any LocalActivitySource)? {
        GeminiActivitySource(root: tmpRoot)
    }

    public var agentSettings: (any AgentSettingsStore)? { nil }

    public var modelCatalog: ModelCatalog { .gemini }

    public var bundledRates: PricingTable {
        PricingTable(rates: [:], fetchedAt: .distantPast, source: .bundled)
    }

    public var pricingSelector: PricingFeedSelector { .gemini }

    public var preferences: [ProviderPreference] {
        [ProviderPreference(
            key: Self.dailyCapKey,
            title: "Assumed daily request cap",
            note: "Google enforces requests per day (1,000 free · 1,500 AI Pro · 2,000 Ultra, reset midnight Pacific) but serves no usage numbers — the meter counts this Mac's prompts against this assumption.",
            defaultValue: Self.defaultDailyCap,
            range: 100...5000,
            step: 100)]
    }

    var dailyCap: Int {
        if let dailyCapOverride { return dailyCapOverride }
        let stored = UserDefaults.standard.integer(forKey: Self.dailyCapKey)
        return stored > 0 ? stored : Self.defaultDailyCap
    }
}

// MARK: - Local traces

/// The serialized daily-count snapshot — this provider's "raw usage" bytes.
struct GeminiUsagePayload: Codable {
    let capturedAt: Date
    let promptsToday: Int
    let cap: Int
}

/// Read-only walk of `~/.gemini/tmp/<project-hash>/`: `logs.json` (the
/// prompt log — only `timestamp`/`type` are decoded, message text is never
/// materialized) and `chats/session-*.jsonl` headers ({sessionId,
/// startTime, …}). Nothing inside is ever written (spec §10).
enum GeminiTraces {
    struct LogEntry: Decodable {
        let timestamp: String?
        let type: String?
    }

    struct SessionHeader: Decodable {
        let startTime: String?
    }

    /// Prompt counts per local calendar day, from every project's log;
    /// days with sessions but no log entries count each session once so a
    /// wiped or empty log still leaves a footprint.
    static func promptDays(root: URL, calendar: Calendar = .current) -> [Date: Int] {
        var logDays: [Date: Int] = [:]
        var sessionDays: [Date: Int] = [:]
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [:] }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "logs.json" {
                guard let data = try? Data(contentsOf: url),
                      let entries = try? JSONDecoder().decode([LogEntry].self, from: data)
                else { continue }
                for entry in entries where entry.type == "user" {
                    guard let stamp = entry.timestamp.flatMap(FlexibleISO8601.date(from:))
                    else { continue }
                    logDays[calendar.startOfDay(for: stamp), default: 0] += 1
                }
            } else if url.pathExtension == "jsonl",
                      url.deletingLastPathComponent().lastPathComponent == "chats" {
                guard let header = firstLineHeader(of: url),
                      let stamp = header.startTime.flatMap(FlexibleISO8601.date(from:))
                else { continue }
                sessionDays[calendar.startOfDay(for: stamp), default: 0] += 1
            }
        }
        var days = logDays
        for (day, count) in sessionDays where days[day] == nil {
            days[day] = count
        }
        return days
    }

    static func usagePayload(root: URL, cap: Int, now: Date) throws -> Data {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw UsageClientError.noLocalData }
        let today = Calendar.current.startOfDay(for: now)
        let count = promptDays(root: root)[today] ?? 0
        let payload = GeminiUsagePayload(capturedAt: now, promptsToday: count, cap: max(1, cap))
        guard let data = try? JSONEncoder().encode(payload) else {
            throw UsageClientError.noLocalData
        }
        return data
    }

    private static func firstLineHeader(of url: URL) -> SessionHeader? {
        guard let data = try? Data(contentsOf: url),
              let line = data.split(separator: UInt8(ascii: "\n")).first
        else { return nil }
        return try? JSONDecoder().decode(SessionHeader.self, from: Data(line))
    }
}

// MARK: - Meter

/// One derived meter: today's locally counted prompts vs the assumed cap.
/// Unlike Codex's served percentages this is never stale — a zero count is
/// fresh information — so `fetchedAt` is the count time itself.
enum GeminiMeterBuilder {
    static func snapshot(
        fromPayload body: Data, thresholds: Thresholds
    ) throws -> Snapshot {
        let payload = try JSONDecoder().decode(GeminiUsagePayload.self, from: body)
        let percent = min(100, Int((Double(payload.promptsToday) / Double(payload.cap) * 100).rounded()))
        let meter = Meter(
            id: "0-daily",
            label: "Daily · counted locally",
            percent: percent,
            resetsAt: nextPacificMidnight(after: payload.capturedAt),
            level: MeterBuilder.level(
                percent: percent, forcesWarning: false, thresholds: thresholds),
            rank: 0,
            limitWindow: 24 * 3600,
            forcesWarning: false,
            scopedModelName: nil)
        return Snapshot(meters: [meter], fetchedAt: payload.capturedAt)
    }

    /// Google's daily quotas reset at midnight America/Los_Angeles.
    static func nextPacificMidnight(after date: Date) -> Date? {
        guard let zone = TimeZone(identifier: "America/Los_Angeles") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)
    }
}

// MARK: - Local activity

/// Gemini's traces carry no token counts — sessions and prompts paint the
/// heatmap's faint prompt-only days, and that's the whole story.
public struct GeminiActivitySource: LocalActivitySource {
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var watchDirectories: [URL] { [root] }
    public var displayPath: String { "~/.gemini/tmp" }

    public func scanTranscripts(now: Date) -> TranscriptScan {
        TranscriptScan(daily: [], timeline: [])
    }

    public func scanTranscriptsReadOnly(now: Date) -> TranscriptScan {
        scanTranscripts(now: now)
    }

    public func scanPromptDays() -> [Date: Int] {
        GeminiTraces.promptDays(root: root)
    }

    public func diskUsage(now: Date) -> TranscriptDiskUsage? {
        TranscriptDiskUsage.measure(root: root, now: now)
    }
}

// MARK: - Catalog

extension ModelCatalog {
    /// Gemini id grammar: "gemini-3-pro-20260115" → "Gemini 3 Pro" (trailing
    /// 8-digit dates are releases, not versions). Families carry the tier
    /// word — Pro ahead of Flash ahead of the lightweights.
    public static let gemini = ModelCatalog(
        displayName: { geminiDisplayName($0) },
        familyName: { id in
            guard id != "unknown" else { return "Other" }
            let words = geminiDisplayName(id).split(separator: " ").map(String.init)
            let tiers: Set<String> = ["Pro", "Flash", "Lite", "Nano"]
            if let tier = words.first(where: { tiers.contains($0) }) {
                return "Gemini \(tier)"
            }
            return words.first ?? id
        },
        familyRank: { family in
            switch family.lowercased() {
            case "gemini pro": 0
            case "gemini flash": 1
            case "gemini lite", "gemini nano": 2
            case "other": 4
            default: 3
            }
        }
    )
}

private func geminiDisplayName(_ id: String) -> String {
    guard id != "unknown" else { return "Other" }
    var tokens = id.split(separator: "-").map(String.init)
    if let last = tokens.last, last.count == 8, last.allSatisfy(\.isNumber) {
        tokens.removeLast()
    }
    return tokens.map { token in
        token.allSatisfy { $0.isNumber || $0 == "." } ? token : token.capitalized
    }.joined(separator: " ")
}
