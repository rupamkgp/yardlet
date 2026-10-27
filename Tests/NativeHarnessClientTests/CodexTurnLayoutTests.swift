import Foundation
import XCTest
@testable import NativeHarnessClient

/// The sections the Codex timeline draws a turn in, and what a turn offers, per fixture: the
/// visual fixture, the timeline rendering fixtures, and the edge cases the rules name.
final class CodexTurnLayoutTests: XCTestCase {
    private let decoder = CodexTaskDecoder()

    #if DEBUG
    func testTheVisualFixtureLaysOutAFinishedAndARunningTurn() throws {
        let thread = try XCTUnwrap(ConversationFixtures.codexTimeline().thread)
        XCTAssertEqual(thread.turns.map { sections($0, showsTurnLabel: thread.turns.count > 1) }, [
            Sections(
                // The fixture's answer comes before its calls, so nothing closes the turn: it stays where
                // Codex wrote it (`ConversationTurnLayout`).
                prompt: ["visual-user-001"], notice: [],
                work: ["visual-agent-001", "visual-command-001", "visual-file-001", "visual-collab-001", "visual-unknown-001"],
                answer: [],
                hasWorkDetails: true, hasUserMessage: true, showsWorkSummary: true, hasAgentOutput: true
            ),
            Sections(
                prompt: ["visual-user-002"], notice: [],
                work: [
                    "visual-agent-002", "visual-reasoning-002", "visual-subagent-002", "visual-mcp-002",
                    "visual-mcp-003", "visual-web-002", "visual-sleep-002", "visual-command-002",
                    "visual-patch-002"
                ],
                answer: [],
                hasWorkDetails: true, hasUserMessage: true, showsWorkSummary: true, hasAgentOutput: true
            )
        ])
        // The running turn neither offers an edit nor a plan.
        XCTAssertNil(CodexTurnLayout.editableTurnID(in: thread))
        XCTAssertNil(CodexTurnLayout.offeredPlan(for: try XCTUnwrap(thread.turns.last), in: thread))
    }
    #endif

    func testAStoppedTurnKeepsItsCommandInTheWorkAndIsTheOneToEdit() {
        let thread = thread([
            turn("turn-1", status: "completed", durationMs: 41_000, items: [
                user("u1", "테스트를 돌려 줘"), command("c0", status: "completed"), answer("a1", "All 30 tests pass.")
            ]),
            turn("turn-2", status: "interrupted", durationMs: 22_000, items: [
                user("u2", "Run the full suite again"), command("c1", status: "interrupted")
            ])
        ])
        XCTAssertEqual(thread.turns.map { sections($0, showsTurnLabel: true) }, [
            Sections(prompt: ["u1"], notice: [], work: ["c0"], answer: ["a1"],
                     hasWorkDetails: true, hasUserMessage: true, showsWorkSummary: true, hasAgentOutput: true),
            Sections(prompt: ["u2"], notice: [], work: ["c1"], answer: [],
                     hasWorkDetails: true, hasUserMessage: true, showsWorkSummary: true, hasAgentOutput: false)
        ])
        XCTAssertEqual(CodexTurnLayout.editableTurnID(in: thread), "turn-2")
    }

    func testAPlanModeTurnAnswersWithItsPlanAndOffersToImplementIt() throws {
        var planTurn = turn("turn-1", status: "completed", durationMs: 95_000, items: [
            user("u1", "중지된 턴 표시를 고치는 계획을 세워 줘"),
            plan("p1", "\n# Show stopped turns\n\n1. Read `Stopped`.\n"),
            answer("a1", "This keeps the change to the timeline.")
        ])
        planTurn.items.append(notice("n1", kind: "modelRerouted"))
        planTurn.items.append(notice("n2", kind: "warning"))
        let thread = thread([planTurn])
        XCTAssertEqual(sections(planTurn, showsTurnLabel: false), Sections(
            prompt: ["u1"], notice: ["n1", "n2"], work: [], answer: ["p1", "a1"],
            hasWorkDetails: false, hasUserMessage: true, showsWorkSummary: true, hasAgentOutput: true
        ))
        XCTAssertEqual(CodexTurnLayout.offeredPlan(for: planTurn, in: thread), "# Show stopped turns\n\n1. Read `Stopped`.")
        XCTAssertEqual(CodexTurnLayout.editableTurnID(in: thread), "turn-1")
    }

