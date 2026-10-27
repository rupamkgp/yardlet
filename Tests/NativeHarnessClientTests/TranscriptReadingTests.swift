import AppKit
import XCTest
@testable import NativeHarnessClient

final class TranscriptReadingTests: XCTestCase {
    func testDenseShortLinesStayBoundedAndCanExpandWithoutLosingUnicode() {
        let lines = (1...2000).map { "\($0) 한글 👩🏽‍💻" }
        let source = lines.joined(separator: "\r\n")
        let first = TranscriptRenderWindow(text: source, characterLimit: 32_000)
        XCTAssertEqual(first.text, lines.prefix(80).joined(separator: "\r\n") + "\n\n…")
        XCTAssertTrue(first.hasMore)
        let expanded = TranscriptRenderWindow(text: source, characterLimit: 64_000, lineLimit: 160)
        XCTAssertEqual(expanded.text, lines.prefix(160).joined(separator: "\r\n") + "\n\n…")
        let all = TranscriptRenderWindow(text: source, characterLimit: 128_000, lineLimit: 3000)
        XCTAssertEqual(all.text, source)
        XCTAssertFalse(all.hasMore)
        XCTAssertTrue(all.isWindowed)
        let short = TranscriptRenderWindow(text: "한글 👩🏽‍💻\nEnd", characterLimit: 32_000)
        XCTAssertEqual(short.text, "한글 👩🏽‍💻\nEnd")
        XCTAssertFalse(short.isWindowed)
    }

    func testShortMultilineOutputRemainsExpandableWithoutLosingItsEnding() {
        let lines = (1...20).map { "Line \($0): 한글 👩🏽‍💻" }
        let output = lines.joined(separator: "\r\n") + "\r\nEND"
        XCTAssertLessThan(output.count, 2_400)
        let window = TranscriptCodeWindow(output, lineLimit: 12, characterLimit: 2_400)
        XCTAssertTrue(window.isTruncated)
        XCTAssertEqual(window.text, lines.prefix(12).joined(separator: "\r\n"))
        XCTAssertTrue(output.hasPrefix(window.text))
        XCTAssertTrue(output.hasSuffix("END"))
        XCTAssertFalse(TranscriptCodeWindow(window.text, lineLimit: 12, characterLimit: 2_400).isTruncated)
    }

