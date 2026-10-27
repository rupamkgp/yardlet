import XCTest
@testable import NativeHarnessClient

/// Reading a long Codex thread: the follow state, and the per-turn lookups the conversation model
/// holds.
final class CodexTimelineReadingTests: XCTestCase {
    func testScrollingWithinSameRegionDoesNotInvalidateTimelineFollowState() {
        var state = TranscriptScrollFollowState()
        state.observe(distance: 100, userDriven: true)
        let reading = state
        for distance: CGFloat in [200, 800, 15_000, 50] {
            state.observe(distance: distance, userDriven: true)
            XCTAssertEqual(state, reading)
        }
        state.observe(distance: 48, userDriven: true)
        XCTAssertTrue(state.isFollowing)
        XCTAssertFalse(state.showsLatest)
        let atBottom = state
        state.observe(distance: 0, userDriven: true)
        XCTAssertEqual(state, atBottom)
    }

    func testIndexedHistoryMatchesExistingProjectionForEveryTurnInLargeThread() {
        var thread = CodexTaskDecoder().thread(from: .object(["id": .string("long-history")]))!
        thread.turns = (1...180).map { index in
            CodexTaskDecoder().turn(from: .object([
                "id": .string("turn-\(index)"), "status": .string("completed"),
                "items": .array([
                    .object(["id": .string("change-\(index)"), "type": .string("fileChange"),
                             "status": .string("completed"),
                             "changes": .array([.object(["path": .string("Sources/File\(index).swift")])])]),
                    .object(["id": .string("answer-\(index)"), "type": .string("agentMessage"),
                             "text": .string(String(repeating: "Paragraph 8: 한글 👩🏽‍💻\n", count: 8))])
                ])
            ]), fallbackID: "turn-\(index)")!
        }
        let state = CodexTaskState(thread: thread)
        let workspace = URL(filePath: "/tmp/codex-reading-fixture")
        let selection = CodexHistorySearchSelection(query: "Paragraph 8", snippet: nil)
        let start = Date()
        let indexed = lookups(state, workspaceURL: workspace, historySelection: selection)
        let indexedTime = Date().timeIntervalSince(start)
        let oldStart = Date()
        for turn in thread.turns {
            // Equivalence with the previous per-turn lookups, including exact paths and item IDs.
            XCTAssertEqual(indexed.changesByTurn[turn.id],
                           CodexWorkSurfaceProjection.changes(from: state, workspaceURL: workspace)
                            .filter { $0.turnID == turn.id })
            XCTAssertEqual(indexed.historyItemsByTurn[turn.id],
                           Set(CodexHistorySearchProjection.hits(in: state, selection: selection)
                            .filter { $0.turnID == turn.id }.map(\.itemID)))
        }
        print(String(format: "180-turn projection comparison: indexed %.4f s; repeated lookups + assertions %.4f s",
                     indexedTime, Date().timeIntervalSince(oldStart)))
        XCTAssertEqual(indexed.changesByTurn.count, 180)
        XCTAssertEqual(indexed.historyItemsByTurn.count, 180)
    }

    func testExactHistoryHitAndPendingRequestsRemainScopedToTheirTurn() {
        let decoder = CodexTaskDecoder()
        var thread = decoder.thread(from: .object(["id": .string("thread")]))!
        thread.turns = ["a", "b"].map { id in
            decoder.turn(from: .object([
                "id": .string(id), "items": .array([.object([
                    "id": .string("shared-item"), "type": .string("agentMessage"), "text": .string("match")
                ])])
            ]), fallbackID: id)!
        }
        var state = CodexTaskState(thread: thread)
        state.approvalsByID["approval"] = CodexApprovalState(
            id: "approval", method: "test", threadID: "thread", turnID: "a", itemID: nil,
            resolution: .pending, raw: nil
        )
        state.serverRequestsByID["request"] = CodexServerRequestState(
            id: "request", method: "test", kind: .unknown("test"), threadID: "thread", turnID: "b",
            itemID: nil, params: nil, resolution: .pending
        )
        state.approvalsByID["unscoped"] = CodexApprovalState(
            id: "unscoped", method: "test", threadID: "thread", turnID: nil, itemID: nil,
            resolution: .pending, raw: nil
        )
        let projection = lookups(
            state, workspaceURL: URL(filePath: "/tmp"),
            historySelection: CodexHistorySearchSelection(query: "match", snippet: nil,
                                                        turnID: "b", itemID: "shared-item")
        )
        XCTAssertNil(projection.historyItemsByTurn["a"])
        XCTAssertEqual(projection.historyItemsByTurn["b"], ["shared-item"])
        XCTAssertEqual(projection.approvalsByTurn["a"]?.map(\.id), ["approval"])
        XCTAssertNil(projection.approvalsByTurn["b"])
        XCTAssertNil(projection.approvalsByTurn[""])
        XCTAssertEqual(projection.requestsByTurn["b"]?.map(\.id), ["request"])
        XCTAssertNil(projection.requestsByTurn["a"])
    }

    /// A thread's per-turn lookups as the conversation model holds them.
    private struct Lookups {
        var changesByTurn: [String: [CodexChangeHandoff]] = [:]
        var historyItemsByTurn: [String: Set<String>] = [:]
        var approvalsByTurn: [String: [CodexApprovalState]] = [:]
        var requestsByTurn: [String: [CodexServerRequestState]] = [:]
    }

    private func lookups(
        _ state: CodexTaskState, workspaceURL: URL, historySelection: CodexHistorySearchSelection
    ) -> Lookups {
        var lookups = Lookups()
        let presentation = CodexConversationProjection.presentation(
            state, workspaceURL: workspaceURL, historySelection: historySelection
        )
        for turn in presentation.turns {
            let items = turn.prompt + turn.notices + turn.work + turn.answers
            let changes = items.flatMap { item -> [CodexChangeHandoff] in
                if case let .fileChange(change) = item.kind { return change.handoffs }
                return []
            }
            if !changes.isEmpty { lookups.changesByTurn[turn.id] = changes }
            let hits = Set(items.filter(\.isHistoryMatch).map(\.id))
            if !hits.isEmpty { lookups.historyItemsByTurn[turn.id] = hits }
            for request in turn.requests {
                switch request.source {
                case let .codexApproval(approval): lookups.approvalsByTurn[turn.id, default: []].append(approval)
                case let .codexServerRequest(serverRequest):
                    lookups.requestsByTurn[turn.id, default: []].append(serverRequest)
                case .transcript: break
                }
            }
        }
        return lookups
    }
}
