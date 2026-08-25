import Foundation

/// The digest's account-presence surface (spec §10 amendment 2026-08-25):
/// who is signed in right now, since when, and how today's and the current
/// window's usage split across the accounts the ledger has observed.
///
/// Nil on `LiveState` means this engine tracks no accounts (the provider
/// declares no identity source, or the digest predates 0.89.0) — ABSENT IS
/// NEVER "no account". Inside the card, absence keeps its meaning too: a
/// nil cost is unpriceable, a nil `ambiguous` bucket means no ambiguous
/// usage existed, and `attributionSince` bounds what can ever be labeled —
/// everything earlier is unattributed forever, never guessed.
public struct AccountPresenceCard: Codable, Sendable, Equatable {
    /// The signed-in account, nil while signed out.
    public let current: AccountRef?
    /// When the current account's continuous presence began.
    public let since: Date?
    /// Freshness of the newest identity observation.
    public let observedAt: Date
    /// The first observation ever — the attribution boundary (D6).
    public let attributionSince: Date?
    /// How many distinct identities the ledger has ever seen — surfaces
    /// auto-show their account chrome only from 2 up.
    public let distinctAccounts: Int
    /// Per-account rollups: every account with usage today or this window,
    /// plus the current account always (an observed zero is a real zero).
    /// Current account first, then heaviest today.
    public let accounts: [AccountUsage]
    /// Usage inside unobserved gaps whose edges disagree — its own bucket,
    /// never split by guesswork. Nil when no such usage exists.
    public let ambiguous: AccountUsage?
    /// Usage from before the first observation ever. Nil when none landed
    /// in today's or the window's span.
    public let unattributed: AccountUsage?
    /// The observed epochs, oldest first (bounded to the newest 50) — the
    /// CLI's `account --all` table.
    public let epochs: [AccountEpochCard]

    public init(
        current: AccountRef?, since: Date?, observedAt: Date,
        attributionSince: Date?, distinctAccounts: Int,
        accounts: [AccountUsage], ambiguous: AccountUsage?,
        unattributed: AccountUsage?, epochs: [AccountEpochCard]
    ) {
        self.current = current
        self.since = since
        self.observedAt = observedAt
        self.attributionSince = attributionSince
        self.distinctAccounts = distinctAccounts
        self.accounts = accounts
        self.ambiguous = ambiguous
        self.unattributed = unattributed
        self.epochs = epochs
    }
}

/// One account as the digest names it. `label` comes resolved (email, org
/// suffix only when labels would collide) so no client re-derives it.
public struct AccountRef: Codable, Sendable, Equatable {
    public let label: String
    public let accountUuid: String
    public let organizationUuid: String?
    public let email: String?
    public let displayName: String?
    public let organizationName: String?
    public let tier: String?

    public init(
        label: String, accountUuid: String, organizationUuid: String?,
        email: String?, displayName: String?, organizationName: String?,
        tier: String?
    ) {
        self.label = label
        self.accountUuid = accountUuid
        self.organizationUuid = organizationUuid
        self.email = email
        self.displayName = displayName
        self.organizationName = organizationName
        self.tier = tier
    }

    init(_ identity: AccountIdentity, label: String) {
        self.init(
            label: label,
            accountUuid: identity.accountUuid,
            organizationUuid: identity.organizationUuid.isEmpty
                ? nil : identity.organizationUuid,
            email: identity.email,
            displayName: identity.displayName,
            organizationName: identity.organizationName,
            tier: identity.tier)
    }
}

/// One row of the split: an account's (or a reserved bucket's) usage today
/// and inside the current limit window. `ref` is nil exactly for the
/// reserved `ambiguous`/`unattributed` buckets.
public struct AccountUsage: Codable, Sendable, Equatable {
    public let ref: AccountRef?
    public let todayTokens: Int
    /// Nil = nothing priceable — absent, never 0.
    public let todayCost: Double?
    /// Nil when no current window is known (never fetched, local provider).
    public let windowTokens: Int?
    public let windowCost: Double?

