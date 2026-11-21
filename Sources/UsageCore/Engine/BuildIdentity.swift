import Foundation
import MachO

/// Which BUILD of a binary is which: the Mach-O `LC_UUID` the linker stamps
/// into every image. The running daemon reads its own from memory — what it
/// actually executes, immune to the file being replaced under it — and
/// `ensure` reads the one in the file its plist points at. Different UUIDs
/// mean the file on disk was rebuilt since the daemon started, which a
/// same-version rebuild hides from the version check (2026-11-21: a fresh app
/// ran as a client of the OLD daemon for minutes). Same file, same UUID: an
/// app launch with nothing rebuilt never restarts anything.
public enum BuildIdentity {
    /// The running process's own main image.
    public static func running() -> String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        let raw = UnsafeRawPointer(header)
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        let size = MemoryLayout<mach_header_64>.size + Int(header.pointee.sizeofcmds)
        return uuid(inImage: Data(bytes: raw, count: size))
    }

    /// The image in a binary on disk, thin or universal (the slice this Mac
    /// would run). Nil for anything unreadable or not Mach-O.
    public static func of(binary url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return nil }
        var offset: UInt64 = 0
        if let slice = sliceOffset(fatHeader: head, cpuType: hostCPUType) {
            offset = slice
        } else if isFat(head) {
            return nil  // universal, without a slice for this Mac
        }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let header = try? handle.read(upToCount: MemoryLayout<mach_header_64>.size),
              header.count == MemoryLayout<mach_header_64>.size,
              header.loadUInt32(at: 0) == MH_MAGIC_64
        else { return nil }
        let commands = Int(header.loadUInt32(at: 20))
        guard commands < 4 * 1024 * 1024,
              let rest = try? handle.read(upToCount: commands), rest.count == commands
        else { return nil }
        return uuid(inImage: header + rest)
    }

    // MARK: - Parsing (pure; the tests feed synthetic images)

    static let lcUUID: UInt32 = 0x1B

    /// `LC_UUID` from a thin 64-bit image's header and load commands.
    static func uuid(inImage data: Data) -> String? {
        let headerSize = MemoryLayout<mach_header_64>.size
        guard data.count >= headerSize, data.loadUInt32(at: 0) == MH_MAGIC_64 else { return nil }
        let count = Int(data.loadUInt32(at: 16))
        var cursor = headerSize
        for _ in 0..<count {
            guard cursor + 8 <= data.count else { return nil }
            let command = data.loadUInt32(at: cursor)
            let size = Int(data.loadUInt32(at: cursor + 4))
            guard size >= 8, cursor + size <= data.count else { return nil }
            if command == lcUUID, size >= 24 {
                let bytes = [UInt8](data[(data.startIndex + cursor + 8)..<(data.startIndex + cursor + 24)])
                let uuid = bytes.withUnsafeBytes { buffer in
                    UUID(uuid: buffer.loadUnaligned(as: uuid_t.self))
                }
                return uuid.uuidString
            }
            cursor += size
        }
        return nil
    }

    static func isFat(_ data: Data) -> Bool {
        let magic = data.loadUInt32(at: 0).bigEndian
        return magic == FAT_MAGIC || magic == FAT_MAGIC_64
    }

    /// The file offset of `cpuType`'s slice in a universal binary's header;
    /// nil for a thin file or a missing slice. Fat headers are big-endian.
    static func sliceOffset(fatHeader data: Data, cpuType: cpu_type_t) -> UInt64? {
        guard data.count >= 8 else { return nil }
        let magic = data.loadUInt32(at: 0).bigEndian
        guard magic == FAT_MAGIC || magic == FAT_MAGIC_64 else { return nil }
        let wide = magic == FAT_MAGIC_64
        let entry = wide ? 32 : 20
        let count = Int(data.loadUInt32(at: 4).bigEndian)
        var found: UInt64?
        for index in 0..<count {
            let base = 8 + index * entry
            guard base + entry <= data.count else { return nil }
            let type = cpu_type_t(bitPattern: data.loadUInt32(at: base).bigEndian)
            guard type == cpuType else { continue }
            // Two slices of one CPU type (arm64 beside arm64e, x86_64 beside
            // x86_64h): which one the kernel runs depends on the machine, so
            // the build is unknown — and an unknown build never kicks.
            guard found == nil else { return nil }
            found = wide
                ? data.loadUInt64(at: base + 8).bigEndian
                : UInt64(data.loadUInt32(at: base + 8).bigEndian)
        }
        return found
    }

    /// The CPU the daemon runs natively on — not this process's own arch: an
    /// Intel build of the app under Rosetta still has an arm64 launchd job.
    static var hostCPUType: cpu_type_t {
        #if arch(arm64)
            CPU_TYPE_ARM64
        #else
            var translated: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let rosetta = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0
                && translated == 1
            return rosetta ? CPU_TYPE_ARM64 : CPU_TYPE_X86_64
        #endif
    }
}

extension Data {
    fileprivate func loadUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    fileprivate func loadUInt64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
    }
}
