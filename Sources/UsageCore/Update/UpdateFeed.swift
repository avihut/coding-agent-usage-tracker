import Foundation

/// Reads the newest published release off the GitHub API — the app's own
/// distribution channel, which is what makes this an APP concern rather
/// than a provider one: it never rides `UsageProvider`, and switching the
/// metered harness doesn't change where this app's updates come from.
///
/// Exactly one endpoint: `/repos/<owner>/<repo>/releases/latest`, which by
/// GitHub's definition already excludes drafts and prereleases. Spec §10
/// (amendment 2026-08-23): a plain anonymous conditional GET — ephemeral
/// cookie-less session, no credential, nothing in the URL beyond the public
/// repo path. The release ASSET is only ever downloaded by an explicit user
/// click, never by this checker.
public struct UpdateFeed: Sendable {
    public enum Outcome: Sendable {
        case fresh(release: GitHubRelease, etag: String?)
        case notModified
        /// The repo has no published releases (404). Not an error — the
        /// checker publishes nothing rather than retrying hot.
        case noReleases
    }

    public enum FeedError: Error, Equatable {
        case badResponse(Int)
        case malformed
        case transport
    }

    public let latestReleaseURL: URL
    private let session: URLSession

    public init(latestReleaseURL: URL, session: URLSession? = nil) {
        self.latestReleaseURL = latestReleaseURL
        self.session = session ?? Self.makeSession()
    }

    public static func latestURL(repository: String) -> URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// Same construction as `StatuspageFeed`: a session that cannot keep
    /// cookies can't leak one, and URLCache stays out of the freshness story.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }

    /// One conditional GET. Throws `FeedError`; the checker turns a throw
    /// into silence, never into an update flag.
    public func fetchLatest(etag: String?) async throws -> Outcome {
        var request = URLRequest(url: latestReleaseURL)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects UA-less requests outright; ours is the honest one.
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw FeedError.transport }
        if http.statusCode == 304 { return .notModified }
        if http.statusCode == 404 { return .noReleases }
        guard (200..<300).contains(http.statusCode) else {
            throw FeedError.badResponse(http.statusCode)
        }
        guard let release = try? GitHubRelease.decode(from: data) else {
            throw FeedError.malformed
        }
        return .fresh(release: release, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}

/// The `releases/latest` payload, decoded to exactly the fields we render.
/// Everything unnamed is ignored, which keeps the parse alive when GitHub
/// grows the shape.
public struct GitHubRelease: Sendable, Equatable {
    public struct Asset: Sendable, Equatable {
        public let name: String
        public let downloadURL: String
        public let bytes: Int?

        public init(name: String, downloadURL: String, bytes: Int?) {
            self.name = name
            self.downloadURL = downloadURL
            self.bytes = bytes
        }
    }

    public let tag: String
    public let pageURL: String
    public let publishedAt: Date?
    public let assets: [Asset]

    public init(tag: String, pageURL: String, publishedAt: Date?, assets: [Asset]) {
        self.tag = tag
        self.pageURL = pageURL
        self.publishedAt = publishedAt
        self.assets = assets
    }

    /// The tag without its conventional leading "v".
    public var version: String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// The zip the one-click flow downloads: the versioned name our dist
    /// pipeline publishes when present, else any zip, else nothing (the UI
    /// then links the release page instead).
    public var updateAsset: Asset? {
        assets.first { $0.name == "ClaudeUsage-\(version).zip" }
            ?? assets.first { $0.name.hasSuffix(".zip") }
    }

    public static func decode(from data: Data) throws -> GitHubRelease {
        let raw = try JSONDecoder().decode(RawRelease.self, from: data)
        guard let tag = raw.tagName, !tag.isEmpty,
              let page = raw.htmlURL, !page.isEmpty
        else { throw UpdateFeed.FeedError.malformed }
        return GitHubRelease(
            tag: tag,
            pageURL: page,
            publishedAt: raw.publishedAt.flatMap(FlexibleISO8601.date(from:)),
            assets: (raw.assets ?? []).compactMap { asset in
                guard let name = asset.name, let url = asset.browserDownloadURL
                else { return nil }
                return Asset(name: name, downloadURL: url, bytes: asset.size)
            })
    }

    private struct RawRelease: Decodable {
        let tagName: String?
        let htmlURL: String?
        let publishedAt: String?
        let assets: [RawAsset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }
    }

    private struct RawAsset: Decodable {
        let name: String?
        let browserDownloadURL: String?
        let size: Int?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }
}
