import Foundation

/// One thing the engine noticed that a person may want to be told about
/// later — the record the notice ledger keeps, in FACTS. Phrasing happens
/// once, in the digest builder (`NoticePhrasing`), so every face repeats the
/// same words and none of them re-derives copy from the facts.
///
/// Two lifecycles share this one shape (user-directed design, 2026-09-05):
/// - an `ongoing` notice is bound to a live condition — an unresolved
///   incident. It cannot be dismissed, and when the condition ends it
///   becomes its own epilogue in place: `ongoing` flips off, `endedAt` is
///   set, and `seenWhileOngoing` remembers whether anyone looked while it
///   ran, because the epilogue's copy differs ("Outage ended" vs the full
///   summary of something that came and went unwatched);
/// - an event notice — the vendor's mid-window reset — is born ended and
///   dismissable.
///
/// `seenAt` and `dismissedAt` are separate states: seen means some face
/// rendered the notice while it was pending; dismissed is the person's
/// click. The menu bar indicator keys off dismissal (a glance is not a
/// decision), the epilogue copy keys off seen.
public struct Notice: Codable, Sendable, Equatable, Identifiable {
    /// The kinds this build knows. Stored as a String on the wire and in
    /// the ledger so a kind a newer build recorded still decodes here.
    public enum Kind: String, Sendable {
        /// The vendor emptied the meters inside a window
        /// (`ResetCliffs.Cliff.Kind.midWindow`, observed on any meter —
        /// `VendorGrants` semantics: one account-wide event).
        case reset
        /// An incident on the provider's status page.
        case outage
    }

    /// Stable across processes and re-observations: `reset|<epoch seconds
    /// of the grant, to the minute>` or `outage|<incident id>`.
    public let id: String
    public let kind: String
    /// When the thing happened — the grant instant, the incident's start.
    public let occurredAt: Date
    /// When the condition ended; nil while `ongoing`. An event notice
    /// carries `occurredAt` here too.
    public var endedAt: Date?
    /// The condition is still live — persistent, never dismissable.
    public var ongoing: Bool
    public var seenAt: Date?
    public var dismissedAt: Date?
    /// Set when an ongoing notice closes: was it seen while it ran?
    public var seenWhileOngoing: Bool
    public let recordedAt: Date

    // MARK: Facts by kind

    /// The incident's name.
    public var subject: String?
    /// The incident's impact vocabulary ("minor" | "major" | "critical").
    public var impact: String?
    /// The incident's lifecycle phase, updated while ongoing.
    public var phase: String?
    /// The incident's newest update text.
    public var message: String?
    public var components: [String]
    public var url: String?
    /// The meter whose drop the reset was read from — the one with the
    /// most to say (highest standing percent).
    public var meterLabel: String?
    /// That meter's percent going in.
    public var fromPercent: Int?

    public init(
        id: String, kind: String, occurredAt: Date, endedAt: Date? = nil,
        ongoing: Bool = false, seenAt: Date? = nil, dismissedAt: Date? = nil,
        seenWhileOngoing: Bool = false, recordedAt: Date,
        subject: String? = nil, impact: String? = nil, phase: String? = nil,
        message: String? = nil, components: [String] = [], url: String? = nil,
        meterLabel: String? = nil, fromPercent: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.occurredAt = occurredAt
        self.endedAt = endedAt
        self.ongoing = ongoing
        self.seenAt = seenAt
        self.dismissedAt = dismissedAt
        self.seenWhileOngoing = seenWhileOngoing
        self.recordedAt = recordedAt
        self.subject = subject
        self.impact = impact
        self.phase = phase
        self.message = message
        self.components = components
        self.url = url
        self.meterLabel = meterLabel
        self.fromPercent = fromPercent
    }

    public var kindValue: Kind? { Kind(rawValue: kind) }
    public var isPending: Bool { dismissedAt == nil }
    /// Only a notice that is not bound to a live condition can be dismissed.
    public var isDismissable: Bool { !ongoing }

    /// The vendor reset's identity: to the minute, so two hosts reading the
    /// same pair of polls (or one host re-reading its history on start) name
    /// the same event.
    public static func resetID(at: Date) -> String {
        "reset|\(Int(at.timeIntervalSince1970) / 60 * 60)"
    }

    public static func outageID(incidentID: String) -> String {
        "outage|\(incidentID)"
    }
}
