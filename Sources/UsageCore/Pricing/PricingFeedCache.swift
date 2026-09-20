import Foundation

/// One download of the rate feed serves every metered harness (v0.101.0).
///
/// The LiteLLM feed is a single mixed-vendor file that each provider slices
/// differently (`PricingFeedSelector`), and each harness keeps its own decoded
/// `pricing.json`. Up to 0.100.x that was one file per PROCESS, because one
/// harness was metered; with three, three `PricingService`s woke on the same
/// daily schedule and each downloaded the same ~2 MB document.
///
/// So the RAW bytes are cached once, at the bundle root above every provider
/// scope (beside `live-state.json`), and a service consults it before
/// reaching for the network. Nothing about spec §10 changes — same single
/// destination, same plain GET with no credential and no account data
/// attached — there is simply one request where there were N.
public struct PricingFeedCache: Sendable {
    public static let fileName = "pricing-feed.json"

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(bundleID: String, roots: StorageScope.Roots = .standard) {
        self.init(fileURL: StorageScope.rootSupportDirectory(bundleID: bundleID, roots: roots)
            .appending(path: Self.fileName))
    }

    /// How long the automatic path may reuse the bytes — the same day the
    /// decoded tables consider themselves fresh for.
    public static let freshness: TimeInterval = 24 * 3600
    /// How long a USER-CLICKED refresh may reuse them. Short enough that a
    /// click always reaches the network, long enough that the click's own
    /// fan-out across harnesses is one request and not three.
    public static let forcedFreshness: TimeInterval = 60

    /// The cached document, or nil when absent, unreadable or older than
    /// `maxAge`. The file's own modification date is the stamp: an envelope
    /// would only be another thing to keep in step with it.
    public func bytes(now: Date = Date(), maxAge: TimeInterval = freshness) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) < maxAge,
              // A clock that moved backwards must not make the cache
              // immortal; treat a future stamp as no cache at all.
              modified.timeIntervalSince(now) < maxAge
        else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    public func store(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // A cache is an optimization; without it every harness simply
            // fetches for itself, exactly as it did before 0.101.0.
        }
    }
}