    func testOnlyTheLatestFinishedTurnOffersItsPlan() {
        var thread = thread([
            turn("turn-1", status: "completed", items: [user("u1", "Plan the fix"), plan("p1", "# Plan\n1. Fix it")]),
            turn("turn-2", status: "completed", items: [
                user("u2", CodexPlanImplementation.request(for: "# Plan\n1. Fix it")), answer("a2", "Fixed.")
            ]),
            turn("turn-3", status: "inProgress", items: [user("u3", "Plan the next step")])
        ])
        thread.turns[2].items.append(decoder.item(
            from: plan("p3", "# Next\n1. Measure the"), fallbackID: "p3", lifecycle: .inProgress
        ))
        XCTAssertEqual(thread.turns.map { CodexTurnLayout.offeredPlan(for: $0, in: thread) }, [nil, nil, nil])
        XCTAssertNil(CodexTurnLayout.editableTurnID(in: thread), "A running turn holds every edit")
        XCTAssertEqual(sections(thread.turns[2], showsTurnLabel: true), Sections(
            prompt: ["u3"], notice: [], work: [], answer: ["p3"],
            hasWorkDetails: false, hasUserMessage: true, showsWorkSummary: true, hasAgentOutput: true
        ))

        // A stopped or failed plan turn offers nothing.
        let stopped = self.thread([turn("turn-1", status: "interrupted", items: [user("u1", "Plan"), plan("p1", "# Plan")])])
        XCTAssertNil(CodexTurnLayout.offeredPlan(for: stopped.turns[0], in: stopped))
    }

    /// Commentary is work and a message with an unknown phase answers; only the message that ends the
    /// turn closes it (`ConversationTurnLayout`), so a compaction after the answers leaves them in the
    /// work where Codex wrote them, as the Codex app draws no answer under such a turn.
    func testCommentaryIsWorkAndAnUnknownPhaseIsAnAnswer() {
        let turn = turn("turn-1", status: "completed", items: [
            user("u1", "Go"),
            message("m1", "Looking around", phase: "commentary"),
            message("m2", "Something new", phase: "future_phase"),
            message("m3", "Done", phase: "final_answer"),
            .object(["id": .string("r1"), "type": .string("reasoning"), "summary": .array([]), "content": .array([])]),
            .object(["id": .string("x1"), "type": .string("contextCompaction")])
        ])
        XCTAssertEqual(sections(turn, showsTurnLabel: false), Sections(
            prompt: ["u1"], notice: [], work: ["m1", "m2", "m3", "r1", "x1"], answer: [],
            hasWorkDetails: true, hasUserMessage: true, showsWorkSummary: true, hasAgentOutput: true
        ))
    }

    func testTheHeaderAppearsOnlyWhenTheTurnHasSomethingToHead() {
        let empty = turn("turn-1", status: "completed", items: [])
        XCTAssertEqual(sections(empty, showsTurnLabel: false), Sections(
            prompt: [], notice: [], work: [], answer: [],
            hasWorkDetails: false, hasUserMessage: false, showsWorkSummary: false, hasAgentOutput: false
        ))
        XCTAssertTrue(sections(empty, showsTurnLabel: true).showsWorkSummary, "A turn label heads it")
        XCTAssertTrue(sections(turn("t", status: "completed", durationMs: 1_000, items: []),
                                      showsTurnLabel: false).showsWorkSummary, "Its duration heads it")

        var started = empty
        started.startedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(sections(started, showsTurnLabel: false).showsWorkSummary, "Its start heads it")

        var paged = empty
        paged.itemsNextCursor = "next"
        XCTAssertTrue(sections(paged, showsTurnLabel: false).hasWorkDetails, "More items to load are work")

        var planned = empty
        planned.plan = CodexPlanState(explanation: nil, steps: [])
        XCTAssertTrue(sections(planned, showsTurnLabel: false).hasWorkDetails, "A step plan is work")
    }

    func testOnlyWrittenTextCountsAsOutput() {
        let blank = turn("turn-1", status: "inProgress", items: [
            user("u1", "Go"), message("m1", "  \n", phase: "final_answer"), plan("p1", " "),
            command("c1", status: "inProgress")
        ])
        XCTAssertFalse(CodexTurnLayout(turn: blank).hasAgentOutput)
        let commentary = turn("turn-1", status: "inProgress", items: [message("m1", "Reading", phase: "commentary")])
        XCTAssertTrue(CodexTurnLayout(turn: commentary).hasAgentOutput)
    }

