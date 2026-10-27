import Foundation
import XCTest
@testable import NativeHarnessClient

/// A typed `@word` searches the task's folders and becomes the same context mention the `@`
/// button adds. These pin where the word is recognized, how files rank, and how listing is
/// bounded and cached.
final class ComposerFileMentionTests: XCTestCase {
    // MARK: - The typed word

    func testAnAtThatStartsAWordAtTheCaretOpensTheList() {
        XCTAssertEqual(ComposerMentions.token(in: "@", caret: 1), .init(location: 0, length: 1, query: ""))
        XCTAssertEqual(ComposerMentions.token(in: "look at @Sess", caret: 13),
                       .init(location: 8, length: 5, query: "Sess"))
        // The whole word counts even when the caret sits inside it.
        XCTAssertEqual(ComposerMentions.token(in: "fix @Sources/App and", caret: 9),
                       .init(location: 4, length: 12, query: "Sources/App"))
        XCTAssertEqual(ComposerMentions.token(in: "first line\n@읽기", caret: 14),
                       .init(location: 11, length: 3, query: "읽기"))
        // Without a known caret the end of the text is used.
        XCTAssertEqual(ComposerMentions.token(in: "see @read", caret: nil as Int?)?.query, "read")
    }

    func testAddressesFinishedWordsAndACaretBeforeTheAtDoNotOpenIt() {
        XCTAssertNil(ComposerMentions.token(in: "mail me@example.com", caret: 19))
        XCTAssertNil(ComposerMentions.token(in: "@done and more", caret: 14))
        XCTAssertNil(ComposerMentions.token(in: "@done ", caret: 6))
        XCTAssertNil(ComposerMentions.token(in: "x @abc", caret: 2))
        XCTAssertNil(ComposerMentions.token(in: "", caret: 0))
    }

    func testTheEditorCaretAppliesOnlyToTheTextItWasMeasuredIn() {
        let text = "@one and @two"
        XCTAssertEqual(ComposerMentions.token(in: text, caret: ComposerCaret(text: text, selection: NSRange(location: 4, length: 0)))?.query, "one")
        // A caret from an older text falls back to the end, never to a stale offset.
        XCTAssertEqual(ComposerMentions.token(in: text, caret: ComposerCaret(text: "@one", selection: NSRange(location: 4, length: 0)))?.query, "two")
        // A selected range is not a place to type a mention.
        XCTAssertNil(ComposerMentions.token(in: text, caret: ComposerCaret(text: text, selection: NSRange(location: 1, length: 3))))
    }

    func testChoosingRemovesTheTypedWordAndTheSpaceItWouldDouble() throws {
        func remove(_ text: String, caret: Int) throws -> (String, Int) {
            let token = try XCTUnwrap(ComposerMentions.token(in: text, caret: caret))
            let result = try XCTUnwrap(ComposerMentions.removing(token, from: text))
            return (result.text, result.caret)
        }
        XCTAssertTrue(try remove("look at @Sess and fix", caret: 13) == ("look at and fix", 8))
        XCTAssertTrue(try remove("look at @Sess", caret: 13) == ("look at", 7))
        XCTAssertTrue(try remove("@Sess", caret: 5) == ("", 0))
        // A line break is the reader's, so it stays.
        XCTAssertTrue(try remove("first\n@Sess", caret: 11) == ("first\n", 6))
        XCTAssertTrue(try remove("한글 @파일 끝", caret: 6) == ("한글 끝", 3))
        // A token from text that has since changed is not applied to the new text.
        let stale = try XCTUnwrap(ComposerMentions.token(in: "see @old", caret: 8))
        XCTAssertNil(ComposerMentions.removing(stale, from: "see @new"))
        XCTAssertNil(ComposerMentions.removing(stale, from: "see"))
    }

    // MARK: - Ranking

    private func ranked(_ paths: [String], _ query: String, limit: Int = 10) -> [String] {
        WorkspaceFileRanking.rank(WorkspaceFileRanking.entries(forFiles: paths), query: query, limit: limit)
            .map { $0.isDirectory ? $0.relativePath + "/" : $0.relativePath }
    }

