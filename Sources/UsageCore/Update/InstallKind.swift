import Foundation

/// How this copy of the app got onto the machine — the gate that decides
/// whether the self-updater runs at all.
///
/// A bundle sitting inside a git checkout is the developer's own build: its
/// update path is `git pull`, and offering to overwrite it with a release
/// download would clobber a working tree's product. A bundle anywhere else
/// (typically /Applications) is a standalone install — the GitHub-release
/// audience the updater exists for. A bare executable (tests, `swift run`)
/// is neither and gets no updater.
public enum InstallKind: Sendable, Equatable {
    case standaloneApp
    case sourceManaged
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
            if fileManager.fileExists(atPath: marker.path) { return .sourceManaged }
            guard directory.pathComponents.count > 1 else { break }
            directory = directory.deletingLastPathComponent()
        }
        return .standaloneApp
    }
}