    func testARequestTheComposerCannotReadBackStaysVisibleWithoutAMenu() {
        // The empty input a capacity retry sends has nothing to put back in the composer.
        let retried = turn("turn-1", status: "completed", items: [
            .object(["id": .string("u1"), "type": .string("userMessage"), "content": .array([])]),
            answer("a1", "Answered")
        ])
        let layout = sections(retried, showsTurnLabel: false)
        XCTAssertEqual(layout.prompt, ["u1"])
        XCTAssertFalse(layout.hasUserMessage)
        XCTAssertFalse(layout.showsWorkSummary)
    }

    func testTheEditableTurnIsTheLatestOneThePersonSentAMessageIn() {
        // A turn the provider started on its own (no sent message) leaves the edit on the one before.
        let thread = thread([
            turn("turn-1", status: "completed", items: [user("u1", "First")]),
            turn("turn-2", status: "completed", items: [user("u2", "Second"), answer("a2", "Done")]),
            turn("turn-3", status: "completed", items: [answer("a3", "Reviewed")])
        ])
        XCTAssertEqual(CodexTurnLayout.editableTurnID(in: thread), "turn-2")
        XCTAssertNil(CodexTurnLayout.editableTurnID(in: self.thread([
            turn("turn-1", status: "completed", items: [answer("a1", "Nothing was sent")])
        ])))
    }

    // MARK: - Fixtures

    private struct Sections: Equatable {
        let prompt: [String]
        let notice: [String]
        let work: [String]
        let answer: [String]
        let hasWorkDetails: Bool
        let hasUserMessage: Bool
        let showsWorkSummary: Bool
        let hasAgentOutput: Bool
    }

    /// The turn as the projection lays it out: its parts, by the rule every harness shares.
    private func sections(_ turn: CodexTurnState, showsTurnLabel: Bool) -> Sections {
        let layout = CodexTurnLayout(turn: turn)
        let projected = CodexConversationProjection.turn(.init(
            turn: turn, workspaceURL: URL(filePath: "/tmp/yardlet-layout", directoryHint: .isDirectory),
            showsTurnLabel: showsTurnLabel, isLatest: true, isEditable: false, canRetry: false,
            approvals: [], serverRequests: [], history: .none
        ))
        return Sections(
            prompt: projected.prompt.map(\.id), notice: projected.notices.map(\.id),
            work: projected.work.map(\.id), answer: projected.answers.map(\.id),
            hasWorkDetails: projected.hasWorkDetails, hasUserMessage: layout.hasUserMessage,
            showsWorkSummary: projected.showsHeader, hasAgentOutput: layout.hasAgentOutput
        )
    }

    private func thread(_ turns: [CodexTurnState]) -> CodexThreadState {
        var thread = decoder.thread(from: .object(["id": .string("thread-layout")]))!
        thread.turns = turns
        return thread
    }

    private func turn(_ id: String, status: String, durationMs: Int64? = nil, items: [JSONValue]) -> CodexTurnState {
        var value: [String: JSONValue] = ["id": .string(id), "status": .string(status), "items": .array(items)]
        if let durationMs { value["durationMs"] = .integer(durationMs) }
        return decoder.turn(from: .object(value), fallbackID: id)!
    }

    private func user(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("userMessage"),
                 "content": .array([.object(["type": .string("text"), "text": .string(text)])])])
    }

    private func answer(_ id: String, _ text: String) -> JSONValue {
        message(id, text, phase: "final_answer")
    }

    private func message(_ id: String, _ text: String, phase: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("agentMessage"), "text": .string(text), "phase": .string(phase)])
    }

    private func plan(_ id: String, _ text: String) -> JSONValue {
        .object(["id": .string(id), "type": .string("plan"), "text": .string(text)])
    }

    private func command(_ id: String, status: String) -> JSONValue {
        .object([
            "id": .string(id), "type": .string("commandExecution"), "command": .string("swift test"),
            "cwd": .string("/tmp/yardlet-layout"), "status": .string(status), "commandActions": .array([]),
            "aggregatedOutput": .null, "exitCode": .null
        ])
    }

    private func notice(_ id: String, kind: String) -> CodexItemState {
        decoder.item(from: .object([
            "id": .string(id), "type": .string(CodexNoticeItem.itemType),
            "kind": .string(kind), "message": .string("Notice \(id)")
        ]), fallbackID: id, lifecycle: .completed)
    }
}