    public init(
        ref: AccountRef?, todayTokens: Int, todayCost: Double?,
        windowTokens: Int?, windowCost: Double?
    ) {
        self.ref = ref
        self.todayTokens = todayTokens
        self.todayCost = todayCost
        self.windowTokens = windowTokens
        self.windowCost = windowCost
    }
}

/// One observed presence epoch, as published. `closed` distinguishes an
/// OBSERVED ending (sign-out, switch) from observation simply stopping.
public struct AccountEpochCard: Codable, Sendable, Equatable {
    public let label: String
    public let organizationName: String?
    public let firstObservedAt: Date
    public let lastObservedAt: Date
    public let closed: Bool

    public init(
        label: String, organizationName: String?, firstObservedAt: Date,
        lastObservedAt: Date, closed: Bool
    ) {
        self.label = label
        self.organizationName = organizationName
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.closed = closed
    }
}

/// What the engine hands the builder: the ledger's raw state. The builder
/// owns every derivation (timeline, rollups, labels) so the join lives in
/// exactly one place.
public struct AccountPresenceInput: Sendable, Equatable {
    public let epochs: [AccountEpoch]
    public let observedAt: Date?

    public init(epochs: [AccountEpoch], observedAt: Date?) {
        self.epochs = epochs
        self.observedAt = observedAt
    }
}

extension LiveStateBuilder {
    /// Labels for a run of identities: email (or uuid prefix), org name
    /// appended only where two identities would otherwise read the same —
    /// the D1 label rule, applied once here for every surface.
    public static func disambiguatedLabels(_ identities: [AccountIdentity]) -> [String] {
        var counts: [String: Int] = [:]
        for identity in identities { counts[identity.label, default: 0] += 1 }
        return identities.map { identity in
            guard counts[identity.label, default: 0] > 1 else { return identity.label }
            let org = identity.organizationName?.isEmpty == false
                ? identity.organizationName!
                : String(identity.organizationUuid.prefix(8))
            return "\(identity.label) (\(org))"
        }
    }

    /// A session's chronological account labels, from its activity
    /// stretches joined against the presence timeline. Empty = attribution
    /// ran and named nobody (pre-tracking history, ambiguous spans).
    /// Public because the app's sessions sidebar computes the same labels
    /// live off the engine's (or a reconstructed) timeline.
    public static func sessionAccountLabels(
        _ session: SessionSummary, timeline: AccountTimeline
    ) -> [String] {
        let intervals = session.stretches.isEmpty
            ? [DateInterval(
                start: session.start, end: max(session.start, session.end))]
            : session.stretches
        return disambiguatedLabels(timeline.accounts(in: intervals))
    }

