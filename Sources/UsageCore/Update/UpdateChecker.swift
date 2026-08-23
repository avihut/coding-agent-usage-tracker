import Foundation

/// Checks the release feed on a slow clock and hands the engine a card.
///
/// The quiet sibling of `StatusPoller`, with a simpler contract: releases
/// are rare, so the cadence is hours, a failed check just keeps the last
/// card (an aging "you're current" is harmless where an aging incident is
/// not), and only a definitive "no releases exist" withdraws the card.
/// Nothing here downloads an asset — that is the app's explicitly clicked
/// `AppUpdater`, never this timer.
@MainActor
public final class UpdateChecker {
    /// Fires whenever the published card changes — the engine republishes
    /// the digest. `nil` withdraws a previously published card.
    public var onCard: ((AppUpdateCard?) -> Void)?

    public private(set) var card: AppUpdateCard?

    /// Releases land weekly at most; four checks a day notices one within
    /// hours while staying far under GitHub's anonymous rate budget.
    public static let interval: TimeInterval = 6 * 3600
    /// The floor between any two actual fetches — pokes and manual checks
    /// inside it are dropped, so a click storm can't turn into a hot loop.
    public static let minimumSpacing: TimeInterval = 60
    /// Sticky opt-out for the background clock; manual checks ignore it.
    public static let autoCheckKey = "updateAutoCheck"
    /// Debug hatch: points the checker at an arbitrary feed URL (the
    /// end-to-end drill serves a synthetic release from localhost). Its
    /// presence also forces the checker — and the install pipeline — on in
    /// a source checkout. Nonisolated: a key constant is not actor state,
    /// and `Distribution` reads it from nonisolated code.
    public nonisolated static let feedOverrideKey = "updateFeedURL"

    private let feed: UpdateFeed
    private let currentVersion: String
    private let defaults: UserDefaults
    private var timer: Timer?
    private var etag: String?
    private var lastFetchAt: Date?
    private var isChecking = false
    private var isStopped = false

    public init(feed: UpdateFeed, currentVersion: String, defaults: UserDefaults) {
        self.feed = feed
        self.currentVersion = currentVersion
        self.defaults = defaults
    }

    public var isAutoCheckEnabled: Bool {
        defaults.object(forKey: Self.autoCheckKey) == nil
            || defaults.bool(forKey: Self.autoCheckKey)
    }

    /// Begins the slow clock, with an immediate first check when the
    /// background clock is enabled.
    public func start() {
        guard !isStopped else { return }
        if isAutoCheckEnabled { check() } else { scheduleNext() }
    }

    public func stop() {
        isStopped = true
        timer?.invalidate()
        timer = nil
        onCard = nil
    }

    /// A user-initiated check — Settings' "Check Now", the control socket's
    /// verb. Ignores the auto-check opt-out (the user just asked), honors
    /// only the spacing floor.
    public func checkNow() {
        guard !isStopped, maySpendFetch() else { return }
        check()
    }

    /// The wake poke: only worth a request when the card has aged past a
    /// full interval (a lid closed overnight), so casual wakes stay silent.
    public func pokeIfStale() {
        guard isAutoCheckEnabled else { return }
        let age = lastFetchAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > Self.interval, maySpendFetch() else { return }
        check()
    }

    private func maySpendFetch() -> Bool {
        guard let lastFetchAt else { return true }
        return Date().timeIntervalSince(lastFetchAt) >= Self.minimumSpacing
    }

    private func check() {
        guard !isStopped, !isChecking else { return }
        isChecking = true
        lastFetchAt = Date()
        let etag = etag
        Task { [weak self] in
            guard let self else { return }
            let result: Result<UpdateFeed.Outcome, Error>
            do {
                result = .success(try await self.feed.fetchLatest(etag: etag))
            } catch {
                result = .failure(error)
            }
            self.finish(result)
        }
    }

    private func finish(_ result: Result<UpdateFeed.Outcome, Error>) {
        isChecking = false
        guard !isStopped else { return }
        let now = Date()

        switch result {
        case .success(.fresh(let release, let newETag)):
            etag = newETag
            publish(Self.card(from: release, currentVersion: currentVersion, checkedAt: now))
        case .success(.notModified):
            // The release we know about is still the latest; only the
            // check's own freshness moved.
            if let card {
                publish(AppUpdateCard(
                    latestVersion: card.latestVersion, url: card.url,
                    publishedAt: card.publishedAt, assetName: card.assetName,
                    assetURL: card.assetURL, assetBytes: card.assetBytes,
                    checkedAt: now, updateAvailable: card.updateAvailable))
            }
        case .success(.noReleases):
            // Definitive: nothing is published. Withdraw rather than age.
            etag = nil
            if card != nil { publish(nil) }
        case .failure:
            // Silence. A failed check must never look like an update, and
            // the card we hold is still the best knowledge we have.
            break
        }
        scheduleNext()
    }

    /// Pure release → card mapping, split out so tests cover it without a
    /// network seam.
    nonisolated public static func card(
        from release: GitHubRelease, currentVersion: String, checkedAt: Date
    ) -> AppUpdateCard {
        let asset = release.updateAsset
        return AppUpdateCard(
            latestVersion: release.version,
            url: release.pageURL,
            publishedAt: release.publishedAt,
            assetName: asset?.name,
            assetURL: asset?.downloadURL,
            assetBytes: asset?.bytes,
            checkedAt: checkedAt,
            updateAvailable: AppVersion.isNewer(release.version, than: currentVersion))
    }

    private func publish(_ fresh: AppUpdateCard?) {
        guard fresh != card else { return }
        card = fresh
        onCard?(fresh)
    }

    private func scheduleNext() {
        guard !isStopped else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                if self.isAutoCheckEnabled { self.check() } else { self.scheduleNext() }
            }
        }
        timer.tolerance = Self.interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
