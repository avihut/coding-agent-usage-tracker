import Foundation

/// A home the provider found beside its standard one that nobody enrolled
/// or dismissed — what the `profileFound` notice offers.
public struct DiscoveredHome: Sendable, Equatable, Identifiable {
    public let home: URL
    public let profileID: String
    /// "~/.claude-personal".
    public let displayPath: String
    /// The sign-in its identity record names, when it has one.
    public let identity: AccountIdentity?
    public let lastActivityAt: Date?

    public var id: String { profileID }

    public init(
        home: URL, profileID: String, displayPath: String, identity: AccountIdentity?,
        lastActivityAt: Date?
    ) {
        self.home = home
        self.profileID = profileID
        self.displayPath = displayPath
        self.identity = identity
        self.lastActivityAt = lastActivityAt
    }
}

/// D2, detect-and-offer: the app lists the provider's candidate homes,
/// reads each one's identity record and session mtimes (read-only, nothing
/// credentialed — spec §10 amendment 2026-09-06), and offers the ones
/// nobody has decided about. A home the person dismissed stays silent
/// until its sign-in changes; a dormant home (D9) is never offered.
public enum ProfileDiscovery {
    public static func discover(
        provider: any UsageProvider, known: [Profile], bundleID: String,
        roots: StorageScope.Roots = .standard, now: Date,
        userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [DiscoveredHome] {
        guard provider.supportsMultipleHomes, let standard = provider.homeDirectory else { return [] }
        var found: [DiscoveredHome] = []
        for home in provider.discoverHomes() {
            let profileID = ProfileID.forHome(home, standard: standard)
            guard profileID != Profile.defaultID else { continue }
            let candidate = provider.withHome(home)
            let probe = ProfileActivity.probe(
                provider: candidate,
                cacheDirectory: StorageScope.supportDirectory(
                    bundleID: bundleID, providerID: provider.id, profileID: profileID, roots: roots),
                now: now)
            if let record = known.first(where: { $0.id == profileID && $0.providerID == provider.id }) {
                // Enrolled: nothing to offer. Dismissed: only a changed
                // sign-in re-opens the question.
                guard record.isDismissed, let identity = probe.identity,
                      identity.key != record.ignoredIdentityKey
                else { continue }
            }
            // A home with sessions long gone is dormant, not news; one with
            // no sessions at all is offered only when someone signed in.
            let dormant = probe.lastActivityAt.map {
                now.timeIntervalSince($0) > Dormancy.window
            } ?? (probe.identity == nil)
            guard !dormant else { continue }
            found.append(DiscoveredHome(
                home: home, profileID: profileID,
                displayPath: PathDisplay.abbreviated(home, home: userHome),
                identity: probe.identity, lastActivityAt: probe.lastActivityAt))
        }
        return found
    }

    /// One `profileFound` notice per discovery, born ended and dismissable;
    /// its id is the profile's, so a re-discovery finds the ledger row
    /// (pending or dismissed) and stays silent.
    public static func offers(_ homes: [DiscoveredHome], providerID: String, now: Date) -> [Notice] {
        homes.map { home in
            Notice(
                id: Notice.profileFoundID(profileID: home.profileID),
                kind: Notice.Kind.profileFound.rawValue,
                occurredAt: now, endedAt: now, ongoing: false, recordedAt: now,
                subject: home.displayPath, message: home.identity?.email)
        }
    }
}