    /// The whole card: current identity, epoch table, and the today/window
    /// usage split — computed from the minute timeline the scan already
    /// produces, so the scanner and its cache never learn about accounts.
    /// Minute slots bound attribution error the same way they bound
    /// window-edge error: under a minute, beneath the observation cadence
    /// itself.
    static func accountPresenceCard(
        input: AccountPresenceInput, slots: [TokenSlot], meters: [Meter],
        pricing: PricingTable, calendar: Calendar, now: Date
    ) -> AccountPresenceCard? {
        // No observation yet = nothing to say; the card appears with the
        // first observation, not with the feature.
        guard let observedAt = input.observedAt else { return nil }
        let timeline = AccountTimeline(epochs: input.epochs)
        let startOfDay = calendar.startOfDay(for: now)
        // The current limit window = the shortest declared window still
        // running; nil (no fetch yet, local provider) keeps window sums nil.
        let windowStart: Date? = meters
            .compactMap { meter -> (window: TimeInterval, start: Date)? in
                guard let resetsAt = meter.resetsAt, let window = meter.limitWindow,
                      resetsAt > now
                else { return nil }
                return (window, resetsAt.addingTimeInterval(-window))
            }
            .min { $0.window < $1.window }?.start

        struct Bucket {
            var today: [String: TokenTally] = [:]
            var window: [String: TokenTally] = [:]
        }
        var buckets: [String: Bucket] = [:]
        var identities: [String: AccountIdentity] = [:]
        for slot in slots {
            let inToday = slot.t >= startOfDay && slot.t <= now
            let inWindow = windowStart.map { slot.t >= $0 && slot.t <= now } ?? false
            guard inToday || inWindow else { continue }
            let key: String
            switch timeline.attribute(slot.t) {
            case .account(let identity):
                key = identity.key
                identities[key] = identity
            case .ambiguous:
                key = "#ambiguous"
            case .unattributed:
                key = "#unattributed"
            }
            var bucket = buckets[key] ?? Bucket()
            if inToday {
                var tally = bucket.today[slot.model] ?? TokenTally()
                tally.add(slot.tally)
                bucket.today[slot.model] = tally
            }
            if inWindow {
                var tally = bucket.window[slot.model] ?? TokenTally()
                tally.add(slot.tally)
                bucket.window[slot.model] = tally
            }
            buckets[key] = bucket
        }

        func priced(_ byModel: [String: TokenTally]) -> Double? {
            let costs = byModel.compactMap { model, tally in
                pricing.rates(for: model).map { $0.dollars(for: tally) }
            }
            return costs.isEmpty ? nil : costs.reduce(0, +)
        }
        func usage(_ bucket: Bucket, ref: AccountRef?) -> AccountUsage {
            AccountUsage(
                ref: ref,
                todayTokens: bucket.today.values.reduce(0) { $0 + $1.total },
                todayCost: priced(bucket.today),
                windowTokens: windowStart == nil
                    ? nil : bucket.window.values.reduce(0) { $0 + $1.total },
                windowCost: priced(bucket.window))
        }

        let current = timeline.current
        // The current account rows even with nothing billed — an observed
        // zero is a real zero, unlike every absence above.
        if let current, buckets[current.account.key] == nil {
            buckets[current.account.key] = Bucket()
            identities[current.account.key] = current.account
        }

        // One label pass over every identity the card will name, so
        // collisions resolve consistently across rows and epochs.
        let epochTail = Array(input.epochs.suffix(50))
        var labelIdentities: [AccountIdentity] = epochTail.map(\.account)
        for identity in identities.values
        where !labelIdentities.contains(where: { $0.key == identity.key }) {
            labelIdentities.append(identity)
        }
        let labels = Dictionary(
            zip(labelIdentities.map(\.key), disambiguatedLabels(labelIdentities))
        ) { first, _ in first }

        func ref(_ identity: AccountIdentity) -> AccountRef {
            AccountRef(identity, label: labels[identity.key] ?? identity.label)
        }

        let currentKey = current?.account.key
        let accountRows = buckets
            .compactMap { key, bucket -> (key: String, usage: AccountUsage)? in
                guard let identity = identities[key] else { return nil }
                return (key, usage(bucket, ref: ref(identity)))
            }
            .sorted { a, b in
                if (a.key == currentKey) != (b.key == currentKey) {
                    return a.key == currentKey
                }
                if a.usage.todayTokens != b.usage.todayTokens {
                    return a.usage.todayTokens > b.usage.todayTokens
                }
                return (a.usage.ref?.label ?? "") < (b.usage.ref?.label ?? "")
            }
            .map(\.usage)

        return AccountPresenceCard(
            current: current.map { ref($0.account) },
            since: current?.firstObservedAt,
            observedAt: observedAt,
            attributionSince: timeline.attributionSince,
            distinctAccounts: Set(input.epochs.map(\.account.key)).count,
            accounts: accountRows,
            ambiguous: buckets["#ambiguous"].map { usage($0, ref: nil) },
            unattributed: buckets["#unattributed"].map { usage($0, ref: nil) },
            epochs: epochTail.map { epoch in
                AccountEpochCard(
                    label: labels[epoch.account.key] ?? epoch.account.label,
                    organizationName: epoch.account.organizationName,
                    firstObservedAt: epoch.firstObservedAt,
                    lastObservedAt: epoch.lastObservedAt,
                    closed: epoch.closedAt != nil)
            })
    }
}
