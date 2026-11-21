import Foundation

/// The provider's "raw usage" bytes: the quota probe's reading (if any)
/// plus the two facts the meters need that the reading can't carry — when
/// this fetch ran, and when a conversation was last written.
struct AntigravityUsagePayload: Codable {
    let fetchedAt: Date
    let reading: AgentQuotaReading?
    let conversationWrittenAt: Date?

    enum CodingKeys: String, CodingKey {
        case fetchedAt, reading, conversationWrittenAt
    }
}

/// What `agy -p /quota --output-format json` prints, how it is read, and
/// the meters it becomes (spec §10 amendment 2026-11-21, second). The shape
/// is the REAL one, captured on 2026-11-21 (CLI 1.5.14, Google AI Pro) and
/// checked against the CLI's own `/usage` screen:
///
/// ```text
/// { status: "SUCCESS", command: { name: "usage", data: { groups: [
///     { buckets: [ { id: "gemini-weekly", window: "weekly",
///                    remaining_fraction: 0.77, reset_time: "2026-11-28T14:02:05Z" }, … ] },
///     … ] } }, … }
/// ```
///
/// Only `status`, the bucket ids, windows, fractions and resets are ever
/// decoded; the payload's text, names and descriptions are skipped.
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

    static func encodePayload(_ payload: AntigravityUsagePayload) throws -> Data {
        do {
            return try encoder().encode(payload)
        } catch {
            throw UsageClientError.noLocalData
        }
    }

    // MARK: The version check

    /// `agy --version` prints one bare version ("1.5.14"). The desktop
    /// app's editor launcher of the same name prints three lines (its own
    /// version, a commit, an architecture) — it is not the agent.
    static func acceptsVersion(_ stdout: Data) -> Bool {
        guard let text = String(data: stdout, encoding: .utf8) else { return false }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // The LAST line must be the version: the editor's launcher ends on
        // its architecture, while a one-off notice the CLI prints first
        // (a migration, say) can't settle a rejection for the whole
        // version. Within that line: a name before the number, a `v`, and
        // a pre-release or build suffix after it are tolerated, so a
        // cosmetic change to the version line can't make the limits vanish.
        guard let last = lines.last, lines.count <= 3 else { return false }
        return last
            .range(of: #"^(\S+\s+)?v?\d+\.\d+(\.\d+)?([-+.]\S*)?$"#,
                   options: .regularExpression) != nil
    }

    // MARK: Reduce

    /// The slice of the output ever decoded. LENIENT ALL THE WAY DOWN: a
    /// field of an unexpected type reads as absent, and a bucket that
    /// doesn't decode is dropped on its own, never the whole reading.
    private struct Envelope: Decodable {
        let status: String?
        let command: Command?
        /// What a print-mode run reports of an AGENT TURN. The limits
        /// command reports zero turns, zero tokens and no conversation;
        /// anything else means the request ran as a prompt.
        let turns: Int?
        let conversationID: String?
        let totalTokens: Int?

        enum CodingKeys: String, CodingKey {
            case status, command
            case turns = "num_turns"
            case conversationID = "conversation_id"
            case usage
        }

        enum UsageKeys: String, CodingKey {
            case totalTokens = "total_tokens"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            command = try? container.decodeIfPresent(Command.self, forKey: .command)
            turns = try? container.decodeIfPresent(Int.self, forKey: .turns)
            conversationID = try? container.decodeIfPresent(String.self, forKey: .conversationID)
            let usage = try? container.nestedContainer(keyedBy: UsageKeys.self, forKey: .usage)
            totalTokens = (try? usage?.decodeIfPresent(Int.self, forKey: .totalTokens)) ?? nil
        }

        /// Whether the run reads as an agent turn rather than the command.
        var ranATurn: Bool {
            (turns ?? 0) > 0 || !(conversationID ?? "").isEmpty || (totalTokens ?? 0) > 0
        }

        struct Command: Decodable {
            /// nil when the shape moved: no `data` object, `groups` of the
            /// wrong type, or a `data` that carries other keys and no
            /// `groups` (renamed). An EMPTY `data` is zero groups — protobuf
            /// JSON omits an empty list.
            let groups: [Group]?

            enum CodingKeys: String, CodingKey {
                case data
            }

            struct DataKey: CodingKey {
                let stringValue: String
                var intValue: Int? { nil }
                init(stringValue: String) { self.stringValue = stringValue }
                init?(intValue: Int) { nil }
                static let groups = DataKey(stringValue: "groups")
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                guard let data = try? container.nestedContainer(keyedBy: DataKey.self, forKey: .data)
                else {
                    groups = nil
                    return
                }
                guard data.contains(.groups) else {
                    groups = data.allKeys.isEmpty ? [] : nil
                    return
                }
                let raw = try? data.decode([Lenient<Group>].self, forKey: .groups)
                groups = raw?.compactMap(\.value)
            }
        }

        struct Group: Decodable {
            let buckets: [Entry]

            enum CodingKeys: String, CodingKey {
                case buckets
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let raw = try? container.decodeIfPresent([Lenient<Entry>].self, forKey: .buckets)
                buckets = (raw ?? nil)?.compactMap(\.value) ?? []
            }
        }

        struct Entry: Decodable {
            let id: String
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
            /// The bucket states an amount (so a missing fraction is not
            /// an omitted zero).
            let reportsAmount: Bool
            let disabled: Bool

            enum CodingKeys: String, CodingKey {
                case id, window, disabled
                case remainingFraction = "remaining_fraction"
                case remainingAmount = "remaining_amount"
                case resetTime = "reset_time"
            }

            /// A number may arrive as a number or a numeric string; anything
            /// unreadable is nil, never 0.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                window = try? container.decodeIfPresent(String.self, forKey: .window)
                var fraction: Double?
                if let number = try? container.decodeIfPresent(Double.self, forKey: .remainingFraction) {
                    fraction = number
                } else if let text = try? container.decodeIfPresent(String.self, forKey: .remainingFraction) {
                    fraction = Double(text)
                }
                remainingFraction = fraction.flatMap { $0.isFinite ? $0 : nil }
                resetTime = try? container.decodeIfPresent(String.self, forKey: .resetTime)
                reportsAmount = container.contains(.remainingAmount)
                    && (try? container.decodeNil(forKey: .remainingAmount)) == false
                disabled = (try? container.decodeIfPresent(Bool.self, forKey: .disabled)) == true
            }
        }

        struct Lenient<T: Decodable>: Decodable {
            let value: T?
            init(from decoder: Decoder) { value = try? T(from: decoder) }
        }
    }

    /// The furthest a reset can sensibly be — a month's window and change;
    /// anything beyond is garbage, not a reset.
    static let maxResetDistance: TimeInterval = 400 * 86400
    /// An untouched pool reports the Unix epoch as its reset ("no window
    /// running"): anything before this is no reset at all.
    static let earliestReset = Date(timeIntervalSince1970: 978_307_200) // 2001-01-01

    /// What the probe's run printed → the buckets, or why there are none.
    /// Sees the output in memory only; keeps bucket numbers alone.
    static func reduce(exitStatus: Int32, stdout: Data, stderr: Data, now: Date) -> AgentQuotaOutcome {
        guard exitStatus == 0 else {
            return .failure(mentionsSignIn(stdout, stderr) ? .notSignedIn : .failed)
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: stdout) else {
            return .failure(.unreadable)
        }
        // An agent turn is not the limits command, whatever its status. The
        // probe stops asking this binary: a CLI that began treating
        // `/quota` as a prompt would spend quota on every attempt
        // (`notALimitsCommand`).
        if envelope.ranATurn { return .failure(.notALimitsCommand) }
        if let status = envelope.status, status.uppercased() != "SUCCESS" {
            return .failure(mentionsSignIn(stdout, stderr) ? .notSignedIn : .failed)
        }
        // A success without the command's result: if the output itself says
        // no turn ran, a shape that moved (unreadable, retried); if it can't
        // say, assume the worst and stop asking.
        if envelope.command == nil {
            return .failure(envelope.turns == 0 ? .unreadable : .notALimitsCommand)
        }
        // A command whose groups are missing or mistyped is a shape that
        // moved: unreadable, so the last reading stands. Groups that are
        // there and empty are a sign-in with no plan quota (an API key) —
        // an honest empty reading, not an error.
        guard let command = envelope.command, let groups = command.groups else {
            return .failure(.unreadable)
        }
        var seen = Set<String>()
        var buckets: [AgentQuotaBucket] = []
        let entries = groups.flatMap(\.buckets)
        for entry in entries where !entry.disabled {
            guard isBucketID(entry.id), !seen.contains(entry.id) else { continue }
            // The bucket's own window must agree with the one its id names;
            // a disagreement means the vocabulary moved — skip, don't guess.
            // A window word this build can't read is no disagreement.
            if let stated = entry.window.map({ $0.lowercased() }).flatMap(windowLength),
               let named = shape(of: entry.id)?.window,
               stated != named {
                continue
            }
            seen.insert(entry.id)
            let resetsAt = entry.resetTime.flatMap(FlexibleISO8601.date(from:)).flatMap {
                $0 >= earliestReset && abs($0.timeIntervalSince(now)) <= maxResetDistance ? $0 : nil
            }
            var fraction = entry.remainingFraction.map { min(1, max(0, $0)) }
            // A documented exception to "absent ≠ zero": the CLI's JSON is
            // protobuf's, which OMITS a field holding its zero value, so a
            // spent bucket arrives with no fraction. Read as nothing left
            // only when it says nothing else — no amount, not disabled —
            // and states a REAL reset still ahead; the epoch never
            // triggers it. Dropping it would hide the meter that matters
            // most. Unverified: no spent bucket has been seen yet.
            if fraction == nil, !entry.reportsAmount, let resetsAt, resetsAt > now {
                fraction = 0
            }
            buckets.append(AgentQuotaBucket(
                id: entry.id, remainingFraction: fraction, resetsAt: resetsAt))
        }
        // Buckets were reported and none could be read: the vocabulary
        // moved under this build — say so rather than show no limits.
        if buckets.isEmpty, entries.contains(where: { !$0.disabled }) {
            return .failure(.unreadable)
        }
        return .buckets(buckets)
    }

    /// Whether a failed run's output reads as "sign in first". Matched in
    /// memory only; never kept, never logged. The not-signed-in output was
    /// never observed (signing out touches the account), so anything else
    /// falls back to the generic failure.
    static func mentionsSignIn(_ stdout: Data, _ stderr: Data) -> Bool {
        let text = (String(data: stderr, encoding: .utf8) ?? "")
            + " " + (String(data: stdout, encoding: .utf8) ?? "")
        let lower = text.lowercased()
        // Whole phrases only: "login keychain is locked" or "TLS
        // authentication failed" on a network error is not "sign in first".
        return ["not logged in", "not signed in", "please log in", "please sign in",
                "please login", "log back in", "sign back in", "log in again",
                "sign in again", "login required", "sign-in required", "sign in required",
                "unauthenticated", "authentication required", "authentication expired"]
            .contains { lower.contains($0) }
    }

    /// Bucket ids are short machine words; anything else is not kept.
    static func isBucketID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    /// Clamped BEFORE the conversion: a stored fraction is read back from a
    /// file, and an out-of-range one must not trap the engine.
    static func usedPercent(_ remaining: Double) -> Int {
        let left = remaining.isFinite ? min(1, max(0, remaining)) : 1
        return Int(((1 - left) * 100).rounded())
    }

    // MARK: Meters

    /// The pool a bucket belongs to and the window it names. Every pool the
    /// plan reports is metered (user-directed 2026-11-21: "I want to see
    /// them while they're available"): the Gemini pool, the Claude + GPT
    /// pool, and Gemini 4 Argon's own weekly, which a Pro plan meters apart
    /// from the Gemini pool. Other buckets are skipped.
    struct BucketShape: Equatable {
        let pool: Pool
        let window: TimeInterval

        enum Pool: Equatable {
            case gemini
            case thirdParty
            case argon

            /// The vendor's own order among the scoped meters.
            var order: Int {
                switch self {
                case .gemini: 0
                case .thirdParty: 1
                case .argon: 2
                }
            }
        }
    }

    static func shape(of bucketID: String) -> BucketShape? {
        let words = bucketID.lowercased().split(separator: "-").map(String.init)
        if words.count == 4, words[0] == "gemini", words[1] == "argon", words[2] == "wtu",
           let window = windowLength(words[3]) {
            return BucketShape(pool: .argon, window: window)
        }
        guard words.count == 2, let window = windowLength(words[1]) else { return nil }
        switch words[0] {
        case "gemini": return BucketShape(pool: .gemini, window: window)
        case "3p": return BucketShape(pool: .thirdParty, window: window)
        default: return nil
        }
    }

    /// The window a bucket id's trailing word (or a bucket's `window`)
    /// names — `reset_time` is when it ends, not how long it is.
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
    static let argonName = "Argon"
    /// What each pool's meters count tokens from (`Meter.modelScope`): the
    /// pools are independent quotas, so none counts — or locks out — the
    /// others' models. Gemini's pool excludes Argon when the plan meters
    /// Argon apart (`!` marks an exclusion).
    static let geminiScope = ["gemini"]
    static let geminiScopeBesideArgon = ["gemini", Meter.excludingMark + "argon"]
    static let thirdPartyScope = ["claude", "gpt"]
    static let argonScope = ["argon"]

    /// "5h", "7d" — the window as the scoped meters' labels write it. They
    /// never repeat the Gemini meters' words ("Session", "Weekly"), or
    /// `usage-cli limits session` would match two meters.
    static func shortWindow(_ window: TimeInterval) -> String {
        let hours = Int((window / 3600).rounded())
        return hours >= 24 && hours % 24 == 0 ? "\(hours / 24)d" : "\(hours)h"
    }

    static func snapshot(
        fromPayload body: Data, thresholds: Thresholds, now: Date = Date()
    ) throws -> Snapshot {
        let payload = try decoder().decode(AntigravityUsagePayload.self, from: body)
        guard let reading = payload.reading else {
            // Conversations but no reading yet: an honest "no limits read",
            // fresh as of this fetch.
            return Snapshot(meters: [], fetchedAt: payload.fetchedAt)
        }
        // Only an Argon bucket that BECOMES a meter takes Argon out of the
        // Gemini meters; otherwise its tokens would count nowhere.
        let argonApart = reading.buckets.contains {
            $0.remainingFraction != nil && shape(of: $0.id)?.pool == .argon
        }
        var built: [(meter: Meter, order: Int)] = []
        for bucket in reading.buckets {
            guard let fraction = bucket.remainingFraction, let shape = shape(of: bucket.id)
            else { continue }
            let kind = LimitWindowKind(window: shape.window)
            var id: String
            var label: String
            let rank: Int
            let scoped: String?
            let scope: [String]
            switch shape.pool {
            case .gemini:
                id = kind.rank == 0 ? "0-session" : "1-\(kind.rawValue)"
                label = kind.label(window: shape.window)
                rank = kind.rank
                scoped = nil
                scope = argonApart ? geminiScopeBesideArgon : geminiScope
            case .thirdParty:
                id = "2-\(bucket.id.lowercased())"
                label = "\(thirdPartyName) (\(shortWindow(shape.window)))"
                rank = 2
                scoped = thirdPartyName
                scope = thirdPartyScope
            case .argon:
                id = "2-\(bucket.id.lowercased())"
                label = "\(argonName) (\(shortWindow(shape.window)))"
                rank = 2
                scoped = argonName
                scope = argonScope
            }
            let name = UsageFormatting.windowName(shape.window)
            if built.contains(where: { $0.meter.id == id }) { id += "-" + name }
            if built.contains(where: { $0.meter.label == label }) { label += " (\(bucket.id))" }
            built.append((meter(
                fraction: fraction, resetsAt: bucket.resetsAt, id: id, label: label,
                rank: rank, window: shape.window, scoped: scoped, scope: scope,
                conversationWrittenAt: payload.conversationWrittenAt,
                fetchedAt: payload.fetchedAt, thresholds: thresholds, now: now),
                shape.pool.order))
        }
        built.sort {
            if $0.meter.rank != $1.meter.rank { return $0.meter.rank < $1.meter.rank }
            if $0.order != $1.order { return $0.order < $1.order }
            return ($0.meter.limitWindow ?? .infinity) < ($1.meter.limitWindow ?? .infinity)
        }
        return Snapshot(meters: built.map(\.meter), fetchedAt: reading.capturedAt)
    }

    /// A window whose reset has passed since the reading is a window nobody
    /// has seen since. "It rolled, so it's 0%" is only true when no
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
