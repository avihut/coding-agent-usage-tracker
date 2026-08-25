import Foundation

/// The `account` noun: who is signed in, since when, and how today's and
/// the current window's usage split across the accounts the presence
/// ledger has observed (spec §10 amendment 2026-08-25).
///
/// Absent-card discipline throughout: an engine that tracks no accounts
/// publishes no card, and this noun prints nothing and exits 0 — it never
/// invents "no account", and signed-out is a stated fact, not an absence.
extension DigestQuery {
    static func runAccount(
        parsed: ParsedArgs, digest: LiveState, now: Date, json: Bool
    ) -> QueryOutput {
        let card = digest.accountPresence
        let unix = parsed.flags["unix"] != nil
        let relative = parsed.flags["relative"] != nil

        func resolve(_ field: String, asJSON: Bool) -> QueryOutput {
            accountField(
                field, card: card, now: now, json: asJSON, unix: unix, relative: relative)
        }
        if let output = multiFieldOutput(
            noun: "account", parsed: parsed, positionalField: parsed.positionals.first,
            json: json, header: parsed.flags["header"] != nil, resolve: resolve)
        {
            return output
        }

        guard let field = parsed.positionals.first else {
            guard parsed.positionals.isEmpty else { return badQuery("too many arguments") }
            guard let card else { return ok(json ? "null" : "") }
            if json { return ok(DigestQueryFormat.jsonValue(card)) }
            if parsed.flags["raw"] != nil {
                return badQuery("raw needs a field — e.g. `account email`")
            }
            return ok(withStaleSuffix(summaryLine(card, now: now), digest: digest))
        }
        guard parsed.positionals.count == 1 else { return badQuery("too many arguments") }
        return resolve(field, asJSON: json)
    }

    /// The human line: who, which org when it says something, for how
    /// long, and what today cost. Signed-out is stated, never blank — a
    /// card exists exactly because something IS tracked.
    private static func summaryLine(_ card: AccountPresenceCard, now: Date) -> String {
        guard let current = card.current else {
            var parts = ["signed out"]
            if card.distinctAccounts > 0 {
                parts.append("\(card.distinctAccounts) accounts seen")
            }
            return parts.joined(separator: " · ")
        }
        var parts = [current.label]
        if let org = current.organizationName, !org.isEmpty,
           !org.hasPrefix(current.label) {
            parts.append(org)
        }
        if let since = card.since {
            parts.append("for \(UsageFormatting.duration(max(0, now.timeIntervalSince(since))))")
        }
        if let mine = card.accounts.first(where: {
            $0.ref?.accountUuid == current.accountUuid
        }) {
            if let cost = mine.todayCost {
                parts.append("today \(UsageFormatting.money(cost))")
            } else if mine.todayTokens > 0 {
                parts.append("today \(TokenFormat.compact(mine.todayTokens)) tokens")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// One field. Current-account accessors go absent while signed out,
    /// the same way the digest's own `current` does.
    private static func accountField(
        _ field: String, card: AccountPresenceCard?, now: Date, json: Bool,
        unix: Bool, relative: Bool
    ) -> QueryOutput {
        let current = card?.current
        let mine = card?.accounts.first { usage in
            usage.ref?.accountUuid == current?.accountUuid && current != nil
        }
        switch field {
        case "label": return DigestQueryFormat.textField(current?.label, json: json)
        case "email": return DigestQueryFormat.textField(current?.email, json: json)
        case "name": return DigestQueryFormat.textField(current?.displayName, json: json)
        case "uuid": return DigestQueryFormat.textField(current?.accountUuid, json: json)
        case "org": return DigestQueryFormat.textField(current?.organizationName, json: json)
        case "tier": return DigestQueryFormat.textField(current?.tier, json: json)
        case "since":
            return DigestQueryFormat.dateField(
                card?.since, json: json, unix: unix, relative: false)
        case "observed":
            return DigestQueryFormat.dateField(
                card?.observedAt, json: json, unix: unix, relative: false)
        case "age":
            let age = card.map { max(0, now.timeIntervalSince($0.observedAt)) }
            return DigestQueryFormat.secondsField(age, json: json, relative: relative)
        case "attribution-since":
            return DigestQueryFormat.dateField(
                card?.attributionSince, json: json, unix: unix, relative: false)
        case "distinct":
            return DigestQueryFormat.intField(card?.distinctAccounts, json: json)
        case "today-tokens":
            return DigestQueryFormat.intField(mine?.todayTokens, json: json)
        case "today-cost":
            return DigestQueryFormat.numberField(mine?.todayCost, json: json)
        case "window-tokens":
            return DigestQueryFormat.intField(mine?.windowTokens, json: json)
        case "window-cost":
            return DigestQueryFormat.numberField(mine?.windowCost, json: json)
        case "accounts":
            // The reserved buckets join the human table as their own rows —
            // the split must reconcile to the unlabeled totals by eye. The
            // JSON register prints the rows verbatim; the whole card (with
            // buckets keyed) is `account --json`.
            var rows = (card?.accounts ?? []).map { usageRow($0.ref?.label ?? "", $0) }
            if let ambiguous = card?.ambiguous {
                rows.append(usageRow("(ambiguous)", ambiguous))
            }
            if let unattributed = card?.unattributed {
                rows.append(usageRow("(unattributed)", unattributed))
            }
            return accountTable(
                rows, columns: usageColumns, card: card, json: json,
                value: card?.accounts)
        case "epochs":
            return accountTable(
                (card?.epochs ?? []).map { epoch in
                    [
                        epoch.label,
                        DigestQueryFormat.iso(epoch.firstObservedAt),
                        DigestQueryFormat.iso(epoch.lastObservedAt),
                        DigestQueryFormat.rawBool(epoch.closed),
                    ]
                },
                columns: ["label", "first", "last", "closed"], card: card,
                json: json, value: card?.epochs)
        default: return unknownField(noun: "account", field: field)
        }
    }

    private static let usageColumns = [
        "label", "today-tokens", "today-cost", "window-tokens", "window-cost",
    ]

    private static func usageRow(_ label: String, _ usage: AccountUsage) -> [String] {
        [
            label,
            DigestQueryFormat.rawInt(usage.todayTokens),
            DigestQueryFormat.rawMoney(usage.todayCost),
            DigestQueryFormat.rawInt(usage.windowTokens),
            DigestQueryFormat.rawMoney(usage.windowCost),
        ]
    }

    /// A table field: no card at all is absent (null / empty), which is NOT
    /// the empty table a tracked-but-single-account card legitimately has.
    private static func accountTable<T: Encodable>(
        _ rows: [[String]], columns: [String], card: AccountPresenceCard?,
        json: Bool, value: T?
    ) -> QueryOutput {
        guard card != nil, let value else { return ok(json ? "null" : "") }
        if json { return ok(DigestQueryFormat.jsonValue(value)) }
        guard !rows.isEmpty else { return ok("") }
        return ok(DigestQueryFormat.tsv(rows, header: columns))
    }
}