    func testNameMatchesBeatFolderMatchesAndContiguousBeatsScattered() {
        let paths = [
            "Sources/App/Views/SessionTranscriptView.swift",
            "Sources/App/Session/Store.swift",
            "Docs/session.md",
            "Sources/App/Views/SideStatusTextView.swift",
            "Tests/SessionTranscriptViewTests.swift"
        ]
        XCTAssertEqual(ranked(paths, "session.md"), ["Docs/session.md"])
        XCTAssertEqual(ranked(paths, "session"), [
            "Docs/session.md",
            "Sources/App/Session/",
            "Tests/SessionTranscriptViewTests.swift",
            "Sources/App/Views/SessionTranscriptView.swift",
            "Sources/App/Session/Store.swift"
        ])
        // Scattered letters still find files, after every contiguous match.
        XCTAssertEqual(Set(ranked(paths, "stv")), [
            "Sources/App/Views/SessionTranscriptView.swift",
            "Sources/App/Views/SideStatusTextView.swift",
            "Tests/SessionTranscriptViewTests.swift"
        ])
        XCTAssertEqual(ranked(paths, "zzz"), [])
        XCTAssertEqual(ranked(paths, ""), [], "An empty query asks the reader to type instead")
    }

    func testAnExactStemShallowPathAndFileComeFirst() {
        let paths = ["deep/nested/folder/README.md", "README.md", "docs/README.markdown"]
        XCTAssertEqual(ranked(paths, "readme"), ["README.md", "docs/README.markdown", "deep/nested/folder/README.md"])
        // Folders are offered as well, after a file of the same rank.
        XCTAssertEqual(ranked(["views/a.swift", "src/views.swift"], "views"),
                       ["src/views.swift", "views/", "views/a.swift"])
    }

    func testInitialsOfANameBeatTheSameLettersScattered() {
        let paths = ["Views/sometextview.swift", "Views/SessionTranscriptView.swift", "Views/session_text_viewer.md"]
        XCTAssertEqual(ranked(paths, "stv"), [
            "Views/session_text_viewer.md",
            "Views/SessionTranscriptView.swift",
            "Views/sometextview.swift"
        ])
    }

    func testASlashSearchesThePathAndCaseAndNormalizationDoNotMatter() {
        let decomposed = "문서/설명서.md".decomposedStringWithCanonicalMapping
        let paths = ["Sources/App/Main.swift", "Tests/AppTests/Main.swift", decomposed]
        XCTAssertEqual(ranked(paths, "app/main").first, "Sources/App/Main.swift")
        XCTAssertEqual(ranked(paths, "MAIN.SWIFT").count, 2)
        XCTAssertEqual(ranked(paths, "설명서"), [decomposed], "Typed Hangul finds a decomposed file name")
    }

