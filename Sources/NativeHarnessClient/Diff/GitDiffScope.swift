import Foundation

enum GitDiffScope: String, CaseIterable, Codable, Sendable {
    case unstaged, staged, commit, branch
    /// The most recent turn's changes as the provider reported them, not read from git. Only Codex
    /// reports a turn's diff, so only Codex tasks offer it, as the Codex app does.
    case lastTurn

    var displayName: String {
        switch self {
        case .unstaged: L10n.string("Unstaged")
        case .staged: L10n.string("Staged")
        case .commit: L10n.string("Commit")
        case .branch: L10n.string("Branch")
        case .lastTurn: L10n.string("Last turn")
        }
    }

    var emptyTitle: String {
        switch self {
        case .unstaged: L10n.string("No unstaged changes")
        case .staged: L10n.string("No staged changes")
        case .commit: L10n.string("No changes in this commit")
        case .branch: L10n.string("No branch changes")
        case .lastTurn: L10n.string("No changes in the last turn")
        }
    }

    /// The scopes a task's review offers.
    static func offered(includingLastTurn: Bool) -> [GitDiffScope] {
        allCases.filter { $0 != .lastTurn || includingLastTurn }
    }
}

struct DiffReviewPreferences: Codable, Equatable {
    var scope: GitDiffScope = .unstaged
    var selectedPaths: [GitDiffScope: String] = [:]
    // Optional so review preferences saved before the Commit scope and the repository menu decode.
    /// The full hash picked for the Commit scope. Nil follows the latest commit.
    var commit: String?
    /// The repository picked when the task's folders hold more than one. Nil is the first of them.
    var repositoryPath: String?
    /// A Markdown file's change is drawn rendered rather than line by line (`MarkdownReviewDiff`).
    /// Nil is the line diff, which reviews saved before the rendered view read as.
    var rendersMarkdown: Bool?

    var selectedPath: String? {
        get { selectedPaths[scope] }
        set { selectedPaths[scope] = newValue }
    }

    /// The folder the review reads. With fewer than two repositories this is the task folder, as
    /// before the menu existed. A remembered repository that is no longer among them is dropped.
    mutating func resolveRepository(among repositories: [URL], workspaceURL: URL) -> URL {
        guard repositories.count > 1 else {
            repositoryPath = nil
            return workspaceURL
        }
        if let match = repositories.first(where: { $0.path(percentEncoded: false) == repositoryPath }) {
            return match
        }
        repositoryPath = nil
        return repositories[0]
    }

    /// The commit the Commit scope shows. A remembered commit that is no longer listed is dropped,
    /// which returns the review to the latest commit.
    mutating func resolveCommit(among commits: [GitCommitSummary]) -> GitCommitSummary? {
        if let match = commits.first(where: { $0.id == commit }) { return match }
        commit = nil
        return commits.first
    }
}
