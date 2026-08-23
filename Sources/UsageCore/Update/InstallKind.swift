import Foundation

/// How this copy of the app got onto the machine — the filesystem sniff
/// `Distribution` builds its channel from.
///
/// A bundle sitting inside a git checkout is the developer's own build: its
/// update path runs through git, and overwriting it with a release download
/// would clobber a working tree's product — `sourceManaged` carries the
/// checkout root so the channel can say more than "somewhere in a repo".
/// A bundle anywhere else (typically /Applications) is a standalone
/// release install. A bare executable (tests, `swift run`) is neither and
/// belongs to no distribution channel at all.
public enum InstallKind: Sendable, Equatable {
    case standaloneApp
    case sourceManaged(root: URL)
    case notAnApp

    public static func detect(
        bundleURL: URL, fileManager: FileManager = .default
    ) -> InstallKind {
        guard bundleURL.pathExtension == "app" else { return .notAnApp }
        // Walk the ancestors for a `.git` — a directory in a plain clone, a
        // FILE in a worktree, so existence is the test, not directory-ness.
        // Terminate on the component count, NOT on parent == self:
        // `deletingLastPathComponent()` of "/" yields "/../" forever, and
        // that spin is exactly the standalone (/Applications) path.
        var directory = bundleURL.deletingLastPathComponent().standardizedFileURL
        while true {
            let marker = directory.appending(path: ".git")
            if fileManager.fileExists(atPath: marker.path) {
                return .sourceManaged(root: directory)
            }
            guard directory.pathComponents.count > 1 else { break }
            directory = directory.deletingLastPathComponent()
        }
        return .standaloneApp
    }
}
