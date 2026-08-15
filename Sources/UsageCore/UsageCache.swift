import Foundation

/// Last-good response cache: body + fetch time only — never the token
/// (spec §6). Best-effort by design: a failed cache write must never take
/// down a refresh, so write errors are deliberately swallowed.
public struct UsageCache: Sendable {
    private struct Envelope: Codable {
        let fetchedAt: Date
        let body: Data
    }

    let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appending(path: "usage.json")
    }

    public func save(body: Data, fetchedAt: Date) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Envelope(fetchedAt: fetchedAt, body: body))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort: losing the fallback is strictly better than
            // failing the refresh that produced fresh data.
        }
    }

    public func load() -> (body: Data, fetchedAt: Date)? {
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return (envelope.body, envelope.fetchedAt)
    }
}
