import Foundation
import XCTest
@testable import NativeHarnessClient

/// Codex file changes and turn diffs as the review panel reads them. The change shapes follow the
/// App Server schema (`FileUpdateChange`) and recorded Codex rollouts: hunks alone for an update,
/// the whole text for an added or deleted file, absolute paths.
final class CodexTurnDiffTests: XCTestCase {
    private let workspace = URL(filePath: "/Users/me/project", directoryHint: .isDirectory)

    private func change(_ path: String, _ kind: JSONValue, _ diff: String) -> JSONValue {
        .object(["path": .string(path), "kind": kind, "diff": .string(diff)])
    }

    func testAnUpdateGetsFileHeadersAroundItsHunksAndARelativePath() throws {
        let text = try XCTUnwrap(CodexFileChangeDiff.unifiedDiff(
            for: change("/Users/me/project/Sources/App.swift",
                        .object(["type": .string("update"), "move_path": .null]),
                        "@@ -1,2 +1,2 @@\n-old\n+new 한글\n keep\n"),
            workspaceURL: workspace
        ))
        XCTAssertEqual(text, """
            diff --git a/Sources/App.swift b/Sources/App.swift
            --- a/Sources/App.swift
            +++ b/Sources/App.swift
            @@ -1,2 +1,2 @@
            -old
            +new 한글
             keep

            """)
        let snapshot = UnifiedDiffParser().parse(text)
        XCTAssertEqual(snapshot.files.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(snapshot.files.first?.status, L10n.string("Modified"))
        XCTAssertEqual(snapshot.additionCount, 1)
        XCTAssertEqual(snapshot.deletionCount, 1)
        XCTAssertEqual(snapshot.lines.first { $0.kind == .addition }?.newLine, 1)
    }

    func testAddedDeletedAndMovedFilesReadAsTheirKind() {
        let added = CodexFileChangeDiff.unifiedDiff(
            for: change("/Users/me/project/notes.md", .object(["type": .string("add")]), "# Title\n\nBody\n"),
            workspaceURL: workspace
        ) ?? ""
        let deleted = CodexFileChangeDiff.unifiedDiff(
            for: change("/Users/me/project/old.txt", .object(["type": .string("delete")]), "gone\n"),
            workspaceURL: workspace
        ) ?? ""
        let moved = CodexFileChangeDiff.unifiedDiff(
            for: change("/Users/me/project/a.swift",
                        .object(["type": .string("update"), "move_path": .string("/Users/me/project/b.swift")]),
                        "@@ -1 +1 @@\n-x\n+y\n"),
            workspaceURL: workspace
        ) ?? ""
        let outside = CodexFileChangeDiff.unifiedDiff(
            for: change("/tmp/scratch.txt", .object(["type": .string("add")]), "one"),
            workspaceURL: workspace
        ) ?? ""
        let files = UnifiedDiffParser().parse(added + deleted + moved + outside).files
        XCTAssertEqual(files.map(\.path), ["notes.md", "old.txt", "b.swift", "/tmp/scratch.txt"])
        XCTAssertEqual(files.map(\.status), [
            L10n.string("Added"), L10n.string("Deleted"), L10n.string("Renamed"), L10n.string("Added")
        ])
        XCTAssertEqual(files.map(\.additionCount), [3, 0, 1, 1])
        XCTAssertEqual(files.map(\.deletionCount), [0, 1, 1, 0])
        XCTAssertTrue(added.contains("@@ -0,0 +1,3 @@\n+# Title\n+\n+Body\n"))
        XCTAssertEqual(CodexFileChangeDiff.lineCounts(for: change("/x", .object(["type": .string("add")]), "a\nb\n")).additions, 2)
        XCTAssertNil(CodexFileChangeDiff.unifiedDiff(for: .object(["diff": .string("@@")]), workspaceURL: workspace))
    }

    // MARK: - Last turn

    private let reducer = CodexTaskReducer()
    private var sequence: UInt64 = 0

    private func apply(_ method: String, _ params: [String: JSONValue], to state: inout CodexTaskState) -> Bool {
        sequence += 1
        var params = params
        params["threadId"] = .string("thread-1")
        return reducer.applyNotification(method: method, params: .object(params), sequence: sequence, to: &state)
    }

    private func thread(turns: [JSONValue]) -> CodexTaskState {
        var state = CodexTaskState.empty
        _ = reducer.applySnapshot(.object([
            "id": .string("thread-1"), "preview": .string(""),
            "status": .object(["type": .string("idle")]),
            "turns": .array(turns)
        ]), to: &state)
        return state
    }

    private func fileChangeItem(_ id: String, status: String, changes: [JSONValue]) -> JSONValue {
        .object(["id": .string(id), "type": .string("fileChange"), "status": .string(status), "changes": .array(changes)])
    }

    private let liveDiff = "diff --git a/Sources/App.swift b/Sources/App.swift\n--- a/Sources/App.swift\n+++ b/Sources/App.swift\n@@ -1 +1 @@\n-old\n+new\n"

    func testTheTurnDiffIsKeptOnItsTurnAndOutlivesTheTurnCompleting() throws {
        var state = thread(turns: [])
        XCTAssertTrue(apply("turn/started", [
            "turn": .object(["id": .string("turn-1"), "status": .string("inProgress"), "items": .array([])])
        ], to: &state))
        XCTAssertTrue(apply("turn/diff/updated", ["turnId": .string("turn-1"), "diff": .string(liveDiff)], to: &state))
        XCTAssertFalse(apply("turn/diff/updated", ["turnId": .string("turn-1"), "diff": .string(liveDiff)], to: &state),
                       "The same diff again changes nothing")
        let before = state.thread?.turns.count
        XCTAssertFalse(apply("turn/diff/updated", ["turnId": .string("other"), "diff": .string(liveDiff)], to: &state))
        XCTAssertEqual(state.thread?.turns.count, before, "An unknown turn gets no phantom turn")
        XCTAssertTrue(apply("turn/completed", [
            "turn": .object(["id": .string("turn-1"), "status": .string("completed"), "items": .array([])])
        ], to: &state))
        XCTAssertEqual(state.thread?.turns.last?.diff, liveDiff)
        XCTAssertTrue(CodexTaskReducer.streamingTextMethods.contains("turn/diff/updated"))

        let lastTurn = try XCTUnwrap(CodexWorkSurfaceProjection.lastTurnDiff(from: state, workspaceURL: workspace))
        XCTAssertEqual(lastTurn.turnID, "turn-1")
        XCTAssertEqual(lastTurn.text, liveDiff)
        XCTAssertFalse(lastTurn.isRunning)
    }

    func testAReopenedTaskRebuildsTheLastTurnFromItsAppliedFileChanges() throws {
        let update = change("/Users/me/project/a.swift", .object(["type": .string("update"), "move_path": .null]),
                            "@@ -1 +1 @@\n-x\n+y\n")
        let added = change("/Users/me/project/b.md", .object(["type": .string("add")]), "hello\n")
        let declined = change("/Users/me/project/c.swift", .object(["type": .string("update"), "move_path": .null]),
                              "@@ -1 +1 @@\n-p\n+q\n")
        let state = thread(turns: [
            .object(["id": .string("turn-old"), "status": .string("completed"), "items": .array([
                fileChangeItem("old", status: "completed", changes: [declined])
            ])]),
            .object(["id": .string("turn-new"), "status": .string("completed"), "items": .array([
                fileChangeItem("one", status: "completed", changes: [update]),
                fileChangeItem("two", status: "declined", changes: [declined]),
                fileChangeItem("three", status: "completed", changes: [added])
            ])])
        ])
        let lastTurn = try XCTUnwrap(CodexWorkSurfaceProjection.lastTurnDiff(from: state, workspaceURL: workspace))
        XCTAssertEqual(lastTurn.turnID, "turn-new")
        let files = UnifiedDiffParser().parse(lastTurn.text).files
        XCTAssertEqual(files.map(\.path), ["a.swift", "b.md"], "Only the latest turn, and only what was applied")

        let empty = thread(turns: [.object(["id": .string("turn-quiet"), "status": .string("inProgress"), "items": .array([])])])
        let quiet = try XCTUnwrap(CodexWorkSurfaceProjection.lastTurnDiff(from: empty, workspaceURL: workspace))
        XCTAssertEqual(quiet.text, "")
        XCTAssertTrue(quiet.isRunning)
        XCTAssertNotEqual(quiet.revision, lastTurn.revision)
        XCTAssertNil(CodexWorkSurfaceProjection.lastTurnDiff(from: thread(turns: []), workspaceURL: workspace))
    }

    func testLastTurnIsOfferedOnlyWhereTheTaskHasTurnDiffs() {
        XCTAssertEqual(GitDiffScope.offered(includingLastTurn: false), [.unstaged, .staged, .commit, .branch])
        XCTAssertEqual(GitDiffScope.offered(includingLastTurn: true), [.unstaged, .staged, .commit, .branch, .lastTurn])
        XCTAssertFalse(ReviewLastTurn.notOffered.isOffered)
        XCTAssertTrue(ReviewLastTurn.offered(nil).isOffered)
        XCTAssertNil(ReviewLastTurn.offered(nil).diff)
        // The chosen scope and its selected file are kept with the task, like the other scopes.
        var preferences = DiffReviewPreferences()
        preferences.scope = .lastTurn
        preferences.selectedPath = "a.swift"
        let saved = try? JSONDecoder().decode(DiffReviewPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(saved, preferences)
    }

    func testALongDiffIsCutOnAWholeLineAndMarkedTruncated() {
        let text = liveDiff + String(repeating: "+more line\n", count: 20)
        let whole = UnifiedDiffParser().parse(text, byteLimit: 10_000)
        XCTAssertFalse(whole.isTruncated)
        let cut = UnifiedDiffParser().parse(text, byteLimit: liveDiff.utf8.count + 15)
        XCTAssertTrue(cut.isTruncated)
        XCTAssertEqual(cut.lines.last?.text, "+more line")
        XCTAssertEqual(cut.additionCount, 2)
    }

    /// A file row counts without building the diff; the counts must stay the parser's.
    func testLineCountsMatchWhatTheParserCountsInTheUnifiedDiff() {
        let update: JSONValue = .object(["type": .string("update"), "move_path": .null])
        let changes = [
            change("/p/a", update, "@@ -1,2 +1,2 @@\n-old\n+new\n keep\n\\ No newline at end of file\n"),
            change("/p/b", update, "@@ -1 +1 @@\n-a\n+b\n@@ bad @@\n+not counted\n@@ -9 +9 @@\n+++counted\n---counted\n"),
            change("/p/c", update, "@@ -1 +1 @@\n+x\ndiff --git a/q b/q\n+not counted\n"),
            change("/p/d", update, "+not a hunk\n-either\n"),
            change("/p/e", update, ""),
            change("/p/f", .object(["type": .string("add")]), "one\r\ntwo\n\nthree"),
            change("/p/g", .object(["type": .string("add")]), "@@ -0,0 +1,2 @@\n+one\n+two\n"),
            change("/p/h", .object(["type": .string("delete")]), "gone\n\n"),
            change("/p/i", .object(["type": .string("delete")]), ""),
            change("/p/j", .string("added"), "@@ -1 +1 @@\n-x\n+y\n"),
            change("", update, "@@ -1 +1 @@\n-x\n+y\n")
        ]
        for value in changes {
            let parsed = CodexFileChangeDiff.unifiedDiff(for: value, workspaceURL: nil)
                .map { UnifiedDiffParser().parse($0) }
            let counts = CodexFileChangeDiff.lineCounts(for: value)
            XCTAssertEqual(counts.additions, parsed?.additionCount ?? 0, "\(value)")
            XCTAssertEqual(counts.deletions, parsed?.deletionCount ?? 0, "\(value)")
        }
        XCTAssertEqual(changes.map { CodexFileChangeDiff.lineCounts(for: $0).additions }, [1, 2, 1, 0, 0, 4, 2, 0, 0, 1, 0])
        XCTAssertEqual(changes.map { CodexFileChangeDiff.lineCounts(for: $0).deletions }, [1, 2, 0, 0, 0, 0, 0, 2, 0, 1, 0])
    }
}
