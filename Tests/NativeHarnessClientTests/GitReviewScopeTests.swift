import Foundation
import Testing
@testable import NativeHarnessClient

/// Commit, Branch and repository choices read real temporary repositories with the selected Git.
struct GitReviewScopeTests {
    @Test func testCommitScopeListsRecentCommitsAndShowsOnlyTheChosenCommit() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one\n", to: "notes.txt", in: root)
        try commit("First", in: root, date: "2026-09-18T09:00:00Z")
        try write("one\ntwo\n", to: "notes.txt", in: root)
        try write("새 파일\n", to: "한글 👩🏽‍💻.txt", in: root)
        try commit("두 번째 👩🏽‍💻 commit", in: root, date: "2026-09-19T09:00:00Z")
        try write("one\ntwo\nthree\n", to: "notes.txt", in: root)
        try commit("Third", in: root, date: "2026-09-20T09:00:00Z")
        try write("uncommitted\n", to: "notes.txt", in: root)
        let index = try Data(contentsOf: root.appending(path: ".git/index"))

        let service = GitDiffService()
        let commits = try await service.recentCommits(workspaceURL: root)
        #expect(commits.map(\.subject) == ["Third", "두 번째 👩🏽‍💻 commit", "First"])
        #expect(commits.allSatisfy { $0.id.count >= 40 && $0.id.hasPrefix($0.shortID) })
        #expect(commits[1].date == ISO8601DateFormatter().date(from: "2026-09-19T09:00:00Z"))
        #expect(try await service.recentCommits(workspaceURL: root, limit: 2).count == 2)

