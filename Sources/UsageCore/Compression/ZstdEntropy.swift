import Foundation

// The entropy layer of the zstd decoder (RFC 8878 §4): the two bit readers,
// FSE tables and Huffman tables. Every read is checked against its range
// before it happens — this runs in the daemon, over files it didn't write,
// so a corrupt table is an error, never a trap.

/// A bit mask of the low `count` bits (`count` 0...64).
@inline(__always)
func lowBits(_ count: Int) -> UInt64 {
    count >= 64 ? ~0 : (UInt64(1) << UInt64(count)) &- 1
}

/// Index of the highest set bit of a positive value (`1` → 0).
@inline(__always)
func highestBit(_ value: Int) -> Int {
    Int.bitWidth - 1 - value.leadingZeroBitCount
}

// MARK: - Bit readers

/// A bitstream read BACKWARD (RFC 8878 §4.1): from the end marker — the
/// highest set bit of the last byte — towards the first byte. Reads past the
/// start return zero bits and drive `position` negative; callers judge a
/// stream by where `position` ends, exactly as the RFC's educational decoder
/// does.
struct ReverseBitReader {
    private let bytes: [UInt8]
    private let start: Int
    /// Bits still unread above `start`'s bit 0. Negative once a read ran past
    /// the start of the stream.
    private(set) var position: Int

    init(_ bytes: [UInt8], range: Range<Int>) throws(ZstdError) {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count, !range.isEmpty else {
            throw .corrupt("empty bitstream")
        }
        let last = bytes[range.upperBound - 1]
        guard last != 0 else { throw .corrupt("bitstream without an end marker") }
        self.bytes = bytes
        self.start = range.lowerBound
        self.position = (range.count - 1) * 8 + (7 - last.leadingZeroBitCount)
    }

    /// The next `count` bits (0...56), most recent stream bits highest.
    @inline(__always)
    mutating func read(_ count: Int) -> UInt64 {
        guard count > 0 else { return 0 }
        position -= count
        if position >= 0 {
            return load(bit: position) & lowBits(count)
        }
        let available = count + position
        guard available > 0 else { return 0 }
        return (load(bit: 0) & lowBits(available)) << UInt64(-position)
    }

    /// Up to 64 bits starting at stream bit `bit` (≥ 0, inside the stream).
    @inline(__always)
    private func load(bit: Int) -> UInt64 {
        let index = start + (bit >> 3)
        let shift = UInt64(bit & 7)
        if index + 8 <= bytes.count {
            let word = bytes.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: index, as: UInt64.self)
            }
            return UInt64(littleEndian: word) >> shift
        }
        var word: UInt64 = 0
        var offset = 0
        while offset < 8, index + offset < bytes.count {
            word |= UInt64(bytes[index + offset]) << UInt64(8 * offset)
            offset += 1
        }
        return word >> shift
    }
}

/// A little-endian bitstream read FORWARD — FSE table descriptions
/// (RFC 8878 §4.1.1). Peeks past the end read as zero; consuming past it is
/// an error.
struct ForwardBitReader {
    private let bytes: [UInt8]
    private let start: Int
    private let end: Int
    private(set) var consumedBits = 0

    init(_ bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        self.start = range.lowerBound
        self.end = range.upperBound
    }

    var consumedBytes: Int { (consumedBits + 7) / 8 }

    func peek(_ count: Int) -> Int {
        var value = 0
        for bit in 0..<count {
            let absolute = consumedBits + bit
            let index = start + absolute / 8
            guard index < end else { break }
            if bytes[index] >> UInt8(absolute % 8) & 1 == 1 { value |= 1 << bit }
        }
        return value
    }

    mutating func skip(_ count: Int) throws(ZstdError) {
        guard consumedBits + count <= (end - start) * 8 else {
            throw .corrupt("table description runs past its block")
        }
        consumedBits += count
    }

    mutating func read(_ count: Int) throws(ZstdError) -> Int {
        let value = peek(count)
        try skip(count)
        return value
    }
}

// MARK: - FSE

/// An FSE decoding table (RFC 8878 §4.1.1): per state, the symbol it emits,
/// how many bits the next state reads, and the base those bits add to.
struct FSETable {
    let accuracyLog: Int
    let symbols: [UInt8]
    let bits: [UInt8]
    let baselines: [Int]

    /// RLE mode: one symbol, every state reads zero bits.
    static func rle(_ symbol: UInt8) -> FSETable {
        FSETable(accuracyLog: 0, symbols: [symbol], bits: [0], baselines: [0])
    }

    private init(accuracyLog: Int, symbols: [UInt8], bits: [UInt8], baselines: [Int]) {
        self.accuracyLog = accuracyLog
        self.symbols = symbols
        self.bits = bits
        self.baselines = baselines
    }

