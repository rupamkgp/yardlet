import Foundation

/// A file named so that the same file in a repository's main checkout and in its worktrees is one:
/// the repository's main folder and the path inside the checkout. A file outside
/// any repository is its own path.
struct FileRepositoryKey: Hashable, Sendable {
    /// The main checkout's folder; nil outside any repository.
    let repository: String?
    /// Inside the checkout when `repository` is set, else the whole path.
    let path: String
}

/// Reads paths into `FileRepositoryKey`s, looking at each folder on the way up from the path, the
/// nearest first:
///
/// 1. a folder a task worked in as a worktree, with the folder it was made from (`knownWorktrees`, the
///    tasks' `origin_workspace_path`), which holds when the worktree is gone;
/// 2. Claude Code's worktree folder, `<repository>/.claude/worktrees/<name>`, also once it is gone;
/// 3. a `.git` folder (a main checkout), or a `.git` file naming the main checkout's `.git` folder (a
///    linked worktree, through its `commondir`) or its own (a submodule).
///
/// Only names on disk are looked at and two small Git files read; no Git command runs. Folders already
/// read are remembered.
struct FileRepositoryResolver {
    /// A worktree's folder and the main checkout it was made from, both standardized.
    let knownWorktrees: [String: String]
    private var checkouts: [String: Checkout?] = [:]

    private struct Checkout: Equatable {
        let folder: String
        let repository: String
    }

    init(knownWorktrees: [String: String] = [:]) {
        self.knownWorktrees = knownWorktrees
    }

    mutating func key(for path: String) -> FileRepositoryKey {
        let standardized = Self.standardized(path)
        guard let checkout = checkout(containing: Self.parent(of: standardized)) else {
            return FileRepositoryKey(repository: nil, path: standardized)
        }
        let inside = standardized == checkout.folder ? "" : String(standardized.dropFirst(checkout.folder.count + 1))
        return FileRepositoryKey(repository: checkout.repository, path: inside)
    }

    /// The repository a folder is in: its main folder, or the folder itself outside any repository.
    mutating func repository(of folder: String) -> String {
        let standardized = Self.standardized(folder)
        return checkout(containing: standardized)?.repository ?? standardized
    }

    private mutating func checkout(containing folder: String) -> Checkout? {
        var visited: [String] = []
        var current = folder
        var found: Checkout?
        while true {
            if let known = checkouts[current] { found = known; break }
            visited.append(current)
            if let checkout = Self.checkout(at: current, knownWorktrees: knownWorktrees) { found = checkout; break }
            let parent = Self.parent(of: current)
            if parent == current { break }
            current = parent
        }
        for folder in visited { checkouts[folder] = found }
        return found
    }

    private static func checkout(at folder: String, knownWorktrees: [String: String]) -> Checkout? {
        if let origin = knownWorktrees[folder] { return Checkout(folder: folder, repository: origin) }
        let parts = folder.split(separator: "/")
        if parts.count >= 3, parts[parts.count - 2] == "worktrees", parts[parts.count - 3] == ".claude" {
            return Checkout(folder: folder, repository: "/" + parts.dropLast(3).joined(separator: "/"))
        }
        let marker = folder == "/" ? "/.git" : folder + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return Checkout(folder: folder, repository: folder) }
        return Checkout(folder: folder, repository: mainCheckout(gitFile: marker) ?? folder)
    }

    /// The main checkout a linked worktree's `.git` file leads to: `gitdir: <main>/.git/worktrees/<name>`,
    /// whose `commondir` names `<main>/.git`. Nil for a `.git` file of anything else (a submodule).
    private static func mainCheckout(gitFile: String) -> String? {
        guard let text = try? String(contentsOfFile: gitFile, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitURL = URL(filePath: gitdir, directoryHint: .isDirectory,
                         relativeTo: URL(filePath: parent(of: gitFile), directoryHint: .isDirectory))
        guard let common = try? String(contentsOf: gitURL.appending(path: "commondir"), encoding: .utf8) else { return nil }
        let commonURL = URL(filePath: common.trimmingCharacters(in: .whitespacesAndNewlines),
                            directoryHint: .isDirectory, relativeTo: gitURL).standardizedFileURL
        guard commonURL.lastPathComponent == ".git" else { return nil }
        return standardized(commonURL.deletingLastPathComponent().path(percentEncoded: false))
    }

    static func standardized(_ path: String) -> String {
        let value = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
        return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        return slash == path.startIndex ? "/" : String(path[..<slash])
    }
}
