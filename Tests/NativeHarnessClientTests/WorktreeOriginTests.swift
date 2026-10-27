import Foundation
import XCTest
@testable import NativeHarnessClient

/// Worktree origin is decided from Git's own on-disk records. These checks use a throwaway
/// repository under the temporary directory — never the user's `~/.yardlet` or any real
/// checkout — plus written-out layouts for the cases a real repository cannot produce.
final class WorktreeOriginTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The temporary directory is reached through a symlink on macOS; Git records the real
        // path, so resolve once here and keep every comparison on the same spelling.
        root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-worktree-origin-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - A real repository and a real `git worktree add`

    func testWorktreeRecordsItsOriginRepositoryNameAndBranch() throws {
        let repository = try makeRepository(named: "origin-repo", branch: "main")
        let worktree = root.appending(path: "feature-work", directoryHint: .isDirectory)
        try runGit(["worktree", "add", "-b", "feature-x", worktree.path(percentEncoded: false)], in: repository)

        let resolved = GitWorktreeOriginResolver.resolve(workspaceURL: worktree)

        XCTAssertEqual(
            resolved.originWorkspacePath,
            ProjectSidebarPresentation.normalizedPath(for: repository)
        )
        XCTAssertEqual(resolved.worktreeName, "feature-work")
        XCTAssertEqual(resolved.branch, "feature-x")
        XCTAssertTrue(resolved.isWorktree)
    }

    func testAFolderInsideAWorktreeResolvesToTheSameOrigin() throws {
        let repository = try makeRepository(named: "nested-origin", branch: "main")
        let worktree = root.appending(path: "nested-work", directoryHint: .isDirectory)
        try runGit(["worktree", "add", "-b", "nested-x", worktree.path(percentEncoded: false)], in: repository)
        let inner = worktree.appending(path: "Sources/Feature", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        let resolved = GitWorktreeOriginResolver.resolve(workspaceURL: inner)

        XCTAssertEqual(
            resolved.originWorkspacePath,
            ProjectSidebarPresentation.normalizedPath(for: repository)
        )
        XCTAssertEqual(resolved.worktreeName, "nested-work", "The worktree folder names the task, not the cwd")
        XCTAssertEqual(resolved.branch, "nested-x")
    }

    func testAnOrdinaryCheckoutKeepsNoOriginButRecordsItsBranch() throws {
        let repository = try makeRepository(named: "plain-repo", branch: "main")

        let resolved = GitWorktreeOriginResolver.resolve(workspaceURL: repository)

        XCTAssertNil(resolved.originWorkspacePath, "A repository is not a worktree of anything")
        XCTAssertNil(resolved.worktreeName)
        XCTAssertEqual(resolved.branch, "main")
        XCTAssertFalse(resolved.isWorktree)
    }

    // MARK: - Written-out layouts and failures

    func testAFolderOutsideGitResolvesToNothing() throws {
        let plain = root.appending(path: "no-repository-here", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        XCTAssertEqual(GitWorktreeOriginResolver.resolve(workspaceURL: plain), .none)
    }

    func testUnreadableGitMetadataResolvesToNothingInsteadOfGuessing() {
        let silent = GitMetadataReader(kind: { _ in nil }, text: { _ in nil })
        XCTAssertEqual(
            GitWorktreeOriginResolver.resolve(workspaceURL: URL(filePath: "/tmp/anything"), reader: silent),
            .none
        )

        // A `.git` file Git would reject leaves the folder with no origin at all.
        let damaged = GitMetadataReader(
            kind: { $0 == "/tmp/broken/.git" ? .file : nil },
            text: { _ in "not a gitdir line\n" }
        )
        XCTAssertEqual(
            GitWorktreeOriginResolver.resolve(workspaceURL: URL(filePath: "/tmp/broken"), reader: damaged),
            .none
        )
    }

    func testASubmoduleIsNotTreatedAsAWorktreeOfItsSuperproject() {
        let reader = GitMetadataReader(
            kind: { $0 == "/repo/vendor/lib/.git" ? .file : nil },
            text: { path in
                switch path {
                case "/repo/vendor/lib/.git": "gitdir: /repo/.git/modules/vendor/lib\n"
                case "/repo/.git/modules/vendor/lib/HEAD": "ref: refs/heads/main\n"
                default: nil
                }
            }
        )

        let resolved = GitWorktreeOriginResolver.resolve(
            workspaceURL: URL(filePath: "/repo/vendor/lib"),
            reader: reader
        )

        XCTAssertNil(resolved.originWorkspacePath)
        XCTAssertNil(resolved.worktreeName)
        XCTAssertEqual(resolved.branch, "main")
    }

    func testARelativeGitdirAndCommondirStillNameTheOriginRepository() {
        let reader = GitMetadataReader(
            kind: { $0 == "/work/trees/blue/.git" ? .file : nil },
            text: { path in
                switch path {
                case "/work/trees/blue/.git": "gitdir: ../../repo/.git/worktrees/blue\n"
                case "/work/repo/.git/worktrees/blue/commondir": "../..\n"
                case "/work/repo/.git/worktrees/blue/HEAD": "ref: refs/heads/blue-branch\n"
                default: nil
                }
            }
        )

        let resolved = GitWorktreeOriginResolver.resolve(
            workspaceURL: URL(filePath: "/work/trees/blue"),
            reader: reader
        )

        XCTAssertEqual(resolved.originWorkspacePath, "/work/repo")
        XCTAssertEqual(resolved.worktreeName, "blue")
        XCTAssertEqual(resolved.branch, "blue-branch")
    }

    func testADetachedWorktreeKeepsItsOriginWithoutABranch() {
        let reader = GitMetadataReader(
            kind: { $0 == "/work/detached/.git" ? .file : nil },
            text: { path in
                switch path {
                case "/work/detached/.git": "gitdir: /work/repo/.git/worktrees/detached\n"
                case "/work/repo/.git/worktrees/detached/HEAD":
                    "9f1a0c2b4e6d8f0a2c4e6d8f0a2c4e6d8f0a2c4e\n"
                default: nil
                }
            }
        )

        let resolved = GitWorktreeOriginResolver.resolve(
            workspaceURL: URL(filePath: "/work/detached"),
            reader: reader
        )

        XCTAssertEqual(resolved.originWorkspacePath, "/work/repo")
        XCTAssertEqual(resolved.worktreeName, "detached")
        XCTAssertNil(resolved.branch, "A detached HEAD names no branch")
    }

    // MARK: - What the sidebar row says

    func testSidebarShowsTheWorktreeNameAndLeavesOrdinaryRowsAlone() {
        let worktreeTask = session(
            workspaceURL: URL(filePath: "/work/trees/blue"),
            originWorkspacePath: "/work/repo",
            worktreeName: "blue",
            branch: "blue-branch"
        )
        XCTAssertEqual(SidebarWorktreeProjection.detail(for: worktreeTask), "blue")

        let unnamed = session(
            workspaceURL: URL(filePath: "/work/trees/green"),
            originWorkspacePath: "/work/repo",
            worktreeName: nil,
            branch: "green-branch"
        )
        XCTAssertEqual(
            SidebarWorktreeProjection.detail(for: unnamed),
            "green-branch",
            "A worktree with no recorded name falls back to its branch"
        )

        let ordinary = session(
            workspaceURL: URL(filePath: "/work/repo"),
            originWorkspacePath: nil,
            worktreeName: nil,
            branch: "main"
        )
        XCTAssertNil(
            SidebarWorktreeProjection.detail(for: ordinary),
            "A task in an ordinary checkout gains no second line"
        )
    }

    // MARK: - Fixtures

    private func session(
        workspaceURL: URL,
        originWorkspacePath: String?,
        worktreeName: String?,
        branch: String?
    ) -> SessionRecord {
        SessionRecord(
            harness: .codex,
            workspaceURL: workspaceURL,
            runtimeExecutableURL: URL(filePath: "/tmp/codex"),
            title: "Task",
            originWorkspacePath: originWorkspacePath,
            worktreeName: worktreeName,
            branch: branch
        )
    }

    private func makeRepository(named name: String, branch: String) throws -> URL {
        let repository = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try runGit(["init"], in: repository)
        try runGit(["symbolic-ref", "HEAD", "refs/heads/\(branch)"], in: repository)
        try Data("seed\n".utf8).write(to: repository.appending(path: "README.md"))
        try runGit(["add", "-A"], in: repository)
        try runGit(["commit", "-m", "Seed the repository"], in: repository)
        return repository
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let executable = GitExecutableLocator.preferredURL()
        guard FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
            throw XCTSkip("No Git executable is available to build the fixture repository")
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // The fixture must not read or write the user's Git configuration.
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "Yardlet Fixture"
        environment["GIT_AUTHOR_EMAIL"] = "fixture@yardlet.invalid"
        environment["GIT_COMMITTER_NAME"] = "Yardlet Fixture"
        environment["GIT_COMMITTER_EMAIL"] = "fixture@yardlet.invalid"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("git \(arguments.first ?? "") failed in the fixture repository")
        }
    }
}
