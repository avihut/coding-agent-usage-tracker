import Foundation

/// How this copy of the app reaches its audience — and therefore how it
/// updates. Each conformer owns one distribution stream's whole story:
/// where release news comes from, whether this install may swap its own
/// bundle, and what to tell the user when it can't.
///
/// The channel is detected from the install itself (`Distribution.channel`),
/// never configured. Future streams slot in as new conformers: a
/// direct-download build would carry its own feed URL; a store build would
/// return nil from `updateFeedURL` and the entire update surface goes dark,
/// because the store owns updates there.
public protocol DistributionChannel: Sendable {
    /// Stable machine name ("github").
    var id: String { get }
    /// The channel plus its install flavor, as the Settings card shows it.
    var displayName: String { get }
    /// Where release availability comes from. Nil means no update checking
    /// at all — no card, no chip, no Settings section.
    var updateFeedURL: URL? { get }
    /// Whether `AppUpdater`'s download→verify→swap pipeline may run here.
    /// False means the channel only informs; `manualUpdateHint` says how
    /// updating actually happens.
    var canSelfInstall: Bool { get }
    /// One sentence of "how you actually update" for installs that can't
    /// self-install. Nil when `canSelfInstall`.
    var manualUpdateHint: String? { get }
}

/// The GitHub stream — currently the only one. One channel, two install
/// flavors, both auto-detected: a release zip installed by hand (typically
/// /Applications) self-updates with the one-click swap, while a bundle
/// built inside a git checkout (`mise run app`) reads the same release
/// feed but only INFORMS — overwriting a working tree's build product is
/// never the app's call, and its real update path runs through the user's
/// own git.
///
/// All the ugly install forensics live here and in the helpers this leans
/// on (`InstallKind`'s ancestor walk, `SourceCheckoutProbe`'s local git
/// reads) so the rest of the app only ever sees the channel contract.
/// Constraint the flavor split exists to keep: the app never runs
/// NETWORKED git — a fetch would spend the user's own credentials against
/// hosts outside spec §10's destinations. Release awareness comes from the
/// same anonymous `api.github.com` feed in both flavors; git operations
/// stay local and read-only.
public struct GitHubChannel: DistributionChannel {
    public enum Flavor: Sendable, Equatable {
        /// Installed from a published release asset; not inside any checkout.
        case releaseInstall
        /// Built inside the git checkout rooted here (the directory whose
        /// `.git` the ancestor walk found — the worktree, in a worktree
        /// layout).
        case sourceCheckout(root: URL)
    }

    public let flavor: Flavor
    /// Whether the checkout root carries a mise.toml — decides if the
    /// manual hint can name the real rebuild task or must stay generic.
    private let hasMiseTask: Bool

    public init(flavor: Flavor, fileManager: FileManager = .default) {
        self.flavor = flavor
        if case .sourceCheckout(let root) = flavor {
            hasMiseTask = fileManager.fileExists(
                atPath: root.appending(path: "mise.toml").path)
        } else {
            hasMiseTask = false
        }
    }

    public var id: String { "github" }

    public var displayName: String {
        switch flavor {
        case .releaseInstall: "GitHub — release install"
        case .sourceCheckout: "GitHub — source checkout"
        }
    }

    public var updateFeedURL: URL? {
        UpdateFeed.latestURL(repository: AppIdentity.repository)
    }

    public var canSelfInstall: Bool {
        switch flavor {
        case .releaseInstall: true
        case .sourceCheckout: false
        }
    }

    public var manualUpdateHint: String? {
        switch flavor {
        case .releaseInstall:
            nil
        case .sourceCheckout:
            hasMiseTask
                ? "Pull the checkout, then rerun “mise run app”."
                : "Pull the checkout and rebuild the app."
        }
    }
}

/// Resolves the distribution channel for an installed bundle.
public enum Distribution {
    /// The channel this install belongs to, or nil for something that is
    /// not a distributed app at all (test bundles, bare `swift run`
    /// binaries) — those have no update story of any kind.
    public static func channel(
        for bundleURL: URL, fileManager: FileManager = .default
    ) -> (any DistributionChannel)? {
        switch InstallKind.detect(bundleURL: bundleURL, fileManager: fileManager) {
        case .notAnApp:
            return nil
        case .standaloneApp:
            return GitHubChannel(flavor: .releaseInstall, fileManager: fileManager)
        case .sourceManaged(let root):
            return GitHubChannel(
                flavor: .sourceCheckout(root: root), fileManager: fileManager)
        }
    }

    /// Whether the one-click bundle swap may run for this install: the
    /// channel's word, except the updater drill's feed override forces it
    /// on — the drill's staged bundle sits inside the checkout by
    /// construction, exactly as the override forces the engine's checker
    /// on there.
    public static func allowsSelfInstall(
        bundleURL: URL, defaults: UserDefaults = .standard
    ) -> Bool {
        if defaults.string(forKey: UpdateChecker.feedOverrideKey) != nil { return true }
        return channel(for: bundleURL)?.canSelfInstall ?? true
    }
}
