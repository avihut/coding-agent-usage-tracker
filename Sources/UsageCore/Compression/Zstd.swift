import Foundation

// A read-only, pure-Swift Zstandard DECODER (RFC 8878), written because
// macOS ships none (the Compression framework has zlib, LZMA, LZFSE, LZ4 and
// Brotli) and this package takes no third-party code. An agent that archives
// its old session files as `.zst` is otherwise unreadable here.
//
// It runs inside the daemon over files this app didn't write, so malformed,
// truncated or hostile input must end in a `ZstdError` — never a trap, a
// hang, or an unbounded allocation:
// - every read is range-checked before it happens (checked subscripts back
//   that up: a missed check traps instead of reading out of bounds);
// - every loop is bounded by input bytes, a sequence count, or the block's
//   output budget;
// - memory is bounded by the limits below — the decoder streams one block
//   at a time and keeps only the window a match may reach back into.
//
// Not supported, by design: dictionaries (a frame naming one is refused).

enum ZstdError: Error, Equatable, Sendable {
    /// The input ended inside a frame (or held no frame at all).
    case truncated
    /// Not a zstd frame: bad magic number, or trailing garbage.
    case notZstd
    /// The frame needs a dictionary; none is supported.
    case dictionaryRequired
    /// The frame's window exceeds `ZstdLimits.maxWindowSize`.
    case windowTooLarge
    /// Decoding would exceed `ZstdLimits.maxOutputSize`.
    case outputTooLarge
    /// The frame decoded to a size other than the one its header states.
    case contentSizeMismatch
    /// The frame's XXH64 content checksum doesn't match its content.
    case checksumMismatch
    /// The compressed data is malformed; the reason is for tests and logs.
    case corrupt(String)
    /// Reading the file failed (vanished, permissions, I/O) — not the
    /// format's fault, so worth retrying later.
    case unreadable(String)

    /// True when the BYTES are at fault (retrying the same bytes is futile).
    var isFormatError: Bool {
        if case .unreadable = self { false } else { true }
    }
}

struct ZstdLimits: Sendable {
    /// 2^27 = 128 MiB: the reference decoder's own default limit, so any
    /// valid frame `zstd -d` decodes without `--memory`, this decodes. (Two
    /// malformed shapes the reference's fast paths tolerate are refused, as
    /// RFC 8878 says: a Huffman stream with bits left over, a match reaching
    /// past the window.) Only the window a frame actually fills is resident.
    var maxWindowSize = 1 << 27
    /// 1 GiB decompressed per stream: far beyond any real session file (the
    /// largest plain one seen was 120 MB); bounds the CPU a decompression
    /// bomb can cost.
    var maxOutputSize = 1 << 30
    /// How far past its window the buffer may grow before the history is
    /// compacted; nil derives it from the window (clamped to 1–8 MiB).
    /// Tests shrink it so a small fixture compacts.
    var windowSlack: Int?

    static let standard = ZstdLimits()
}

/// Which decoding paths a stream exercised — test evidence that the
/// fixtures reach every branch. Counting costs a few increments per block.
struct ZstdStats: Equatable, Sendable {
    var frames = 0
    var skippableFrames = 0
    var windowDescriptors = 0
    var checksumsVerified = 0
    var rawBlocks = 0
    var rleBlocks = 0
    var compressedBlocks = 0
    var rawLiterals = 0
    var rleLiterals = 0
    var huffmanLiterals1Stream = 0
    var huffmanLiterals4Streams = 0
    var treelessLiterals = 0
    var predefinedTables = 0
    var rleTables = 0
    var fseTables = 0
    var repeatTables = 0
    var repeatOffsets = 0
    var compactions = 0
}

/// Pull decoder: each `next()` returns the next block's decompressed bytes
/// (≤ 128 KiB), nil once the input ends cleanly after a whole frame.
struct ZstdDecoder {
    /// Bumped whenever a change could make this decoder accept bytes an
    /// older revision refused — caches that remember "undecodable" key their
    /// verdict by it, so a fix gets to retry.
    static let revision = 1

    static let blockSizeMax = 128 << 10
    private static let frameMagic: UInt32 = 0xFD2F_B528

    private let source: ByteSource
    private let limits: ZstdLimits
    private var frame: Frame?
    private var framesSeen = 0
    private var produced = 0
    private var failure: ZstdError?
    private(set) var stats = ZstdStats()

    init(source: ByteSource, limits: ZstdLimits = .standard) {
        self.source = source
        self.limits = limits
    }

    /// Whole-buffer convenience (tests, verification).
    static func decompress(_ data: Data, limits: ZstdLimits = .standard) throws(ZstdError) -> Data {
        var decoder = ZstdDecoder(source: ByteSource(data: data), limits: limits)
        var output = Data()
        while let chunk = try decoder.next() { output.append(contentsOf: chunk) }
        return output
    }

    /// Sticky: once a stream has failed, every later call fails the same
    /// way rather than resynchronizing on whatever bytes follow.
    mutating func next() throws(ZstdError) -> [UInt8]? {
        if let failure { throw failure }
        do throws(ZstdError) {
            return try step()
        } catch {
            failure = error
            throw error
        }
    }

