import Foundation

/// One continuous stretch of a signed-in identity, as observed. Epochs are
/// the queryable truth of the presence ledger — bounded by login changes,
/// not by observation count.
public struct AccountEpoch: Codable, Sendable, Equatable {
    public let account: AccountIdentity
    public let firstObservedAt: Date
    public var lastObservedAt: Date
    /// Set only when the ending was itself OBSERVED — a sign-out or a
    /// switch seen happening. Nil means observation simply stopped (the
    /// host quit); such an epoch may be rejoined by a later observation of
    /// the same identity, because the intervening gap attributes to it
    /// anyway. An observed sign-out is a real boundary and forbids rejoin.
    public var closedAt: Date?

    public init(
        account: AccountIdentity, firstObservedAt: Date, lastObservedAt: Date,
        closedAt: Date? = nil
    ) {
        self.account = account
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.closedAt = closedAt
    }
}

/// What a moment in time attributes to, per the presence rule. `ambiguous`
/// and `unattributed` are real answers a reader must carry as their own
/// buckets — never guessed into an account, never dropped.
public enum AccountAttribution: Sendable, Equatable {
    case account(AccountIdentity)
    /// Inside an unobserved gap whose two edges are different identities.
    case ambiguous
    /// Before the first observation ever — pre-feature history stays here
    /// forever (absent ≠ zero, never backfilled by assumption).
    case unattributed
}

/// The pure attribution rule over a settled epoch list. A value type handed
/// to the digest builder, so the join lives in exactly one place:
///
/// - inside an epoch → that account, exactly;
/// - inside a gap whose edges agree → that account (the alternative
///   requires a round-trip through another login entirely unobserved);
/// - inside a gap whose edges differ → ambiguous, permanently;
/// - before the first observation → unattributed;
/// - after the final epoch: the account while it's open (that's the
///   present), unattributed once its end was observed.
public struct AccountTimeline: Sendable, Equatable {
    /// Chronological by first observation.
    public let epochs: [AccountEpoch]

    public init(epochs: [AccountEpoch]) {
        self.epochs = epochs.sorted { $0.firstObservedAt < $1.firstObservedAt }
    }

    public func attribute(_ t: Date) -> AccountAttribution {
        guard let first = epochs.first, t >= first.firstObservedAt else {
            return .unattributed
        }
        // The last epoch that started at or before t.
        var index = epochs.count - 1
        while index > 0, epochs[index].firstObservedAt > t { index -= 1 }
        let epoch = epochs[index]
        if t <= epoch.lastObservedAt { return .account(epoch.account) }
        guard index + 1 < epochs.count else {
            // Trailing time past the newest epoch: the open epoch is the
            // present and owns it; an observed ending returns the ledger
            // to knowing nothing.
            return epoch.closedAt == nil ? .account(epoch.account) : .unattributed
        }
        let next = epochs[index + 1]
        return epoch.account.key == next.account.key
            ? .account(epoch.account) : .ambiguous
    }

    /// The distinct identities present inside any of the intervals, in
    /// order of first appearance — a session card's chronological account
    /// list, fed the session's activity stretches. Gap-attributed spans
    /// count; ambiguous and unattributed spans don't name anyone.
    public func accounts(in intervals: [DateInterval]) -> [AccountIdentity] {
        guard !intervals.isEmpty else { return [] }
        let horizon = intervals.map(\.end).max() ?? .distantPast
        var seen: [String: (at: Date, account: AccountIdentity)] = [:]
        for (index, epoch) in epochs.enumerated() {
            // The span this epoch answers for: its observed body, plus the
            // following gap when the gap attributes to it.
            var end = epoch.lastObservedAt
            if index + 1 < epochs.count {
                let next = epochs[index + 1]
                if next.account.key == epoch.account.key {
                    end = next.firstObservedAt
                }
            } else if epoch.closedAt == nil {
                end = max(end, horizon)
            }
            let span = DateInterval(
                start: epoch.firstObservedAt, end: max(epoch.firstObservedAt, end))
            for interval in intervals {
                guard let overlap = span.intersection(with: interval) else { continue }
                if let held = seen[epoch.account.key], held.at <= overlap.start { continue }
                seen[epoch.account.key] = (overlap.start, epoch.account)
            }
        }
        return seen.values.sorted { $0.at < $1.at }.map(\.account)
    }