    /// Builds the table from normalized probabilities (−1 = "less than one").
    /// The caller has checked that they sum to `1 << accuracyLog`.
    init(probabilities: [Int], accuracyLog: Int) throws(ZstdError) {
        let size = 1 << accuracyLog
        guard probabilities.count <= 256 else { throw .corrupt("FSE table has too many symbols") }
        var symbols = [UInt8](repeating: 0, count: size)
        var next = [Int](repeating: 0, count: probabilities.count)
        var highThreshold = size
        for (symbol, probability) in probabilities.enumerated() where probability == -1 {
            highThreshold -= 1
            guard highThreshold >= 0 else { throw .corrupt("FSE table overfull") }
            symbols[highThreshold] = UInt8(symbol)
            next[symbol] = 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        let mask = size - 1
        var position = 0
        for (symbol, probability) in probabilities.enumerated() where probability > 0 {
            next[symbol] = probability
            for _ in 0..<probability {
                guard highThreshold > 0 else { throw .corrupt("FSE table overfull") }
                symbols[position] = UInt8(symbol)
                // `step` is odd, so coprime to the power-of-two size: the walk
                // visits every cell, and at most `size` steps find a free one.
                var hops = 0
                repeat {
                    position = (position + step) & mask
                    hops += 1
                } while position >= highThreshold && hops <= size
            }
        }
        guard position == 0 else { throw .corrupt("FSE probabilities don't fill the table") }
        var bits = [UInt8](repeating: 0, count: size)
        var baselines = [Int](repeating: 0, count: size)
        for state in 0..<size {
            let symbol = Int(symbols[state])
            guard symbol < next.count, next[symbol] > 0 else {
                throw .corrupt("FSE table cell without a symbol")
            }
            let descriptor = next[symbol]
            next[symbol] += 1
            let count = accuracyLog - highestBit(descriptor)
            guard count >= 0 else { throw .corrupt("FSE state out of range") }
            bits[state] = UInt8(count)
            baselines[state] = (descriptor << count) - size
        }
        self.init(accuracyLog: accuracyLog, symbols: symbols, bits: bits, baselines: baselines)
    }

    /// Reads a table description (RFC 8878 §4.1.1) starting at `range`'s
    /// lower bound; returns the table and the bytes it occupied.
    static func read(
        _ bytes: [UInt8], range: Range<Int>, maxAccuracyLog: Int, maxSymbol: Int
    ) throws(ZstdError) -> (table: FSETable, consumed: Int) {
        var reader = ForwardBitReader(bytes, range: range)
        let accuracyLog = 5 + (try reader.read(4))
        guard accuracyLog <= maxAccuracyLog else { throw .corrupt("FSE accuracy log too large") }
        var remaining = 1 << accuracyLog
        var probabilities: [Int] = []
        while remaining > 0 {
            guard probabilities.count <= maxSymbol else { throw .corrupt("FSE symbol out of range") }
            let width = highestBit(remaining + 1) + 1
            var value = reader.peek(width)
            let lowerMask = (1 << (width - 1)) - 1
            let threshold = (1 << width) - 1 - (remaining + 1)
            if value & lowerMask < threshold {
                try reader.skip(width - 1)
                value &= lowerMask
            } else {
                try reader.skip(width)
                if value > lowerMask { value -= threshold }
            }
            let probability = value - 1
            remaining -= abs(probability)
            guard remaining >= 0 else { throw .corrupt("FSE probabilities overflow the table") }
            probabilities.append(probability)
            if probability == 0 {
                // A zero is followed by 2-bit repeat counts; 3 means "and more".
                while true {
                    let repeats = try reader.read(2)
                    guard probabilities.count + repeats <= maxSymbol + 1 else {
                        throw .corrupt("FSE symbol out of range")
                    }
                    probabilities.append(contentsOf: repeatElement(0, count: repeats))
                    if repeats != 3 { break }
                }
            }
        }
        guard probabilities.count <= maxSymbol + 1 else { throw .corrupt("FSE symbol out of range") }
        let table = try FSETable(probabilities: probabilities, accuracyLog: accuracyLog)
        return (table, reader.consumedBytes)
    }
}

// MARK: - Huffman

/// A Huffman decoding table for literals (RFC 8878 §4.2): indexed by the
/// next `maxBits` stream bits, each entry names its symbol and code length.
struct HuffmanTable {
    static let maxCodeLength = 11

    let maxBits: Int
    let symbols: [UInt8]
    let lengths: [UInt8]

