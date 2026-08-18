import Foundation

/// The provider's own service health, normalized — what its public status
/// page says, in vocabulary no vendor owns. Published in the digest so every
/// face (menu bar, panel, TUI, usage-cli) renders the same card and none of
/// them polls anything.
///
/// Absent ≠ healthy: a nil card means this engine doesn't track status (no
/// feed for the provider, or a build that predates the feature), never "all
/// clear". A card that couldn't be refreshed says so through `stale` and the
/// `unknown` indicator — a fetch failure NEVER becomes an incident.
public struct ServiceStatusCard: Codable, Sendable, Equatable {
    /// Which provider this card describes — a client switching providers can
    /// tell a stale card from the new provider's.
    public let providerID: String
    /// The status page's own name for itself ("Claude").
    public let pageName: String
    /// Where a human goes for the full story.
    public let pageURL: String
    /// `Indicator.rawValue` — see that type for the ladder. A String on the
    /// wire so an indicator this build has never heard of decodes and
    /// renders quietly rather than failing the digest.
    public let indicator: String
    /// The page's own words ("All Systems Operational").
    public let descriptionText: String
    /// Last attempt, successful or not.
    public let checkedAt: Date
    /// Last SUCCESSFUL read; nil when nothing has ever landed.
    public let okAt: Date?
    /// The poller's own verdict: the card is old enough to distrust.
    public let stale: Bool
    public let components: [StatusComponent]
    /// Unresolved incidents, worst impact first.
    public let incidents: [StatusIncident]
    /// Resolved within the last hour — the quiet "all clear" the popover
    /// keeps after the loud surfaces have already gone dark.
    public let recentlyResolved: [StatusIncident]
    public let maintenances: [StatusMaintenance]

    public init(
        providerID: String, pageName: String, pageURL: String, indicator: String,
        descriptionText: String, checkedAt: Date, okAt: Date?, stale: Bool,
        components: [StatusComponent], incidents: [StatusIncident],
        recentlyResolved: [StatusIncident] = [], maintenances: [StatusMaintenance] = []
    ) {
        self.providerID = providerID
        self.pageName = pageName
        self.pageURL = pageURL
        self.indicator = indicator
        self.descriptionText = descriptionText
        self.checkedAt = checkedAt
        self.okAt = okAt
        self.stale = stale
        self.components = components
        self.incidents = incidents
        self.recentlyResolved = recentlyResolved
        self.maintenances = maintenances
    }

    /// The incident driving every loud surface — worst first, already sorted
    /// by the feed adapter. Maintenance is deliberately NOT an incident here:
    /// it colors the quiet dot and lists in the popover, and nothing else.
    public var activeIncident: StatusIncident? { incidents.first }

    /// True when something unresolved is happening — the badge/banner gate.
    public var hasIncident: Bool { !incidents.isEmpty }

    /// The severity ladder, as the loud surfaces rank it. Raw values are the
    /// wire vocabulary; `unknown` sits OUTSIDE the ladder (grey, never
    /// alarming) and `maintenance` below every real impact.
    public enum Indicator: String, Sendable, CaseIterable {
        case none, maintenance, minor, major, critical, unknown

        /// Higher wins when two sources disagree; `unknown` ranks lowest so a
        /// failed read never outranks a real observation.
        public var rank: Int {
            switch self {
            case .unknown: -1
            case .none: 0
            case .maintenance: 1
            case .minor: 2
            case .major: 3
            case .critical: 4
            }
        }

        /// An unrecognized indicator reads as `unknown`, never as healthy —
        /// the safe direction for a vocabulary that may grow.
        public static func parse(_ raw: String) -> Indicator {
            Indicator(rawValue: raw) ?? .unknown
        }
    }

    public var indicatorValue: Indicator { Indicator.parse(indicator) }
}

/// One service on the page ("Claude Code") and its current state. `status` is
/// the feed's own vocabulary (operational, degraded_performance,
/// partial_outage, major_outage, under_maintenance) — see `isOperational`.
public struct StatusComponent: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let status: String

    public var id: String { name }

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }

    public var isOperational: Bool { status == "operational" }

    /// "degraded_performance" → "Degraded performance".
    public var displayStatus: String {
        let spaced = status.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

/// One incident, flattened to what a dashboard renders: identity, severity,
/// where it is in its lifecycle, and the newest thing anyone said about it.
public struct StatusIncident: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// "none" | "minor" | "major" | "critical" — the feed's impact vocabulary.
    public let impact: String
    /// "investigating" | "identified" | "monitoring" | "resolved".
    public let phase: String
    public let startedAt: Date
    /// When the newest update was posted; nil when an incident carries none.
    public let lastUpdateAt: Date?
    /// The newest update's text — the "last message" every surface shows.
    public let lastMessage: String?
    public let url: String?
    /// Names only, matching `StatusComponent.name`.
    public let componentNames: [String]
    /// Set once resolved — `recentlyResolved` entries carry it.
    public let resolvedAt: Date?

    public init(
        id: String, name: String, impact: String, phase: String, startedAt: Date,
        lastUpdateAt: Date?, lastMessage: String?, url: String?,
        componentNames: [String], resolvedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.impact = impact
        self.phase = phase
        self.startedAt = startedAt
        self.lastUpdateAt = lastUpdateAt
        self.lastMessage = lastMessage
        self.url = url
        self.componentNames = componentNames
        self.resolvedAt = resolvedAt
    }

    public var impactValue: ServiceStatusCard.Indicator {
        ServiceStatusCard.Indicator.parse(impact)
    }

    /// How long this has been going — to resolution if it got there, else to
    /// `now`. The panel's "going 1h 12m".
    public func duration(now: Date) -> TimeInterval {
        max(0, (resolvedAt ?? now).timeIntervalSince(startedAt))
    }
}

/// One scheduled maintenance window. Quiet by design (decision D2): it tints
/// the footer dot and lists in the popover, and never badges or banners.
public struct StatusMaintenance: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// "scheduled" | "in_progress" | "verifying" | "completed".
    public let phase: String
    public let windowStart: Date?
    public let windowEnd: Date?

    public init(
        id: String, name: String, phase: String, windowStart: Date?, windowEnd: Date?
    ) {
        self.id = id
        self.name = name
        self.phase = phase
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }

    public var isActive: Bool { phase == "in_progress" || phase == "verifying" }
}
