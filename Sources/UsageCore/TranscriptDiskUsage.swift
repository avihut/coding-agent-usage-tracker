import Foundation

/// Read-only sizing of Claude Code's transcript store, for the retention
/// setting's disk story: what the retained days weigh now, and what a
/// longer window would weigh at the same daily rate. Scanner rules apply —
/// this measures, never touches.
public struct TranscriptDiskUsage: Equatable, Sendable {
    public let bytes: Int64
    /// Days spanned by the oldest file's age, floored at one.
    public let days: Int

    public init(bytes: Int64, days: Int) {
        self.bytes = bytes
        self.days = days
    }

    public var bytesPerDay: Double {
        Double(bytes) / Double(max(1, days))
    }

    /// Today's per-day weight scaled to a target retention window.
    public func projectedBytes(forDays target: Int) -> Int64 {
        Int64((bytesPerDay * Double(target)).rounded())
    }

    /// Walks the tree summing regular files; the oldest modification date
    /// anchors how many days the current holdings span. Nil when the root
    /// is missing or holds nothing — the card then just says nothing.
    public static func measure(root: URL, now: Date = Date()) -> TranscriptDiskUsage? {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
        else { return nil }
        var total: Int64 = 0
        var oldest: Date?
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
            if let modified = values.contentModificationDate,
               oldest.map({ modified < $0 }) ?? true {
                oldest = modified
            }
        }
        guard total > 0, let oldest else { return nil }
        let days = max(1, Int((now.timeIntervalSince(oldest) / 86400).rounded(.up)))
        return TranscriptDiskUsage(bytes: total, days: days)
    }
}