    // MARK: - Listing

    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "nhc-mentions-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ relativePath: String, in root: URL) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    func testAFolderWithoutGitIsWalkedWithoutDependencyAndBuildFolders() throws {
        let root = try makeFolder()
        for path in ["README.md", "src/app.swift", "src/한글 파일.txt", ".github/workflows/ci.yml",
                     "node_modules/pkg/index.js", ".build/debug/out.o", "build/out.bin", ".git/HEAD",
                     "nested/node_modules/x.js"] {
            try write(path, in: root)
        }
        let files = try XCTUnwrap(WorkspaceFileListing.walkedFiles(in: root))
        XCTAssertEqual(Set(files.map(\.precomposedStringWithCanonicalMapping)),
                       ["README.md", "src/app.swift", "src/한글 파일.txt", ".github/workflows/ci.yml"])
        XCTAssertEqual(WorkspaceFileListing.walkedFiles(in: root, limit: 2)?.count, 2)
        XCTAssertNil(WorkspaceFileListing.walkedFiles(in: root.appending(path: "missing")))
    }

    func testAGitWorkTreeListsTrackedAndUntrackedFilesButNotIgnoredOnes() throws {
        let root = try makeFolder()
        let git = GitExecutableLocator.preferredURL()
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = git
            process.currentDirectoryURL = root
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw XCTSkip("git \(arguments.first ?? "") is unavailable here") }
        }
        try run(["init", "-q"])
        try write(".gitignore", in: root)
        try Data("ignored.log\n".utf8).write(to: root.appending(path: ".gitignore"))
        try write("tracked/a.swift", in: root)
        try run(["add", "tracked/a.swift", ".gitignore"])
        try write("untracked.md", in: root)
        try write("ignored.log", in: root)

        let files = try XCTUnwrap(WorkspaceFileListing.gitFiles(in: root))
        XCTAssertEqual(Set(files), [".gitignore", "tracked/a.swift", "untracked.md"])
        // A folder Git does not own is not a Git listing; the walk takes over.
        let plain = try makeFolder()
        try write("only.txt", in: plain)
        XCTAssertNil(WorkspaceFileListing.gitFiles(in: plain))
        XCTAssertEqual(WorkspaceFileListing.files(in: plain), ["only.txt"])
    }

    // MARK: - Cache and roots

    func testAListingIsSharedForAShortWhileThenReadAgain() async throws {
        let calls = Counter()
        let index = WorkspaceFileSearchIndex(lifetime: .milliseconds(200)) { _ in
            calls.increment()
            return ["Sources/Main.swift", "README.md"]
        }
        let root = URL(filePath: "/tmp/project", directoryHint: .isDirectory)
        let first = await index.search("main", in: [root])
        _ = await index.search("readme", in: [root])
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(first.matches.map(\.relativePath), ["Sources/Main.swift"])
        XCTAssertEqual(first.matches.first?.url.path(percentEncoded: false), "/tmp/project/Sources/Main.swift")
        try await Task.sleep(for: .milliseconds(300))
        _ = await index.search("main", in: [root])
        XCTAssertEqual(calls.value, 2)
    }

    func testEveryRootContributesItsBestMatchAndAnUnreadableRootIsReported() async {
        let index = WorkspaceFileSearchIndex { root in
            switch root.lastPathComponent {
            case "app": ["Package.swift", "Sources/PackageInfo.swift"]
            case "docs": ["package-notes.md"]
            default: nil
            }
        }
        let app = URL(filePath: "/tmp/app", directoryHint: .isDirectory)
        let docs = URL(filePath: "/tmp/docs", directoryHint: .isDirectory)
        let result = await index.search("package", in: [app, docs])
        XCTAssertEqual(result.matches.map(\.relativePath), ["Package.swift", "package-notes.md", "Sources/PackageInfo.swift"])
        XCTAssertEqual(result.matches.map(\.root.lastPathComponent), ["app", "docs", "app"])
        XCTAssertFalse(result.failed)

        let missing = await index.search("package", in: [URL(filePath: "/tmp/missing", directoryHint: .isDirectory)])
        XCTAssertTrue(missing.failed)
        XCTAssertEqual(missing.matches, [])
    }

    @MainActor
    func testTheListFollowsTheLatestQueryAndArrowKeysWrap() async throws {
        let index = WorkspaceFileSearchIndex { _ in ["a/alpha.swift", "a/alphabet.swift", "b/beta.swift"] }
        let search = ComposerFileMentionSearch(index: index)
        let roots = [URL(filePath: "/tmp/mentions", directoryHint: .isDirectory)]
        search.update(query: "alp", roots: roots)
        // A newer query replaces the pending one before it answers.
        search.update(query: "beta", roots: roots)
        try await waitUntil { search.isSearching == false }
        XCTAssertEqual(search.matches.map(\.relativePath), ["b/beta.swift"])

        search.update(query: "alpha", roots: roots)
        try await waitUntil { search.matches.count == 2 }
        XCTAssertEqual(search.highlightedMatch?.relativePath, "a/alpha.swift")
        search.moveHighlight(by: 1)
        XCTAssertEqual(search.highlightedMatch?.relativePath, "a/alphabet.swift")
        search.moveHighlight(by: 1)
        XCTAssertEqual(search.highlightedMatch?.relativePath, "a/alpha.swift")
        search.moveHighlight(by: -1)
        XCTAssertEqual(search.highlightedMatch?.relativePath, "a/alphabet.swift")

        search.update(query: "", roots: roots)
        XCTAssertEqual(search.matches, [])
        XCTAssertFalse(search.isSearching)
        search.reset()
        XCTAssertNil(search.query)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
