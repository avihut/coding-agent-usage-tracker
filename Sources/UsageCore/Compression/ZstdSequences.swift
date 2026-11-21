import Foundation

// The sequences section of a compressed block (RFC 8878 §3.1.1.3.2):
// literal-length / offset / match-length codes through three FSE tables,
// decoded and executed one sequence at a time, so no sequence array is ever
// materialized.

/// The three tables a block's sequences decode through — kept across the
/// blocks of one frame for the Repeat mode.
struct SequenceTables {
    var literalLengths: FSETable?
    var offsets: FSETable?
    var matchLengths: FSETable?
}

/// Which of the three tables a description belongs to, and its limits.
private enum SequenceTableKind {
    case literalLength, offset, matchLength

    var maxAccuracyLog: Int {
        switch self {
        case .literalLength, .matchLength: 9
        case .offset: 8
        }
    }

    var maxSymbol: Int {
        switch self {
        case .literalLength: 35
        case .offset: 31
        case .matchLength: 52
        }
    }

    var predefined: FSETable {
        switch self {
        case .literalLength: ZstdTables.predefinedLiteralLengths
        case .offset: ZstdTables.predefinedOffsets
        case .matchLength: ZstdTables.predefinedMatchLengths
        }
    }
}

enum ZstdTables {
    // Predefined distributions (RFC 8878 §3.1.1.3.2.2). Built once; a build
    // failure here is a bug in these constants, which tests pin.
    static let predefinedLiteralLengths = predefined(
        [4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
         -1, -1, -1, -1], accuracyLog: 6)
    static let predefinedMatchLengths = predefined(
        [1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
         1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1], accuracyLog: 6)
    static let predefinedOffsets = predefined(
        [1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1],
        accuracyLog: 5)

    private static func predefined(_ probabilities: [Int], accuracyLog: Int) -> FSETable {
        // These constants are the RFC's; they always build (pinned by tests).
        (try? FSETable(probabilities: probabilities, accuracyLog: accuracyLog)) ?? .rle(0)
    }

    // Literal-length and match-length codes → baseline + extra bits (§3.1.1.3.2.1.1).
    static let literalLengthBase: [Int] = Array(0..<16) + [
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768,
        65536,
    ]
    static let literalLengthBits: [Int] = Array(repeating: 0, count: 16) + [
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    ]
    static let matchLengthBase: [Int] = Array(3..<35) + [
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387,
        32771, 65539,
    ]
    static let matchLengthBits: [Int] = Array(repeating: 0, count: 32) + [
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    ]
}

