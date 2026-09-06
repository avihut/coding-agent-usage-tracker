import Foundation

/// Where a notification leads when clicked (v0.93.0). The PROVIDER decides:
/// it knows which of its events have an official record on the web and
/// which exist only in this app's own observations.
public enum NoticeDestination: Sendable, Equatable {
    /// An official record of the event — an incident's report on the status
    /// site, a vendor's announcement page.
    case web(URL)
    /// No official record exists: the meter's own history card, opened with
    /// the event's mark lit. `meterLabel` is the meter that voiced the
    /// notice (nil when unknown — the face falls back to its weekly meter);
    /// `at` is the instant to light.
    case meterHistory(meterLabel: String?, at: Date)
    /// The Accounts settings card — where a discovered home is enrolled.
    case accounts
}

extension UsageProvider {
    /// Where an outage leads, whatever face shows it — the notice row, the
    /// chart's outage nub: the incident's own report when the page gave one,
    /// else the status page, else nowhere. ONE rule so the two clicks can't
    /// disagree.
    public func outageDestination(url raw: String?) -> URL? {
        if let raw, let url = URL(string: raw) { return url }
        return statusFeed?.pageURL
    }

    /// The default policy: an outage leads to its incident page (else the
    /// status page), a reset to the meter card — no vendor is known to
    /// publish a feed of limit resets. A provider with such a feed
    /// overrides this for `.reset`.
    public func noticeDestination(for notice: NoticeCard) -> NoticeDestination? {
        switch Notice.Kind(rawValue: notice.kind) {
        case .outage:
            return outageDestination(url: notice.url).map { .web($0) }
        case .reset:
            return .meterHistory(meterLabel: notice.meterLabel, at: notice.occurredAt)
        case .profileFound:
            return .accounts
        case nil:
            return notice.url.flatMap(URL.init(string:)).map { .web($0) }
        }
    }
}