        let second = try await service.load(workspaceURL: root, target: .commit(commits[1].id))
        #expect(Set(second.files.map(\.path)) == ["notes.txt", "한글 👩🏽‍💻.txt"])
        #expect(second.lines.contains { $0.text == "+two" })
        #expect(!second.lines.contains { $0.text == "+three" || $0.text == "+uncommitted" })
        #expect(second.files.first { $0.path == "한글 👩🏽‍💻.txt" }?.status == L10n.string("Added"))
        #expect(try Data(contentsOf: root.appending(path: ".git/index")) == index)
    }

    @Test func testRootCommitComparesWithTheEmptyTree() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("alpha\n", to: "a.txt", in: root)
        try write("beta\n", to: "nested/b.txt", in: root)
        try commit("Root", in: root)

        let service = GitDiffService()
        let rootCommit = try #require(try await service.recentCommits(workspaceURL: root).first)
        let snapshot = try await service.load(workspaceURL: root, target: .commit(rootCommit.id))
        #expect(Set(snapshot.files.map(\.path)) == ["a.txt", "nested/b.txt"])
        #expect(snapshot.files.allSatisfy { $0.oldPath == nil })
        #expect(snapshot.lines.contains { $0.text == "+alpha" })
        #expect(snapshot.lines.contains { $0.text == "+beta" })
    }

    @Test func testMergeCommitComparesWithItsFirstParent() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", to: "base.txt", in: root)
        try commit("Base", in: root)
        try git(["checkout", "-q", "-b", "feature"], in: root)
        try write("feature\n", to: "feature.txt", in: root)
        try commit("Feature", in: root)
        try git(["checkout", "-q", "main"], in: root)
        try write("main\n", to: "main.txt", in: root)
        try commit("Main", in: root)
        try git(["merge", "-q", "--no-ff", "-m", "Merge feature", "feature"], in: root)

        let service = GitDiffService()
        let merge = try #require(try await service.recentCommits(workspaceURL: root).first)
        #expect(merge.subject == "Merge feature")
        let snapshot = try await service.load(workspaceURL: root, target: .commit(merge.id))
        // What the merge brought into main, not what main already had.
        #expect(snapshot.files.map(\.path) == ["feature.txt"])
        #expect(snapshot.lines.contains { $0.text == "+feature" })
    }

    @Test func testRememberedRevisionIsNeverReadAsAnOption() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", to: "base.txt", in: root)
        try commit("Base", in: root)
        let output = root.appending(path: "written-by-option.txt")
        for target in [GitDiffTarget.commit("--output=\(output.path)"), .branch(base: "--output=\(output.path)")] {
            do {
                _ = try await GitDiffService().load(workspaceURL: root, target: target)
                Issue.record("A revision that looks like an option must fail as a revision")
            } catch let error as GitDiffServiceError {
                guard case .commandFailed = error else { Issue.record("Unexpected \(error)"); continue }
            }
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!written.contains { $0.hasPrefix("written-by-option") })
    }

    @Test func testUnbornHeadHasNoCommitsAndNoBaseBranch() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("draft\n", to: "draft.txt", in: root)
        let service = GitDiffService()
        #expect(try await service.recentCommits(workspaceURL: root).isEmpty)
        #expect(try await service.baseBranch(workspaceURL: root) == .missing)
    }

    @Test func testBaseBranchPrefersOriginHeadThenMainThenMaster() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", to: "base.txt", in: root)
        try commit("Base", in: root)
        try git(["branch", "master"], in: root)
        try git(["update-ref", "refs/remotes/origin/trunk", "HEAD"], in: root)
        try git(["checkout", "-q", "-b", "feature"], in: root)
        let service = GitDiffService()

        // Without origin/HEAD, local main comes before master.
        #expect(try await service.baseBranch(workspaceURL: root) == .found("refs/heads/main"))

        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"], in: root)
        #expect(try await service.baseBranch(workspaceURL: root) == .found("refs/remotes/origin/trunk"))

        // An origin/HEAD whose branch is gone falls back to the local branches.
        try git(["update-ref", "-d", "refs/remotes/origin/trunk"], in: root)
        #expect(try await service.baseBranch(workspaceURL: root) == .found("refs/heads/main"))

        try git(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], in: root)
        try git(["branch", "-q", "-D", "main"], in: root)
        #expect(try await service.baseBranch(workspaceURL: root) == .found("refs/heads/master"))

        try git(["branch", "-q", "-m", "master", "develop"], in: root)
        #expect(try await service.baseBranch(workspaceURL: root) == .missing)
    }

    @Test func testBaseBranchItselfHasNothingToCompare() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", to: "base.txt", in: root)
        try commit("Base", in: root)
        let service = GitDiffService()
        #expect(try await service.baseBranch(workspaceURL: root) == .current)

        // A local branch that origin/HEAD names is the base as well.
        try git(["update-ref", "refs/remotes/origin/trunk", "HEAD"], in: root)
        try git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk"], in: root)
        try git(["checkout", "-q", "-b", "trunk"], in: root)
        #expect(try await service.baseBranch(workspaceURL: root) == .current)

        // A detached HEAD is compared like a branch.
        try git(["checkout", "-q", "--detach"], in: root)
        #expect(try await service.baseBranch(workspaceURL: root) == .found("refs/remotes/origin/trunk"))
    }

    @Test func testBranchScopeShowsCommitsSinceTheMergeBaseOnly() async throws {
        let root = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("base\n", to: "shared.txt", in: root)
        try commit("Base", in: root)
        try git(["checkout", "-q", "-b", "feature"], in: root)
        try write("base\nfeature\n", to: "shared.txt", in: root)
        try commit("Feature one", in: root)
        try write("added on feature\n", to: "feature.txt", in: root)
        try commit("Feature two", in: root)
        try git(["checkout", "-q", "main"], in: root)
        try write("later on main\n", to: "main-only.txt", in: root)
        try commit("Main moves on", in: root)
        try git(["checkout", "-q", "feature"], in: root)
        try write("uncommitted\n", to: "feature.txt", in: root)
        try write("staged\n", to: "staged.txt", in: root)
        try git(["add", "staged.txt"], in: root)
        let index = try Data(contentsOf: root.appending(path: ".git/index"))

        let service = GitDiffService()
        let base = try await service.baseBranch(workspaceURL: root)
        #expect(base == .found("refs/heads/main"))
        guard case let .found(ref) = base else { return }
        let snapshot = try await service.load(workspaceURL: root, target: .branch(base: ref))
        #expect(Set(snapshot.files.map(\.path)) == ["shared.txt", "feature.txt"])
        #expect(snapshot.lines.contains { $0.text == "+feature" })
        #expect(snapshot.lines.contains { $0.text == "+added on feature" })
        #expect(!snapshot.lines.contains { $0.text == "+uncommitted" || $0.text == "+staged" })
        #expect(try Data(contentsOf: root.appending(path: ".git/index")) == index)
    }

    @Test func testEachRepositoryAmongTheTaskFoldersIsFoundOnceAndReadable() async throws {
        let container = FileManager.default.temporaryDirectory.appending(path: "nhc-repos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let first = try makeRepository(at: container.appending(path: "first"))
        let second = try makeRepository(at: container.appending(path: "second repo 한글"))
        let plain = container.appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: first.appending(path: "nested"), withIntermediateDirectories: true)
        try write("first\n", to: "first.txt", in: first)
        try write("second\n", to: "second.txt", in: second)

        let service = GitDiffService()
        let found = try await service.repositories(
            containing: [first, plain, first.appending(path: "nested"), second]
        )
        // Folders outside Git are skipped and a folder inside a repository names that repository.
        #expect(found.map(\.lastPathComponent) == ["first", "second repo 한글"])
        #expect(try await service.repositories(containing: [plain, first]).map(\.lastPathComponent) == ["first"])
        #expect(try await service.load(workspaceURL: found[0]).files.map(\.path) == ["first.txt"])
        #expect(try await service.load(workspaceURL: found[1]).files.map(\.path) == ["second.txt"])
    }

    @Test func testRepositoryChoiceFallsBackQuietlyWhenItIsGone() {
        let workspace = URL(filePath: "/tmp/task")
        let found = [URL(filePath: "/tmp/task"), URL(filePath: "/tmp/second repo 한글")]
        var review = DiffReviewPreferences()
        #expect(review.resolveRepository(among: found, workspaceURL: workspace) == found[0])
        review.repositoryPath = found[1].path(percentEncoded: false)
        #expect(review.resolveRepository(among: found, workspaceURL: workspace) == found[1])
        #expect(review.repositoryPath == found[1].path(percentEncoded: false))

        review.repositoryPath = "/tmp/removed"
        #expect(review.resolveRepository(among: found, workspaceURL: workspace) == found[0])
        #expect(review.repositoryPath == nil)

        // With one repository the review reads the task folder, as before the menu existed.
        review.repositoryPath = found[1].path(percentEncoded: false)
        #expect(review.resolveRepository(among: [found[1]], workspaceURL: workspace) == workspace)
        #expect(review.repositoryPath == nil)
        #expect(review.resolveRepository(among: [], workspaceURL: workspace) == workspace)
    }

    @Test func testRememberedCommitThatNoLongerExistsFollowsTheLatest() {
        let latest = GitCommitSummary(id: String(repeating: "b", count: 40), shortID: "bbbbbbb", subject: "Latest", date: .now)
        let older = GitCommitSummary(id: String(repeating: "a", count: 40), shortID: "aaaaaaa", subject: "Older", date: .now)
        var review = DiffReviewPreferences(scope: .commit, commit: older.id)
        #expect(review.resolveCommit(among: [latest, older]) == older)
        #expect(review.commit == older.id)
        #expect(review.resolveCommit(among: [latest]) == latest)
        #expect(review.commit == nil)
        #expect(review.resolveCommit(among: []) == nil)
    }

    @MainActor
    @Test func testReviewSavedWithOnlyUnstagedAndStagedDecodesUnchanged() throws {
        // The shape written before the Commit and Branch scopes and the repository menu existed.
        let previous = Data("""
        {"version":1,"panels":{"trailingSurfaceID":"diff","isTerminalPresented":false},\
        "layout":{"panelWidth":520,"terminalHeight":240,"isExpanded":false},\
        "transcript":{"anchorID":"message-7","fraction":0.25,"followsLatest":false},\
        "codex":{"fraction":0,"followsLatest":true},\
        "review":{"scope":"staged","selectedPaths":["unstaged","Sources/working.swift","staged","Sources/한글 👩🏽‍💻.swift"]}}
        """.utf8)
        let state = TaskWorkspaceState(snapshot: try JSONDecoder().decode(TaskWorkspaceSnapshot.self, from: previous))
        #expect(state.review.scope == .staged)
        #expect(state.review.selectedPath == "Sources/한글 👩🏽‍💻.swift")
        #expect(state.review.selectedPaths[.unstaged] == "Sources/working.swift")
        #expect(state.review.commit == nil)
        #expect(state.review.repositoryPath == nil)
        #expect(state.transcript.bookmark.anchorID == "message-7")
        #expect(state.layout.panelWidth == 520)

        // Unchosen commit and repository stay out of what is written.
        let rewritten = String(decoding: try JSONEncoder().encode(state.snapshot), as: UTF8.self)
        #expect(!rewritten.contains("\"commit\"") && !rewritten.contains("repositoryPath"))

        state.review.scope = .commit
        state.review.commit = String(repeating: "c", count: 40)
        state.review.repositoryPath = "/tmp/second"
        state.review.selectedPath = "README.md"
        let restored = TaskWorkspaceState(snapshot: try JSONDecoder().decode(
            TaskWorkspaceSnapshot.self, from: try JSONEncoder().encode(state.snapshot)
        ))
        #expect(restored.review == state.review)
        restored.review.scope = .staged
        #expect(restored.review.selectedPath == "Sources/한글 👩🏽‍💻.swift")
    }

    // MARK: - Fixture repositories

    private func makeRepository(at directory: URL? = nil) throws -> URL {
        let root = directory ?? FileManager.default.temporaryDirectory.appending(path: "nhc-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: root)
        return root
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func commit(_ message: String, in root: URL, date: String = "2026-09-20T12:00:00Z") throws {
        try git(["add", "-A"], in: root)
        try git(["commit", "-q", "-m", message], in: root, date: date)
    }

    private func git(_ arguments: [String], in directory: URL, date: String = "2026-09-20T12:00:00Z") throws {
        let process = Process()
        process.executableURL = GitExecutableLocator.preferredURL()
        // The fixture never reads the user's own Git configuration, identity or signing setup.
        process.arguments = ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.test",
            "GIT_COMMITTER_NAME": "Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.test",
            "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_DATE": date
        ]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "GitFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
    }
}
