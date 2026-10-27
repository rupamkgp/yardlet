import Foundation

/// A branch that never shipped gave each Antigravity turn a Yardlet folder through `--add-dir`
/// (`~/Library/Caches/com.zzunkie.yardlet/antigravity/<task>/`, an approval hook and Yardlet's MCP
/// server). It was removed because Antigravity CLI records that folder in the conversation and
/// revives it when the conversation continues outside Yardlet. Launch removes the folder if a
/// development or QA run left one. Nothing else under Caches is touched, and never `~/.gemini`.
enum AntigravityLeftoverFolder {
    static let name = "antigravity"

    static func url(cachesDirectory: URL) -> URL {
        cachesDirectory
            .appending(path: YardletProduct.bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
    }

    /// True when a folder was there and is now gone.
    @discardableResult
    static func removeIfPresent(cachesDirectory: URL?, fileManager: FileManager = .default) -> Bool {
        guard let cachesDirectory else { return false }
        let folder = url(cachesDirectory: cachesDirectory)
        guard fileManager.fileExists(atPath: folder.path(percentEncoded: false)) else { return false }
        return (try? fileManager.removeItem(at: folder)) != nil
    }
}
