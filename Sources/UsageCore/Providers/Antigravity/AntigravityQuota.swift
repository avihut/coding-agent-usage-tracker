import Foundation

// MARK: - The kept reading

/// What the status-line export keeps of one Antigravity status-line
/// payload: the quota buckets, the plan tier and the CLI version — and when
/// it was captured. Nothing else of the payload (email, working directory,
/// transcript path, conversation title, model) is ever decoded.
struct AntigravityQuotaReading: Codable, Equatable {
    struct Bucket: Codable, Equatable {
        /// The CLI's bucket id: `gemini-5h`, `gemini-weekly`, `3p-weekly`, …
        let id: String
        /// 0…1, how much of the bucket is left; nil when the bucket reports
        /// an amount instead (no percent can honestly be drawn from that).
        let remainingFraction: Double?
        /// Absolute — computed at capture from `reset_time`, or from
        /// `reset_in_seconds` when only that was given.
        let resetsAt: Date?
        let disabled: Bool

        // Explicit: this file is written by `usage-cli` and read by the
        // engine, possibly from different builds — a renamed property must
        // never quietly change the format.
        enum CodingKeys: String, CodingKey {
            case id, remainingFraction, resetsAt, disabled
        }
    }

    static let currentVersion = 1

    let version: Int
    let capturedAt: Date
    let planTier: String?
    let cliVersion: String?
    let buckets: [Bucket]

    enum CodingKeys: String, CodingKey {
        case version, capturedAt, planTier, cliVersion, buckets
    }
}

/// The provider's "raw usage" bytes: the reading (if any) plus the two
/// facts the meters need that the reading can't carry — when this fetch
/// ran, and when a conversation was last written.
struct AntigravityUsagePayload: Codable {
    let fetchedAt: Date
    let reading: AntigravityQuotaReading?
    let conversationWrittenAt: Date?

    enum CodingKeys: String, CodingKey {
        case fetchedAt, reading, conversationWrittenAt
    }
}

enum AntigravityQuota {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func decodeReading(_ data: Data) -> AntigravityQuotaReading? {
        guard let reading = try? decoder().decode(AntigravityQuotaReading.self, from: data),
              reading.version == AntigravityQuotaReading.currentVersion
        else { return nil }
        return reading
    }

    static func encodePayload(_ payload: AntigravityUsagePayload) throws -> Data {
        do {
            return try encoder().encode(payload)
        } catch {
            throw UsageClientError.noLocalData
        }
    }

    // MARK: Reduce (the status-line side)

    /// The slice of the status-line payload ever decoded. LENIENT ALL THE
    /// WAY DOWN (the payload's shape is the vendor's, and a status line that
    /// silently stops reporting is the worst failure here): a field of an
    /// unexpected type reads as absent, and a bucket that doesn't decode is
    /// dropped on its own, never the whole reading.
    private struct StatusLine: Decodable {
        let quota: [String: Entry]
        let planTier: String?
        let version: String?

        enum CodingKeys: String, CodingKey {
            case quota
            case planTier = "plan_tier"
            case version
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            planTier = try? container.decodeIfPresent(String.self, forKey: .planTier)
            version = try? container.decodeIfPresent(String.self, forKey: .version)
            let raw = try? container.decodeIfPresent([String: Lenient<Entry>].self, forKey: .quota)
            quota = (raw ?? nil)?.compactMapValues(\.value) ?? [:]
        }

        struct Lenient<T: Decodable>: Decodable {
            let value: T?
            init(from decoder: Decoder) { value = try? T(from: decoder) }
        }

        struct Entry: Decodable {
            let remainingFraction: Double?
            /// Whether the bucket states an AMOUNT left (no percent can be
            /// drawn from one, so such a bucket isn't a meter).
            let reportsAmount: Bool
            let resetTime: String?
            let resetInSeconds: Double?
            let disabled: Bool?

            enum CodingKeys: String, CodingKey {
                case remainingFraction = "remaining_fraction"
                case remainingAmount = "remaining_amount"
                case resetTime = "reset_time"
                case resetInSeconds = "reset_in_seconds"
                case disabled
            }

