import Foundation

/// The lines of a newline-delimited file, plain or zstd-compressed, read a
/// bounded chunk at a time — neither the file nor its decompressed form is
/// ever held whole. Lines come out exactly as `Data.split(separator: 0x0A)`
/// would give them: empty lines dropped, a last unterminated line kept.
///
/// A failed stream ends the iteration early and records `failure`; a caller
/// that must not count half a file checks it once the loop ends (the partial
/// last line of a failed stream is never yielded).
final class LineReader: Sequence, IteratorProtocol {
    /// A longer line is skipped without being buffered: ~5× the longest line
    /// seen in a real agent session file (13.6 MB), and it bounds memory.
    static let defaultMaxLineBytes = 64 << 20
    private static let plainChunkSize = 1 << 20

    private let maxLineBytes: Int
    private var handle: FileHandle?
    private var decoder: ZstdDecoder?
    private(set) var failure: ZstdError?

    private var chunk: [UInt8] = []
    private var cursor = 0
    private var pending: [UInt8] = []
    private var skippingLongLine = false
    private var finished = false

    /// Nil when the file can't be opened. `compressed` selects the zstd
    /// path; nothing is sniffed from the content.
    init?(
        url: URL, compressed: Bool, limits: ZstdLimits = .standard,
        maxLineBytes: Int = defaultMaxLineBytes
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.maxLineBytes = maxLineBytes
        if compressed {
            decoder = ZstdDecoder(source: ByteSource(handle: handle), limits: limits)
        } else {
            self.handle = handle
        }
    }

    /// In-memory input (tests).
    init(
        data: Data, compressed: Bool, limits: ZstdLimits = .standard,
        maxLineBytes: Int = defaultMaxLineBytes
    ) {
        self.maxLineBytes = maxLineBytes
        if compressed {
            decoder = ZstdDecoder(source: ByteSource(data: data), limits: limits)
        } else {
            chunk = [UInt8](data)
            finished = true
        }
    }

    func next() -> Data? {
        while true {
            if cursor < chunk.count {
                if let newline = newlineIndex() {
                    defer { cursor = newline + 1 }
                    if skippingLongLine {
                        skippingLongLine = false
                        continue
                    }
                    if pending.isEmpty {
                        guard newline > cursor, newline - cursor <= maxLineBytes else { continue }
                        return Data(chunk[cursor..<newline])
                    }
                    guard pending.count + (newline - cursor) <= maxLineBytes else {
                        pending = []
                        continue
                    }
                    pending.append(contentsOf: chunk[cursor..<newline])
                    defer { pending = [] }
                    return Data(pending)
                }
                // No newline in what's left: carry it into the next chunk.
                if !skippingLongLine {
                    if pending.count + (chunk.count - cursor) > maxLineBytes {
                        skippingLongLine = true
                        pending = []
                    } else {
                        pending.append(contentsOf: chunk[cursor...])
                    }
                }
                cursor = chunk.count
            }
            if finished {
                guard failure == nil, !skippingLongLine, !pending.isEmpty else { return nil }
                defer { pending = [] }
                return Data(pending)
            }
            refill()
        }
    }

    /// The next newline at or after `cursor` in the current chunk — only the
    /// bytes not yet searched, so a long line stays linear.
    private func newlineIndex() -> Int? {
        chunk.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, cursor < buffer.count,
                  let hit = memchr(base + cursor, 0x0A, buffer.count - cursor)
            else { return nil }
            return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
        }
    }

    private func refill() {
        chunk = []
        cursor = 0
        do throws(ZstdError) {
            if decoder != nil {
                // Mutated in place: a local copy would share the decoder's
                // window and copy it on every block.
                if let bytes = try decoder?.next() { chunk = bytes } else { finished = true }
            } else if let handle {
                let data: Data?
                do {
                    // Pooled per read, as in `ByteSource`.
                    data = try autoreleasepool { try handle.read(upToCount: Self.plainChunkSize) }
                } catch {
                    throw .unreadable("read failed")
                }
                if let data, !data.isEmpty { chunk = [UInt8](data) } else { finished = true }
            } else {
                finished = true
            }
        } catch {
            failure = error
            finished = true
            pending = []
        }
    }
}
