import Foundation
import XCTest
@testable import NativeHarnessClient

final class StructuredHeadlessProtocolTests: XCTestCase {
    func testCursorProjectsSessionTextToolAndResult() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .cursor)
        let initEvent: JSONValue = .object([
            "type": .string("system"),
            "subtype": .string("init"),
            "session_id": .string("cursor-session")
        ])
        XCTAssertEqual(
            projector.project(initEvent, hasAssistantText: false).providerSessionID,
            "cursor-session"
        )

        let assistant: JSONValue = .object([
            "type": .string("assistant"),
            "message": .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("hello")
                ])])
            ])
        ])
        XCTAssertEqual(
            projector.project(assistant, hasAssistantText: false).payloads,
            [.assistantDelta("hello")]
        )

        let result: JSONValue = .object([
            "type": .string("result"),
            "subtype": .string("success"),
            "result": .string("hello"),
            "session_id": .string("cursor-session")
        ])
        let projection = projector.project(result, hasAssistantText: true)
        XCTAssertTrue(projection.isTerminal)
        XCTAssertEqual(projection.payloads, [.turnCompleted])
    }

    func testCursorErrorResultEndsTheTurnWithoutCompletingIt() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .cursor)
        let projection = projector.project(
            .object([
                "type": .string("result"),
                "subtype": .string("error"),
                "is_error": .bool(true),
                "result": .string("Cursor failed"),
                "session_id": .string("cursor-session")
            ]),
            hasAssistantText: false
        )
        XCTAssertTrue(projection.isTerminal)
        XCTAssertEqual(projection.payloads, [.error(message: "Cursor failed", recoverable: true)])
    }

    func testAntigravityProjectsCurrentNestedEventContract() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .antigravity)
        let initEvent: JSONValue = .object([
            "event": .string("init"),
            "conversation_id": .string("agy-current"),
            "init": .object([
                "cwd": .string("/tmp/project"),
                "permission_mode": .string("request-review")
            ])
        ])
        XCTAssertEqual(
            projector.project(initEvent, hasAssistantText: false).providerSessionID,
            "agy-current"
        )

        let delta: JSONValue = .object([
            "event": .string("step_update"),
            "step_update": .object([
                "conversation_id": .string("agy-current"),
                "step_index": .integer(3),
                "state": .string("ACTIVE"),
                "step_type": .string("agent_response"),
                "text_delta": .string("ready")
            ])
        ])
        XCTAssertEqual(
            projector.project(delta, hasAssistantText: false).payloads,
            [.assistantDelta("ready")]
        )

        let tool: JSONValue = .object([
            "event": .string("step_update"),
            "step_update": .object([
                "conversation_id": .string("agy-current"),
                "step_index": .integer(4),
                "state": .string("DONE"),
                "step_type": .string("tool"),
                "tool_name": .string("run_command"),
                "tool_info": .object([
                    "name": .string("run_command"),
                    "output": .string("done")
                ])
            ])
        ])
        let toolPayload = try XCTUnwrap(
            projector.project(tool, hasAssistantText: true).payloads.first
        )
        guard case let .activityCompleted(activity) = toolPayload else {
            return XCTFail("Expected completed activity, got \(toolPayload)")
        }
        XCTAssertEqual(activity.id, "agy-current-4")
        XCTAssertEqual(activity.kind, "run_command")

        let result: JSONValue = .object([
            "event": .string("result"),
            "result": .object([
                "conversation_id": .string("agy-current"),
                "status": .string("SUCCESS"),
                "response": .string("ready"),
                "usage": .object(["input_tokens": .integer(10)])
            ])
        ])
        let terminal = projector.project(result, hasAssistantText: true)
        XCTAssertEqual(terminal.providerSessionID, "agy-current")
        XCTAssertEqual(terminal.payloads, [.turnCompleted])
        XCTAssertTrue(terminal.isTerminal)

        let resultOnly = projector.project(result, hasAssistantText: false)
        XCTAssertEqual(
            resultOnly.payloads,
            [.assistantMessageCompleted("ready"), .turnCompleted]
        )
    }

    func testAntigravitySurfacesStructuredToolErrorWithoutDoneState() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .antigravity)
        let projection = projector.project(
            antigravityToolEvent(toolInfo: observedAntigravityToolInfo(), state: "ACTIVE"),
            hasAssistantText: false
        )
        let activity = try completedActivity(from: projection.payloads)
        XCTAssertEqual(activity.id, "agy-current-2")
        XCTAssertEqual(activity.kind, "list_dir")
        XCTAssertEqual(activity.detail, Self.observedAntigravityToolError)
        XCTAssertEqual(activity.outcome, .failed)
        XCTAssertFalse(projection.isTerminal)
        XCTAssertFalse(projection.payloads.contains { payload in
            if case .error = payload { return true }
            return payload == .turnCompleted
        })
    }

    func testAntigravityStructuredToolErrorSurvivesLargeParameterTruncation() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .antigravity)
        let padding = String(repeating: "x", count: 400)
        let toolInfo = observedAntigravityToolInfo(padding: padding)
        XCTAssertGreaterThan(try XCTUnwrap(encodedJSONLength(toolInfo)), 360)

        let activity = try completedActivity(
            from: projector.project(
                antigravityToolEvent(toolInfo: toolInfo, state: "ACTIVE"),
                hasAssistantText: false
            ).payloads
        )
        XCTAssertEqual(activity.detail, Self.observedAntigravityToolError)
        XCTAssertEqual(activity.outcome, .failed)
        XCTAssertFalse(activity.detail?.contains(padding) == true)
        XCTAssertFalse(activity.detail?.hasSuffix("…") == true)
    }

    func testAntigravityLegacyStructuredToolErrorStillCompletesActivity() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .antigravity)
        let projection = projector.project(
            .object([
                "type": .string("step_update"),
                "step_id": .string("legacy-step"),
                "step_type": .string("tool"),
                "conversation_id": .string("agy-legacy"),
                "tool_info": observedAntigravityToolInfo()
            ]),
            hasAssistantText: false
        )
        let activity = try completedActivity(from: projection.payloads)
        XCTAssertEqual(activity.id, "legacy-step")
        XCTAssertEqual(activity.kind, "list_dir")
        XCTAssertEqual(activity.detail, Self.observedAntigravityToolError)
        XCTAssertEqual(activity.outcome, .failed)
        XCTAssertEqual(projection.providerSessionID, "agy-legacy")
    }

    func testCursorToolProjectionIsUnchangedByAntigravityErrorHandling() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .cursor)
        let started = projector.project(
            .object([
                "type": .string("tool_call"),
                "call_id": .string("cursor-call"),
                "subtype": .string("started"),
                "tool_call": .object(["ShellToolCall": .object(["command": .string("pwd")])])
            ]),
            hasAssistantText: false
        )
        guard case let .activityStarted(activity) = started.payloads.first else {
            return XCTFail("Cursor must still start in-progress tool cards, got \(started.payloads)")
        }
        XCTAssertEqual(activity.id, "cursor-call")
        XCTAssertEqual(activity.kind, "ShellToolCall")
        XCTAssertTrue(activity.detail?.contains("pwd") == true)
    }

    func testAntigravityStillProjectsLegacyFlatEventContract() throws {
        let projector = StructuredHeadlessEventProjector(flavor: .antigravity)
        let initEvent: JSONValue = .object([
            "type": .string("init"),
            "conversation_id": .string("agy-conversation")
        ])
        XCTAssertEqual(
            projector.project(initEvent, hasAssistantText: false).providerSessionID,
            "agy-conversation"
        )
        let delta: JSONValue = .object([
            "type": .string("step_update"),
            "step_type": .string("assistant_message"),
            "delta": .string("ready")
        ])
        XCTAssertEqual(
            projector.project(delta, hasAssistantText: false).payloads,
            [.assistantDelta("ready")]
        )
        let result: JSONValue = .object([
            "type": .string("result"),
            "status": .string("success"),
            "conversation_id": .string("agy-conversation"),
            "usage": .object(["input_tokens": .integer(10)])
        ])
        XCTAssertTrue(projector.project(result, hasAssistantText: true).isTerminal)
    }

    private static let observedAntigravityToolError =
        "permission check failed for read_file \"/tmp/yardlet-fixture\": user denied permission for read_file(/tmp/yardlet-fixture)"

    private func observedAntigravityToolInfo(padding: String? = nil) -> JSONValue {
        var parameters: [String: JSONValue] = [
            "DirectoryPath": .string("/tmp/yardlet-fixture")
        ]
        if let padding {
            parameters["padding"] = .string(padding)
        }
        return .object([
            "name": .string("list_dir"),
            "parameters": .object(parameters),
            "error": .object([
                "type": .string("TOOL_ERROR"),
                "message": .string(Self.observedAntigravityToolError)
            ])
        ])
    }

    private func antigravityToolEvent(toolInfo: JSONValue, state: String) -> JSONValue {
        .object([
            "event": .string("step_update"),
            "step_update": .object([
                "conversation_id": .string("agy-current"),
                "step_index": .integer(2),
                "state": .string(state),
                "step_type": .string("tool"),
                "tool_name": .string("list_dir"),
                "tool_info": toolInfo
            ])
        ])
    }

    private func completedActivity(from payloads: [HarnessEventPayload]) throws -> HarnessActivity {
        XCTAssertEqual(payloads.count, 1)
        guard case let .activityCompleted(activity) = payloads.first else {
            XCTFail("Expected completed activity, got \(payloads)")
            throw NSError(domain: "StructuredHeadlessProtocolTests", code: 1)
        }
        return activity
    }

    private func encodedJSONLength(_ value: JSONValue) throws -> Int {
        try JSONEncoder().encode(value).count
    }
}