    private mutating func step() throws(ZstdError) -> [UInt8]? {
        while true {
            if frame == nil {
                if try source.isAtEnd() {
                    guard framesSeen > 0 else { throw .truncated }
                    return nil
                }
                guard try beginFrame() else { continue }
            }
            guard var current = frame else { continue }
            frame = nil
            let (bytes, last) = try current.decodeBlock(source, stats: &stats)
            produced += bytes.count
            guard produced <= limits.maxOutputSize else { throw .outputTooLarge }
            if last {
                try current.finish(source, stats: &stats)
            } else {
                frame = current
            }
            if !bytes.isEmpty { return bytes }
        }
    }

    /// Reads one frame header; false after skipping a skippable frame.
    private mutating func beginFrame() throws(ZstdError) -> Bool {
        let magic = UInt32(try source.readInteger(4))
        framesSeen += 1
        if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
            let size = Int(try source.readInteger(4))
            try source.skip(size)
            stats.skippableFrames += 1
            return false
        }
        guard magic == Self.frameMagic else { throw .notZstd }
        let descriptor = try source.readInteger(1)
        guard descriptor & 0x08 == 0 else { throw .corrupt("reserved frame header bit set") }
        let singleSegment = descriptor & 0x20 != 0
        var windowSize = 0
        if !singleSegment {
            let byte = Int(try source.readInteger(1))
            let base = 1 << (10 + (byte >> 3))
            windowSize = base + (base >> 3) * (byte & 7)
            stats.windowDescriptors += 1
        }
        let dictionaryIDSize = [0, 1, 2, 4][Int(descriptor & 3)]
        if try source.readInteger(dictionaryIDSize) != 0 { throw .dictionaryRequired }
        let contentSizeSize = [singleSegment ? 1 : 0, 2, 4, 8][Int(descriptor >> 6)]
        var contentSize: Int?
        if contentSizeSize > 0 {
            var value = try source.readInteger(contentSizeSize)
            if contentSizeSize == 2 { value += 256 }
            guard value <= UInt64(limits.maxOutputSize) else { throw .outputTooLarge }
            contentSize = Int(value)
        }
        if singleSegment { windowSize = contentSize ?? 0 }
        guard windowSize <= limits.maxWindowSize else { throw .windowTooLarge }
        frame = Frame(
            windowSize: windowSize, contentSize: contentSize,
            hasChecksum: descriptor & 0x04 != 0, slack: limits.windowSlack)
        stats.frames += 1
        return true
    }

    /// One frame's decoding state. Frames are independent: each starts with
    /// an empty window, fresh repeat offsets and no previous tables.
    struct Frame {
        let windowSize: Int
        let contentSize: Int?
        let hasChecksum: Bool
        /// Block_Maximum_Size: the cap on a block's size, in and out.
        let blockLimit: Int
        /// How far past `windowSize` the buffer grows before compaction.
        let slack: Int
        /// The tail of the output a match may still reach, plus the block
        /// being decoded.
        var window: [UInt8] = []
        var producedInFrame = 0
        var repeatOffsets = (1, 4, 8)
        var huffman: HuffmanTable?
        var tables = SequenceTables()
        var hasher = XXHash64()

        init(windowSize: Int, contentSize: Int?, hasChecksum: Bool, slack: Int?) {
            self.windowSize = windowSize
            self.contentSize = contentSize
            self.hasChecksum = hasChecksum
            self.blockLimit = min(windowSize, ZstdDecoder.blockSizeMax)
            self.slack = slack ?? max(1 << 20, min(windowSize, 8 << 20))
            // Reserved once, at its ceiling: grown by doubling, the buffer
            // peaked near 3× the window (295 MB for a 4.5 KB hostile file
            // declaring 2^27; 145 MB reserved). Untouched pages stay
            // non-resident, so a small frame declaring a big window costs
            // nothing (1.8 MB peak).
            window.reserveCapacity(windowSize + self.slack + blockLimit)
        }

        mutating func decodeBlock(
            _ source: ByteSource, stats: inout ZstdStats
        ) throws(ZstdError) -> (bytes: [UInt8], last: Bool) {
            let header = Int(try source.readInteger(3))
            let last = header & 1 == 1
            let size = header >> 3
            let blockStart = window.count
            guard size <= blockLimit else { throw .corrupt("block larger than its maximum size") }
            switch (header >> 1) & 3 {
            case 0:
                window.append(contentsOf: try source.read(size))
                stats.rawBlocks += 1
            case 1:
                let byte = try source.read(1)[0]
                window.append(contentsOf: repeatElement(byte, count: size))
                stats.rleBlocks += 1
            case 2:
                let block = try source.read(size)
                let (literals, used) = try decodeLiterals(block, stats: &stats)
                try executeSequences(
                    block, range: used..<block.count, literals: literals, stats: &stats)
                stats.compressedBlocks += 1
            default:
                throw .corrupt("reserved block type")
            }
            let bytes = Array(window[blockStart...])
            producedInFrame += bytes.count
            if let contentSize, producedInFrame > contentSize { throw .contentSizeMismatch }
            if hasChecksum { hasher.update(bytes) }
            if trimWindow() { stats.compactions += 1 }
            return (bytes, last)
        }

        /// After the last block: the stated size and checksum must hold.
        mutating func finish(_ source: ByteSource, stats: inout ZstdStats) throws(ZstdError) {
            if let contentSize, producedInFrame != contentSize { throw .contentSizeMismatch }
            if hasChecksum {
                let stored = UInt32(try source.readInteger(4))
                guard stored == UInt32(truncatingIfNeeded: hasher.digest()) else {
                    throw .checksumMismatch
                }
                stats.checksumsVerified += 1
            }
        }

        /// Keeps the last `windowSize` bytes — all a match may reach — once
        /// the buffer has grown a slack past that: one window copied per
        /// slack of output (16× at 2^27, measured negligible next to the
        /// decode itself).
        private mutating func trimWindow() -> Bool {
            guard window.count > windowSize + slack else { return false }
            window.removeFirst(window.count - windowSize)
            return true
        }

        mutating func appendLiterals(
            _ literals: [UInt8], range: Range<Int>, blockStart: Int
        ) throws(ZstdError) {
            guard !range.isEmpty else { return }
            guard window.count - blockStart + range.count <= blockLimit else {
                throw .corrupt("block decodes past its maximum size")
            }
            window.append(contentsOf: literals[range])
        }

        mutating func copyMatch(offset: Int, length: Int, blockStart: Int) throws(ZstdError) {
            guard window.count - blockStart + length <= blockLimit else {
                throw .corrupt("block decodes past its maximum size")
            }
            let reach = producedInFrame + (window.count - blockStart)
            guard offset > 0, offset <= reach, offset <= windowSize, offset <= window.count else {
                throw .corrupt("match offset beyond the window")
            }
            let destination = window.count
            let source = destination - offset
            window.append(contentsOf: repeatElement(0, count: length))
            window.withUnsafeMutableBufferPointer { buffer in
                // Proven above: source ≥ 0 and destination + length ≤ count.
                guard let base = buffer.baseAddress else { return }
                if offset >= length {
                    (base + destination).update(from: base + source, count: length)
                } else {
                    // Overlapping: the match repeats its last `offset` bytes.
                    for index in 0..<length {
                        base[destination + index] = base[source + index]
                    }
                }
            }
        }
    }
}

