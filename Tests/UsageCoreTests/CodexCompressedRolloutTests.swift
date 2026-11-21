import Foundation
import Testing
@testable import UsageCore

/// Codex compresses a rollout in place once it has gone a week without a
/// write (`rollout-….jsonl` → `rollout-….jsonl.zst`, mtime kept, the plain
/// file deleted after), and re-inflates it on resume. These pin that a
/// compressed rollout counts exactly like its plain form, once, through the
/// hand-over — the bug was its whole history vanishing the day it was
/// compressed.
@Suite("Codex compressed rollouts")
struct CodexCompressedRolloutTests {
    /// Inside the 56-day timeline retention of the fixture's October days.
    private static let now = Date(timeIntervalSince1970: 1_792_500_000)
    private static let day = "2026/10/14"
    private static let id = "rollout-2026-10-14T20-05-00-synthetic"

    private static func scan(_ tree: RolloutTree, persist: Bool = false) -> TranscriptScan {
        let source = tree.source
        return persist ? source.scanTranscripts(now: now) : source.scanTranscriptsReadOnly(now: now)
    }

    private static func plainTree() throws -> RolloutTree {
        let tree = try RolloutTree()
        try tree.write("\(day)/\(id).jsonl", ZstdFixture.data("rollout.jsonl"))
        return tree
    }

    @Test("a compressed rollout scans exactly like its plain form")
    func sameAsPlain() throws {
        let plain = try Self.plainTree()
        defer { plain.tearDown() }
        let compressed = try RolloutTree()
        defer { compressed.tearDown() }
        try compressed.write("\(Self.day)/\(Self.id).jsonl.zst", ZstdFixture.data("rollout.jsonl.zst"))

        let expected = Self.scan(plain)
        #expect(!expected.daily.isEmpty && !expected.timeline.isEmpty)
        #expect(expected.sessions.map(\.id) == [Self.id])
        #expect(Self.scan(compressed) == expected)
        #expect(compressed.source.sessionDetail(id: Self.id) == plain.source.sessionDetail(id: Self.id))
        #expect(compressed.source.sessionDetail(id: Self.id) != nil)
        // The meter's newest-first walk reads a compressed rollout too.
        // Compared decoded: JSONEncoder promises no key order.
        let compressedMeter = try JSONSerialization.jsonObject(
            with: CodexRollouts.latestUsagePayload(root: compressed.root)) as? NSDictionary
        let plainMeter = try JSONSerialization.jsonObject(
            with: CodexRollouts.latestUsagePayload(root: plain.root)) as? NSDictionary
        #expect(compressedMeter != nil && compressedMeter == plainMeter)
    }

    @Test("both names at once count once")
    func bothNamesCountOnce() throws {
        let plain = try Self.plainTree()
        defer { plain.tearDown() }
        let both = try Self.plainTree()
        defer { both.tearDown() }
        try both.write("\(Self.day)/\(Self.id).jsonl.zst", ZstdFixture.data("rollout.l19.jsonl.zst"))
        #expect(Self.scan(both) == Self.scan(plain))
        #expect(Self.scan(both, persist: true).sessions.count == 1)
    }

    @Test("the hand-over keeps the session's id and totals, through a warm cache")
    func handOver() throws {
        let tree = try Self.plainTree()
        defer { tree.tearDown() }
        let before = Self.scan(tree, persist: true)
        // Codex: publish the compressed file, then delete the plain one.
        try tree.write("\(Self.day)/\(Self.id).jsonl.zst", ZstdFixture.data("rollout.jsonl.zst"))
        #expect(Self.scan(tree, persist: true) == before)
        try tree.remove("\(Self.day)/\(Self.id).jsonl")
        #expect(Self.scan(tree, persist: true) == before)
        // Resume: re-inflated to plain, then appended to — the plain copy wins.
        let resumed = try ZstdFixture.data("rollout.jsonl") + Data("\n".utf8) + Self.extraTurn
        try tree.write("\(Self.day)/\(Self.id).jsonl", resumed)
        let after = Self.scan(tree, persist: true)
        #expect(after.sessions.count == 1)
        #expect(after.sessions.first?.apiCalls == (before.sessions.first?.apiCalls ?? 0) + 1)
    }

    private static let extraTurn = Data("""
        {"timestamp":"2026-10-16T09:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10}}}}
        """.utf8)

