import Foundation

// The literals section of a compressed block (RFC 8878 §3.1.1.3.1): raw,
// RLE, Huffman-coded in one or four streams, or "treeless" — Huffman with
// the previous block's table.

extension ZstdDecoder.Frame {
    /// The block's literals and the bytes the section occupied.
    mutating func decodeLiterals(
        _ block: [UInt8], stats: inout ZstdStats
    ) throws(ZstdError) -> (literals: [UInt8], consumed: Int) {
        guard let first = block.first else { throw .truncated }
        let type = Int(first & 3)
        let format = Int(first >> 2) & 3

        if type < 2 {
            // Raw or RLE: 5, 12 or 20 bits of size.
            let headerSize: Int
            let size: Int
            switch format {
            case 1:
                guard block.count >= 2 else { throw .truncated }
                headerSize = 2
                size = Int(first >> 4) | Int(block[1]) << 4
            case 3:
                guard block.count >= 3 else { throw .truncated }
                headerSize = 3
                size = Int(first >> 4) | Int(block[1]) << 4 | Int(block[2]) << 12
            default:
                headerSize = 1
                size = Int(first >> 3)
            }
            guard size <= blockLimit else { throw .corrupt("literals larger than the block") }
            if type == 0 {
                guard headerSize + size <= block.count else { throw .truncated }
                stats.rawLiterals += 1
                return (Array(block[headerSize..<(headerSize + size)]), headerSize + size)
            }
            guard headerSize < block.count else { throw .truncated }
            stats.rleLiterals += 1
            return ([UInt8](repeating: block[headerSize], count: size), headerSize + 1)
        }

        // Huffman: regenerated and compressed sizes share a 3–5 byte header.
        let streams = format == 0 ? 1 : 4
        let headerSize = [3, 3, 4, 5][format]
        let sizeBits = [10, 10, 14, 18][format]
        guard block.count >= headerSize else { throw .truncated }
        var header: UInt64 = 0
        for index in 0..<headerSize {
            header |= UInt64(block[index]) << UInt64(8 * index)
        }
        let regenerated = Int((header >> 4) & lowBits(sizeBits))
        let compressed = Int((header >> UInt64(4 + sizeBits)) & lowBits(sizeBits))
        guard regenerated <= blockLimit else { throw .corrupt("literals larger than the block") }
        let end = headerSize + compressed
        guard end <= block.count else { throw .truncated }

        var position = headerSize
        if type == 2 {
            let (table, used) = try HuffmanTable.read(block, range: position..<end)
            huffman = table
            position += used
        } else {
            stats.treelessLiterals += 1
        }
        guard let table = huffman else { throw .corrupt("treeless literals with no previous table") }

        var literals: [UInt8] = []
        literals.reserveCapacity(regenerated)
        if streams == 1 {
            try table.decode(block, range: position..<end, count: regenerated, into: &literals)
            stats.huffmanLiterals1Stream += 1
        } else {
            // A jump table of three stream sizes; the fourth is the rest.
            guard position + 6 <= end else { throw .truncated }
            let sizes = (0..<3).map { Int(block[position + 2 * $0]) | Int(block[position + 2 * $0 + 1]) << 8 }
            position += 6
            let total = sizes.reduce(0, +)
            guard total <= end - position else { throw .corrupt("Huffman jump table overruns") }
            let segment = (regenerated + 3) / 4
            let lastSegment = regenerated - 3 * segment
            guard lastSegment >= 0 else { throw .corrupt("too few literals for four streams") }
            for (index, size) in (sizes + [end - position - total]).enumerated() {
                try table.decode(
                    block, range: position..<(position + size),
                    count: index == 3 ? lastSegment : segment, into: &literals)
                position += size
            }
            stats.huffmanLiterals4Streams += 1
        }
        return (literals, end)
    }
}
