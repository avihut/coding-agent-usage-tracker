import Foundation
import MachO
import Testing

@testable import UsageCore

/// The build identity a same-version rebuild is told apart by (2026-11-21).
@Suite("Build identity")
struct BuildIdentityTests {
    private static let uuidBytes: [UInt8] = Array(0x10...0x1F)

    /// A thin 64-bit image: header, one unrelated command, then LC_UUID.
    private func thinImage(uuid: [UInt8] = uuidBytes, cpu: cpu_type_t = CPU_TYPE_ARM64) -> Data {
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let other: UInt32 = 16
        let uuidCommand: UInt32 = 24
        put32(MH_MAGIC_64)
        put32(UInt32(bitPattern: cpu))
        put32(0)  // subtype
        put32(UInt32(MH_EXECUTE))
        put32(2)  // ncmds
        put32(other + uuidCommand)  // sizeofcmds
        put32(0)  // flags
        put32(0)  // reserved
        put32(0x32)  // LC_BUILD_VERSION, padded out
        put32(other)
        put32(0)
        put32(0)
        put32(BuildIdentity.lcUUID)
        put32(uuidCommand)
        data.append(contentsOf: uuid)
        return data
    }

    private func fat(_ slices: [(cpu_type_t, Data)]) -> Data {
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) } }
        put32(FAT_MAGIC)
        put32(UInt32(slices.count))
        var offset = UInt32(4096)
        var bodies = Data()
        for (cpu, body) in slices {
            put32(UInt32(bitPattern: cpu))
            put32(0)
            put32(offset)
            put32(UInt32(body.count))
            put32(12)
            bodies.append(body)
            bodies.append(Data(count: 4096 - body.count))
            offset += 4096
        }
        data.append(Data(count: 4096 - data.count))
        data.append(bodies)
        return data
    }

    private func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "build-id-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test("a thin image's LC_UUID reads out, past the commands before it")
    func thin() throws {
        let expected = UUID(uuid: Self.uuidBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
        #expect(BuildIdentity.uuid(inImage: thinImage()) == expected.uuidString)
        let url = try write(thinImage())
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BuildIdentity.of(binary: url) == expected.uuidString)
    }

    @Test("a universal binary reads this Mac's slice, and nil without one")
    func universal() throws {
        let other: [UInt8] = Array(0x20...0x2F)
        let otherCPU: cpu_type_t = BuildIdentity.hostCPUType == CPU_TYPE_ARM64 ? CPU_TYPE_X86_64 : CPU_TYPE_ARM64
        let both = try write(fat([
            (otherCPU, thinImage(uuid: other, cpu: otherCPU)),
            (BuildIdentity.hostCPUType, thinImage(cpu: BuildIdentity.hostCPUType)),
        ]))
        defer { try? FileManager.default.removeItem(at: both) }
        let mine = UUID(uuid: Self.uuidBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) })
        #expect(BuildIdentity.of(binary: both) == mine.uuidString)

        let foreign = try write(fat([(otherCPU, thinImage(uuid: other, cpu: otherCPU))]))
        defer { try? FileManager.default.removeItem(at: foreign) }
        #expect(BuildIdentity.of(binary: foreign) == nil)

        // Two slices of this Mac's type (arm64 + arm64e): which runs is the
        // kernel's call, so the build is unknown rather than a guess.
        let twin = try write(fat([
            (BuildIdentity.hostCPUType, thinImage(cpu: BuildIdentity.hostCPUType)),
            (BuildIdentity.hostCPUType, thinImage(uuid: other, cpu: BuildIdentity.hostCPUType)),
        ]))
        defer { try? FileManager.default.removeItem(at: twin) }
        #expect(BuildIdentity.of(binary: twin) == nil)
    }

    @Test("garbage, truncation and a missing file are nil, never a crash")
    func malformed() throws {
        #expect(BuildIdentity.uuid(inImage: Data()) == nil)
        #expect(BuildIdentity.uuid(inImage: Data(thinImage().prefix(40))) == nil)
        let text = try write(Data("#!/bin/sh\necho hi\n".utf8))
        defer { try? FileManager.default.removeItem(at: text) }
        #expect(BuildIdentity.of(binary: text) == nil)
        #expect(BuildIdentity.of(binary: URL(fileURLWithPath: "/nonexistent/usaged")) == nil)
    }

    @Test("the running image's identity is its own file's")
    func runningMatchesItsFile() throws {
        let running = try #require(BuildIdentity.running())
        var size = UInt32(4096)
        var buffer = [CChar](repeating: 0, count: Int(size))
        #expect(_NSGetExecutablePath(&buffer, &size) == 0)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath()
        #expect(BuildIdentity.of(binary: path) == running)
    }

    // MARK: - The marker

    @Test("the marker round-trips; an empty or torn file is unknown")
    func marker() throws {
        let marker = DaemonMarker(pid: 4242, version: "0.104.0", build: "ABC")
        #expect(DaemonMarker.decode(marker.encoded()) == marker)
        #expect(DaemonMarker.decode(Data()) == nil)  // a pre-content daemon's file
        #expect(DaemonMarker.decode(Data(marker.encoded().prefix(10))) == nil)
        let current = DaemonMarker.current()
        #expect(current.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(current.version == AppIdentity.version)
        #expect(current.build == BuildIdentity.running())
    }
}
