import Foundation
import XCTest
@testable import NativeHarnessClient

/// The renderer's engine (plan M9): a turn's parts in its record's order, and the local window over a
/// long conversation's turns (A5.3, D11).
final class ConversationTurnWindowTests: XCTestCase {
    func testATranscriptTurnKeepsItsEntriesOrderWhateverPartEachBecame() throws {
        let user = TranscriptEntry(content: .user(text: "Fix it"))
        let note = TranscriptEntry(content: .assistant(text: "Looking.", isStreaming: false))
        let waiting = TranscriptEntry(content: .permission(
            PermissionRequest(id: "p", title: "Run", detail: nil, command: "ls"), state: .pending
        ))
        let plan = TranscriptEntry(content: .plan("☐ Step"))
        let tool = TranscriptEntry(content: .activity(HarnessActivity(id: "t", kind: "Bash", title: "Bash"), state: .completed))
        let allowed = TranscriptEntry(content: .permission(
            PermissionRequest(id: "a", title: "Bash", detail: nil, command: nil, toolCallID: "t"), state: .allowed
        ))
        let failure = TranscriptEntry(content: .error(message: "Broke", recoverable: true))
        let entries = [user, note, waiting, plan, tool, allowed, failure]
        let presentation = TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: false
        )
        let turn = try XCTUnwrap(presentation.turns.first)
        // The allowed request reads on its tool's card, so the order leaves it out.
        XCTAssertEqual(turn.recordOrder, [user, note, waiting, plan, tool, failure].map(\.id.uuidString))
        XCTAssertEqual(turn.partsInRecordOrder.map(\.id), turn.recordOrder)
        guard case .request = turn.partsInRecordOrder[2], case .plan = turn.partsInRecordOrder[3],
              case .outcome = turn.partsInRecordOrder[5] else {
            return XCTFail("\(turn.partsInRecordOrder)")
        }
        // A Codex turn has no record order of its own.
        XCTAssertTrue(ConversationTurn(id: "turn-1", status: .completed, timing: .init())
            .partsInRecordOrder.isEmpty)
    }

    func testTheWindowKeepsTheLatestTurnsAndCountsTheRest() {
        let presentation = transcript(turns: 10)
        XCTAssertEqual(ConversationTurnWindow().apply(to: presentation), presentation, "ten turns fit the window")
        // D11: the latest 10 turns, and 10 more at a time (40 until the eager stack, 2026-10-18).
        XCTAssertEqual(ConversationTurnWindow.initialTurnCount, 10)
        XCTAssertEqual(ConversationTurnWindow.step, 10)
        let long = transcript(turns: 90)
        XCTAssertEqual(ConversationTurnWindow().apply(to: long).turns.map(\.id), Array(long.turns.suffix(10)).map(\.id))
        XCTAssertEqual(ConversationTurnWindow().apply(to: long).earlier, .local(hiddenCount: 80))
        XCTAssertEqual(ConversationTurnWindow().widened().apply(to: long).earlier, .local(hiddenCount: 70))

        let window = ConversationTurnWindow(turnCount: 4)
        let windowed = window.apply(to: presentation)
        XCTAssertEqual(windowed.turns.map(\.id), Array(presentation.turns.suffix(4)).map(\.id))
        XCTAssertEqual(windowed.earlier, .local(hiddenCount: 6))
        XCTAssertTrue(window.hides(presentation.turns[2].id, in: presentation))
        XCTAssertFalse(window.hides(presentation.turns[8].id, in: presentation))
        XCTAssertFalse(window.hides("elsewhere", in: presentation))

        XCTAssertEqual(window.widened().turnCount, 4 + ConversationTurnWindow.step)
        // A turn the reader went to stays in, with every turn after it.
        var reached = window
        reached.earliestTurnID = presentation.turns[2].id
        XCTAssertEqual(reached.apply(to: presentation).turns.map(\.id), Array(presentation.turns[2...]).map(\.id))
        XCTAssertEqual(reached.apply(to: presentation).earlier, .local(hiddenCount: 2))
    }

    /// A Codex thread pages its own turns; the window applies to the loaded ones, and the provider's
    /// cursor stands once every loaded turn is in the window (D11).
    func testTheWindowAppliesToTheTurnsAProviderLoaded() {
        var paged = transcript(turns: 10)
        paged.earlier = .provider(cursor: "earlier")
        let windowed = ConversationTurnWindow(turnCount: 2).apply(to: paged)
        XCTAssertEqual(windowed.turns.map(\.id), Array(paged.turns.suffix(2)).map(\.id))
        XCTAssertEqual(windowed.earlier, .local(hiddenCount: 8))
        XCTAssertEqual(ConversationTurnWindow(turnCount: 10).apply(to: paged), paged)
    }

    private func transcript(turns: Int) -> ConversationPresentation {
        let entries = (1...turns).flatMap { index in
            [TranscriptEntry(content: .user(text: "Request \(index)")),
             TranscriptEntry(content: .assistant(text: "Answer \(index)", isStreaming: false))]
        }
        return TranscriptConversationProjection.presentation(
            from: entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )
    }
}
