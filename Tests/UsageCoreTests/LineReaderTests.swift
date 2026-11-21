import Foundation
import Testing
@testable import UsageCore

@Suite("LineReader")
struct LineReaderTests {
    /// What the scanners did before: the whole file, split on newlines.
    private static func split(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    private static func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "line-reader-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test(
        "lines match Data.split exactly",
        arguments: [
            "", "\n", "\n\n\n", "one", "one\n", "one\ntwo", "one\n\ntwo\n", "\nlead", "crlf\r\nline\r\n",
            "a\nb\nc\n\n\nd",
        ])
    func parity(text: String) {
        let data = Data(text.utf8)
        #expect(Array(LineReader(data: data, compressed: false)) == Self.split(data))
    }

    @Test("a file read in chunks: lines across chunk boundaries come out whole")
    func chunkBoundaries() throws {
        // ~3 MB of lines of varying length, so many cross the 1 MiB chunks,
        // one of them longer than a chunk.
        var text = ""
        for index in 0..<40000 { text += String(repeating: "x", count: index % 97) + "\(index)\n" }
        text += String(repeating: "y", count: 1_500_000) + "\nlast"
        let data = Data(text.utf8)
        let url = try Self.temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(LineReader(url: url, compressed: false))
        #expect(Array(reader) == Self.split(data))
        #expect(reader.failure == nil)
    }

    @Test("a compressed file yields its plain twin's lines, block by block")
    func compressed() throws {
        let plain = try ZstdFixture.data("rollout.jsonl")
        let url = try Self.temporaryFile(ZstdFixture.data("rollout.jsonl.zst"))
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try #require(LineReader(url: url, compressed: true))
        #expect(Array(reader) == Self.split(plain))
        #expect(reader.failure == nil)
    }

    @Test("a line past the cap is skipped whole, in one chunk or across many")
    func overlongLine() throws {
        let text = "short\n" + String(repeating: "z", count: 5000) + "\nafter\n" + String(repeating: "w", count: 5000)
        let inMemory = LineReader(data: Data(text.utf8), compressed: false, maxLineBytes: 1000)
        #expect(Array(inMemory) == [Data("short".utf8), Data("after".utf8)])

        // Across zstd blocks: the 1 KiB-window fixture arrives in ~1 KiB
        // pieces; cap lines at 300 bytes and only the short ones survive.
        let plain = try ZstdFixture.data("tiny.jsonl")
        let reader = LineReader(
            data: try ZstdFixture.data("tiny.wlog10.jsonl.zst"), compressed: true, maxLineBytes: 300)
        #expect(Array(reader) == Self.split(plain).filter { $0.count <= 300 })
        #expect(Self.split(plain).contains { $0.count > 300 }, "the fixture must have a long line")
    }

    @Test("a stream that fails part-way stops, says why, and never yields its partial line")
    func failure() throws {
        // The 1 KiB-window fixture: many small blocks, so half of it still
        // decodes several before the cut.
        let data = try ZstdFixture.data("tiny.wlog10.jsonl.zst")
        let reader = LineReader(data: data.prefix(data.count / 2), compressed: true)
        let lines = Array(reader)
        #expect(reader.failure == .truncated)
        let plain = Self.split(try ZstdFixture.data("tiny.jsonl"))
        #expect(!lines.isEmpty && lines.count < plain.count)
        #expect(Array(plain.prefix(lines.count)) == lines, "only whole lines before the failure")
    }

    @Test("a file that can't be opened is nil, not an empty read")
    func unopenable() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).jsonl")
        #expect(LineReader(url: url, compressed: false) == nil)
    }
}
