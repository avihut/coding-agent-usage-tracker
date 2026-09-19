import Foundation
import Testing

@testable import UsageCore

/// Holds this tree's digest to ANOTHER ref's goldens — the merge gate's
/// half of "FROZEN, additive-only forever".
///
/// `LiveStateTests.golden` can't hold that line alone: the golden is
/// regenerated in place, so on any one branch the code and its golden
/// always agree, and a breaking change plus `UPDATE_GOLDENS=1` passes both
/// suites. Only the other side of a merge still has the old file. The gate
/// (daft.yml pre-merge, or `mise run digest-freeze`) exports the target
/// branch's goldens with scripts/digest-baseline.sh and names the directory
/// in `DIGEST_BASELINE_DIR`; without it there is no baseline and these
/// tests don't run.
@Suite("Digest freeze")
struct DigestFreezeTests {
    private static let baselineDirectory: URL? =
        ProcessInfo.processInfo.environment["DIGEST_BASELINE_DIR"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

    private static var baselines: [URL] {
        guard let baselineDirectory else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: baselineDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted()
            .map { baselineDirectory.appending(path: $0) }
    }

    private var currentGoldens: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/digest")
    }

    /// Every key path a JSON value carries, arrays flattened to `[]` so a
    /// list's elements pool their keys (one element lacking an optional
    /// field is not a removal).
    private func keyPaths(_ value: Any, under prefix: String = "") -> Set<String> {
        switch value {
        case let object as [String: Any]:
            return object.reduce(into: []) { paths, entry in
                let path = prefix.isEmpty ? entry.key : "\(prefix).\(entry.key)"
                paths.insert(path)
                paths.formUnion(keyPaths(entry.value, under: path))
            }
        case let list as [Any]:
            return list.reduce(into: []) { $0.formUnion(keyPaths($1, under: "\(prefix)[]")) }
        default:
            return []
        }
    }

    /// New code reads old digests: a field added as non-optional makes a
    /// digest written before it fail to decode WHOLESALE (the
    /// `SessionCard.end` lesson, v0.84.0).
    @Test("this tree's decoder reads every baseline golden",
          .enabled(if: baselineDirectory != nil))
    func decoderReadsTheBaseline() throws {
        for baseline in Self.baselines {
            let data = try Data(contentsOf: baseline)
            #expect(throws: Never.self, "\(baseline.lastPathComponent) no longer decodes") {
                _ = try LiveState.decoder().decode(LiveState.self, from: data)
            }
        }
    }

    /// Old readers keep working: nothing the baseline put on the wire was
    /// removed or renamed. A key that vanished because the FIXTURE changed
    /// (an optional now nil) trips this too — restore it in the fixture; the
    /// golden is the wire's record.
    @Test("every key the baseline golden carries is still on the wire",
          .enabled(if: baselineDirectory != nil))
    func nothingLeftTheWire() throws {
        for baseline in Self.baselines {
            let name = baseline.lastPathComponent
            let current = currentGoldens.appending(path: name)
            guard FileManager.default.fileExists(atPath: current.path) else {
                Issue.record("the golden \(name) was deleted — goldens are additive-only")
                continue
            }
            let before = keyPaths(try JSONSerialization.jsonObject(with: Data(contentsOf: baseline)))
            let after = keyPaths(try JSONSerialization.jsonObject(with: Data(contentsOf: current)))
            let removed = before.subtracting(after).sorted()
            #expect(removed.isEmpty, "\(name) lost keys the baseline carries: \(removed)")
        }
    }
}
