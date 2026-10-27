import XCTest
@testable import NativeHarnessClient

final class CodexHistorySearchProjectionTests: XCTestCase {
    func testImportListNavigationUsesListedOrderAndWraps() throws {
        let history = VisualFixtureScenario.conversation.codexHistory.map(\.id)
        XCTAssertEqual(history, ["visual-codex-session", "fixture-history-2"])
        // A search page that lists the second thread first and repeats it on the next page.
        let listed = [history[1], history[0], history[1]]
        XCTAssertEqual(CodexHistorySearchProjection.targetID(in: listed, selectedID: history[1], offset: 1), history[0])
        XCTAssertEqual(CodexHistorySearchProjection.targetID(in: listed, selectedID: history[0], offset: 1), history[1],
                       "The repeated row counts once, so Down wraps to the first")
        XCTAssertEqual(CodexHistorySearchProjection.targetID(in: listed, selectedID: nil, offset: -1), history[0])
        XCTAssertEqual(CodexHistorySearchProjection.targetID(in: listed, selectedID: "gone", offset: 1), history[1],
                       "A stale selection starts before the first row for Down")
    }

    func testImportListNavigationFailsClosedForEmptyResultsAndZeroOffset() {
        XCTAssertNil(CodexHistorySearchProjection.targetID(in: [], selectedID: nil, offset: 1))
        XCTAssertNil(CodexHistorySearchProjection.targetID(in: ["thread"], selectedID: nil, offset: 0))
    }

    func testSegmentsPreserveProviderTextAndMarkCaseInsensitiveMatches() {
        XCTAssertEqual(
            CodexHistorySearchProjection.segments(
                "Restore the Codex shell",
                query: "codex"
            ),
            [
                CodexHistorySearchSegment(text: "Restore the ", isMatch: false),
                CodexHistorySearchSegment(text: "Codex", isMatch: true),
                CodexHistorySearchSegment(text: " shell", isMatch: false)
            ]
        )
    }

    func testSegmentsHandleRepeatedMatchesAndEmptyQueryWithoutInventingText() {
        XCTAssertEqual(
            CodexHistorySearchProjection.segments("abab", query: "ab"),
            [
                CodexHistorySearchSegment(text: "ab", isMatch: true),
                CodexHistorySearchSegment(text: "ab", isMatch: true)
            ]
        )
        XCTAssertEqual(
            CodexHistorySearchProjection.segments("History", query: ""),
            [CodexHistorySearchSegment(text: "History", isMatch: false)]
        )
        XCTAssertEqual(CodexHistorySearchProjection.segments("", query: "history"), [])
    }

    func testAccessibleSummaryOmitsMissingSnippet() {
        XCTAssertEqual(
            CodexHistorySearchProjection.accessibleSummary(
                title: "Native shell",
                snippet: nil,
                updatedLabel: "updated just now"
            ),
            "Native shell, updated just now"
        )
    }

    func testHydratedThreadSearchReturnsStableTurnAndItemHitsWithoutProviderWork() throws {
        let fixture = VisualFixtureScenario.conversation
        let session = try XCTUnwrap(fixture.sessions.first)
        let state = try XCTUnwrap(fixture.codexPresentation[session.id])

        XCTAssertEqual(
            CodexHistorySearchProjection.hits(in: state, query: "provider identity"),
            [CodexHistorySearchHit(turnID: "visual-turn-001", itemID: "visual-agent-001")]
        )
        XCTAssertEqual(
            CodexHistorySearchProjection.matchingTurnIDs(in: state, query: "provider identity"),
            ["visual-turn-001"]
        )
        XCTAssertTrue(CodexHistorySearchProjection.hits(in: state, query: " ").isEmpty)
    }

    func testHydratedThreadSearchIncludesObjectShapedFileChangePaths() {
        let snapshot: JSONValue = .object([
            "id": .string("thread"),
            "turns": .array([
                .object([
                    "id": .string("turn"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "id": .string("change"),
                            "type": .string("fileChange"),
                            "status": .string("completed"),
                            "changes": .array([
                                .object([
                                    "path": .string("Sources/NativeHarnessClient/AppModel.swift"),
                                    "kind": .string("modified"),
                                    "line": .integer(742)
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(snapshot, to: &state))

        XCTAssertEqual(
            CodexHistorySearchProjection.hits(
                in: state,
                query: "AppModel.swift"
            ),
            [CodexHistorySearchHit(turnID: "turn", itemID: "change")]
        )
        XCTAssertEqual(
            CodexHistorySearchProjection.hits(in: state, query: "742"),
            [CodexHistorySearchHit(turnID: "turn", itemID: "change")]
        )
    }

    func testProviderOccurrenceSelectionWinsOverLocalTextGuess() throws {
        let fixture = VisualFixtureScenario.conversation
        let session = try XCTUnwrap(fixture.sessions.first)
        let state = try XCTUnwrap(fixture.codexPresentation[session.id])
        let selection = CodexHistorySearchSelection(
            query: "a query that is not in the fixture",
            snippet: "provider snippet",
            threadID: state.thread?.id,
            turnID: "visual-turn-001",
            itemID: "visual-agent-001",
            turnCursor: "turn-cursor",
            snippetMatchRange: CodexTextRange(start: 0, end: 8)
        )

        XCTAssertEqual(
            CodexHistorySearchProjection.hits(in: state, selection: selection),
            [CodexHistorySearchHit(turnID: "visual-turn-001", itemID: "visual-agent-001")]
        )
    }

    func testUserInputSearchIncludesVisibleTypedLabelsAndLegacyText() throws {
        let snapshot: JSONValue = .object([
            "id": .string("thread"),
            "turns": .array([.object([
                "id": .string("turn"), "status": .string("completed"),
                "items": .array([.object([
                    "id": .string("request"), "type": .string("userMessage"),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("선택 범위 👩🏽‍💻")]),
                        .object(["type": .string("localImage"), "path": .string("/tmp/layout.png")]),
                        .object(["type": .string("skill"), "name": .string("review-ui"), "path": .string("/tmp/skill")]),
                        .string("Legacy request")
                    ])
                ])])
            ])])
        ])
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(snapshot, to: &state))
        for query in ["  선택 범위 👩🏽‍💻  ", "layout.png", "$review-ui", "LEGACY REQUEST"] {
            XCTAssertEqual(CodexHistorySearchProjection.hits(in: state, query: query), [
                CodexHistorySearchHit(turnID: "turn", itemID: "request")
            ], query)
            XCTAssertTrue(CodexHistorySearchProjection.contains(in: state, query: query), query)
        }
        for query in [" ", "missing text", "localImage"] {
            XCTAssertTrue(CodexHistorySearchProjection.hits(in: state, query: query).isEmpty, query)
            XCTAssertFalse(CodexHistorySearchProjection.contains(in: state, query: query), query)
        }
        XCTAssertFalse(CodexHistorySearchProjection.contains(in: .empty, query: "request"))
    }

    func testHistorySelectionRepositoryRoundTripsAndRemoves() throws {
        let suiteName = testDefaultsSuite("NativeHarnessClientTests.history-selection")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let repository = UserDefaultsCodexHistorySelectionRepository(
            defaults: defaults,
            keyPrefix: "selection."
        )
        let sessionID = UUID()
        let selection = CodexHistorySearchSelection(
            query: "provider identity",
            snippet: "Keep provider identity stable."
        )

        repository.save(selection, for: sessionID)
        XCTAssertEqual(repository.load(for: sessionID), selection)

        repository.remove(for: sessionID)
        XCTAssertNil(repository.load(for: sessionID))
    }
}
