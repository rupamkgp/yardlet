import Foundation
import XCTest
@testable import NativeHarnessClient

/// The Codex app's Plan mode follow-up (`implementPlanRequest.*`) and the command card's output
/// window. The implement request text is the app's `PLEASE IMPLEMENT THIS PLAN:` line.
final class CodexPlanImplementationTests: XCTestCase {
    private func turn(status: String, items: [JSONValue]) -> CodexTurnState {
        CodexTaskDecoder().turn(from: .object([
            "id": .string("turn-plan"), "status": .string(status), "items": .array(items)
        ]), fallbackID: "turn-plan")!
    }

    private func plan(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("plan"), "text": .string(text)])
    }

    func testOnlyACompletedTurnWithAPlanOffersIt() {
        let answer: JSONValue = .object([
            "id": .string("answer"), "type": .string("agentMessage"), "text": .string("Here is the plan.")
        ])
        XCTAssertEqual(
            offeredPlan(turn(status: "completed", items: [
                plan("draft", "# Old"), plan("final", "\n# Plan\n1. Ship it\n"), answer
            ])),
            "# Plan\n1. Ship it"
        )
        XCTAssertNil(offeredPlan(turn(status: "interrupted", items: [plan("p", "# Plan")])))
        XCTAssertNil(offeredPlan(turn(status: "inProgress", items: [plan("p", "# Plan")])))
        XCTAssertNil(offeredPlan(turn(status: "completed", items: [plan("p", "  \n")])))
        XCTAssertNil(offeredPlan(turn(status: "completed", items: [answer])))
    }

    /// The plan the conversation offers on a thread whose latest turn is `turn`.
    private func offeredPlan(_ turn: CodexTurnState) -> String? {
        var thread = CodexTaskDecoder().thread(from: .object(["id": .string("thread-plan")]))!
        thread.turns = [turn]
        return CodexConversationProjection.presentation(
            CodexTaskState(thread: thread), workspaceURL: URL(filePath: "/tmp"), historySelection: nil
        ).turns.last?.actions.planToImplement
    }

    func testTheImplementRequestIsTheCodexAppsAndShowsAsTheChoiceThatSentIt() {
        let request = CodexPlanImplementation.request(for: "# Plan\n1. Ship it")
        XCTAssertEqual(request, "PLEASE IMPLEMENT THIS PLAN:\n# Plan\n1. Ship it")
        let sent = CodexUserMessageItem(
            content: [.object(["type": .string("text"), "text": .string(request), "text_elements": .array([])])],
            clientID: nil
        )
        XCTAssertEqual(sent.displayText, L10n.string("Yes, implement this plan"))
        XCTAssertEqual(L10n.string("Yes, implement this plan", languageCode: "ko"), "네, 이 계획을 구현합니다")
        XCTAssertEqual(L10n.string("Implement this plan?", languageCode: "ko"), "이 계획을 구현할까요?")
        let typed = CodexUserMessageItem(
            content: [.object(["type": .string("text"), "text": .string("Please implement step 1 only")])],
            clientID: nil
        )
        XCTAssertEqual(typed.displayText, "Please implement step 1 only")
    }

    func testTheCommandCardShowsTheLatestLinesOfItsOutput() {
        let output = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let window = CodexCommandOutputWindow(output)
        XCTAssertEqual(window.text, (9...20).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertTrue(window.isTruncated)

        let short = CodexCommandOutputWindow("Build complete\n")
        XCTAssertEqual(short.text, "Build complete")
        XCTAssertFalse(short.isTruncated)

        let wide = CodexCommandOutputWindow(String(repeating: "한", count: 3_000) + "\r\nend")
        XCTAssertTrue(wide.text.hasSuffix("\r\nend"))
        XCTAssertEqual(wide.text.count, 2_400)
        XCTAssertTrue(wide.isTruncated)
    }
}
