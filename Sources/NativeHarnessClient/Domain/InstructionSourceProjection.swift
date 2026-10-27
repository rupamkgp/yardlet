import Foundation

/// What the task information surface can honestly say about instruction files.
/// Yardlet never merges, copies, or creates them — it only reports.
struct TaskInstructionSources: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// The provider reported the files it loaded for this thread.
        case provider
        /// Yardlet only checked which instruction files exist in the cwd chain and the extra
        /// roots. It cannot claim the harness read them.
        case detected
    }

    var origin: Origin
    var paths: [String]

    var isEmpty: Bool { paths.isEmpty }
}

enum InstructionSourceProjection {
    static let fileNames = ["AGENTS.md", "CLAUDE.md"]

    /// Instruction files that exist in the cwd's folder chain and in each extra root. The order
    /// is deterministic: the cwd chain from the innermost folder outwards, then the extra roots
    /// in the order the task recorded them.
    static func existingPaths(
        cwd: URL,
        additionalRoots: [URL] = [],
        fileNames: [String] = fileNames,
        fileManager: FileManager = .default
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        func append(_ directory: URL) {
            for name in fileNames {
                let candidate = directory.appending(path: name).standardizedFileURL
                let path = candidate.path(percentEncoded: false)
                guard fileManager.fileExists(atPath: path), seen.insert(path).inserted else { continue }
                result.append(path)
            }
        }

        for directory in folderChain(from: cwd) { append(directory) }
        for root in additionalRoots { append(root.standardizedFileURL) }
        return result
    }

    /// The cwd and each of its ancestors, innermost first.
    static func folderChain(from cwd: URL) -> [URL] {
        var chain: [URL] = []
        var current = cwd.standardizedFileURL
        while true {
            chain.append(current)
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if ProjectSidebarPresentation.normalizedPath(for: parent)
                == ProjectSidebarPresentation.normalizedPath(for: current) { break }
            current = parent
        }
        return chain
    }

    /// The provider's own answer wins; otherwise report what exists without claiming it was read.
    static func sources(
        providerReported: [String]?,
        cwd: URL,
        additionalRoots: [URL],
        fileManager: FileManager = .default
    ) -> TaskInstructionSources {
        if let providerReported {
            return TaskInstructionSources(origin: .provider, paths: providerReported)
        }
        return TaskInstructionSources(
            origin: .detected,
            paths: existingPaths(
                cwd: cwd,
                additionalRoots: additionalRoots,
                fileManager: fileManager
            )
        )
    }
}
