import Foundation

/// Reads an Atlassian Statuspage — the format nearly every vendor's status
/// page runs on, which is what makes one client cover any provider that
/// declares a `.statuspage` feed.
///
/// Exactly one endpoint is ever fetched: `/api/v2/summary.json` (~2 KB),
/// which carries the overall indicator, every component, unresolved
/// incidents WITH their updates, and scheduled maintenances. The sibling
/// endpoints are all subsets of it, and `incidents.json` is 100× the weight
/// for history the popover links out to instead.
///
/// Spec §10 (amendment 2026-08-19): a plain anonymous GET. The session is
/// ephemeral and cookie-less, no credential is ever attached, nothing goes in
/// the URL, and only `If-None-Match` rides along — so a poll tells the page
/// nothing about the user beyond an IP that reaching the page would reveal
/// anyway.
public struct StatuspageFeed: Sendable {
    /// What a poll came back with. `notModified` is the common case: the CDN
    /// caches for 10s and we poll far slower, so most reads are a 304 with no
    /// body at all.
    public enum Outcome: Sendable {
        case fresh(page: StatuspageSummary, etag: String?)
        case notModified
    }

    public enum FeedError: Error, Equatable {
        case badResponse(Int)
        case malformed
        case transport
    }

    private let base: URL
    private let session: URLSession

    public init(base: URL, session: URLSession? = nil) {
        self.base = base
        self.session = session ?? Self.makeSession()
    }

    /// Cookie-less and credential-less by construction rather than by
    /// discipline: a session that cannot persist cookies can't leak one, and
    /// `.reloadIgnoringLocalCacheData` keeps URLCache out of the freshness
    /// story (the ETag is ours to manage, and a locally cached body would
    /// make `checkedAt` lie).
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: configuration)
    }

    public var summaryURL: URL { base.appending(path: "api/v2/summary.json") }

    /// One conditional GET. Throws `FeedError`; the poller turns a throw into
    /// a failure count, never into an incident.
    public func fetchSummary(etag: String?) async throws -> Outcome {
        var request = URLRequest(url: summaryURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw FeedError.transport }
        if http.statusCode == 304 { return .notModified }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedError.badResponse(http.statusCode)
        }
        guard let page = try? StatuspageSummary.decode(from: data) else {
            throw FeedError.malformed
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        return .fresh(page: page, etag: etag)
    }
}

/// The `summary.json` payload, decoded to exactly the fields we render.
/// Statuspage sends far more per object; everything unnamed here is ignored
/// (Codable's default), which is also what keeps the parse working when
/// Atlassian adds a field.
public struct StatuspageSummary: Sendable, Decodable {
    public struct Page: Sendable, Decodable {
        public let name: String?
        public let url: String?
    }

    public struct Status: Sendable, Decodable {
        public let indicator: String?
        public let description: String?
    }

    public struct Component: Sendable, Decodable {
        public let name: String?
        public let status: String?
        /// Statuspage hides these unless they're degraded; they'd otherwise
        /// pad the popover with rows the page itself doesn't show.
        public let onlyShowIfDegraded: Bool?
        /// A GROUP header, not a service — the page renders its children.
        public let group: Bool?

        enum CodingKeys: String, CodingKey {
            case name, status, group
            case onlyShowIfDegraded = "only_show_if_degraded"
        }
    }

    public struct Update: Sendable, Decodable {
        public let status: String?
        public let body: String?
        public let createdAt: Date?
        public let displayAt: Date?

        enum CodingKeys: String, CodingKey {
            case status, body
            case createdAt = "created_at"
            case displayAt = "display_at"
        }

        /// Statuspage lets an author post-date an update; the page sorts by
        /// `display_at` when it's set, so we agree with what the user saw.
        public var shownAt: Date? { displayAt ?? createdAt }
    }

    public struct Incident: Sendable, Decodable {
        public let id: String?
        public let name: String?
        public let status: String?
        public let impact: String?
        public let createdAt: Date?
        public let startedAt: Date?
        public let resolvedAt: Date?
        public let shortlink: String?
        public let incidentUpdates: [Update]?
        public let components: [Component]?

        enum CodingKeys: String, CodingKey {
            case id, name, status, impact, shortlink, components
            case createdAt = "created_at"
            case startedAt = "started_at"
            case resolvedAt = "resolved_at"
            case incidentUpdates = "incident_updates"
        }
    }

    public struct Maintenance: Sendable, Decodable {
        public let id: String?
        public let name: String?
        public let status: String?
        public let scheduledFor: Date?
        public let scheduledUntil: Date?

        enum CodingKeys: String, CodingKey {
            case id, name, status
            case scheduledFor = "scheduled_for"
            case scheduledUntil = "scheduled_until"
        }
    }

    public let page: Page?
    public let status: Status?
    public let components: [Component]?
    public let incidents: [Incident]?
    public let scheduledMaintenances: [Maintenance]?

    enum CodingKeys: String, CodingKey {
        case page, status, components, incidents
        case scheduledMaintenances = "scheduled_maintenances"
    }

