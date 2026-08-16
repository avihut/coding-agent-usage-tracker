import Foundation

/// Writes the live-state digest to disk so consumer interfaces can render
/// without holding the engine. Atomic by construction — encode to a temp
/// file, then rename — so a reader polling the file's mtime never sees a
/// torn write. Encoding and IO run on one serial utility queue off the
/// main actor; publishes queue in order, newest state lands last.
final class StatePublisher: Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(
        label: "com.avihu.ClaudeUsage.state-publisher", qos: .utility)

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func publish(_ state: LiveState) {
        let fileURL = fileURL
        queue.async {
            guard let data = try? LiveState.encoder().encode(state) else { return }
            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                // Publishing is an offering to consumers; the engine's own
                // rendering never depends on it. Next landing point retries.
            }
        }
    }
}
