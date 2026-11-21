import Foundation

/// What a host is: which bundle's files it keeps, which process kind it
/// reports, where its roots are, and what it is allowed to poll. Split out of
/// `MeteringHost` at the 600-line rule — a whole type, its own file.
extension MeteringHost {
    public struct Configuration: Sendable {
        public var bundleID: String
        public var kind: UsageEngine.Host
        public var roots: StorageScope.Roots
        /// False builds no status poller (tests, an offline host).
        public var pollsStatus: Bool
        /// The release feed to poll; nil = no update checker.
        public var updateFeedURL: URL?
        public var reprobeInterval: TimeInterval
        /// The user home "~" and discovery are judged against.
        public var userHome: URL
        /// The span the launch polls of N engines spread across.
        public var stagger: TimeInterval
        /// Where the control socket binds; nil = the broker's standard path.
        public var socketURL: URL?
        public var bindsSocket: Bool
        /// What runs an agent's own tool for its limits (the quota probe,
        /// spec §10 amendment 2026-11-21, second). Nil — the default, and
        /// what tests and snapshots keep — means no engine here can spawn
        /// anything; usaged and the app's hosting path pass the real one.
        public var agentCommandRunner: (any AgentCommandRunner)?

        public init(
            bundleID: String, kind: UsageEngine.Host, roots: StorageScope.Roots = .standard,
            pollsStatus: Bool = true, updateFeedURL: URL? = nil, reprobeInterval: TimeInterval = 600,
            userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
            stagger: TimeInterval = TriggerGate.floor, socketURL: URL? = nil, bindsSocket: Bool = true,
            agentCommandRunner: (any AgentCommandRunner)? = nil
        ) {
            self.bundleID = bundleID
            self.kind = kind
            self.roots = roots
            self.pollsStatus = pollsStatus
            self.updateFeedURL = updateFeedURL
            self.reprobeInterval = reprobeInterval
            self.userHome = userHome
            self.stagger = stagger
            self.socketURL = socketURL
            self.bindsSocket = bindsSocket
            self.agentCommandRunner = agentCommandRunner
        }

        /// The release feed a real host polls: both GitHub flavors, so a
        /// source checkout still learns it is behind; the drill's override
        /// both supplies the URL and forces the checker on.
        public static func updateFeedURL(defaults: UserDefaults) -> URL? {
            let channel = Distribution.channel(for: Bundle.main.bundleURL)
            let override = defaults.string(forKey: UpdateChecker.feedOverrideKey)
                .flatMap(URL.init(string:))
            return override ?? channel?.updateFeedURL
        }
    }
}