extension ZstdDecoder.Frame {
    /// Decodes the sequences section in `range` of `block` and executes it
    /// against `literals`, appending to the frame's window.
    mutating func executeSequences(
        _ block: [UInt8], range: Range<Int>, literals: [UInt8], stats: inout ZstdStats
    ) throws(ZstdError) {
        var position = range.lowerBound
        let end = range.upperBound
        guard position < end else { throw .truncated }
        let first = Int(block[position])
        var count: Int
        if first < 128 {
            count = first
            position += 1
        } else if first < 255 {
            guard position + 2 <= end else { throw .truncated }
            count = ((first - 128) << 8) + Int(block[position + 1])
            position += 2
        } else {
            guard position + 3 <= end else { throw .truncated }
            count = Int(block[position + 1]) + (Int(block[position + 2]) << 8) + 0x7F00
            position += 3
        }
        let blockStart = window.count
        if count == 0 {
            // No sequences: the block is its literals, and nothing may follow.
            guard position == end else { throw .corrupt("bytes after an empty sequences section") }
            try appendLiterals(literals, range: 0..<literals.count, blockStart: blockStart)
            return
        }

        guard position < end else { throw .truncated }
        let modes = block[position]
        position += 1
        guard modes & 0b11 == 0 else { throw .corrupt("reserved bits set in sequence modes") }
        let literalLengths = try table(
            mode: Int(modes >> 6), kind: .literalLength, current: tables.literalLengths,
            block, &position, end, &stats)
        let offsets = try table(
            mode: Int(modes >> 4) & 3, kind: .offset, current: tables.offsets,
            block, &position, end, &stats)
        let matchLengths = try table(
            mode: Int(modes >> 2) & 3, kind: .matchLength, current: tables.matchLengths,
            block, &position, end, &stats)
        tables = SequenceTables(
            literalLengths: literalLengths, offsets: offsets, matchLengths: matchLengths)

        var reader = try ReverseBitReader(block, range: position..<end)
        var literalState = Int(reader.read(literalLengths.accuracyLog))
        var offsetState = Int(reader.read(offsets.accuracyLog))
        var matchState = Int(reader.read(matchLengths.accuracyLog))
        var literalPosition = 0

        for index in 0..<count {
            let offsetCode = Int(offsets.symbols[offsetState])
            let literalCode = Int(literalLengths.symbols[literalState])
            let matchCode = Int(matchLengths.symbols[matchState])
            guard offsetCode <= 31, literalCode <= 35, matchCode <= 52 else {
                throw .corrupt("sequence code out of range")
            }
            let offsetValue = (1 << offsetCode) + Int(reader.read(offsetCode))
            let matchLength = ZstdTables.matchLengthBase[matchCode]
                + Int(reader.read(ZstdTables.matchLengthBits[matchCode]))
            let literalLength = ZstdTables.literalLengthBase[literalCode]
                + Int(reader.read(ZstdTables.literalLengthBits[literalCode]))
            if index != count - 1 {
                literalState = literalLengths.baselines[literalState]
                    + Int(reader.read(Int(literalLengths.bits[literalState])))
                matchState = matchLengths.baselines[matchState]
                    + Int(reader.read(Int(matchLengths.bits[matchState])))
                offsetState = offsets.baselines[offsetState]
                    + Int(reader.read(Int(offsets.bits[offsetState])))
            }

            let offset = try resolveOffset(offsetValue, literalLength: literalLength, stats: &stats)
            guard literalLength <= literals.count - literalPosition else {
                throw .corrupt("sequence needs more literals than the block holds")
            }
            try appendLiterals(
                literals, range: literalPosition..<(literalPosition + literalLength),
                blockStart: blockStart)
            literalPosition += literalLength
            try copyMatch(offset: offset, length: matchLength, blockStart: blockStart)
        }
        guard reader.position == 0 else { throw .corrupt("sequence bitstream size mismatch") }
        try appendLiterals(
            literals, range: literalPosition..<literals.count, blockStart: blockStart)
    }

    private func table(
        mode: Int, kind: SequenceTableKind, current: FSETable?,
        _ block: [UInt8], _ position: inout Int, _ end: Int, _ stats: inout ZstdStats
    ) throws(ZstdError) -> FSETable {
        switch mode {
        case 0:
            stats.predefinedTables += 1
            return kind.predefined
        case 1:
            guard position < end else { throw .truncated }
            let symbol = block[position]
            guard Int(symbol) <= kind.maxSymbol else { throw .corrupt("RLE sequence symbol out of range") }
            position += 1
            stats.rleTables += 1
            return .rle(symbol)
        case 2:
            let (table, used) = try FSETable.read(
                block, range: position..<end, maxAccuracyLog: kind.maxAccuracyLog,
                maxSymbol: kind.maxSymbol)
            position += used
            stats.fseTables += 1
            return table
        default:
            guard let current else { throw .corrupt("repeat mode with no previous table") }
            stats.repeatTables += 1
            return current
        }
    }

    /// Offset_Value → offset through the three repeat offsets (§3.1.1.5),
    /// including the literal-length-zero shift.
    private mutating func resolveOffset(
        _ value: Int, literalLength: Int, stats: inout ZstdStats
    ) throws(ZstdError) -> Int {
        if value > 3 {
            let offset = value - 3
            repeatOffsets = (offset, repeatOffsets.0, repeatOffsets.1)
            return offset
        }
        stats.repeatOffsets += 1
        let index = value - 1 + (literalLength == 0 ? 1 : 0)
        switch index {
        case 0:
            return repeatOffsets.0
        case 1:
            let offset = repeatOffsets.1
            repeatOffsets = (offset, repeatOffsets.0, repeatOffsets.2)
            return offset
        case 2:
            let offset = repeatOffsets.2
            repeatOffsets = (offset, repeatOffsets.0, repeatOffsets.1)
            return offset
        default:
            let offset = repeatOffsets.0 - 1
            guard offset > 0 else { throw .corrupt("repeat offset of zero") }
            repeatOffsets = (offset, repeatOffsets.0, repeatOffsets.1)
            return offset
        }
    }
}
