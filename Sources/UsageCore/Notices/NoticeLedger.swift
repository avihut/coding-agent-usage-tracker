import Foundation

/// The engine-side notice store: `notices.json` beside `history.json`, same
/// atomic-rewrite, best-effort idiom, same single writer (the lease holder).
/// Seen and dismiss marks arrive from the faces over the control socket and
/// land here — a client-mode app never writes this file itself.
///
/// Dismissed notices stay for a month so a re-observation (the same grant
/// read off another meter's samples, the same incident in a wake-time
/// history read) finds the record and stays silent, then age out.
public struct NoticeLedger: Sendable {
    /// Chronological by `occurredAt`.
    public private(set) var notices: [Notice]
    public let fileURL: URL

    public static let keepDismissedFor: TimeInterval = 30 * 86400
    public static let cap = 200
    /// Two grants inside this span are one event — `VendorGrants`' rule.
    public static let grantTolerance: TimeInterval = 120

    private struct File: Codable {
        var version: Int
        var notices: [Notice]
    }

    public init(directory: URL) {
        self.fileURL = directory.appending(path: "notices.json")
        if let data = try? Data(contentsOf: fileURL),
           let file = try? Self.decoder().decode(File.self, from: data) {
            self.notices = file.notices.sorted { $0.occurredAt < $1.occurredAt }
        } else {
            self.notices = []
        }
    }

    /// An in-memory ledger for tests and previews — never persists.
    public init(notices: [Notice] = []) {
        self.fileURL = URL(fileURLWithPath: "/dev/null")
        self.notices = notices.sorted { $0.occurredAt < $1.occurredAt }
    }

    public func notice(id: String) -> Notice? {
        notices.first { $0.id == id }
    }

    /// Undismissed notices for the faces: ongoing first, then newest first.
    public var pending: [Notice] {
        notices.filter(\.isPending).sorted { a, b in
            if a.ongoing != b.ongoing { return a.ongoing }
            return a.occurredAt > b.occurredAt
        }
    }

    /// A reset notice already names an instant within tolerance of `at`.
    public func hasReset(near at: Date, tolerance: TimeInterval = grantTolerance) -> Bool {
        notices.contains {
            $0.kindValue == .reset && abs($0.occurredAt.timeIntervalSince(at)) <= tolerance
        }
    }

    /// Adds a notice unless its id is already known. Returns whether the
    /// ledger changed.
    @discardableResult
    public mutating func record(_ notice: Notice, now: Date = Date()) -> Bool {
        guard !notices.contains(where: { $0.id == notice.id }) else { return false }
        notices.append(notice)
        notices.sort { $0.occurredAt < $1.occurredAt }
        prune(now: now)
        persist()
        return true
    }

    /// Edits one notice in place. Returns whether anything changed.
    @discardableResult
    public mutating func update(id: String, _ edit: (inout Notice) -> Void) -> Bool {
        guard let index = notices.firstIndex(where: { $0.id == id }) else { return false }
        var edited = notices[index]
        edit(&edited)
        guard edited != notices[index] else { return false }
        notices[index] = edited
        persist()
        return true
    }

    /// A face rendered these while pending. Marks only the ones not yet
    /// seen; returns whether anything changed.
    @discardableResult
    public mutating func markSeen(ids: [String], at now: Date = Date()) -> Bool {
        let wanted = Set(ids)
        var changed = false
        for index in notices.indices
        where wanted.contains(notices[index].id) && notices[index].isPending
            && notices[index].seenAt == nil {
            notices[index].seenAt = now
            changed = true
        }
        if changed { persist() }
        return changed
    }

    /// The person's click. Refused for an ongoing notice — the condition
    /// is live and the face must keep saying so.
    @discardableResult
    public mutating func dismiss(id: String, at now: Date = Date()) -> Bool {
        guard let index = notices.firstIndex(where: { $0.id == id }),
              notices[index].isPending, notices[index].isDismissable
        else { return false }
        notices[index].dismissedAt = now
        if notices[index].seenAt == nil { notices[index].seenAt = now }
        persist()
        return true
    }

    @discardableResult
    public mutating func dismissAll(at now: Date = Date()) -> Bool {
        var changed = false
        for index in notices.indices where notices[index].isPending && notices[index].isDismissable {
            notices[index].dismissedAt = now
            if notices[index].seenAt == nil { notices[index].seenAt = now }
            changed = true
        }
        if changed { persist() }
        return changed
    }

    /// Closes an ongoing notice: it becomes its own epilogue in place, a
    /// fresh pending item whose copy remembers whether it was watched.
    @discardableResult
    public mutating func close(id: String, endedAt: Date) -> Bool {
        update(id: id) { notice in
            guard notice.ongoing else { return }
            notice.ongoing = false
            notice.endedAt = endedAt
            notice.seenWhileOngoing = notice.seenAt != nil
            // The epilogue is new news — unseen until a face shows it.
            notice.seenAt = nil
        }
    }

    private mutating func prune(now: Date) {
        notices.removeAll { notice in
            guard let dismissedAt = notice.dismissedAt else { return false }
            return now.timeIntervalSince(dismissedAt) > Self.keepDismissedFor
        }
        if notices.count > Self.cap {
            // Oldest dismissed go first; pending are never pruned by count.
            var excess = notices.count - Self.cap
            notices.removeAll { notice in
                guard excess > 0, !notice.isPending else { return false }
                excess -= 1
                return true
            }
        }
    }

    private func persist() {
        guard fileURL.path != "/dev/null" else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder().encode(File(version: 1, notices: notices))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Notices are an enhancement; persistence must never break a refresh.
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
