import Foundation

/// The `health` noun: the metered service's own status, for status bars and
/// scripts. Named `health` because `status` was already taken by the ENGINE's
/// status (pid, host, freshness, backoff) — two different questions that a
/// shared noun would blur.
///
/// Absent-card discipline runs through every branch: an engine that tracks no
/// status publishes no card, and this noun then prints nothing and exits 0.
/// It never invents a healthy answer, and it never errors — a prompt segment
/// re-running this every render must go quiet, not red.
extension DigestQuery {
    /// `health --check` exits with this when something is unresolved. Next
    /// free code after 21 (stale), and part of the CLI's API: a script can
    /// branch on it without parsing a word of output.
    static let exitIncident: Int32 = 22

    static func runHealth(
        parsed: ParsedArgs, digest: LiveState, now: Date, json: Bool
    ) -> QueryOutput {
        let card = digest.serviceStatus
        let unix = parsed.flags["unix"] != nil
        let relative = parsed.flags["relative"] != nil

        if parsed.flags["check"] != nil {
            // No card is not an incident. Silence and 0 — the same answer a
            // healthy service gives, because neither is news.
            let incident = card?.hasIncident ?? false
            return QueryOutput(stdout: "", exitCode: incident ? exitIncident : exitOK)
        }

        func resolve(_ field: String, asJSON: Bool) -> QueryOutput {
            healthField(
                field, card: card, now: now, json: asJSON, unix: unix, relative: relative)
        }
        if let output = multiFieldOutput(
            noun: "health", parsed: parsed, positionalField: parsed.positionals.first,
            json: json, header: parsed.flags["header"] != nil, resolve: resolve)
        {
            return output
        }

        guard let field = parsed.positionals.first else {
            guard parsed.positionals.isEmpty else { return badQuery("too many arguments") }
            guard let card else { return ok(json ? "null" : "") }
            if json { return ok(DigestQueryFormat.jsonValue(card)) }
            if parsed.flags["raw"] != nil {
                return badQuery("raw needs a field — e.g. `health indicator`")
            }
            return ok(withStaleSuffix(summaryLine(card, now: now), digest: digest))
        }
        guard parsed.positionals.count == 1 else { return badQuery("too many arguments") }
        return resolve(field, asJSON: json)
    }

    /// The human line: what's wrong (or that nothing is), how long, and how
    /// fresh the reading is.
    private static func summaryLine(_ card: ServiceStatusCard, now: Date) -> String {
        var parts = [card.indicator]
        if let incident = card.activeIncident {
            parts.append(incident.name)
            parts.append(incident.phase)
            parts.append(UsageFormatting.duration(incident.duration(now: now)))
        } else if card.indicatorValue == .unknown {
            parts.append("status unavailable")
        } else if !card.descriptionText.isEmpty {
            parts.append(card.descriptionText)
        }
        let age = max(0, now.timeIntervalSince(card.checkedAt))
        parts.append("checked \(UsageFormatting.duration(age)) ago")
        return parts.joined(separator: " · ")
    }

    /// One field. Every accessor tolerates a nil card the same way the digest
    /// does: absent, not zero and not "none".
    private static func healthField(
        _ field: String, card: ServiceStatusCard?, now: Date, json: Bool, unix: Bool,
        relative: Bool
    ) -> QueryOutput {
        let incident = card?.activeIncident
        switch field {
        case "indicator": return DigestQueryFormat.textField(card?.indicator, json: json)
        case "description": return DigestQueryFormat.textField(card?.descriptionText, json: json)
        case "page": return DigestQueryFormat.textField(card?.pageName, json: json)
        case "page-url": return DigestQueryFormat.textField(card?.pageURL, json: json)
        case "ok":
            // Absent when the feed couldn't be read: an unreachable page has
            // no READABLE incidents, and reporting that as `true` would tell
            // a script the service is fine on the strength of knowing
            // nothing. Unknown is unknown, so the field goes empty.
            return DigestQueryFormat.boolField(
                card.flatMap { $0.indicatorValue == .unknown ? nil : !$0.hasIncident },
                json: json)
        case "stale": return DigestQueryFormat.boolField(card?.stale, json: json)
        case "checked":
            return DigestQueryFormat.dateField(
                card?.checkedAt, json: json, unix: unix, relative: false)
        case "age":
            let age = card.map { max(0, now.timeIntervalSince($0.checkedAt)) }
            return DigestQueryFormat.secondsField(age, json: json, relative: relative)
        case "incident": return DigestQueryFormat.textField(incident?.name, json: json)
        case "impact": return DigestQueryFormat.textField(incident?.impact, json: json)
        case "phase": return DigestQueryFormat.textField(incident?.phase, json: json)
        case "started":
            return DigestQueryFormat.dateField(
                incident?.startedAt, json: json, unix: unix, relative: false)
        case "duration":
            return DigestQueryFormat.secondsField(
                incident.map { $0.duration(now: now) }, json: json, relative: relative)
        case "message": return DigestQueryFormat.textField(incident?.lastMessage, json: json)
        case "message-at":
            return DigestQueryFormat.dateField(
                incident?.lastUpdateAt, json: json, unix: unix, relative: false)
        case "incident-url": return DigestQueryFormat.textField(incident?.url, json: json)
        case "components":
            return healthTable(
                card?.components.map { [$0.name, $0.status] } ?? [],
                columns: ["name", "status"], card: card, json: json,
                value: card?.components)
        case "incidents":
            return healthTable(
                (card?.incidents ?? []).map(incidentRow(now: now)),
                columns: incidentColumns, card: card, json: json, value: card?.incidents)
        case "resolved":
            return healthTable(
                (card?.recentlyResolved ?? []).map(incidentRow(now: now)),
                columns: incidentColumns, card: card, json: json,
                value: card?.recentlyResolved)
        case "maintenances":
            return healthTable(
                (card?.maintenances ?? []).map { [$0.name, $0.phase] },
                columns: ["name", "phase"], card: card, json: json, value: card?.maintenances)
        default: return unknownField(noun: "health", field: field)
        }
    }

    private static let incidentColumns = ["name", "impact", "phase", "duration"]

    private static func incidentRow(now: Date) -> (StatusIncident) -> [String] {
        { incident in
            [
                incident.name, incident.impact, incident.phase,
                String(Int(incident.duration(now: now).rounded())),
            ]
        }
    }

    /// A table field. With no card at all the answer is absent (null / empty),
    /// which is NOT the same as the empty table a card with no incidents
    /// legitimately has.
    private static func healthTable<T: Encodable>(
        _ rows: [[String]], columns: [String], card: ServiceStatusCard?, json: Bool,
        value: T?
    ) -> QueryOutput {
        guard card != nil, let value else { return ok(json ? "null" : "") }
        if json { return ok(DigestQueryFormat.jsonValue(value)) }
        guard !rows.isEmpty else { return ok("") }
        return ok(DigestQueryFormat.tsv(rows, header: columns))
    }
}
