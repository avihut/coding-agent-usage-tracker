import Foundation

/// The `accounts` noun (0.96.0): every profile the writer meters — id,
/// label, home, state, focus, freshness, limits — the CLI face of the
/// account strip. A table by default (`--raw` TSV, `--json` the digest's
/// own `profiles` list), plus three scalars: `count`, `focused` (the
/// writer's choice) and `selected` (what THIS invocation answered for —
/// `--account`, the home variable, or the focus).
///
/// Absent-card discipline: a pre-0.96 writer publishes no profile list, so
/// the table prints nothing and `count`/`focused` go absent; `selected`
/// still answers, because the selector resolved regardless.
extension DigestQuery {
    static let accountsColumns = ["id", "label", "home", "state", "focused", "updated", "limits"]

    static func runAccounts(
        parsed: ParsedArgs, digest: LiveState, now: Date, json: Bool, raw: Bool, selectedID: String
    ) -> QueryOutput {
        let unix = parsed.flags["unix"] != nil
        func resolve(_ field: String, asJSON: Bool) -> QueryOutput {
            accountsField(
                field, digest: digest, now: now, json: asJSON, raw: raw, unix: unix,
                selectedID: selectedID)
        }
        if let output = multiFieldOutput(
            noun: "accounts", parsed: parsed, positionalField: parsed.positionals.first,
            json: json, header: parsed.flags["header"] != nil, resolve: resolve)
        {
            return output
        }

        guard let field = parsed.positionals.first else {
            guard parsed.positionals.isEmpty else { return badQuery("too many arguments") }
            guard let profiles = digest.profiles else { return ok(json ? "null" : "") }
            if json { return ok(DigestQueryFormat.jsonValue(profiles)) }
            return ok(itemsTable(profiles, now: now, raw: raw, unix: unix))
        }
        guard parsed.positionals.count == 1 else { return badQuery("too many arguments") }
        return resolve(field, asJSON: json)
    }

    private static func accountsField(
        _ field: String, digest: LiveState, now: Date, json: Bool, raw: Bool, unix: Bool,
        selectedID: String
    ) -> QueryOutput {
        switch field {
        case "count": return DigestQueryFormat.intField(digest.profiles?.count, json: json)
        case "focused": return DigestQueryFormat.textField(digest.focusedProfile, json: json)
        case "selected": return DigestQueryFormat.textField(selectedID, json: json)
        case "items":
            guard let profiles = digest.profiles else { return ok(json ? "null" : "") }
            if json { return ok(DigestQueryFormat.jsonValue(profiles)) }
            return ok(itemsTable(profiles, now: now, raw: raw, unix: unix))
        default: return unknownField(noun: "accounts", field: field)
        }
    }

    private static func itemsTable(_ profiles: [ProfileState], now: Date, raw: Bool, unix: Bool) -> String {
        let rows = profiles.map { accountRow($0, now: now, raw: raw, unix: unix) }
        guard !rows.isEmpty else { return "" }
        return raw
            ? DigestQueryFormat.tsv(rows, header: accountsColumns)
            : DigestQueryFormat.table([accountsColumns] + rows)
    }

    /// `updated` is the section's own fetch stamp — relative in the human
    /// register, ISO (or `--unix`) in raw; `limits` the bar's segments that
    /// carry a percent ("S 53% W 80%", raw "S=53 W=80").
    private static func accountRow(_ profile: ProfileState, now: Date, raw: Bool, unix: Bool) -> [String] {
        var updated = ""
        if let fetchedAt = profile.engine?.fetchedAt {
            if raw {
                updated = unix ? String(Int(fetchedAt.timeIntervalSince1970)) : DigestQueryFormat.iso(fetchedAt)
            } else {
                updated = UsageFormatting.duration(max(0, now.timeIntervalSince(fetchedAt))) + " ago"
            }
        }
        let limits = (profile.menuBar ?? []).compactMap { segment in
            segment.percent.map { raw ? "\(segment.tag)=\($0)" : "\(segment.tag) \($0)%" }
        }
        return [
            profile.id,
            profile.label,
            profile.homeDisplayPath ?? "",
            accountState(profile, now: now),
            raw ? DigestQueryFormat.rawBool(profile.isFocused) : (profile.isFocused ? "focused" : ""),
            updated,
            limits.joined(separator: " "),
        ]
    }

    /// One word per row, in the strip's own vocabulary
    /// (`UsageFormatting.profileStateLine`): the writer's `enabled` and
    /// `dormant` facts first, then the last write's age.
    static func accountState(_ profile: ProfileState, now: Date) -> String {
        if !profile.enabled { return "disabled" }
        if profile.dormant { return "dormant" }
        guard let last = profile.lastActivityAt else { return "no sessions" }
        return now.timeIntervalSince(last) <= 3600 ? "active" : "quiet"
    }
}
