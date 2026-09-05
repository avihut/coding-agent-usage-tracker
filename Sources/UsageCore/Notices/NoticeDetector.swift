import Foundation

/// Turns the engine's observations into ledger entries. Pure over its
/// inputs — the engine owns the clock and the ledger, tests own everything.
public enum NoticeDetector {
    // MARK: - Vendor resets

    /// The vendor's mid-window grants visible in `samples`, one notice per
    /// instant however many meters dropped (`VendorGrants` rule), voiced by
    /// the meter that stood highest going in. `since` bounds the search so
    /// a per-fetch call walks a few recent samples and a start-up catch-up
    /// walks two days — never the whole history.
    public static func grants(
        samples: [UsageSample], since: Date?, now: Date,
        tolerance: TimeInterval = NoticeLedger.grantTolerance
    ) -> [Notice] {
        // Fill FIRST over the recent tail, then trim: a stampless zeroed poll
        // inherits the stamp from the poll before it, and that pair is what
        // names a mid-window drop.
        let filled = ResetCarry.fill(samples).filter { $0.t <= now }
        let labels = Set(filled.flatMap { $0.percents.keys }).sorted()
        struct Hit { let at: Date; let label: String; let from: Int }
        var hits: [Hit] = []
        for label in labels {
            let series = filled.compactMap { sample -> ResetCliffs.Sample? in
                guard let percent = sample.percents[label] else { return nil }
                return ResetCliffs.Sample(
                    t: sample.t, percent: percent, resetsAt: sample.resets?[label])
            }
            for (a, b) in zip(series, series.dropFirst())
            where ResetCliffs.resetKind(from: a, to: b) == .midWindow {
                let at = ResetCliffs.midpoint(a, b)
                if let since, at < since { continue }
                hits.append(Hit(at: at, label: label, from: a.percent))
            }
        }
        var notices: [Notice] = []
        for hit in hits.sorted(by: { $0.at < $1.at }) {
            if let index = notices.firstIndex(where: {
                abs($0.occurredAt.timeIntervalSince(hit.at)) <= tolerance
            }) {
                // Same instant: the meter with more to say voices it.
                if hit.from > (notices[index].fromPercent ?? 0) {
                    notices[index].meterLabel = hit.label
                    notices[index].fromPercent = hit.from
                }
                continue
            }
            notices.append(Notice(
                id: Notice.resetID(at: hit.at), kind: Notice.Kind.reset.rawValue,
                occurredAt: hit.at, endedAt: hit.at, ongoing: false, recordedAt: now,
                meterLabel: hit.label, fromPercent: hit.from))
        }
        return notices
    }

    /// Records the grants not yet in the ledger. Returns whether it changed.
    @discardableResult
    public static func noteGrants(
        samples: [UsageSample], since: Date?, now: Date, into ledger: inout NoticeLedger
    ) -> Bool {
        var changed = false
        for notice in grants(samples: samples, since: since, now: now)
        where !ledger.hasReset(near: notice.occurredAt) {
            changed = ledger.record(notice, now: now) || changed
        }
        return changed
    }

    // MARK: - Outages

    /// Applies one status card to the ledger: incidents newly open become
    /// ongoing notices, open ones refresh their phase and message, ones
    /// that left the open list close (their epilogue), and incidents the
    /// page reports as recently resolved that were never seen open are
    /// recorded already closed. Returns whether the ledger changed.
    ///
    /// A card that lost the feed (`unknown`) closes nothing: not reaching
    /// the page is not the incident ending.
    @discardableResult
    public static func apply(
        card: ServiceStatusCard, now: Date, into ledger: inout NoticeLedger
    ) -> Bool {
        var changed = false
        let open = Set(card.incidents.map(\.id))

        for incident in card.incidents {
            let id = Notice.outageID(incidentID: incident.id)
            if ledger.notice(id: id) != nil {
                changed = ledger.update(id: id) { notice in
                    notice.impact = incident.impact
                    notice.phase = incident.phase
                    notice.message = incident.lastMessage
                    notice.components = incident.componentNames
                    notice.url = incident.url ?? notice.url
                    if !notice.ongoing, notice.endedAt != nil {
                        // The page reopened it: live again, and news again.
                        notice.ongoing = true
                        notice.endedAt = nil
                        notice.dismissedAt = nil
                    }
                } || changed
            } else {
                changed = ledger.record(outage(from: incident, ongoing: true, now: now), now: now)
                    || changed
            }
        }

        if card.indicatorValue != .unknown {
            let resolvedAt = Dictionary(
                card.recentlyResolved.map { ($0.id, $0.resolvedAt ?? now) },
                uniquingKeysWith: { first, _ in first })
            for notice in ledger.notices
            where notice.kindValue == .outage && notice.ongoing {
                let incidentID = String(notice.id.dropFirst("outage|".count))
                guard !open.contains(incidentID) else { continue }
                changed = ledger.close(id: notice.id, endedAt: resolvedAt[incidentID] ?? now)
                    || changed
            }
        }

        for incident in card.recentlyResolved
        where ledger.notice(id: Notice.outageID(incidentID: incident.id)) == nil {
            changed = ledger.record(outage(from: incident, ongoing: false, now: now), now: now)
                || changed
        }
        return changed
    }

    /// A wake-time (or start-time) read of the page's incident history:
    /// incidents that opened AND resolved while nobody was polling become
    /// closed notices. Only ones resolved at or after `since`; unresolved
    /// ones are the summary poll's business. Returns whether it changed.
    @discardableResult
    public static func backfill(
        history: [StatusIncident], since: Date, now: Date, into ledger: inout NoticeLedger
    ) -> Bool {
        var changed = false
        for incident in history {
            guard let resolvedAt = incident.resolvedAt, resolvedAt >= since,
                  ledger.notice(id: Notice.outageID(incidentID: incident.id)) == nil
            else { continue }
            changed = ledger.record(outage(from: incident, ongoing: false, now: now), now: now)
                || changed
        }
        return changed
    }

    static func outage(from incident: StatusIncident, ongoing: Bool, now: Date) -> Notice {
        Notice(
            id: Notice.outageID(incidentID: incident.id), kind: Notice.Kind.outage.rawValue,
            occurredAt: incident.startedAt,
            endedAt: ongoing ? nil : (incident.resolvedAt ?? now),
            ongoing: ongoing, recordedAt: now,
            subject: incident.name, impact: incident.impact, phase: incident.phase,
            message: incident.lastMessage, components: incident.componentNames,
            url: incident.url)
    }
}