    @Test("a compressed rollout that doesn't decode counts for nothing, and nothing else moves")
    func undecodable() throws {
        let tree = try RolloutTree()
        defer { tree.tearDown() }
        try tree.write("2026/10/11/rollout-tiny.jsonl", ZstdFixture.data("tiny.jsonl"))
        let alone = Self.scan(tree)
        let rollout = try ZstdFixture.data("rollout.jsonl.zst")
        try tree.write("\(Self.day)/\(Self.id).jsonl.zst", rollout.prefix(rollout.count / 2))
        #expect(Self.scan(tree, persist: true) == alone)
        #expect(tree.source.sessionDetail(id: Self.id) == nil)
        // The verdict is cached with the decoder revision that reached it.
        let cache = try JSONSerialization.jsonObject(with: Data(contentsOf: tree.cacheFile)) as? [String: Any]
        let files = try #require(cache?["files"] as? [String: [String: Any]])
        let entry = try #require(files.first { $0.key.hasSuffix(".jsonl.zst") }?.value)
        #expect(entry["undecodable"] as? Int == ZstdDecoder.revision)
        // Its plain twin, when present, is what counts.
        try tree.write("\(Self.day)/\(Self.id).jsonl", ZstdFixture.data("rollout.jsonl"))
        let plain = try Self.plainTree()
        defer { plain.tearDown() }
        try plain.write("2026/10/11/rollout-tiny.jsonl", ZstdFixture.data("tiny.jsonl"))
        #expect(Self.scan(tree) == Self.scan(plain))
    }

    @Test("a file that can't be read isn't cached: it counts once it can be")
    func unreadableIsRetried() throws {
        let tree = try Self.plainTree()
        defer { tree.tearDown() }
        let expected = Self.scan(tree)
        let path = "\(Self.day)/\(Self.id).jsonl"
        try tree.setReadable(path, false)
        #expect(Self.scan(tree, persist: true).sessions.isEmpty)
        try tree.setReadable(path, true)
        #expect(Self.scan(tree, persist: true) == expected)
    }

    @Test("session detail falls back to the compressed twin when the plain file can't be read")
    func detailFallsBack() throws {
        let tree = try Self.plainTree()
        defer { tree.tearDown() }
        let expected = try #require(tree.source.sessionDetail(id: Self.id))
        try tree.write("\(Self.day)/\(Self.id).jsonl.zst", ZstdFixture.data("rollout.jsonl.zst"))
        try tree.setReadable("\(Self.day)/\(Self.id).jsonl", false)
        defer { try? tree.setReadable("\(Self.day)/\(Self.id).jsonl", true) }
        #expect(tree.source.sessionDetail(id: Self.id) == expected)
    }

    @Test("a cache entry written before this change still hits")
    func oldCacheEntriesHit() throws {
        let tree = try Self.plainTree()
        defer { tree.tearDown() }
        let original = Self.scan(tree, persist: true)
        // The entry carries no `undecodable` key, exactly as an older build
        // wrote it.
        let cacheText = try String(contentsOf: tree.cacheFile, encoding: .utf8)
        #expect(!cacheText.contains("undecodable"))
        // Same size, same mtime, different bytes: a hit keeps the cached
        // tallies, a re-parse would not.
        let path = "\(Self.day)/\(Self.id).jsonl"
        let mtime = try tree.modified(path)
        let plain = try ZstdFixture.data("rollout.jsonl")
        try tree.write(path, Data(repeating: UInt8(ascii: " "), count: plain.count))
        try tree.setModified(path, mtime)
        #expect(Self.scan(tree) == original)
    }
}

/// A throwaway `sessions` tree plus the source's cache directory.
private struct RolloutTree {
    let base: URL
    let root: URL
    let cacheDirectory: URL

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "codex-compressed-tests-\(UUID().uuidString)")
        root = base.appending(path: "sessions")
        cacheDirectory = base.appending(path: "cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    var source: CodexActivitySource {
        CodexActivitySource(root: root, cacheDirectory: cacheDirectory)
    }

    var cacheFile: URL { cacheDirectory.appending(path: "activity-cache.json") }

    /// Every file gets the same fixed mtime: Codex keeps the plain file's
    /// mtime on the compressed one.
    func write(_ path: String, _ data: Data) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try setModified(path, Date(timeIntervalSince1970: 1_792_000_000))
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appending(path: path))
    }

    func setModified(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: root.appending(path: path).path)
    }

    func modified(_ path: String) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appending(path: path).path)
        return try #require(attributes[.modificationDate] as? Date)
    }

    func setReadable(_ path: String, _ readable: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: readable ? 0o644 : 0o000], ofItemAtPath: root.appending(path: path).path)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }
}