    /// When attribution became possible at all — the D6 boundary.
    public var attributionSince: Date? { epochs.first?.firstObservedAt }

    /// The open epoch, if the newest one is still being observed.
    public var current: AccountEpoch? {
        guard let last = epochs.last, last.closedAt == nil else { return nil }
        return last
    }
}

/// The engine-side presence ledger: observes identities, coalesces them
/// into epochs, and persists `account-presence.json` beside `history.json`
/// (same atomic-rewrite, best-effort idiom). The engine host is the single
/// writer, exactly like every other store in its support directory.
public struct AccountPresenceLedger: Sendable {
    public private(set) var epochs: [AccountEpoch]
    public let fileURL: URL
    /// When the newest observation landed — the digest card's freshness.
    public private(set) var observedAt: Date?
    private var lastPersistAt: Date?

    /// Rapid pileups (wake + scan + fetch in one burst) collapse to one
    /// observation; anything slower is worth recording.
    public static let observationFloor: TimeInterval = 15
    /// The open epoch's advancing edge hits disk at most this often — a
    /// crash costs at most this much edge precision, nothing else.
    public static let heartbeatPersistInterval: TimeInterval = 300

    private struct Ledger: Codable {
        var version: Int
        var epochs: [AccountEpoch]
    }

    public init(directory: URL) {
        self.fileURL = directory.appending(path: "account-presence.json")
        if let data = try? Data(contentsOf: fileURL),
           let ledger = try? Self.decoder().decode(Ledger.self, from: data) {
            self.epochs = ledger.epochs.sorted { $0.firstObservedAt < $1.firstObservedAt }
        } else {
            self.epochs = []
        }
    }

    /// Records one observation. Returns true when the ledger CHANGED in a
    /// way worth publishing (an epoch opened, closed, or rejoined) — the
    /// engine treats that as a landing point; heartbeats return false.
    @discardableResult
    public mutating func observe(_ identity: AccountIdentity?, at now: Date) -> Bool {
        if let observedAt, now.timeIntervalSince(observedAt) < Self.observationFloor {
            return false
        }
        observedAt = now

        guard let identity else {
            // Signed out: an observed ending. Recording it once is enough.
            guard var last = epochs.last, last.closedAt == nil else { return false }
            last.closedAt = now
            epochs[epochs.count - 1] = last
            persist(now: now, force: true)
            return true
        }

        if var last = epochs.last, last.closedAt == nil,
           last.account.key == identity.key {
            // The same identity, still (or again after an unobserved stop —
            // the gap attributes to it either way, so the epoch extends).
            last.lastObservedAt = max(last.lastObservedAt, now)
            epochs[epochs.count - 1] = last
            persist(now: now, force: false)
            return false
        }

        // A different identity — or the first ever, or a re-login after an
        // observed sign-out. Close what's open and open the new epoch.
        if var last = epochs.last, last.closedAt == nil, last.account.key != identity.key {
            last.closedAt = now
            epochs[epochs.count - 1] = last
        }
        epochs.append(AccountEpoch(
            account: identity, firstObservedAt: now, lastObservedAt: now))
        persist(now: now, force: true)
        return true
    }

    /// Shutdown flush — the open epoch's edge must not lose its last
    /// heartbeat window.
    public mutating func flush(now: Date = Date()) {
        persist(now: now, force: true)
    }

    public var timeline: AccountTimeline { AccountTimeline(epochs: epochs) }

    private mutating func persist(now: Date, force: Bool) {
        if !force, let last = lastPersistAt,
           now.timeIntervalSince(last) < Self.heartbeatPersistInterval {
            return
        }
        lastPersistAt = now
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder().encode(Ledger(version: 1, epochs: epochs))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Presence is an enhancement; persistence must never break a scan.
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
