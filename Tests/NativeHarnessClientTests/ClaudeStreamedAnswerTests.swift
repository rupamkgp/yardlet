import Foundation
import XCTest
@testable import NativeHarnessClient

/// A Claude answer that streams while a background subagent works shows once and whole
/// (2026-10-16: the orchestrator's long reply showed as three fragments starting mid-word and then
/// again in full, beside rows for its subagents' own commands; transcript
/// `4EBD4D44-7698-409A-A317-9F7AAD442C2E`). Frames follow the CLI's stream-json shapes (2.1.291 and
/// 2.1.295 read as bytes; 2.1.293 is no longer installed): `message_start`, `text_delta`s, the
/// subagent's `task_progress` and its own background command's `task_started` (`owned_by_subagent`,
/// `parent_task_id`) and `task_notification` between them, then the completed `assistant` message.
final class ClaudeStreamedAnswerTests: XCTestCase {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func delta(_ text: String) -> String {
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}}}"#
    }

    private func answers(in builder: TranscriptBuilder) -> [String] {
        builder.entries.compactMap { entry in
            if case let .assistant(text, _) = entry.content { return text }
            return nil
        }
    }

    private func activityIDs(in builder: TranscriptBuilder) -> [String] {
        builder.entries.compactMap { entry in
            if case let .activity(activity, _) = entry.content { return activity.id }
            return nil
        }
    }

    private static let full = "세 가지를 정리해 드리겠습니다. Claude도 계정을 모릅니다. 사용자 파일은 고치지 않습니다."

    func testAnAnswerStreamingBesideASubagentsBackgroundWorkShowsOnceAndWhole() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("정리해 줘")
        func apply(_ json: String) throws {
            for payload in projection.payloads(from: try decode(json)) { builder.apply(payload) }
        }
        // The main turn's background research agent, from an earlier step of the turn; its launch
        // result names the model it runs on.
        for json in [
            #"{"type":"assistant","message":{"id":"msg_0","content":[{"type":"tool_use","id":"agent","name":"Agent","input":{"description":"Research","prompt":"Read the code","run_in_background":true}}]}}"#,
            #"{"type":"system","subtype":"task_started","task_id":"sub","tool_use_id":"agent","description":"Research","task_type":"local_agent","is_backgrounded":true,"owned_by_subagent":false}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent","content":"Async agent launched"}]},"tool_use_result":{"isAsync":true,"status":"async_launched","agentId":"sub","description":"Research","resolvedModel":"claude-opus-5-5"}}"#
        ] { try apply(json) }
        // The answer streams; the subagent and its own background command report between deltas.
        try apply(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}}}"#)
        try apply(delta("세 가지를 "))
        try apply(#"{"type":"system","subtype":"task_progress","task_id":"sub","tool_use_id":"agent","description":"Research","last_tool_name":"Bash","usage":{"total_tokens":900,"tool_uses":3,"duration_ms":4000}}"#)
        try apply(delta("정리해 드리겠습니다. Claude도 계정을"))
        try apply(#"{"type":"system","subtype":"task_started","task_id":"sub-bash","owned_by_subagent":true,"tool_use_id":"sub-bash-tool","description":"Build tests with send experiment","is_backgrounded":true,"parent_task_id":"sub","task_type":"local_bash"}"#)
        // While it runs, the subagent's command is a row of the line above the composer, under
        // its subagent, and the answer is still one entry.
        let bar = BackgroundTasksProjection(entries: builder.entries)
        XCTAssertEqual(bar.rows.map(\.id), ["agent", "sub-bash-tool"])
        XCTAssertEqual(bar.rows.map(\.depth), [0, 1])
        XCTAssertEqual(bar.rows.map(\.showsHarnessModel), [true, false], "a shell has no model")
        XCTAssertEqual(bar.rows[0].activity.subtask?.model, "claude-opus-5-5")
        XCTAssertEqual(answers(in: builder), ["세 가지를 정리해 드리겠습니다. Claude도 계정을"])
        try apply(delta(" 모릅니다. 사용"))
        try apply(#"{"type":"system","subtype":"task_progress","task_id":"sub-bash","tool_use_id":"sub-bash-tool","description":"Build tests with send experiment","usage":{"total_tokens":0,"tool_uses":0,"duration_ms":900}}"#)
        try apply(delta("자 파일은 "))
        try apply(#"{"type":"system","subtype":"task_notification","task_id":"sub-bash","tool_use_id":"sub-bash-tool","status":"completed","summary":"Build complete","output_file":"/tmp/out"}"#)
        try apply(delta("고치지 않습니다."))
        XCTAssertEqual(answers(in: builder).count, 1, "Interleaved reports never split the answer while it streams")
        try apply(#"{"type":"system","subtype":"task_progress","task_id":"sub","tool_use_id":"agent","description":"Research","last_tool_name":"Read","usage":{"total_tokens":1200,"tool_uses":4,"duration_ms":6000}}"#)
        try apply(#"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"\#(Self.full)"}]}}"#)
        try apply(#"{"type":"result","subtype":"success","is_error":false,"result":"\#(Self.full)"}"#)

        XCTAssertEqual(answers(in: builder), [Self.full], "One answer, whole, with no fragment and no second copy")
        XCTAssertEqual(BackgroundTasksProjection(entries: builder.entries).rows.map(\.id), ["agent"],
                       "The finished command leaves the line")
        // The conversation shows the agent's card and the answer; the subagent's own command is no card.
        let turn = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: builder.entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
        ).turns.last)
        let cards = turn.work.compactMap { item -> String? in
            if case let .subagent(subagent) = item.kind { return subagent.title }
            if case let .command(command) = item.kind { return command.description ?? command.command }
            return nil
        }
        XCTAssertEqual(cards, ["Research"], "\(turn.work.map(\.kind))")
        guard case let .subagent(agent)? = turn.work.first(where: { if case .subagent = $0.kind { true } else { false } })?.kind
        else { return XCTFail("no agent card") }
        XCTAssertEqual(agent.model, "claude-opus-5-5", "The card names the model the CLI resolved")
    }

    /// CLI 2.1.291 marks a subagent's own command without naming its subagent: it is still no card,
    /// and the line lists it on its own.
    func testASubagentsCommandWithoutItsParentIsStillTheLinesNotTheSessions() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Go")
        builder.apply(.assistantDelta("Working on "))
        for json in [
            #"{"type":"system","subtype":"task_started","task_id":"b1","owned_by_subagent":true,"tool_use_id":"b1-tool","description":"Wait for the build","is_backgrounded":true,"task_type":"local_bash"}"#
        ] {
            for payload in projection.payloads(from: try decode(json)) { builder.apply(payload) }
        }
        builder.apply(.assistantDelta("it."))
        XCTAssertEqual(answers(in: builder), ["Working on it."])
        let bar = BackgroundTasksProjection(entries: builder.entries)
        XCTAssertEqual(bar.rows.map(\.id), ["b1-tool"])
        XCTAssertEqual(bar.rows.map(\.depth), [0])
        let turn = try XCTUnwrap(TranscriptConversationProjection.presentation(
            from: builder.entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
        ).turns.last)
        XCTAssertFalse(turn.work.contains { if case .command = $0.kind { true } else { false } })
    }

    /// The model an Agent call asks for names its card until its result reports the one it resolved.
    func testAnAgentCallsModelNamesItsCardUntilItsResultResolvesOne() throws {
        var projection = ClaudeSessionProjection()
        var activity: HarnessActivity?
        for json in [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{"description":"Review","prompt":"Review it","model":"sonnet"}}]}}"#,
            #"{"type":"system","subtype":"task_started","task_id":"t1","tool_use_id":"a1","description":"Review","task_type":"local_agent"}"#
        ] {
            for payload in projection.payloads(from: try decode(json)) {
                if case let .activityStarted(started) = payload { activity = started }
                if case let .activityUpdated(updated) = payload { activity = updated }
            }
        }
        XCTAssertEqual(activity?.subtask?.model, "sonnet")
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a1","content":[{"type":"text","text":"Looks good."}]}]},"tool_use_result":{"status":"completed","agentId":"t1","resolvedModel":"claude-sonnet-5","content":[{"type":"text","text":"Looks good."}]}}"#
        var completed: HarnessActivity?
        for case let .activityCompleted(done) in projection.payloads(from: try decode(result)) { completed = done }
        XCTAssertEqual(completed?.subtask?.model, "claude-sonnet-5")
        XCTAssertEqual(completed?.subtask?.agentID, "t1")
    }

    func testANewCardBetweenDeltasStillLeavesOneAnswerWhereItBegan() {
        var builder = TranscriptBuilder()
        builder.appendUser("Go")
        builder.apply(.assistantDelta("Part one, "))
        builder.apply(.activityStarted(HarnessActivity(id: "late", kind: "Agent", title: "Late agent", isBackground: true)))
        builder.apply(.assistantDelta("part two, "))
        builder.apply(.activityUpdated(HarnessActivity(id: "late", kind: "Agent", title: "Late agent", isBackground: true)))
        builder.apply(.assistantDelta("part three."))
        XCTAssertEqual(answers(in: builder), ["Part one, ", "part two, part three."],
                       "A new card ends the streamed entry; an update to a card already shown does not")
        builder.apply(.assistantMessageCompleted("Part one, part two, part three."))
        XCTAssertEqual(answers(in: builder), ["Part one, part two, part three."])
        guard case .assistant(_, false) = builder.entries[1].content else {
            return XCTFail("The answer takes the place of its first part: \(builder.entries.map(\.content))")
        }
        XCTAssertEqual(activityIDs(in: builder), ["late"])
    }

    func testEachMessageOfATurnCompletesOnlyWhatItStreamed() {
        var builder = TranscriptBuilder()
        builder.appendUser("Go")
        builder.apply(.assistantDelta("Checking."))
        builder.apply(.assistantMessageCompleted("Checking."))
        builder.apply(.activityStarted(HarnessActivity(id: "ls", kind: "Bash", title: "ls")))
        builder.apply(.activityCompleted(HarnessActivity(id: "ls", kind: "Bash", title: "ls", output: "a")))
        builder.apply(.assistantDelta("Found "))
        builder.apply(.activityStarted(HarnessActivity(id: "bg", kind: "Agent", title: "Background", isBackground: true)))
        builder.apply(.assistantDelta("one file."))
        builder.apply(.assistantMessageCompleted("Found one file."))
        XCTAssertEqual(answers(in: builder), ["Checking.", "Found one file."])
    }

    func testAPartOfAnUnfinishedMessageStaysWhenTheNextMessageCompletes() {
        var builder = TranscriptBuilder()
        builder.appendUser("Go")
        builder.apply(.assistantDelta("Interrupted thou"))
        builder.apply(.activityStarted(HarnessActivity(id: "tool", kind: "Bash", title: "pwd")))
        builder.apply(.assistantDelta("Next "))
        builder.apply(.assistantDelta("answer."))
        builder.apply(.assistantMessageCompleted("Next answer."))
        XCTAssertEqual(answers(in: builder), ["Interrupted thou", "Next answer."])
    }

    func testAMessageWithoutDeltasIsAddedOnce() {
        var builder = TranscriptBuilder()
        builder.appendUser("Go")
        builder.apply(.assistantMessageCompleted("Whole answer."))
        builder.apply(.turnCompleted)
        XCTAssertEqual(answers(in: builder), ["Whole answer."])
    }

    func testThinkingSplitByAProgressReportIsOneThoughtToo() {
        var builder = TranscriptBuilder()
        builder.appendUser("Go")
        builder.apply(.activityStarted(HarnessActivity(id: "agent", kind: "Agent", title: "Research", isBackground: true)))
        builder.apply(.reasoningDelta("Weighing "))
        builder.apply(.activityUpdated(HarnessActivity(id: "agent", kind: "Agent", title: "Research", isBackground: true)))
        builder.apply(.reasoningDelta("the options."))
        builder.apply(.reasoningCompleted("Weighing the options."))
        let thoughts = builder.entries.compactMap { entry -> String? in
            if case let .reasoning(text, _) = entry.content { return text }
            return nil
        }
        XCTAssertEqual(thoughts, ["Weighing the options."])
    }

    func testASubagentsTaskNamedOnlyByItsParentStaysOutOfTheSession() throws {
        var projection = ClaudeSessionProjection()
        for json in [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent","name":"Agent","input":{"description":"Research","prompt":"Read"}}]}}"#,
            #"{"type":"system","subtype":"task_started","task_id":"sub","tool_use_id":"agent","description":"Research","task_type":"local_agent"}"#
        ] { _ = projection.payloads(from: try decode(json)) }
        for json in [
            #"{"type":"system","subtype":"task_started","task_id":"child","tool_use_id":"child-tool","description":"Wait while research agents run","task_type":"local_bash","parent_task_id":"sub"}"#,
            #"{"type":"system","subtype":"task_progress","task_id":"child","description":"Wait while research agents run"}"#,
            #"{"type":"system","subtype":"task_updated","task_id":"child","patch":{"status":"completed"}}"#
        ] {
            XCTAssertTrue(projection.payloads(from: try decode(json)).isEmpty, json)
        }
        let own = try decode(#"{"type":"system","subtype":"task_started","task_id":"mine","tool_use_id":"mine-tool","description":"Run the build","task_type":"local_bash","is_backgrounded":true,"owned_by_subagent":false}"#)
        XCTAssertFalse(projection.payloads(from: own).isEmpty, "The session's own background command still shows")
    }
}
