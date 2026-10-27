import Foundation
import XCTest
@testable import NativeHarnessClient

final class ClaudeSubtaskTests: XCTestCase {
    func testTaskSpecificStopUsesLiveIDOnDirectAndProductRoutes() async throws {
        for routed in [false, true] {
            let transport = FakeClaudeTransport()
            let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake-claude"), transportFactory: { _ in transport })
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude())
                : direct
            let controller = try XCTUnwrap(adapter as? any HarnessSubtaskControlling)
            let handle = try await adapter.createSession(.init(localSessionID: UUID(),
                workspaceURL: URL(filePath: "/tmp/subtasks"), initialPrompt: nil))
            let ready = expectation(description: "Both tasks observed on \(routed)")
            let ended = expectation(description: "Only selected task stopped on \(routed)")
            let recorder = SubtaskEventRecorder()
            let collector = Task {
                for await event in await adapter.events(for: handle) {
                    await recorder.append(event.payload)
                    if case let .activityStarted(activity) = event.payload, activity.subtask?.taskID == "task-b" {
                        ready.fulfill()
                    }
                    if case let .activityCompleted(activity) = event.payload,
                       activity.id == "tool-a", activity.outcome == .stopped { ended.fulfill() }
                }
            }
            try await adapter.send("Parent work", to: handle)
            await transport.emit(start("task-a", tool: "tool-a"))
            await transport.emit(start("task-b", tool: "tool-b"))
            await fulfillment(of: [ready], timeout: 3)
            let before = await recorder.values
            try await controller.stopSubtask(activityID: "tool-a", in: handle)
            let requests = await transport.requestedValues
            XCTAssertEqual(requests.last?["request"]?["subtype"], .string("stop_task"))
            XCTAssertEqual(requests.last?["request"]?["task_id"], .string("task-a"))
            let subtypes = await transport.requestSubtypes
            XCTAssertFalse(subtypes.contains("interrupt"))
            let stopCount = await transport.stopCount
            XCTAssertEqual(stopCount, 0)
            let after = await recorder.values
            XCTAssertEqual(after, before, "Acknowledgement must not end the parent or invent a child outcome")
            let activity = before.compactMap { payload -> HarnessActivity? in
                if case let .activityStarted(value) = payload, value.id == "tool-a" { return value }
                return nil
            }.last
            XCTAssertEqual(activity?.subtask?.toolUseID, "tool-a")
            XCTAssertEqual(activity?.subtask?.taskID, "task-a")
            XCTAssertEqual(activity?.subtask?.hasConversation, true)
            do {
                try await controller.stopSubtask(activityID: "not-a-live-card", in: handle)
                XCTFail("A saved/unknown card must not authorize a control request")
            } catch {}
            let forged = HarnessSessionHandle(harness: .claudeCode, localSessionID: handle.localSessionID,
                providerSessionID: UUID().uuidString, workspaceURL: handle.workspaceURL)
            do { try await controller.stopSubtask(activityID: "tool-b", in: forged); XCTFail("Wrong parent accepted") }
            catch {}
            await transport.emit(.object(["type": .string("system"), "subtype": .string("task_notification"),
                "task_id": .string("task-a"), "status": .string("stopped"), "summary": .string("Stopped")]))
            await fulfillment(of: [ended], timeout: 3)
            do { try await controller.stopSubtask(activityID: "tool-a", in: handle); XCTFail("Terminal task accepted") }
            catch {}
            try await controller.stopSubtask(activityID: "tool-b", in: handle)
            let finalRequests = await transport.requestedValues
            XCTAssertEqual(finalRequests.filter { $0["request"]?["subtype"]?.stringValue == "stop_task" }.count, 2)
            XCTAssertEqual(finalRequests.last?["request"]?["task_id"], .string("task-b"))
            try await adapter.send("Parent continues", to: handle)
            let sent = await transport.sentValues
            XCTAssertEqual(sent.last?["session_id"], .string(handle.providerSessionID))
            collector.cancel()
            await adapter.close(handle)
        }
    }

    func testFailureDoesNotFallBackToParentInterrupt() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil))
        let ready = expectation(description: "Task exists")
        let collector = Task {
            for await event in await adapter.events(for: handle) {
                if case .activityStarted = event.payload { ready.fulfill(); break }
            }
        }
        await transport.emit(start("live-task", tool: "tool"))
        await fulfillment(of: [ready], timeout: 2)
        await transport.setTaskControlError(.capabilityUnavailable("Rejected by Claude"))
        do { try await adapter.stopSubtask(activityID: "tool", in: handle); XCTFail("Error discarded") }
        catch { XCTAssertEqual(error.localizedDescription, "Rejected by Claude") }
        let subtypes = await transport.requestSubtypes
        XCTAssertEqual(subtypes, ["initialize", "stop_task"])
        collector.cancel()
        await adapter.close(handle)
    }

    func testBackgroundIdentitySurvivesParentCompletionAndTerminalPatch() throws {
        var projection = ClaudeSessionProjection()
        _ = projection.payloads(from: start("background", tool: "tool"))
        _ = projection.payloads(from: .object(["type": .string("result"), "is_error": .bool(false)]))
        XCTAssertEqual(projection.activeTaskID(for: "tool"), "background")
        _ = projection.payloads(from: .object(["type": .string("system"), "subtype": .string("task_updated"),
            "task_id": .string("background"), "patch": .object(["status": .string("killed")])]))
        XCTAssertNil(projection.activeTaskID(for: "tool"))
    }

    func testProviderCanceledApprovalExpiresWithoutDenyingOrEndingTheParentOnBothRoutes() async throws {
        for routed in [false, true] {
            let transport = FakeClaudeTransport()
            let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/fake"), transportFactory: { _ in transport })
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude())
                : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/work"), initialPrompt: nil))
            let pending = expectation(description: "Approval pending")
            let resumed = expectation(description: "Parent running after provider cancellation")
            let recorder = SubtaskEventRecorder()
            let collector = Task {
                var sawExpiration = false
                for await event in await adapter.events(for: handle) {
                    await recorder.append(event.payload)
                    if case .permissionRequested = event.payload { pending.fulfill() }
                    if case .permissionExpired("permission") = event.payload { sawExpiration = true }
                    if sawExpiration, event.payload == .sessionStatusChanged(.running) { resumed.fulfill(); break }
                }
            }
            try await adapter.send("Parent work", to: handle)
            await transport.emit(.object(["type": .string("control_request"), "request_id": .string("permission"),
                "request": .object(["subtype": .string("can_use_tool"), "tool_name": .string("Bash"),
                    "agent_id": .string("agent"), "input": .object(["command": .string("pwd")])])]))
            await fulfillment(of: [pending], timeout: 2)
            await transport.emit(.object(["type": .string("control_cancel_request"), "request_id": .string("permission")]))
            await fulfillment(of: [resumed], timeout: 2)
            var builder = TranscriptBuilder()
            for payload in await recorder.values { builder.apply(payload) }
            XCTAssertTrue(builder.entries.contains {
                if case let .permission(request, state) = $0.content { return request.id == "permission" && state == .expired }
                return false
            })
            let sent = await transport.sentValues
            XCTAssertFalse(sent.contains { $0["type"]?.stringValue == "control_response" }, "No user denial may be invented")
            do { try await adapter.respond(to: "permission", decision: .allow, in: handle); XCTFail("Canceled approval answered") }
            catch {}
            collector.cancel()
            await adapter.close(handle)
        }
    }

    func testTypedAgentResultPreservesConversationReferenceAndOldCacheCompatibility() throws {
        var projection = ClaudeSessionProjection()
        let tool = JSONValue.object(["type": .string("assistant"), "message": .object(["content": .array([
            .object(["type": .string("tool_use"), "id": .string("tool"), "name": .string("Agent"),
                     "input": .object(["description": .string("Read the code")])])])])])
        let finish = JSONValue.object(["type": .string("user"), "tool_use_result": .object(["agentId": .string("actual-agent")]),
            "message": .object(["content": .array([.object(["type": .string("tool_result"),
                "tool_use_id": .string("tool"), "content": .string("Result")])])])])
        _ = projection.payloads(from: tool)
        let completed = projection.payloads(from: finish).compactMap { payload -> HarnessActivity? in
            if case let .activityCompleted(activity) = payload { return activity }; return nil
        }.first
        XCTAssertEqual(completed?.subtask?.agentID, "actual-agent")
        XCTAssertNil(completed?.subtask?.taskID, "An agent ID must not invent a stoppable task ID")
        let old = Data(#"{"id":"old","kind":"Agent","title":"Old task"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(HarnessActivity.self, from: old).subtask)
        let data = try JSONEncoder().encode(XCTUnwrap(completed))
        XCTAssertEqual(try JSONDecoder().decode(HarnessActivity.self, from: data).subtask, completed?.subtask)
    }

    private func start(_ id: String, tool: String) -> JSONValue {
        .object(["type": .string("system"), "subtype": .string("task_started"), "task_id": .string(id),
            "tool_use_id": .string(tool), "description": .string("Review"),
            "task_type": .string("local_agent"), "is_backgrounded": .bool(true)])
    }
}

private actor SubtaskEventRecorder {
    var values: [HarnessEventPayload] = []
    func append(_ payload: HarnessEventPayload) { values.append(payload) }
}