    /// Statuspage stamps ISO-8601 with fractional seconds and an explicit
    /// offset; `FlexibleISO8601` already handles both that and the plain
    /// form, so a page that drops the fraction still parses.
    public static func decode(from data: Data) throws -> StatuspageSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = FlexibleISO8601.date(from: text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "bad date '\(text)'"))
            }
            return date
        }
        return try decoder.decode(StatuspageSummary.self, from: data)
    }
}

/// Statuspage payload → the digest's normalized card. Pure and static: the
/// poller owns the clock, the failure count, and the resolved-memory, so this
/// is a deterministic function of (page, identity, timestamps) and tests
/// exercise it with no network and no engine.
public enum StatuspageAdapter {
    /// Incidents a page still considers open.
    static func isUnresolved(_ incident: StatuspageSummary.Incident) -> Bool {
        let phase = incident.status ?? ""
        return phase != "resolved" && phase != "postmortem"
    }

    public static func card(
        from page: StatuspageSummary, providerID: String, pageURL: String,
        checkedAt: Date, okAt: Date?, stale: Bool,
        recentlyResolved: [StatusIncident] = []
    ) -> ServiceStatusCard {
        let components = (page.components ?? [])
            // Group headers aren't services, and Statuspage's own page hides
            // `only_show_if_degraded` components while they're fine.
            .filter { component in
                guard component.group != true else { return false }
                guard component.onlyShowIfDegraded == true else { return true }
                return (component.status ?? "operational") != "operational"
            }
            .compactMap { component -> StatusComponent? in
                guard let name = component.name else { return nil }
                return StatusComponent(name: name, status: component.status ?? "operational")
            }

        let incidents = (page.incidents ?? [])
            .filter(isUnresolved)
            .compactMap { incident(from: $0, fallbackDate: checkedAt) }
            .sorted { lhs, rhs in
                lhs.impactValue.rank != rhs.impactValue.rank
                    ? lhs.impactValue.rank > rhs.impactValue.rank
                    : lhs.startedAt > rhs.startedAt
            }

        let maintenances = (page.scheduledMaintenances ?? [])
            .compactMap { entry -> StatusMaintenance? in
                guard let id = entry.id, let name = entry.name else { return nil }
                let phase = entry.status ?? "scheduled"
                guard phase != "completed" else { return nil }
                return StatusMaintenance(
                    id: id, name: name, phase: phase,
                    windowStart: entry.scheduledFor, windowEnd: entry.scheduledUntil)
            }

        return ServiceStatusCard(
            providerID: providerID,
            pageName: page.page?.name ?? providerID,
            pageURL: page.page?.url ?? pageURL,
            indicator: indicator(
                page: page, incidents: incidents, maintenances: maintenances),
            descriptionText: page.status?.description ?? "",
            checkedAt: checkedAt,
            okAt: okAt,
            stale: stale,
            components: components,
            incidents: incidents,
            recentlyResolved: recentlyResolved,
            maintenances: maintenances)
    }

    /// The page's own indicator, with two corrections. A page reporting
    /// `none` while an in-progress maintenance runs becomes `maintenance` (the
    /// quiet blue state, decision D2); a page reporting `none` while carrying
    /// an unresolved incident takes the incident's impact, because the loud
    /// surfaces key off the indicator and would otherwise stay dark.
    static func indicator(
        page: StatuspageSummary, incidents: [StatusIncident],
        maintenances: [StatusMaintenance]
    ) -> String {
        let reported = ServiceStatusCard.Indicator.parse(page.status?.indicator ?? "none")
        let worstIncident = incidents.map(\.impactValue).max { $0.rank < $1.rank } ?? .none
        var resolved = reported.rank >= worstIncident.rank ? reported : worstIncident
        if resolved == .none, maintenances.contains(where: \.isActive) {
            resolved = .maintenance
        }
        return resolved.rawValue
    }

    /// One incident, flattened. The newest update by display time supplies
    /// the message every surface shows — a feed that posts them oldest-first
    /// must not leave us quoting the first thing anyone said.
    static func incident(
        from raw: StatuspageSummary.Incident, fallbackDate: Date
    ) -> StatusIncident? {
        guard let id = raw.id, let name = raw.name else { return nil }
        let updates = (raw.incidentUpdates ?? [])
            .filter { $0.shownAt != nil }
            .sorted { ($0.shownAt ?? .distantPast) > ($1.shownAt ?? .distantPast) }
        let newest = updates.first
        return StatusIncident(
            id: id,
            name: name,
            impact: raw.impact ?? "minor",
            phase: raw.status ?? "investigating",
            startedAt: raw.startedAt ?? raw.createdAt ?? fallbackDate,
            lastUpdateAt: newest?.shownAt,
            lastMessage: newest?.body,
            url: raw.shortlink,
            componentNames: (raw.components ?? []).compactMap(\.name),
            resolvedAt: raw.resolvedAt)
    }
}
