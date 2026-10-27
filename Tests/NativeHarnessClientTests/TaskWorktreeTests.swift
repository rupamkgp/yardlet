import Foundation
import XCTest
@testable import NativeHarnessClient

/// A throwaway repository and worktree folder under the temporary directory — never the user's
/// `~/.yardlet` or a real checkout — and Git run without the user's configuration or hooks.
struct WorktreeFixture {
    let root: URL
    let layout: TaskWorktreeLayout

    static let gitEnvironment = [
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "Fixture",
        "GIT_AUTHOR_EMAIL": "fixture@example.test",
        "GIT_COMMITTER_NAME": "Fixture",
        "GIT_COMMITTER_EMAIL": "fixture@example.test"
    ]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-task-worktree-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = TaskWorktreeLayout(rootURL: root.appending(path: "worktrees", directoryHint: .isDirectory))
    }

    func service(timeout: Duration = .seconds(30)) -> TaskWorktreeService {
        TaskWorktreeService(layout: layout, timeout: timeout, checkoutTimeout: timeout,
                            environment: Self.gitEnvironment)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A repository with one commit on `main`, holding `README.md` and `app/main.txt`.
    func makeRepository(named name: String = "Sample Repo") throws -> URL {
        let repository = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository.appending(path: "app"), withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: repository)
        try write("seed\n", to: "README.md", in: repository)
        try write("app\n", to: "app/main.txt", in: repository)
        try write(".build/\n", to: ".gitignore", in: repository)
        try commit("Seed", in: repository)
        return repository
    }

    func write(_ text: String, to path: String, in folder: URL) throws {
        let url = folder.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func commit(_ message: String, in folder: URL) throws {
        try git(["add", "-A"], in: folder)
        try git(["commit", "-q", "-m", message], in: folder)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL, allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = GitExecutableLocator.preferredURL()
        process.arguments = ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(Self.gitEnvironment) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0, !allowFailure {
            throw XCTSkip("git \(arguments.joined(separator: " ")) failed in the fixture repository")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func branchExists(_ branch: String, in repository: URL) throws -> Bool {
        try !git(["for-each-ref", "--format=%(refname)", "refs/heads/" + branch], in: repository).isEmpty
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}

final class TaskWorktreeTests: XCTestCase {
    private var fixture: WorktreeFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try WorktreeFixture()
    }

    override func tearDown() {
        fixture?.remove()
        fixture = nil
        super.tearDown()
    }

    // MARK: - Naming and layout

    func testNamesAreShortReadableAndValidBranchNames() throws {
        XCTAssertEqual(TaskWorktreeNaming.slug(from: "Fix the login bug in the parser!"), "fix-the-login-bug",
                       "The first five words, without a dangling filler word")
        XCTAssertEqual(TaskWorktreeNaming.slug(from: "\n  Add   dark-mode toggle\n\nThen explain it"), "add-dark-mode-toggle",
                       "Only the first line names the task")
        XCTAssertEqual(TaskWorktreeNaming.slug(from: "로그인 버그 고쳐줘"), "logeu-in-beogeu-gochyeojwo",
                       "Korean is transliterated rather than dropped")
        XCTAssertEqual(TaskWorktreeNaming.slug(from: "Café naïve résumé"), "cafe-naive-resume")
        XCTAssertEqual(TaskWorktreeNaming.slug(from: "👩🏽‍💻🚀 ..."), "task")
        XCTAssertEqual(TaskWorktreeNaming.slug(from: ""), "task")
        XCTAssertEqual(TaskWorktreeNaming.slug(from: "../../.git/HEAD.lock"), "git-head-lock")
        let long = TaskWorktreeNaming.slug(from: String(repeating: "a", count: 90) + " tail")
        XCTAssertEqual(long.count, TaskWorktreeNaming.maximumLength)
        let words = TaskWorktreeNaming.slug(from: "Refactor the session repository so archived rows load faster")
        XCTAssertLessThanOrEqual(words.count, TaskWorktreeNaming.maximumLength)
        XCTAssertFalse(words.hasSuffix("-"))
        XCTAssertEqual(TaskWorktreeNaming.candidates(for: "fix").prefix(3), ["fix", "fix-2", "fix-3"])

        let repository = try fixture.makeRepository()
        for prompt in ["Fix the login bug", "로그인 버그 고쳐줘", "ログインのバグ", "--force", "a..b", "@{-1}", "x.lock"] {
            let branch = TaskWorktreeLayout.branchPrefix + TaskWorktreeNaming.slug(from: prompt)
            XCTAssertEqual(try fixture.git(["check-ref-format", "--branch", branch], in: repository), branch)
        }
    }

    func testOnlyFoldersExactlyInsideTheWorktreeFolderAreYardletWorktrees() {
        let layout = TaskWorktreeLayout(rootURL: URL(filePath: "/tmp/yardlet-home/.yardlet/worktrees"))
        let worktree = URL(filePath: "/tmp/yardlet-home/.yardlet/worktrees/sample-repo/fix-bug")
        XCTAssertEqual(layout.worktreeURL(containing: worktree)?.path(percentEncoded: false), worktree.path(percentEncoded: false) + "/")
        XCTAssertEqual(layout.worktreeURL(containing: worktree.appending(path: "app/src")), layout.worktreeURL(containing: worktree))
        XCTAssertNil(layout.worktreeURL(containing: URL(filePath: "/tmp/yardlet-home/.yardlet/worktrees/sample-repo")))
        XCTAssertNil(layout.worktreeURL(containing: URL(filePath: "/tmp/yardlet-home/.yardlet/worktrees")))
        XCTAssertNil(layout.worktreeURL(containing: URL(filePath: "/tmp/yardlet-home/.yardlet/worktrees-old/a/b")))
        XCTAssertNil(layout.worktreeURL(containing: URL(filePath: "/tmp/yardlet-home/projects/sample-repo")))
        XCTAssertEqual(
            TaskWorktreeLayout.live(homeURL: URL(filePath: "/Users/someone")).rootURL.path(percentEncoded: false),
            "/Users/someone/.yardlet/worktrees/"
        )
    }

    // MARK: - Creating

    func testCreatesALinkedWorktreeOnANewBranchFromHEADOutsideTheRepository() async throws {
        let repository = try fixture.makeRepository()
        try fixture.write("uncommitted\n", to: "README.md", in: repository)
        let head = try fixture.git(["rev-parse", "HEAD"], in: repository)
        let service = fixture.service()

        let worktree = try await service.create(from: repository, prompt: "Fix the login bug")

        let expected = fixture.layout.worktreeURL(repositoryFolder: "sample-repo", name: "fix-the-login-bug")
        XCTAssertEqual(worktree.worktreeURL.path(percentEncoded: false), ProjectSidebarPresentation.normalizedPath(for: expected))
        XCTAssertEqual(worktree.workspaceURL, worktree.worktreeURL)
        XCTAssertEqual(worktree.branch, "yardlet/fix-the-login-bug")
        XCTAssertEqual(worktree.baseCommit, head)
        XCTAssertEqual(try fixture.git(["rev-parse", "HEAD"], in: worktree.worktreeURL), head)
        XCTAssertEqual(try fixture.git(["symbolic-ref", "--short", "HEAD"], in: worktree.worktreeURL), "yardlet/fix-the-login-bug")
        XCTAssertEqual(try String(contentsOf: worktree.worktreeURL.appending(path: "README.md"), encoding: .utf8), "seed\n",
                       "The worktree starts from the commit, not the checkout's uncommitted edits")
        XCTAssertEqual(try fixture.git(["status", "--porcelain"], in: repository), "M README.md",
                       "The original checkout is left as it was")
        XCTAssertTrue(fixture.exists(fixture.layout.rootURL.appending(path: ".metadata_never_index")))

        // What the task records comes from Git's own files, as for any worktree.
        let origin = GitWorktreeOriginResolver.resolve(workspaceURL: worktree.workspaceURL)
        XCTAssertEqual(origin.originWorkspacePath, ProjectSidebarPresentation.normalizedPath(for: repository))
        XCTAssertEqual(origin.worktreeName, "fix-the-login-bug")
        XCTAssertEqual(origin.branch, "yardlet/fix-the-login-bug")

        let second = try await service.create(from: repository, prompt: "Fix the login bug")
        XCTAssertEqual(second.branch, "yardlet/fix-the-login-bug-2")
        XCTAssertEqual(second.worktreeURL.lastPathComponent, "fix-the-login-bug-2")

        // A worktree made from a worktree still belongs to, and is named after, the repository.
        let nested = try await service.create(from: worktree.workspaceURL, prompt: "Follow-up")
        XCTAssertEqual(nested.worktreeURL.deletingLastPathComponent().lastPathComponent, "sample-repo")
        XCTAssertEqual(GitWorktreeOriginResolver.resolve(workspaceURL: nested.workspaceURL).originWorkspacePath,
                       ProjectSidebarPresentation.normalizedPath(for: repository))
    }

    func testANameTakenByABranchFolderOrStaleRecordIsSkipped() async throws {
        let repository = try fixture.makeRepository()
        try fixture.git(["branch", "yardlet/review"], in: repository)
        let taken = fixture.layout.worktreeURL(repositoryFolder: "sample-repo", name: "review-2")
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        let stale = fixture.layout.worktreeURL(repositoryFolder: "sample-repo", name: "review-3")
        try fixture.git(["worktree", "add", "-q", "-b", "elsewhere", stale.path(percentEncoded: false)], in: repository)
        try FileManager.default.removeItem(at: stale)

        let worktree = try await fixture.service().create(from: repository, prompt: "Review")

        XCTAssertEqual(worktree.branch, "yardlet/review-4")
    }

    func testATaskStartedInASubfolderRunsInTheSameSubfolderOfTheWorktree() async throws {
        let repository = try fixture.makeRepository()

        let worktree = try await fixture.service().create(from: repository.appending(path: "app"), prompt: "Tidy app")

        XCTAssertEqual(worktree.workspaceURL.lastPathComponent, "app")
        XCTAssertEqual(worktree.workspaceURL.deletingLastPathComponent().path(percentEncoded: false),
                       worktree.worktreeURL.path(percentEncoded: false) + "/")
        XCTAssertTrue(fixture.exists(worktree.workspaceURL.appending(path: "main.txt")))
    }

    func testFailuresSayWhyAndLeaveNothingBehind() async throws {
        let service = fixture.service()
        let plain = fixture.root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        await assertThrows(TaskWorktreeError.notARepository) { _ = try await service.create(from: plain, prompt: "x") }

        let empty = fixture.root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try fixture.git(["init", "-q", "-b", "main"], in: empty)
        await assertThrows(TaskWorktreeError.noCommits) { _ = try await service.create(from: empty, prompt: "x") }

        // An untracked folder has no counterpart in a worktree made from HEAD.
        let repository = try fixture.makeRepository()
        let untracked = repository.appending(path: "scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: untracked, withIntermediateDirectories: true)
        await assertThrows(TaskWorktreeError.missingFolder("scratch")) {
            _ = try await service.create(from: untracked, prompt: "Scratch work")
        }
        XCTAssertFalse(try fixture.branchExists("yardlet/scratch-work", in: repository))
        XCTAssertFalse(fixture.exists(fixture.layout.worktreeURL(repositoryFolder: "sample-repo", name: "scratch-work")))

        // Git refuses the branch (a `yardlet` branch blocks every `yardlet/` name); its message is shown.
        try fixture.git(["branch", "yardlet"], in: repository)
        do {
            _ = try await service.create(from: repository, prompt: "Blocked")
            XCTFail("A refused branch must fail the creation")
        } catch let TaskWorktreeError.gitFailed(message) {
            XCTAssertTrue(message.contains("refs/heads/yardlet"), message)
            XCTAssertFalse(message.hasPrefix("fatal:"), "Git's own explanation, without its progress lines")
            XCTAssertEqual(TaskWorktreeError.gitFailed(message).localizedDescription,
                           L10n.format("Couldn't create the worktree: %@", message))
        }
        XCTAssertFalse(fixture.exists(fixture.layout.worktreeURL(repositoryFolder: "sample-repo", name: "blocked")))
        XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain"], in: repository)
            .components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.count, 1)
        XCTAssertFalse(fixture.exists(fixture.layout.rootURL.appending(path: "sample-repo")),
                       "An empty repository folder is not left behind")
    }

    /// Homebrew puts `git-lfs` beside its Git, and a GUI launch's PATH has neither folder. A checkout
    /// in a repository with LFS files starts the filter by name; unfound, Git says "the remote end
    /// hung up unexpectedly". Here a required filter lives only beside the Git that runs.
    func testGitFindsTheFilterProgramsInstalledBesideIt() async throws {
        let repository = try fixture.makeRepository()
        try fixture.write("*.dat filter=fixture\n", to: ".gitattributes", in: repository)
        try fixture.write("payload\n", to: "asset.dat", in: repository)
        try fixture.commit("Filtered asset", in: repository)
        try fixture.git(["config", "filter.fixture.smudge", "fixture-smudge"], in: repository)
        try fixture.git(["config", "filter.fixture.required", "true"], in: repository)
        let bin = fixture.root.appending(path: "bin", directoryHint: .isDirectory)
        try fixture.write("#!/bin/sh\nexec \(GitExecutableLocator.preferredURL().path(percentEncoded: false)) \"$@\"\n",
                          to: "git", in: bin)
        try fixture.write("#!/bin/sh\ncat\n", to: "fixture-smudge", in: bin)
        for name in ["git", "fixture-smudge"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: bin.appending(path: name).path(percentEncoded: false))
        }
        let service = TaskWorktreeService(layout: fixture.layout, executableURL: bin.appending(path: "git"),
                                          environment: WorktreeFixture.gitEnvironment)

        let worktree = try await service.create(from: repository, prompt: "Filtered")

        XCTAssertEqual(try String(contentsOf: worktree.worktreeURL.appending(path: "asset.dat"), encoding: .utf8), "payload\n")
    }

    /// A checkout needs no download, as in both apps: Git LFS's filter stays out of it, the files
    /// whose content this Mac has are filled from it, as the Claude app fills them, and the rest stay
    /// pointers and are counted for the notice. Needs Git LFS where Homebrew or a manual install puts it.
    func testLargeFilesComeFromThisMacAndTheRestStayPointers() async throws {
        guard let lfs = ["/opt/homebrew/bin/git-lfs", "/usr/local/bin/git-lfs"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("Git LFS is not installed")
        }
        let repository = try fixture.makeRepository()
        for (key, value) in [("filter.lfs.process", "\(lfs) filter-process"), ("filter.lfs.clean", "\(lfs) clean -- %f"),
                             ("filter.lfs.smudge", "\(lfs) smudge -- %f"), ("filter.lfs.required", "true")] {
            try fixture.git(["config", key, value], in: repository)
        }
        try fixture.write("*.bin filter=lfs diff=lfs merge=lfs -text\n", to: ".gitattributes", in: repository)
        try fixture.write(String(repeating: "kept here ", count: 500), to: "kept.bin", in: repository)
        try fixture.write(String(repeating: "never fetched ", count: 300), to: "missing.bin", in: repository)
        try fixture.commit("Large files", in: repository)
        // The content of one was never downloaded to this Mac.
        let pointer = try fixture.git(["cat-file", "-p", "HEAD:missing.bin"], in: repository)
        let oid = try XCTUnwrap(pointer.split(separator: "\n").first { $0.hasPrefix("oid sha256:") }?.dropFirst(11))
        try FileManager.default.removeItem(at: repository.appending(
            path: ".git/lfs/objects/\(oid.prefix(2))/\(oid.dropFirst(2).prefix(2))/\(oid)"))

        let worktree = try await fixture.service().create(from: repository, prompt: "Large files")

        XCTAssertEqual(try String(contentsOf: worktree.worktreeURL.appending(path: "kept.bin"), encoding: .utf8),
                       String(repeating: "kept here ", count: 500))
        XCTAssertTrue(try String(contentsOf: worktree.worktreeURL.appending(path: "missing.bin"), encoding: .utf8)
            .hasPrefix("version https://git-lfs.github.com/spec/v1"))
        XCTAssertEqual(worktree.largeFilesLeftAsPointers, 1)
    }

    func testAGitThatHangsTimesOutAndIsStopped() async throws {
        let repository = try fixture.makeRepository()
        let script = fixture.root.appending(path: "slow-git")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        let service = TaskWorktreeService(layout: fixture.layout, executableURL: script,
                                          timeout: .milliseconds(300), checkoutTimeout: .milliseconds(300))
        let started = ContinuousClock.now
        do {
            _ = try await service.create(from: repository, prompt: "Slow")
            XCTFail("A hanging Git must not hang the task start")
        } catch let TaskWorktreeError.gitFailed(message) {
            XCTAssertEqual(message, TaskWorktreeError.timedOut.localizedDescription)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
    }

    func testACheckoutCutOffByTheTimeoutIsTakenBack() async throws {
        let repository = try fixture.makeRepository()
        // Real Git, except that `worktree add` hangs once it has done its work.
        let script = fixture.root.appending(path: "hanging-add-git")
        try Data("""
            #!/bin/sh
            \(GitExecutableLocator.preferredURL().path(percentEncoded: false)) "$@"
            status=$?
            case " $* " in *" worktree add "*) sleep 30 ;; esac
            exit $status
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        let service = TaskWorktreeService(layout: fixture.layout, executableURL: script, timeout: .seconds(5),
                                          checkoutTimeout: .seconds(2), environment: WorktreeFixture.gitEnvironment)
        do {
            _ = try await service.create(from: repository, prompt: "Cut off")
            XCTFail("A checkout past its deadline must fail the creation")
        } catch let TaskWorktreeError.gitFailed(message) {
            XCTAssertEqual(message, TaskWorktreeError.timedOut.localizedDescription)
        }
        XCTAssertFalse(fixture.exists(fixture.layout.worktreeURL(repositoryFolder: "sample-repo", name: "cut-off")))
        XCTAssertFalse(try fixture.branchExists("yardlet/cut-off", in: repository))
        XCTAssertEqual(try fixture.git(["worktree", "list", "--porcelain"], in: repository)
            .components(separatedBy: "\n").filter { $0.hasPrefix("worktree ") }.count, 1)
    }

    // MARK: - Archive clean-up

    func testACleanWorktreeIsRemovedAndItsBranchKept() async throws {
        let repository = try fixture.makeRepository()
        let service = fixture.service()
        let worktree = try await service.create(from: repository, prompt: "Clean")
        // Ignored build output is not work.
        try fixture.write("artifact", to: ".build/out.o", in: worktree.worktreeURL)

        let result = await service.cleanUp(workspaceURL: worktree.workspaceURL, recordedBranch: worktree.branch)

        XCTAssertEqual(result, .removed)
        XCTAssertFalse(fixture.exists(worktree.worktreeURL))
        XCTAssertFalse(fixture.exists(worktree.worktreeURL.deletingLastPathComponent()))
        XCTAssertTrue(try fixture.branchExists(worktree.branch, in: repository), "The branch stays for unarchiving")
    }

    func testUncommittedOrUntrackedWorkKeepsTheWorktree() async throws {
        let repository = try fixture.makeRepository()
        let service = fixture.service()
        let modified = try await service.create(from: repository, prompt: "Modified")
        try fixture.write("edited\n", to: "README.md", in: modified.worktreeURL)
        let untracked = try await service.create(from: repository, prompt: "Untracked")
        try fixture.write("new\n", to: "notes.txt", in: untracked.worktreeURL)
        let staged = try await service.create(from: repository, prompt: "Staged")
        try fixture.write("staged\n", to: "app/main.txt", in: staged.worktreeURL)
        try fixture.git(["add", "-A"], in: staged.worktreeURL)

        for worktree in [modified, untracked, staged] {
            let result = await service.cleanUp(workspaceURL: worktree.workspaceURL, recordedBranch: worktree.branch)
            XCTAssertEqual(result, .keptUncommittedChanges, worktree.branch)
            XCTAssertTrue(fixture.exists(worktree.worktreeURL))
        }
        XCTAssertEqual(try String(contentsOf: modified.worktreeURL.appending(path: "README.md"), encoding: .utf8), "edited\n")
    }

    func testCommitsNoOtherBranchHasKeepTheWorktreeUntilTheyAreMerged() async throws {
        let repository = try fixture.makeRepository()
        let service = fixture.service()
        let worktree = try await service.create(from: repository, prompt: "Feature")
        try fixture.write("feature\n", to: "feature.txt", in: worktree.worktreeURL)
        try fixture.commit("Add the feature", in: worktree.worktreeURL)

        let kept = await service.cleanUp(workspaceURL: worktree.workspaceURL, recordedBranch: worktree.branch)
        XCTAssertEqual(kept, .keptUnmergedCommits(branch: "yardlet/feature"))
        XCTAssertTrue(fixture.exists(worktree.worktreeURL))

        try fixture.git(["merge", "-q", "--ff-only", worktree.branch], in: repository)
        let removed = await service.cleanUp(workspaceURL: worktree.workspaceURL, recordedBranch: worktree.branch)
        XCTAssertEqual(removed, .removed)
        XCTAssertTrue(try fixture.branchExists(worktree.branch, in: repository))
    }

    func testCommitsOnADetachedHeadKeepTheWorktree() async throws {
        let repository = try fixture.makeRepository()
        let service = fixture.service()
        let worktree = try await service.create(from: repository, prompt: "Detached")
        try fixture.git(["checkout", "-q", "--detach"], in: worktree.worktreeURL)
        try fixture.write("loose\n", to: "loose.txt", in: worktree.worktreeURL)
        try fixture.commit("Loose commit", in: worktree.worktreeURL)

        let result = await service.cleanUp(workspaceURL: worktree.workspaceURL, recordedBranch: worktree.branch)

        XCTAssertEqual(result, .keptUnmergedCommits(branch: nil))
        XCTAssertTrue(fixture.exists(worktree.worktreeURL))
    }

    func testWorktreesYardletDidNotMakeAreNeverTouched() async throws {
        let repository = try fixture.makeRepository()
        let service = fixture.service()
        // The user's own worktree, somewhere else.
        let own = fixture.root.appending(path: "my-worktree", directoryHint: .isDirectory)
        try fixture.git(["worktree", "add", "-q", "-b", "yardlet/mine", own.path(percentEncoded: false)], in: repository)
        let ownResult = await service.cleanUp(workspaceURL: own, recordedBranch: "yardlet/mine")
        XCTAssertEqual(ownResult, .untouched)
        XCTAssertTrue(fixture.exists(own))
        let checkoutResult = await service.cleanUp(workspaceURL: repository, recordedBranch: "main")
        XCTAssertEqual(checkoutResult, .untouched)
        XCTAssertTrue(fixture.exists(repository))

        // A plain folder or a whole checkout that happens to sit in Yardlet's folder is not a worktree.
        let plain = fixture.layout.worktreeURL(repositoryFolder: "sample-repo", name: "plain")
        try fixture.write("keep\n", to: "file.txt", in: plain)
        let plainResult = await service.cleanUp(workspaceURL: plain, recordedBranch: nil)
        XCTAssertEqual(plainResult, .untouched)
        XCTAssertTrue(fixture.exists(plain.appending(path: "file.txt")))
        let clone = fixture.layout.worktreeURL(repositoryFolder: "sample-repo", name: "clone")
        try fixture.git(["clone", "-q", repository.path(percentEncoded: false), clone.path(percentEncoded: false)],
                        in: fixture.root)
        let cloneResult = await service.cleanUp(workspaceURL: clone, recordedBranch: "main")
        XCTAssertEqual(cloneResult, .untouched)
        XCTAssertTrue(fixture.exists(clone.appending(path: "README.md")))
    }

    func testALockedWorktreeIsKeptWithGitsReason() async throws {
        let repository = try fixture.makeRepository()
        let service = fixture.service()
        let worktree = try await service.create(from: repository, prompt: "Locked")
        try fixture.git(["worktree", "lock", worktree.worktreeURL.path(percentEncoded: false)], in: repository)

        let result = await service.cleanUp(workspaceURL: worktree.workspaceURL, recordedBranch: worktree.branch)

        guard case let .failed(message) = result else { return XCTFail("\(result)") }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(fixture.exists(worktree.worktreeURL.appending(path: "README.md")))
    }

    // MARK: - Unarchive

    func testARemovedWorktreeIsRecreatedFromItsBranchInTheSamePlace() async throws {
        let repository = try fixture.makeRepository()
        let service = fixture.service()
        let worktree = try await service.create(from: repository.appending(path: "app"), prompt: "Restore me")
        let removed = await service.cleanUp(workspaceURL: worktree.workspaceURL, recordedBranch: worktree.branch)
        XCTAssertEqual(removed, .removed)

        let result = await service.restore(workspaceURL: worktree.workspaceURL, repositoryURL: repository,
                                           branch: worktree.branch)

        XCTAssertEqual(result, .recreated)
        XCTAssertTrue(fixture.exists(worktree.workspaceURL.appending(path: "main.txt")))
        XCTAssertEqual(try fixture.git(["symbolic-ref", "--short", "HEAD"], in: worktree.worktreeURL), worktree.branch)
        let again = await service.restore(workspaceURL: worktree.workspaceURL, repositoryURL: repository,
                                          branch: worktree.branch)
        XCTAssertEqual(again, .notNeeded)
    }

    func testAWorktreeDeletedBehindGitsBackIsRecreatedToo() async throws {
        let repository = try fixture.makeRepository()
        let service = fixture.service()
        let worktree = try await service.create(from: repository, prompt: "Deleted by hand")
        try FileManager.default.removeItem(at: worktree.worktreeURL)

        let result = await service.restore(workspaceURL: worktree.workspaceURL, repositoryURL: repository,
                                           branch: worktree.branch)

        XCTAssertEqual(result, .recreated)
        XCTAssertTrue(fixture.exists(worktree.worktreeURL.appending(path: "README.md")))
    }

    func testRestoringExplainsAMissingBranchOrRepository() async throws {
        let repository = try fixture.makeRepository()
        let service = fixture.service()
        let worktree = try await service.create(from: repository, prompt: "Gone")
        _ = await service.cleanUp(workspaceURL: worktree.workspaceURL, recordedBranch: worktree.branch)
        try fixture.git(["branch", "-D", worktree.branch], in: repository)

        let noBranch = await service.restore(workspaceURL: worktree.workspaceURL, repositoryURL: repository,
                                             branch: worktree.branch)
        XCTAssertEqual(noBranch, .branchMissing("yardlet/gone"))
        let unrecorded = await service.restore(workspaceURL: worktree.workspaceURL, repositoryURL: repository, branch: nil)
        XCTAssertEqual(unrecorded, .branchMissing(nil))
        let missingRepository = fixture.root.appending(path: "moved-away")
        let noRepository = await service.restore(workspaceURL: worktree.workspaceURL, repositoryURL: missingRepository,
                                                 branch: worktree.branch)
        XCTAssertEqual(noRepository, .repositoryMissing(missingRepository.path(percentEncoded: false)))
        XCTAssertFalse(fixture.exists(worktree.worktreeURL))
        let elsewhere = await service.restore(workspaceURL: repository, repositoryURL: repository, branch: "main")
        XCTAssertEqual(elsewhere, .notNeeded, "Only Yardlet's own worktrees are ever recreated")
    }

    /// Homebrew's Git is preferred when present, Apple's otherwise; both must agree on every step.
    func testTheRoundTripWorksWithEachGitOnThisMac() async throws {
        let gits = Set((GitExecutableLocator.standardPaths + ["/usr/bin/git"])
            .filter { FileManager.default.isExecutableFile(atPath: $0) })
        for (index, git) in gits.sorted().enumerated() {
            let service = TaskWorktreeService(layout: fixture.layout, executableURL: URL(filePath: git),
                                              environment: WorktreeFixture.gitEnvironment)
            let repository = try fixture.makeRepository(named: "repo-\(index)")
            let worktree = try await service.create(from: repository, prompt: "Round trip")
            XCTAssertEqual(worktree.branch, "yardlet/round-trip", git)
            try fixture.write("work\n", to: "work.txt", in: worktree.worktreeURL)
            let kept = await service.cleanUp(workspaceURL: worktree.workspaceURL, recordedBranch: worktree.branch)
            XCTAssertEqual(kept, .keptUncommittedChanges, git)
            try FileManager.default.removeItem(at: worktree.worktreeURL.appending(path: "work.txt"))
            let removed = await service.cleanUp(workspaceURL: worktree.workspaceURL, recordedBranch: worktree.branch)
            XCTAssertEqual(removed, .removed, git)
            let restored = await service.restore(workspaceURL: worktree.workspaceURL, repositoryURL: repository,
                                                 branch: worktree.branch)
            XCTAssertEqual(restored, .recreated, git)
            try FileManager.default.removeItem(at: worktree.worktreeURL)
            let restoredAgain = await service.restore(workspaceURL: worktree.workspaceURL, repositoryURL: repository,
                                                      branch: worktree.branch)
            XCTAssertEqual(restoredAgain, .recreated, "\(git) after the folder was deleted by hand")
        }
    }

    private func assertThrows(
        _ expected: TaskWorktreeError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as TaskWorktreeError {
            XCTAssertEqual(error, expected, file: file, line: line)
            XCTAssertNotNil(error.errorDescription, file: file, line: line)
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }
}