            /// A number may arrive as a number or a numeric string; anything
            /// unreadable is nil, never 0.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                func number(_ key: CodingKeys) -> Double? {
                    var value: Double?
                    if let decoded = try? container.decodeIfPresent(Double.self, forKey: key) {
                        value = decoded
                    } else if let text = try? container.decodeIfPresent(String.self, forKey: key) {
                        value = Double(text)
                    }
                    guard let value, value.isFinite else { return nil }
                    return value
                }
                remainingFraction = number(.remainingFraction)
                reportsAmount = number(.remainingAmount) != nil
                resetTime = try? container.decodeIfPresent(String.self, forKey: .resetTime)
                resetInSeconds = number(.resetInSeconds)
                disabled = try? container.decodeIfPresent(Bool.self, forKey: .disabled)
            }
        }
    }

    /// The furthest a reset can sensibly be — a month's window and change;
    /// anything beyond is garbage, not a reset.
    static let maxResetDistance: TimeInterval = 400 * 86400

    /// Status-line stdin → the bytes the export keeps; nil when the payload
    /// carries no quota at all (an API-key sign-in has none, and an older
    /// CLI may not send it).
    static func reduce(statusLine payload: Data, now: Date) -> Data? {
        guard let line = try? JSONDecoder().decode(StatusLine.self, from: payload),
              !line.quota.isEmpty
        else { return nil }
        let quota = line.quota
        let buckets = quota.keys.sorted().compactMap { id -> AntigravityQuotaReading.Bucket? in
            guard let entry = quota[id], isBucketID(id) else { return nil }
            let stamped = entry.resetTime.flatMap(FlexibleISO8601.date(from:))
            let counted = entry.resetInSeconds
                .flatMap { (0...maxResetDistance).contains($0) ? $0 : nil }
                .map { now.addingTimeInterval($0) }
            let resetsAt = (stamped.flatMap {
                abs($0.timeIntervalSince(now)) <= maxResetDistance ? $0 : nil
            }) ?? counted
            var fraction = entry.remainingFraction.map { min(1, max(0, $0)) }
            // A spent bucket may arrive with its fraction OMITTED (protobuf
            // JSON and Go's omitempty both drop a zero): a bucket that still
            // states its reset, and no amount, is read as nothing left
            // rather than dropped — dropping it would hide the one meter
            // that matters most. Unverified against a real payload (plan
            // step V0).
            if fraction == nil, !entry.reportsAmount, !(entry.disabled ?? false),
               entry.resetTime != nil || entry.resetInSeconds != nil {
                fraction = 0
            }
            return AntigravityQuotaReading.Bucket(
                id: id, remainingFraction: fraction, resetsAt: resetsAt,
                disabled: entry.disabled ?? false)
        }
        guard !buckets.isEmpty else { return nil }
        let reading = AntigravityQuotaReading(
            version: AntigravityQuotaReading.currentVersion, capturedAt: now,
            planTier: line.planTier.flatMap(shortToken),
            cliVersion: line.version.flatMap(shortToken), buckets: buckets)
        return try? encoder().encode(reading)
    }

    /// Bucket ids are short machine words; anything else is not kept.
    static func isBucketID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    /// A tier or version string kept only when it looks like one.
    private static func shortToken(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 40, !trimmed.contains("@"), !trimmed.contains("/")
        else { return nil }
        return trimmed
    }

    /// A fresh reading differs when anything a meter would show moved: the
    /// set of buckets, a bucket's switch, its percent (to the point), its
    /// reset (beyond the stamp jitter tolerance), or the plan tier. The
    /// capture time alone is not a difference — the writer's refresh
    /// interval keeps that honest.
    static func differs(stored: Data, fresh: Data) -> Bool {
        guard let old = decodeReading(stored), let new = decodeReading(fresh) else { return true }
        guard old.planTier == new.planTier, old.buckets.count == new.buckets.count else {
            return true
        }
        for (a, b) in zip(old.buckets, new.buckets) {
            if a.id != b.id || a.disabled != b.disabled { return true }
            if a.remainingFraction.map(usedPercent) != b.remainingFraction.map(usedPercent) {
                return true
            }
            if ResetStamp.moved(a.resetsAt, b.resetsAt) { return true }
        }
        return false
    }

    /// Clamped BEFORE the conversion: a stored fraction is read back from a
    /// file, and an out-of-range one must not trap the engine.
    static func usedPercent(_ remaining: Double) -> Int {
        let left = remaining.isFinite ? min(1, max(0, remaining)) : 1
        return Int(((1 - left) * 100).rounded())
    }

    // MARK: Meters

    /// The pool a bucket belongs to, by its id's leading word, and the
    /// window its trailing word names. v1 meters the Gemini pool and the
    /// third-party (Claude + GPT) pool; model-specific and lite/image
    /// buckets are skipped (user-decided 2026-11-21).
    struct BucketShape: Equatable {
        let pool: Pool
        let window: TimeInterval

        enum Pool: Equatable {
            case gemini
            case thirdParty
        }
    }

    static func shape(of bucketID: String) -> BucketShape? {
        let words = bucketID.lowercased().split(separator: "-").map(String.init)
        guard words.count == 2, let window = windowLength(words[1]) else { return nil }
        switch words[0] {
        case "gemini": return BucketShape(pool: .gemini, window: window)
        case "3p": return BucketShape(pool: .thirdParty, window: window)
        default: return nil
        }
    }

    /// The window a bucket id's trailing word names — the payload states no
    /// window length, and `reset_in_seconds` is time LEFT, not the window.
    static func windowLength(_ word: String) -> TimeInterval? {
        switch word {
        case "daily": return 86400
        case "weekly": return 7 * 86400
        case "monthly": return 30 * 86400
        default:
            // Bounded, so a garbage id can't overflow the arithmetic below.
            guard (2...6).contains(word.count), let count = Int(word.dropLast()),
                  (1...10_000).contains(count)
            else { return nil }
            switch word.last {
            case "h": return TimeInterval(count * 3600)
            case "d": return TimeInterval(count * 86400)
            default: return nil
            }
        }
    }

    static let thirdPartyName = "Claude + GPT"
    /// What each pool's meters count tokens from (`Meter.modelScope`): the
    /// two pools are independent quotas, so neither counts — or locks out —
    /// the other's models.
    static let geminiScope = ["gemini"]
    static let thirdPartyScope = ["claude", "gpt"]

    /// "5h", "7d" — the window as the third-party pool's labels write it.
    /// Its labels never repeat the Gemini meters' words ("Session",
    /// "Weekly"), or `usage-cli limits session` would match two meters.
    static func shortWindow(_ window: TimeInterval) -> String {
        let hours = Int((window / 3600).rounded())
        return hours >= 24 && hours % 24 == 0 ? "\(hours / 24)d" : "\(hours)h"
    }

    static func snapshot(
        fromPayload body: Data, thresholds: Thresholds, now: Date = Date()
    ) throws -> Snapshot {
        let payload = try decoder().decode(AntigravityUsagePayload.self, from: body)
        guard let reading = payload.reading else {
            // Conversations but no status-line reading yet: an honest "no
            // limits read", fresh as of this fetch (like Gemini's zero count).
            return Snapshot(meters: [], fetchedAt: payload.fetchedAt)
        }
        var meters: [Meter] = []
        for bucket in reading.buckets where !bucket.disabled {
            guard let fraction = bucket.remainingFraction, let shape = shape(of: bucket.id)
            else { continue }
            let kind = LimitWindowKind(window: shape.window)
            var id: String
            var label: String
            let rank: Int
            switch shape.pool {
            case .gemini:
                id = kind.rank == 0 ? "0-session" : "1-\(kind.rawValue)"
                label = kind.label(window: shape.window)
                rank = kind.rank
            case .thirdParty:
                id = "2-\(bucket.id.lowercased())"
                label = "\(thirdPartyName) (\(shortWindow(shape.window)))"
                rank = 2
            }
            let name = UsageFormatting.windowName(shape.window)
            if meters.contains(where: { $0.id == id }) { id += "-" + name }
            if meters.contains(where: { $0.label == label }) { label += " (\(bucket.id))" }
            meters.append(meter(
                fraction: fraction, resetsAt: bucket.resetsAt, id: id, label: label,
                rank: rank, window: shape.window,
                scoped: shape.pool == .thirdParty ? thirdPartyName : nil,
                scope: shape.pool == .thirdParty ? thirdPartyScope : geminiScope,
                conversationWrittenAt: payload.conversationWrittenAt,
                fetchedAt: payload.fetchedAt, thresholds: thresholds, now: now))
        }
        meters.sort {
            $0.rank != $1.rank
                ? $0.rank < $1.rank
                : ($0.limitWindow ?? .infinity) < ($1.limitWindow ?? .infinity)
        }
        let plan = reading.planTier.map { PlanInfo(subscriptionType: $0, rateLimitTier: nil) }
        return Snapshot(meters: meters, fetchedAt: reading.capturedAt, plan: plan)
    }

    /// A window whose reset has passed since the reading is a window nobody
    /// has seen since. Headless `agy -p` runs spend quota but never run the
    /// status line, so "it rolled, so it's 0%" is only true when no
    /// conversation was written after the reset; otherwise the percent is
    /// unknown (a dash), never a 0 nobody observed. Either way the next
    /// boundary is server-side state, so no reset is shown.
    ///
    /// "No conversation since" has to be KNOWN: with no write time at all,
    /// or a payload read before the reset (a cached body replayed later
    /// knows nothing of the writes after it), the answer is a dash too.
    private static func meter(
        fraction: Double, resetsAt: Date?, id: String, label: String, rank: Int,
        window: TimeInterval, scoped: String?, scope: [String],
        conversationWrittenAt: Date?, fetchedAt: Date, thresholds: Thresholds, now: Date
    ) -> Meter {
        var percent: Int? = usedPercent(fraction)
        var reset = resetsAt
        if let resetsAt, resetsAt < now {
            reset = nil
            let quietSince = fetchedAt >= resetsAt
                && (conversationWrittenAt.map { $0 <= resetsAt } ?? false)
            percent = quietSince ? 0 : nil
        }
        return Meter(
            id: id,
            label: label,
            percent: percent,
            resetsAt: reset,
            level: percent.map {
                MeterBuilder.level(percent: $0, forcesWarning: false, thresholds: thresholds)
            } ?? .normal,
            rank: rank,
            limitWindow: window,
            forcesWarning: false,
            scopedModelName: scoped,
            modelScope: scope)
    }
}
