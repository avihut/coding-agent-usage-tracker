import Foundation

/// The digest's picture of the newest published GitHub release — written by
/// whichever host runs the engine, rendered by the app's quiet update chip
/// and the Settings card. Absent means the updater has nothing to say:
/// source-managed builds don't check, and a feed that has never answered
/// (or has no releases) publishes nothing. Absent is never "up to date".
public struct AppUpdateCard: Codable, Sendable, Equatable {
    /// The release tag with its leading "v" stripped — "0.87.0".
    public let latestVersion: String
    /// The release's page for humans (notes, manual download).
    public let url: String
    public let publishedAt: Date?
    /// The one-click download, when the release shipped a zip asset. A
    /// release without one degrades to opening `url`.
    public let assetName: String?
    public let assetURL: String?
    public let assetBytes: Int?
    public let checkedAt: Date
    /// Precomputed against the WRITING host's own version — consumers render
    /// rather than compare, with one exception: a face whose own version
    /// already equals `latestVersion` (it updated before the daemon did)
    /// stays quiet regardless.
    public let updateAvailable: Bool

    public init(
        latestVersion: String, url: String, publishedAt: Date?,
        assetName: String?, assetURL: String?, assetBytes: Int?,
        checkedAt: Date, updateAvailable: Bool
    ) {
        self.latestVersion = latestVersion
        self.url = url
        self.publishedAt = publishedAt
        self.assetName = assetName
        self.assetURL = assetURL
        self.assetBytes = assetBytes
        self.checkedAt = checkedAt
        self.updateAvailable = updateAvailable
    }

    enum CodingKeys: String, CodingKey {
        case latestVersion, url, publishedAt, assetName, assetURL, assetBytes
        case checkedAt, updateAvailable
    }
}