    /// From per-symbol weights; the last symbol's weight is implied (§4.2.1).
    init(weights: [UInt8]) throws(ZstdError) {
        guard !weights.isEmpty, weights.count < 256 else {
            throw .corrupt("Huffman table has a bad symbol count")
        }
        var sum = 0
        for weight in weights {
            guard weight <= Self.maxCodeLength else { throw .corrupt("Huffman weight too large") }
            if weight > 0 { sum += 1 << (Int(weight) - 1) }
        }
        guard sum > 0 else { throw .corrupt("Huffman table without symbols") }
        let maxBits = highestBit(sum) + 1
        guard maxBits <= Self.maxCodeLength else { throw .corrupt("Huffman table too deep") }
        let leftover = (1 << maxBits) - sum
        guard leftover > 0, leftover & (leftover - 1) == 0 else {
            throw .corrupt("Huffman weights don't complete a tree")
        }
        let lastWeight = highestBit(leftover) + 1
        var codeLengths = weights.map { $0 > 0 ? maxBits + 1 - Int($0) : 0 }
        codeLengths.append(maxBits + 1 - lastWeight)

        var rankCount = [Int](repeating: 0, count: maxBits + 1)
        for length in codeLengths {
            guard length <= maxBits else { throw .corrupt("Huffman code too long") }
            rankCount[length] += 1
        }
        let size = 1 << maxBits
        // Longest codes first, each length's run in symbol order (§4.2.1.3).
        var rankStart = [Int](repeating: 0, count: maxBits + 2)
        for length in stride(from: maxBits, through: 1, by: -1) {
            rankStart[length - 1] = rankStart[length] + rankCount[length] * (1 << (maxBits - length))
        }
        guard rankStart[0] == size else { throw .corrupt("Huffman codes don't fill the table") }
        var symbols = [UInt8](repeating: 0, count: size)
        var lengths = [UInt8](repeating: 0, count: size)
        for (symbol, length) in codeLengths.enumerated() where length > 0 {
            let first = rankStart[length]
            let span = 1 << (maxBits - length)
            guard first + span <= size else { throw .corrupt("Huffman codes overflow the table") }
            for index in first..<(first + span) {
                symbols[index] = UInt8(symbol)
                lengths[index] = UInt8(length)
            }
            rankStart[length] += span
        }
        self.maxBits = maxBits
        self.symbols = symbols
        self.lengths = lengths
    }

    /// Reads a Huffman tree description (§4.2.1) at `range`'s lower bound.
    static func read(
        _ bytes: [UInt8], range: Range<Int>
    ) throws(ZstdError) -> (table: HuffmanTable, consumed: Int) {
        guard !range.isEmpty else { throw .truncated }
        let header = Int(bytes[range.lowerBound])
        var weights: [UInt8] = []
        let consumed: Int
        if header >= 128 {
            // Direct: 4 bits per weight, first weight in the high nibble.
            let count = header - 127
            let length = (count + 1) / 2
            guard 1 + length <= range.count else { throw .corrupt("Huffman weights run past the block") }
            for index in 0..<count {
                let byte = bytes[range.lowerBound + 1 + index / 2]
                weights.append(index.isMultiple(of: 2) ? byte >> 4 : byte & 0x0F)
            }
            consumed = 1 + length
        } else {
            // FSE-compressed weights: `header` bytes of description + stream.
            guard header > 0, 1 + header <= range.count else {
                throw .corrupt("Huffman weights run past the block")
            }
            let streamRange = (range.lowerBound + 1)..<(range.lowerBound + 1 + header)
            let (table, used) = try FSETable.read(
                bytes, range: streamRange, maxAccuracyLog: 6, maxSymbol: 255)
            guard used < header else { throw .corrupt("Huffman weights stream missing") }
            weights = try decodeWeights(
                bytes, range: (streamRange.lowerBound + used)..<streamRange.upperBound, table: table)
            consumed = 1 + header
        }
        return (try HuffmanTable(weights: weights), consumed)
    }

    /// Two interleaved FSE states share one table; the stream running out
    /// (a read past its start) ends it, after the other state's last symbol.
    private static func decodeWeights(
        _ bytes: [UInt8], range: Range<Int>, table: FSETable
    ) throws(ZstdError) -> [UInt8] {
        var reader = try ReverseBitReader(bytes, range: range)
        var first = Int(reader.read(table.accuracyLog))
        var second = Int(reader.read(table.accuracyLog))
        var weights: [UInt8] = []
        func step(_ state: inout Int) {
            state = table.baselines[state] + Int(reader.read(Int(table.bits[state])))
        }
        // A degenerate table can read zero bits forever: the 255-weight cap
        // is what ends that loop.
        while weights.count < 255 {
            weights.append(table.symbols[first])
            step(&first)
            if reader.position < 0 {
                weights.append(table.symbols[second])
                return weights
            }
            weights.append(table.symbols[second])
            step(&second)
            if reader.position < 0 {
                weights.append(table.symbols[first])
                return weights
            }
        }
        throw .corrupt("too many Huffman weights")
    }

    /// Decodes exactly `count` symbols from one stream; the stream must end
    /// exactly where its last symbol does.
    func decode(
        _ bytes: [UInt8], range: Range<Int>, count: Int, into output: inout [UInt8]
    ) throws(ZstdError) {
        var reader = try ReverseBitReader(bytes, range: range)
        let mask = (1 << maxBits) - 1
        var state = Int(reader.read(maxBits))
        for _ in 0..<count {
            output.append(symbols[state])
            let length = Int(lengths[state])
            state = ((state << length) | Int(reader.read(length))) & mask
        }
        guard reader.position == -maxBits else { throw .corrupt("Huffman stream size mismatch") }
    }
}
