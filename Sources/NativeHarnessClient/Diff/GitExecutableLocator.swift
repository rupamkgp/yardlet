import Foundation

enum GitExecutableLocator {
    static let standardPaths = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/opt/local/bin/git"
    ]

    // GUI launches do not inherit the user's shell PATH. Prefer an independently
    // installed Git, without executing a shell or searching the workspace.
    static func preferredURL(
        candidates: [String] = standardPaths,
        isExecutableFile: (String) -> Bool = isExecutableFile
    ) -> URL {
        URL(filePath: candidates.first(where: isExecutableFile) ?? "/usr/bin/git")
    }

    /// What every Git Yardlet runs is started with: the app's environment with a harness's PATH
    /// (`RuntimeProcessEnvironment`: Git's own folder, Homebrew, `/usr/local/bin`, `~/.local/bin`),
    /// then `overrides`. Git starts programs of its own by name: Git LFS's filter on a checkout or a
    /// status, a credential helper, a signing program. A GUI launch's PATH has only the system's
    /// folders, so with it a Homebrew Git cannot find the `git-lfs` installed beside it, and a
    /// checkout in a repository with LFS files fails with "the remote end hung up unexpectedly".
    static func environment(for executableURL: URL, overrides: [String: String] = [:]) -> [String: String] {
        RuntimeProcessEnvironment.values(executableURL: executableURL, overrides: overrides)
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}