/// Buffered input over a file or a byte buffer — the compressed file is
/// read a chunk at a time, never whole. Files are read only through the
/// THROWING `FileHandle.read(upToCount:)` (the legacy reads raise an
/// uncatchable exception), never mapped (a file replaced underneath would
/// fault the process), and each read drains its own autorelease pool: the
/// chunks are autoreleased, and a scan thread with no pool of its own held
/// all of them — measured, 365 MB peak over 801 files, 30 MB pooled.
final class ByteSource {
    private static let chunkSize = 256 << 10

    private var buffer: [UInt8]
    private var position = 0
    private let handle: FileHandle?
    private var exhausted: Bool

    init(data: Data) {
        buffer = [UInt8](data)
        handle = nil
        exhausted = true
    }

    init(handle: FileHandle) {
        buffer = []
        self.handle = handle
        exhausted = false
    }

    private var available: Int { buffer.count - position }

    /// Makes at least `count` bytes available; fewer only at end of input.
    private func fill(_ count: Int) throws(ZstdError) {
        guard available < count, !exhausted, let handle else { return }
        if position > 0 {
            buffer.removeFirst(position)
            position = 0
        }
        while buffer.count < count {
            let data: Data?
            do {
                let size = max(Self.chunkSize, count - buffer.count)
                data = try autoreleasepool { try handle.read(upToCount: size) }
            } catch {
                throw .unreadable("read failed")
            }
            guard let data, !data.isEmpty else {
                exhausted = true
                return
            }
            buffer.append(contentsOf: data)
        }
    }

    func isAtEnd() throws(ZstdError) -> Bool {
        try fill(1)
        return available == 0
    }

    func read(_ count: Int) throws(ZstdError) -> [UInt8] {
        guard count > 0 else { return [] }
        try fill(count)
        guard available >= count else { throw .truncated }
        defer { position += count }
        return Array(buffer[position..<(position + count)])
    }

    /// A little-endian integer of `count` bytes (0...8).
    func readInteger(_ count: Int) throws(ZstdError) -> UInt64 {
        guard count > 0 else { return 0 }
        try fill(count)
        guard available >= count else { throw .truncated }
        var value: UInt64 = 0
        for index in 0..<count {
            value |= UInt64(buffer[position + index]) << UInt64(8 * index)
        }
        position += count
        return value
    }

    func skip(_ count: Int) throws(ZstdError) {
        var left = count
        while left > 0 {
            try fill(min(left, Self.chunkSize))
            guard available > 0 else { throw .truncated }
            let step = min(left, available)
            position += step
            left -= step
        }
    }
}
