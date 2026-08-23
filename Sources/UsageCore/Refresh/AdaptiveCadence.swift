import Foundation

/// Decides how often to poll the usage endpoint. Three forces:
///
/// - Evidence that Claude is in use right now (Claude Code writing transcripts
///   locally, usage percentages rising between polls) holds sampling at the
///   user's chosen active pace.
/// - Sustained quiet decays the pace in steps — ×2 after 15 minutes, ×4 after
///   an hour, ×8 after four hours — capped at an hour between polls (or the
///   chosen pace itself, when that's deliberately slower).
/// - HTTP 429 forces exponential backoff (honoring Retry-After) that heals on
///   the next successful fetch.
///
/// Pure state + arithmetic: the store feeds it events, the scheduler asks it
/// for the next delay. No timers, no I/O — fully testable with fixed dates.
public struct AdaptiveCadence: Sendable, Equatable {
    /// Poll interval while Claude is actively in use — the user-facing setting.
    public var activeInterval: TimeInterval

    /// Most recent proof that Claude is in use.
    public private(set) var lastEvidence: Date
    /// Consecutive 429s; any success resets it.
    public private(set) var rateLimitStrikes = 0
    /// Nothing polls automatically before this instant.
    public private(set) var backoffUntil: Date?

    /// Never poll faster than this, matching `TriggerGate` (spec §9): the
    /// endpoint rate-limits sustained sub-3-minute polling.
    public static let floor: TimeInterval = TriggerGate.floor
    /// Decay never slows polling beyond this — a meter an hour stale stops
    /// being a meter. A *chosen* pace slower than this is honored as-is.
    public static let ceiling: TimeInterval = 3600
    /// Top of the settings slider: the slowest selectable active pace.
    public static let maxActiveInterval: TimeInterval = 7200
    /// First 429 waits this long, unless Retry-After asks for more...
    public static let backoffBase: TimeInterval = 300
    /// ...and however large Retry-After is, re-check within two hours.
    public static let backoffCeiling: TimeInterval = 7200

    public init(activeInterval: TimeInterval, now: Date) {
        self.activeInterval = activeInterval
        // Launching (or relaunching) the app is itself engagement: start
        // attentive and let quiet decay the pace from there.
        self.lastEvidence = now
    }

    /// Quiet-time decay ladder: time since the last evidence of use, as a
    /// multiple of the active interval.
    public func multiplier(now: Date) -> Int {
        let quiet = now.timeIntervalSince(lastEvidence)
        if quiet < 15 * 60 { return 1 }
        if quiet < 60 * 60 { return 2 }
        if quiet < 4 * 3600 { return 4 }
        return 8
    }

    /// Delay until the next automatic poll.
    public func interval(now: Date) -> TimeInterval {
        if let backoffUntil, backoffUntil > now {
            return max(Self.floor, backoffUntil.timeIntervalSince(now))
        }
        let paced = activeInterval * Double(multiplier(now: now))
        // The decay cap must never *speed up* a deliberately slow user pace:
        // cap at an hour or the chosen pace, whichever is slower.
        return min(max(Self.ceiling, activeInterval), max(Self.floor, paced))
    }

    public func isBackingOff(now: Date) -> Bool {
        guard let backoffUntil else { return false }
        return backoffUntil > now
    }

    /// Whether an activity signal warrants polling right now. Keyed on how old
    /// the displayed data is, not on the decay multiplier: agentic Claude Code
    /// sessions write transcripts continuously even while the user is away,
    /// which keeps `lastEvidence` fresh — yet the human returning still
    /// deserves numbers no staler than the pace they chose. Also recovers
    /// timers App Nap has let drift. Never during backoff; the trigger gate
    /// still owns the polling floor.
    public func shouldPollOnActivity(dataAge: TimeInterval?, now: Date) -> Bool {
        if isBackingOff(now: now) { return false }
        guard let dataAge else { return true }
        return dataAge >= activeInterval
    }

    /// A local push signal (Claude Code wrote a transcript). Deliberately does
    /// not touch backoff: user activity during a 429 pause must not shorten
    /// the pause.
    public mutating func noteActivity(at now: Date) {
        lastEvidence = max(lastEvidence, now)
    }

    /// A successful poll heals any backoff; rising usage counts as evidence.
    public mutating func noteSuccess(usageAdvanced: Bool, at now: Date) {
        rateLimitStrikes = 0
        backoffUntil = nil
        if usageAdvanced {
            lastEvidence = max(lastEvidence, now)
        }
    }

    public mutating func noteRateLimited(retryAfter: TimeInterval?, at now: Date) {
        rateLimitStrikes += 1
        let exponential = min(
            Self.ceiling, Self.backoffBase * pow(2, Double(rateLimitStrikes - 1)))
        let delay = min(Self.backoffCeiling, max(retryAfter ?? 0, exponential))
        backoffUntil = now.addingTimeInterval(delay)
    }
}

/// The settings slider's logarithmic 3 min – 2 hr scale with magnetic marks
/// at the preferred paces. Log because the useful resolution is at the fast
/// end; marks because the presets are what you almost always want. Pure
/// math so the snap behavior is testable.
public enum RefreshIntervalScale {
    public static let range: ClosedRange<Double> =
        TriggerGate.floor...AdaptiveCadence.maxActiveInterval
    /// The marked stops: the original 3/5/15-minute presets plus the slower
    /// stops the extended range makes room for.
    public static let marks: [Double] = [180, 300, 900, 1800, 3600, 7200]
    /// Snap distance in normalized log space (~3% of the track).
    static let snapRadius = 0.03

    /// Seconds → 0...1 along the log track.
    public static func position(of value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    /// 0...1 → seconds: magnetic near a mark, otherwise rounded to a clean
    /// step — whole minutes under an hour, 5-minute steps above.
    public static func value(at position: Double) -> Double {
        let p = min(max(position, 0), 1)
        for mark in marks where abs(Self.position(of: mark) - p) <= snapRadius {
            return mark
        }
        let raw = range.lowerBound * exp(p * log(range.upperBound / range.lowerBound))
        let step: Double = raw < 3600 ? 60 : 300
        return min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
    }
}

/// Parses an HTTP `Retry-After` header value: either delta-seconds ("120") or
/// an HTTP-date ("Wed, 21 Oct 2015 07:28:00 GMT"), normalized to seconds from
/// `now`. Unparseable values return nil and the caller falls back to its own
/// exponential backoff.
public enum RetryAfter {
    public static func seconds(from header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces),
              !header.isEmpty else { return nil }
        if let delta = TimeInterval(header) {
            return delta.isFinite ? max(0, delta) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// Detects real consumption between two snapshots: a meter's percent rose, a
/// meter entered a fresh window (reset time moved) with usage already in it,
/// or a new scoped meter appeared with usage. A percent drop alone is a limit
/// reset, not activity. This is the signal that notices Claude app / web
/// usage, which leaves no local files behind.
public enum UsageMovement {
    public static func advanced(from old: Snapshot?, to new: Snapshot) -> Bool {
        guard let old else { return false }
        let previous = Dictionary(
            old.meters.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        return new.meters.contains { meter in
            guard let percent = meter.percent else { return false }
            guard let before = previous[meter.label] else { return percent > 0 }
            if let beforePercent = before.percent, percent > beforePercent { return true }
            return ResetStamp.moved(before.resetsAt, meter.resetsAt) && percent > 0
        }
    }
}
