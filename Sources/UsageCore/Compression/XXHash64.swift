import Foundation

/// Streaming XXH64 (seed 0 by default) — zstd's content checksum is its low
/// 32 bits. All arithmetic wraps, as the algorithm defines it.
struct XXHash64 {
    private static let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let prime3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let prime4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let prime5: UInt64 = 0x27D4_EB2F_1656_67C5

    private let seed: UInt64
    private var lanes: (UInt64, UInt64, UInt64, UInt64)
    /// Bytes waiting for a whole 32-byte stripe (always < 32).
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    init(seed: UInt64 = 0) {
        self.seed = seed
        lanes = (
            seed &+ Self.prime1 &+ Self.prime2, seed &+ Self.prime2, seed, seed &- Self.prime1
        )
    }

    @inline(__always)
    private static func round(_ accumulator: UInt64, _ input: UInt64) -> UInt64 {
        rotate(accumulator &+ input &* prime2, 31) &* prime1
    }

    @inline(__always)
    private static func rotate(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value << count) | (value >> (64 - count))
    }

    @inline(__always)
    private static func merge(_ hash: UInt64, _ lane: UInt64) -> UInt64 {
        (hash ^ round(0, lane)) &* prime1 &+ prime4
    }

    mutating func update(_ bytes: [UInt8]) {
        length &+= UInt64(bytes.count)
        var input = bytes[...]
        if !pending.isEmpty {
            let take = min(32 - pending.count, input.count)
            pending.append(contentsOf: input.prefix(take))
            input = input.dropFirst(take)
            guard pending.count == 32 else { return }
            consumeStripes(pending[...])
            pending.removeAll(keepingCapacity: true)
        }
        let whole = input.count - input.count % 32
        consumeStripes(input.prefix(whole))
        pending.append(contentsOf: input.dropFirst(whole))
    }

    /// Folds whole 32-byte stripes into the four lanes.
    private mutating func consumeStripes(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset + 32 <= raw.count {
                lanes.0 = Self.round(lanes.0, Self.word64(raw, offset))
                lanes.1 = Self.round(lanes.1, Self.word64(raw, offset + 8))
                lanes.2 = Self.round(lanes.2, Self.word64(raw, offset + 16))
                lanes.3 = Self.round(lanes.3, Self.word64(raw, offset + 24))
                offset += 32
            }
        }
    }

    @inline(__always)
    private static func word64(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @inline(__always)
    private static func word32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt64 {
        UInt64(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
    }

    func digest() -> UInt64 {
        var hash: UInt64
        if length >= 32 {
            hash = Self.rotate(lanes.0, 1) &+ Self.rotate(lanes.1, 7)
                &+ Self.rotate(lanes.2, 12) &+ Self.rotate(lanes.3, 18)
            hash = Self.merge(hash, lanes.0)
            hash = Self.merge(hash, lanes.1)
            hash = Self.merge(hash, lanes.2)
            hash = Self.merge(hash, lanes.3)
        } else {
            hash = seed &+ Self.prime5
        }
        hash &+= length
        pending.withUnsafeBytes { raw in
            var offset = 0
            while offset + 8 <= raw.count {
                hash ^= Self.round(0, Self.word64(raw, offset))
                hash = Self.rotate(hash, 27) &* Self.prime1 &+ Self.prime4
                offset += 8
            }
            if offset + 4 <= raw.count {
                hash ^= Self.word32(raw, offset) &* Self.prime1
                hash = Self.rotate(hash, 23) &* Self.prime2 &+ Self.prime3
                offset += 4
            }
            while offset < raw.count {
                hash ^= UInt64(raw[offset]) &* Self.prime5
                hash = Self.rotate(hash, 11) &* Self.prime1
                offset += 1
            }
        }
        hash ^= hash >> 33
        hash &*= Self.prime2
        hash ^= hash >> 29
        hash &*= Self.prime3
        hash ^= hash >> 32
        return hash
    }
}
