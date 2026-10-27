import Foundation

/// A JavaScript dialog opened while a tool waited on the page. The page is paused until the
/// agent answers it, so the tool reports the dialog instead of waiting out its time limit.
struct BrowserAgentDialogOpened: Error {}

/// Lets exactly one of two racing callbacks resume a continuation.
@MainActor
final class BrowserAgentOnce {
    private var isClaimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}

/// Files the agent may hand to a page's file chooser: only inside the task's project folders,
/// after `..` and symbolic links are resolved, so an upload cannot reach the rest of the disk.
enum BrowserAgentWorkspaceFile {
    static func resolve(_ path: String, roots: [URL], mode: BrowserFileDialog.Mode) throws -> String {
        guard let primary = roots.first else {
            throw BrowserAgentToolError("This task has no project folder, so no file can be uploaded.")
        }
        let requested = path.hasPrefix("/") ? URL(filePath: path) : primary.appending(path: path)
        let standardized = requested.standardizedFileURL
        // A file to be saved need not exist yet; its folder must.
        let resolved = mode == .save
            ? standardized.deletingLastPathComponent().resolvingSymlinksInPath()
                .appending(path: standardized.lastPathComponent)
            : standardized.resolvingSymlinksInPath()
        let resolvedRoots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        guard resolvedRoots.contains(where: { contains($0, resolved) }) else {
            throw BrowserAgentToolError("\(path) is outside this task's project folders.")
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved.path(percentEncoded: false), isDirectory: &isDirectory)
        switch mode {
        case .open, .openMultiple:
            guard exists, !isDirectory.boolValue else { throw BrowserAgentToolError("\(path) is not a file.") }
        case .openFolder:
            guard exists, isDirectory.boolValue else { throw BrowserAgentToolError("\(path) is not a folder.") }
        case .save:
            var parentIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: resolved.deletingLastPathComponent().path(percentEncoded: false), isDirectory: &parentIsDirectory
            ), parentIsDirectory.boolValue, !isDirectory.boolValue else {
                throw BrowserAgentToolError("\(path) cannot be saved there.")
            }
        }
        return resolved.path(percentEncoded: false)
    }

    /// Compares whole path components, so `/work/app` does not contain `/work/application`.
    static func contains(_ root: URL, _ candidate: URL) -> Bool {
        let rootComponents = root.pathComponents
        let components = candidate.pathComponents
        return components.count >= rootComponents.count && Array(components.prefix(rootComponents.count)) == rootComponents
    }
}