    func testErrorSummaryUsesTheActualMessageAndKeepsDetailsSeparate() throws {
        let payload: JSONValue = .object([
            "message": .string("Connection interrupted.\nMore diagnostic details."),
            "code": .integer(503)
        ])
        let details = try XCTUnwrap(TranscriptRecoveryProjection.codexErrorDetails(payload))
        XCTAssertEqual(TranscriptRecoveryProjection.errorSummary(details), "Connection interrupted.")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(details.utf8)), payload)
        XCTAssertEqual(TranscriptRecoveryProjection.errorSummary("\n  \n  Raw failure\r\nEND"), "  Raw failure")
        XCTAssertEqual(TranscriptRecoveryProjection.errorSummary("{\"error\":{\"message\":\"Nested failure\"}}"), "Nested failure")
        let unicode = String(repeating: "👩🏽‍💻", count: 310)
        XCTAssertEqual(TranscriptRecoveryProjection.errorSummary(unicode), String(unicode.prefix(300)) + "…")
    }

    func testApprovalContextPreservesDecisionFieldsWithoutRenderingAccountOrRoutingData() throws {
        let permissions: JSONValue = .object([
            "network": .object(["enabled": .bool(true)]),
            "futurePermission": .array([.string("preserve unknown scope")])
        ])
        let command = "  printf '한글 👩🏽‍💻'\n"
        let context = CodexRequestContextProjection(params: .object([
            "reason": .string("Review this scope."), "message": .string("Review this scope."),
            "command": .string(command), "cwd": .string("/tmp/a project"),
            "permissions": permissions, "threadId": .string("routing-only"),
            "accessToken": .string("fixture-token-never-rendered")
        ]))
        XCTAssertEqual(context.messages, ["Review this scope."])
        XCTAssertEqual(context.fields.map(\.id), ["command", "cwd", "permissions"])
        XCTAssertEqual(context.fields[0].text, command)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(context.fields[2].text.utf8)), permissions)
        XCTAssertTrue(CodexRequestContextProjection(params: .object(["threadId": .string("id")])).isEmpty)
        let argv: JSONValue = .array([.string("echo"), .string("a b")])
        let legacy = CodexRequestContextProjection(params: .object(["command": argv]))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(legacy.fields[0].text.utf8)), argv)
    }

    func testCodeFencesAndPreviewPreserveMixedLineEndings() {
        let code = "  let value = \"한글 👩🏽‍💻\"\r\n\nprint(value)\r\n"
        let source = "## Mixed endings\r\n\r\n```swift\r\n" + code + "\r\n```"
        XCTAssertEqual(TranscriptCopyPayload.code(in: source, blockIndex: 1), code)
        let window = TranscriptCodeWindow(String(repeating: "line\r\n", count: 100))
        XCTAssertEqual(window.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count, 40)
        XCTAssertTrue(window.text.contains("\r\n"))
        XCTAssertTrue(window.isTruncated)
    }

    func testCodexStructuredErrorsRetainMessageAndDiagnosticFields() throws {
        let value: JSONValue = .object([
            "message": .string("Request interrupted: 한글 👩🏽‍💻"),
            "codexErrorInfo": .object(["httpConnectionFailed": .object(["httpStatusCode": .integer(503)])]),
            "additionalDetails": .string("  Preserve diagnostic detail\n")
        ])
        let details = try XCTUnwrap(TranscriptRecoveryProjection.codexErrorDetails(value))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(details.utf8)), value)
        XCTAssertEqual(TranscriptRecoveryProjection.codexErrorDetails(.string(" raw failure\n")), " raw failure\n")
        XCTAssertNil(TranscriptRecoveryProjection.codexErrorDetails(.null))
        XCTAssertNil(TranscriptRecoveryProjection.codexErrorDetails(nil))
    }

    func testCodePreviewBoundsLinesAndUnicodeWithoutChangingTheFullPayload() {
        let source = String(repeating: "print(\"한글 👩🏽‍💻\")\n", count: 3_000)
        let window = TranscriptCodeWindow(source)
        XCTAssertTrue(window.isTruncated)
        XCTAssertEqual(window.text.split(separator: "\n", omittingEmptySubsequences: false).count, 40)
        XCTAssertTrue(source.hasPrefix(window.text))
        let singleLine = TranscriptCodeWindow(String(repeating: "👩🏽‍💻", count: 8_000))
        XCTAssertEqual(singleLine.text.count, 6_000)
        XCTAssertTrue(singleLine.isTruncated)
    }

    func testCopyResolvesWholeCodeBeyondTheRenderWindow() {
        let code = "let 한국어 = \"👩🏽‍💻\"\n" + String(repeating: "  print(한국어)\n", count: 4_000)
        let source = "## Code\n\n```swift\n\(code)```"
        let window = TranscriptRenderWindow(text: source, characterLimit: 100)
        XCTAssertTrue(window.hasMore)
        XCTAssertEqual(TranscriptCopyPayload.code(in: source, blockIndex: 1), String(code.dropLast()))
        XCTAssertNil(TranscriptCopyPayload.code(in: source, blockIndex: 0))
        XCTAssertNil(TranscriptCopyPayload.code(in: source, blockIndex: 200))
    }

    func testFencesPreserveEmbeddedShorterFencesAndTrailingBlankLines() {
        let source = "````markdown\n```swift\nlet n = 1\n```\n\n  ````\nAfter"
        XCTAssertEqual(TranscriptMarkdownDocument(source).blocks, [
            .code(language: "markdown", text: "```swift\nlet n = 1\n```\n"), .paragraph("After")
        ])
        XCTAssertEqual(TranscriptMarkdownDocument("```text\n```not-a-close\nend\n```").blocks,
                       [.code(language: "text", text: "```not-a-close\nend")])
    }

    func testHighlightingDoesNotRecognizeKeywordsInsideStringsOrComments() {
        let source = "let title = \"if // 42 한국어 👩🏽‍💻\" // return 12\nlet count = 3"
        let tokens = TranscriptCodeSyntax.tokens(in: source, language: "swift")
        let ns = source as NSString
        XCTAssertEqual(tokens.filter { $0.kind == .keyword }.map { ns.substring(with: $0.range) }, ["let", "let"])
        XCTAssertEqual(tokens.filter { $0.kind == .number }.map { ns.substring(with: $0.range) }, ["3"])
        XCTAssertEqual(tokens.filter { $0.kind == .comment }.map { ns.substring(with: $0.range) }, ["// return 12"])
        XCTAssertTrue(TranscriptCodeSyntax.tokens(in: source, language: "unknown").isEmpty)
    }

    @MainActor
    func testCopyPreservesTheExactUnicodePayloadAndDoesNotReplaceClipboardWhenUnavailable() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let source = "  let 한글 = \"👩🏽‍💻\"\r\n\n"
        XCTAssertTrue(TranscriptClipboard.copy(source, to: board))
        XCTAssertEqual(board.string(forType: .string), source)
        XCTAssertFalse(TranscriptClipboard.copy(nil, to: board))
        XCTAssertEqual(board.string(forType: .string), source)
    }

    func testReadingPositionSurvivesContentGrowthAndResumesOnlyAtBottom() {
        var state = TranscriptScrollFollowState()
        state.observe(distance: 400, userDriven: true)
        XCTAssertFalse(state.isFollowing)
        state.observe(distance: 900, userDriven: false)
        XCTAssertFalse(state.isFollowing)
        XCTAssertTrue(state.showsLatest)
        state.observe(distance: 12, userDriven: true)
        XCTAssertTrue(state.isFollowing)
        state.observe(distance: 600, userDriven: false)
        XCTAssertTrue(state.isFollowing)
        XCTAssertFalse(state.showsLatest)
    }

    func testOnlyAnIdleLatestFailureCanRestoreItsOwnRequest() {
        let user = TranscriptEntry(content: .user(text: "  Keep this exact request\n"))
        let error = TranscriptEntry(content: .error(message: "timeout", recoverable: true))
        let entries = [user, error]
        XCTAssertEqual(TranscriptRecoveryProjection.editableRequest(for: error.id, entries: entries, status: .failed),
                       "  Keep this exact request\n")
        for status: SessionStatus in [.running, .waitingForApproval, .completed] {
            XCTAssertNil(TranscriptRecoveryProjection.editableRequest(for: error.id, entries: entries, status: status))
        }
        let nextUser = TranscriptEntry(content: .user(text: "A newer request"))
        XCTAssertNil(TranscriptRecoveryProjection.editableRequest(for: error.id, entries: entries + [nextUser], status: .failed))
        let answer = TranscriptEntry(content: .assistant(text: "Recovered", isStreaming: false))
        XCTAssertNil(TranscriptRecoveryProjection.editableRequest(for: error.id, entries: entries + [answer], status: .ready))
        XCTAssertNil(TranscriptRecoveryProjection.editableRequest(for: error.id, entries: [error], status: .failed))
    }

    func testUnfinishedWorkAndErrorsAreNeverHiddenByAFinalAnswer() {
        let user = TranscriptEntry(content: .user(text: "Check"))
        let final = TranscriptEntry(content: .assistant(text: "Answer", isStreaming: false))
        let unfinished: [TranscriptEntryContent] = [
            .assistant(text: "Still streaming", isStreaming: true),
            .error(message: "Not completed", recoverable: true),
            .activity(HarnessActivity(id: "running", kind: "tool", title: "Running", detail: nil), state: .running)
        ]
        for content in unfinished {
            let work = TranscriptEntry(content: content)
            let turn = TranscriptConversationProjection.presentation(
                from: [user, work, final], harness: .claudeCode, status: .ready, latestTurnIsComplete: true
            ).turns[0]
            // Work still going keeps the turn open; an error is the turn's outcome card, drawn above the
            // fold, or one the turn went past stays in view when the work folds (2026-10-23, the one rule
            // for every harness).
            XCTAssertTrue(!turn.foldsWork || turn.outcome != nil || turn.workKeptWhenFolded.map(\.id) == [work.id.uuidString],
                          "\(content)")
            XCTAssertEqual(turn.answers.map(\.id), [final.id.uuidString], "\(content)")
        }
    }
}
