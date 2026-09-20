import Foundation

/// The vendor-level half of metering for EVERY metered harness (v0.101.0):
/// one `ProviderServices` per provider — its pricing feed, its status
/// poller, its one notice ledger — built the first time that harness is
/// metered and kept for the host's life. A second harness is a second
/// vendor's services; a second ACCOUNT still shares its harness's, which is
/// what keeps spec §10's destinations one-per-provider however many homes
/// and harnesses are metered.
///
/// It is also the router for the notice verbs: a digest names another
/// harness's notice with a qualified id (`NoticeRouting`), and a verb lands
/// in that harness's ledger alone.
@MainActor
public final class ProviderServicesRegistry {
    public private(set) var all: [String: ProviderServices] = [:]
    /// Any harness's services changed something a digest should show.
    public var onChange: (@MainActor () -> Void)?

    private let bundleID: String
    private let roots: StorageScope.Roots
    private let pollsStatus: Bool
    private var isStarted = false
    private var isStopped = false

    public init(bundleID: String, roots: StorageScope.Roots = .standard, pollsStatus: Bool = true) {
        self.bundleID = bundleID
        self.roots = roots
        self.pollsStatus = pollsStatus
    }

    /// This harness's services, built on first use and started at once when
    /// the host is already running (a harness installed mid-session).
    ///
    /// CREATING — and creating means starting a status poller, i.e. a network
    /// destination. Only the host's own reconciliation may call it, for a
    /// harness it has decided to meter; every reader asks `services(forHarness:)`
    /// (or the subscript), which answers nil for a harness nobody meters
    /// rather than quietly spinning one up.
    @discardableResult
    public func services(for provider: any UsageProvider) -> ProviderServices {
        if let existing = all[provider.id] { return existing }
        let services = ProviderServices(
            provider: provider, bundleID: bundleID, roots: roots, pollsStatus: pollsStatus)
        services.onChange = { [weak self] in self?.onChange?() }
        all[provider.id] = services
        if isStarted, !isStopped { services.start() }
        return services
    }

    public subscript(providerID: String) -> ProviderServices? { all[providerID] }

    /// A reader's lookup: nil for a harness this host does not meter.
    public func services(forHarness providerID: String) -> ProviderServices? { all[providerID] }

    public func start() {
        guard !isStopped else { return }
        isStarted = true
        for services in all.values { services.start() }
    }

    public func stop() {
        isStopped = true
        onChange = nil
        for services in all.values { services.stop() }
    }

    public func noteWake() {
        for services in all.values { services.noteWake() }
    }

    public func refreshPricingNow() {
        for services in all.values { services.refreshPricingNow() }
    }

    public func refreshServiceStatus() {
        for services in all.values { services.refreshServiceStatus() }
    }

    // MARK: - Notice verbs, routed by id

    public func markSeen(_ ids: [String]) {
        let routed = Dictionary(grouping: ids.map(NoticeRouting.split), by: \.providerID)
        for (providerID, parts) in routed {
            all[providerID]?.notices.mutate { $0.markSeen(ids: parts.map(\.id)) }
        }
    }

    @discardableResult
    public func dismiss(_ id: String) -> Bool {
        let routed = NoticeRouting.split(id)
        return all[routed.providerID]?.notices.mutate { $0.dismiss(id: routed.id) } ?? false
    }

    public func dismissAll() {
        for services in all.values { services.notices.mutate { $0.dismissAll() } }
    }
}
