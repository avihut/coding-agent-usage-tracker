import Foundation

/// One metered harness in the digest (v0.101.0): who it is, whether the
/// person shows it, how much it has been used lately, and the cards that
/// belong to the VENDOR rather than to an account — its service health, its
/// notices, its outage spans. Every harness found on this machine is listed,
/// hidden ones included: hiding is a display choice, and the rates list
/// keeps naming a hidden harness's models (user-decided).
///
/// The digest's top level stays the FOCUSED harness's projection, so every
/// reader that knows nothing about harnesses keeps working; a reader that
/// does walks this list, and `LiveState.viewing(profile:)` projects any
/// account of any harness onto the top level with its own cards.
public struct HarnessState: Codable, Sendable, Equatable, Identifiable {
    /// The provider id ("claude", "codex") — also the `providerID` every
    /// profile section and menu bar cell carries.
    public let id: String
    public let serviceName: String
    public let agentName: String
    public let glyph: String
    /// The agent's first word ("Claude", "Codex", "Gemini") — what a face
    /// with no glyph alphabet prints where the glyph would go.
    public let shortName: String
    public let accent: RGBColor
    /// No network destinations: usage is read from local files, so there is
    /// no budget gauge and a refresh is a rescan.
    public let isLocalProvider: Bool
    /// Found on this machine. False only for the bundled harness on a Mac
    /// where nothing was found at all — metered so the faces have something
    /// honest to show.
    public let present: Bool
    /// Drawn in the bar and eligible for focus. A hidden harness is still
    /// metered, still forecast, still priced.
    public let shown: Bool
    /// Session files written inside the activity window, across its
    /// accounts; nil when the writer counts none.
    public let recentFiles: Int?
    /// Distinct days inside that window with a write — what ranks harnesses
    /// against each other (`HarnessFocusRule`).
    public let activeDays: Int?
    public let newestActivityAt: Date?
    /// Enrolled accounts, dormant ones included.
    public let accountCount: Int
    /// This vendor's service health; nil = it publishes no status feed, or
    /// the card has not landed yet. ABSENT IS NOT HEALTHY.
    public let serviceStatus: ServiceStatusCard?
    /// This harness's pending notices, already phrased, ids qualified so a
    /// dismissal reaches this ledger and no other (`NoticeRouting`).
    public let notices: NoticesCard?
    /// Its incidents within the sample retention; nil = it records none.
    public let outages: [OutageSpan]?

    public init(
        id: String, serviceName: String, agentName: String, glyph: String, shortName: String,
        accent: RGBColor, isLocalProvider: Bool, present: Bool, shown: Bool,
        recentFiles: Int?, activeDays: Int?, newestActivityAt: Date?, accountCount: Int,
        serviceStatus: ServiceStatusCard?, notices: NoticesCard?, outages: [OutageSpan]?
    ) {
        self.id = id
        self.serviceName = serviceName
        self.agentName = agentName
        self.glyph = glyph
        self.shortName = shortName
        self.accent = accent
        self.isLocalProvider = isLocalProvider
        self.present = present
        self.shown = shown
        self.recentFiles = recentFiles
        self.activeDays = activeDays
        self.newestActivityAt = newestActivityAt
        self.accountCount = accountCount
        self.serviceStatus = serviceStatus
        self.notices = notices
        self.outages = outages
    }
}

/// What the host hands the composer for one metered harness: the provider
/// itself, how it stands, and its vendor-level cards as its services have
/// them right now.
public struct HarnessSection: Sendable {
    public let provider: any UsageProvider
    public let present: Bool
    public let shown: Bool
    public let recentFiles: Int?
    public let activeDays: Int?
    public let serviceStatus: ServiceStatusCard?
    public let notices: [Notice]?
    public let outages: [OutageSpan]?

    public init(
        provider: any UsageProvider, present: Bool = true, shown: Bool = true,
        recentFiles: Int? = nil, activeDays: Int? = nil,
        serviceStatus: ServiceStatusCard? = nil, notices: [Notice]? = nil,
        outages: [OutageSpan]? = nil
    ) {
        self.provider = provider
        self.present = present
        self.shown = shown
        self.recentFiles = recentFiles
        self.activeDays = activeDays
        self.serviceStatus = serviceStatus
        self.notices = notices
        self.outages = outages
    }

    /// The short name every face falls back to when it cannot draw a glyph:
    /// the agent's first word, so nothing outside the provider files has to
    /// know a vendor's name.
    public var shortName: String {
        provider.agentName.split(separator: " ").first.map(String.init) ?? provider.serviceName
    }
}
