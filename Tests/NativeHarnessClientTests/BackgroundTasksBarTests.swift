import Foundation
import XCTest
@testable import NativeHarnessClient

/// The line above the composer while a task's background agents and tasks run: what it lists as
/// Claude Code starts, reports and ends them, and "Stop all", which asks first and then stops each
/// task through the same route as its card.
final class BackgroundTasksBarTests: XCTestCase {
    func testTheBarListsBackgroundTasksFromStartThroughProgressToTheEnd() throws {
        var projection = ClaudeSessionProjection()
        var builder = TranscriptBuilder()
        builder.appendUser("Review the parser and run the slow suite")
        func apply(_ json: String) throws {
            for payload in projection.payloads(from: try ClaudeWireCodec().decodeLine(Data(json.utf8))) {
                builder.apply(payload)
            }
        }
        func bar() -> BackgroundTasksProjection { BackgroundTasksProjection(entries: builder.entries) }

        // A foreground agent runs inside the turn; it is the turn's own card, not a background task.
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"front","name":"Agent","input":{"description":"Read the lexer","prompt":"Read"}}]}}"#)
        try apply(#"{"type":"system","subtype":"task_started","task_id":"t-front","tool_use_id":"front","description":"Read the lexer","task_type":"local_agent","is_backgrounded":false}"#)
        XCTAssertFalse(bar().isShown)

        // A background agent and a background shell start.
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent","name":"Agent","input":{"description":"Review the parser","prompt":"Review","run_in_background":true}}]}}"#)
        try apply(#"{"type":"system","subtype":"task_started","task_id":"t-agent","tool_use_id":"agent","description":"Review the parser","task_type":"local_agent","is_backgrounded":true}"#)
        try apply(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"agent","content":"Agent launched in the background"}]}}"#)
        try apply(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"shell","name":"Bash","input":{"command":"swift test","run_in_background":true}}]}}"#)
        try apply(#"{"type":"system","subtype":"task_started","task_id":"t-shell","tool_use_id":"shell","description":"swift test","task_type":"local_bash","is_backgrounded":true}"#)
        XCTAssertEqual(bar().rows.map(\.id), ["agent", "shell"])
        XCTAssertEqual(bar().rows.map(\.title), ["Review the parser", "swift test"])
        XCTAssertEqual(bar().rows.map(\.opensConversation), [true, false])
        XCTAssertEqual(bar().rows.map(\.canStop), [true, true])
        XCTAssertEqual(bar().countText, L10n.format("%lld running tasks", 2))
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(BackgroundTasksProjection.elapsedText(since: start, now: start.addingTimeInterval(42)),
                       L10n.format("%llds", 42))
        XCTAssertEqual(BackgroundTasksProjection.elapsedText(since: start, now: start.addingTimeInterval(192)),
                       L10n.format("%lldm %llds", 3, 12))
        XCTAssertEqual(BackgroundTasksProjection.elapsedText(since: start, now: start.addingTimeInterval(3_900)),
                       L10n.format("%lldh %lldm", 1, 5))

        // The turn ends: the foreground agent stops with it, the background ones keep running.
        try apply(#"{"type":"system","subtype":"task_notification","task_id":"t-front","status":"completed","summary":"Done"}"#)
        try apply(#"{"type":"result","is_error":false,"subtype":"success"}"#)
        XCTAssertEqual(bar().rows.map(\.id), ["agent", "shell"])

        // Progress keeps the row and follows a new description.
        try apply(#"{"type":"system","subtype":"task_progress","task_id":"t-agent","usage":{"total_tokens":1200,"tool_uses":3,"duration_ms":4000},"last_tool_name":"Read"}"#)
        try apply(#"{"type":"system","subtype":"task_updated","task_id":"t-shell","patch":{"description":"swift test --parallel"}}"#)
        XCTAssertEqual(bar().rows.map(\.title), ["Review the parser", "swift test --parallel"])

        // Each leaves as Claude Code ends it; with none running the line hides.
        try apply(#"{"type":"system","subtype":"task_notification","task_id":"t-agent","status":"completed","summary":"Reviewed"}"#)
        XCTAssertEqual(bar().rows.map(\.id), ["shell"])
        XCTAssertEqual(bar().countText, L10n.string("1 running task"))
        try apply(#"{"type":"system","subtype":"task_updated","task_id":"t-shell","patch":{"status":"killed"}}"#)
        XCTAssertFalse(bar().isShown)
        XCTAssertTrue(bar().rows.isEmpty)
    }

    @MainActor
    func testStopAllAsksFirstThenStopsEachTaskNotAlreadyStopping() {
        let rows = ["a", "b", "c"].map { id in
            HarnessActivity(id: id, kind: "Agent", title: "Task \(id)", isBackground: true,
                            subtask: HarnessSubtaskReference(taskID: "task-\(id)", taskType: "local_agent"))
        }
        let projection = BackgroundTasksProjection(entries: rows.map {
            TranscriptEntry(content: .activity($0, state: .running))
        } + [TranscriptEntry(content: .activity(HarnessActivity(id: "done", kind: "Agent", title: "Done",
            isBackground: true, subtask: HarnessSubtaskReference(taskID: "task-done")), state: .completed))])
        XCTAssertEqual(projection.rows.map(\.id), ["a", "b", "c"])
        var stopped: [String] = []
        let actions = HarnessActivityActions(open: { _ in }, stop: { stopped.append($0.id) },
                                             isStopping: { $0 == "b" }, error: { _ in nil })
        var stopAll = BackgroundTasksStopAll()

        stopAll.request()
        XCTAssertTrue(stopAll.isConfirming)
        XCTAssertEqual(stopped, [], "Nothing stops before the person confirms")
        stopAll.cancel()
        XCTAssertFalse(stopAll.isConfirming)
        XCTAssertEqual(stopped, [])

        stopAll.request()
        XCTAssertEqual(stopAll.confirm(projection, actions: actions), ["a", "c"])
        XCTAssertEqual(stopped, ["a", "c"], "A task already stopping is not asked again")
        XCTAssertFalse(stopAll.isConfirming)

        // Without a stop route (a detached task) it stops nothing.
        stopped = []
        let readOnly = HarnessActivityActions(open: { _ in }, stop: nil, isStopping: { _ in false }, error: { _ in nil })
        XCTAssertEqual(stopAll.confirm(projection, actions: readOnly), [])
        XCTAssertEqual(stopped, [])
    }

    /// The real adapter on a fake CLI: "Stop all" sends Claude Code one `stop_task` per running
    /// background task, through `AppModel.stopClaudeSubtask` as each card's stop does, and never
    /// interrupts the conversation's turn.
    @MainActor
    func testStopAllSendsEachTaskItsOwnStopThroughTheCardsRoute() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-background-tasks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appending(path: "fixture-claude")
        try "#!/bin/sh\nprintf '%s\\n' '2.1.281 (Claude Code)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path(percentEncoded: false))
        let transport = FakeClaudeTransport()
        let adapter = YHPProviderCompatibilityAdapter(
            adapter: ClaudeAdapter(executableURL: executable, transportFactory: { _ in transport }),
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("BackgroundTasksBarTests")))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            registry: HarnessRegistry { _, _ in adapter as any HarnessAdapter },
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults, keyPrefix: "pending."),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            restoresIndexOnLaunch: false
        )
        let created = await model.createSession(
            harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/background-tasks"),
            runtimeExecutableURL: executable, title: "Parser review"
        )
        let session = try XCTUnwrap(created)
        for json in [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"agent","name":"Agent","input":{"description":"Review the parser","prompt":"Review","run_in_background":true}}]}}"#,
            #"{"type":"system","subtype":"task_started","task_id":"t-agent","tool_use_id":"agent","description":"Review the parser","task_type":"local_agent","is_backgrounded":true}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"shell","name":"Bash","input":{"command":"swift test","run_in_background":true}}]}}"#,
            #"{"type":"system","subtype":"task_started","task_id":"t-shell","tool_use_id":"shell","description":"swift test","task_type":"local_bash","is_backgrounded":true}"#,
            #"{"type":"result","is_error":false,"subtype":"success"}"#
        ] { await transport.emit(try ClaudeWireCodec().decodeLine(Data(json.utf8))) }
        func bar() -> BackgroundTasksProjection {
            BackgroundTasksProjection(entries: model.transcriptBySessionID[session.id] ?? [])
        }
        try await waitUntil { bar().rows.count == 2 }

        let current = try XCTUnwrap(model.store.sessions.first { $0.id == session.id })
        let actions = HarnessActivityActions(
            open: { _ in },
            stop: { activity in Task { try? await model.stopClaudeSubtask(activityID: activity.id, from: current) } },
            isStopping: { _ in false }, error: { _ in nil }
        )
        var stopAll = BackgroundTasksStopAll()
        stopAll.request()
        try await Task.sleep(for: .milliseconds(50))
        var stops = await transport.requestedValues.filter { $0["request"]?["subtype"]?.stringValue == "stop_task" }
        XCTAssertEqual(stops.count, 0, "Asking does not stop anything")

        XCTAssertEqual(stopAll.confirm(bar(), actions: actions), ["agent", "shell"])
        let deadline = ContinuousClock.now + testWaitLimit
        repeat {
            stops = await transport.requestedValues.filter { $0["request"]?["subtype"]?.stringValue == "stop_task" }
            if stops.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        } while ContinuousClock.now < deadline
        XCTAssertEqual(Set(stops.compactMap { $0["request"]?["task_id"]?.stringValue }), ["t-agent", "t-shell"])
        let subtypes = await transport.requestSubtypes
        XCTAssertFalse(subtypes.contains("interrupt"), "Stopping the tasks does not interrupt the conversation")

        // The CLI's own terminal events take the rows away, and the line hides.
        await transport.emit(.object(["type": .string("system"), "subtype": .string("task_notification"),
                                      "task_id": .string("t-agent"), "status": .string("stopped")]))
        await transport.emit(.object(["type": .string("system"), "subtype": .string("task_updated"),
                                      "task_id": .string("t-shell"), "patch": .object(["status": .string("killed")])]))
        try await waitUntil { !bar().isShown }
        await model.shutdown()
    }
}
