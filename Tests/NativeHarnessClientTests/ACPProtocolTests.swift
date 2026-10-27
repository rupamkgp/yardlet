import Foundation
import XCTest
@testable import NativeHarnessClient

final class ACPProtocolTests: XCTestCase {
    func testStableV1InitializeAndPromptUseOfficialJSONRPCShape() throws {
        let codec = ACPWireCodec()
        let initialize = try codec.decodeLine(try codec.encodeLine(ACPProtocol.initialize(id: 1)))
        XCTAssertEqual(initialize["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(initialize["method"]?.stringValue, "initialize")
        XCTAssertEqual(initialize["params"]?["protocolVersion"]?.integerValue, 1)
        XCTAssertEqual(
            initialize["params"]?["clientCapabilities"]?["fs"]?["writeTextFile"]?.boolValue,
            false
        )

        let prompt = ACPProtocol.prompt(
            id: 2,
            providerSessionID: "session-1",
            text: "hello"
        )
        XCTAssertEqual(prompt["method"]?.stringValue, "session/prompt")
        XCTAssertEqual(prompt["params"]?["sessionId"]?.stringValue, "session-1")
        XCTAssertEqual(
            prompt["params"]?["prompt"]?.arrayValue?.first?["text"]?.stringValue,
            "hello"
        )

        let cancel = ACPProtocol.cancel(providerSessionID: "session-1")
        XCTAssertEqual(cancel["method"]?.stringValue, "session/cancel")
        XCTAssertNil(cancel["id"])
    }

    func testProjectsMessageToolAndPlanUpdates() {
        let projector = ACPEventProjector()
        XCTAssertEqual(
            projector.payloads(from: .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("hello")
                ])
            ])),
            [.assistantDelta("hello")]
        )

        let activity = HarnessActivity(
            id: "tool-1",
            kind: "execute",
            title: "Run tests",
            detail: "swift test",
            input: "swift test"
        )
        XCTAssertEqual(
            projector.payloads(from: .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("tool-1"),
                "kind": .string("execute"),
                "title": .string("Run tests"),
                "rawInput": .object(["command": .string("swift test")])
            ])),
            [.activityStarted(activity)]
        )

        XCTAssertEqual(
            projector.payloads(from: .object([
                "sessionUpdate": .string("plan"),
                "entries": .array([
                    .object([
                        "content": .string("Inspect"),
                        "status": .string("completed")
                    ])
                ])
            ])),
            [.planUpdated("[completed] Inspect")]
        )
    }

    func testProjectsGrokTurnUsageWithoutInventingContext() throws {
        let usage = try XCTUnwrap(ACPEventProjector().usage(from: .object([
            "sessionUpdate": .string("turn_completed"),
            "usage": .object([
                "inputTokens": .integer(20_618),
                "cachedReadTokens": .integer(6_400),
                "outputTokens": .integer(64),
                "reasoningTokens": .integer(50),
                "costUsdTicks": .integer(54_434_000)
            ])
        ])))

        XCTAssertEqual(usage.inputTokens, 20_618)
        XCTAssertEqual(usage.cachedInputTokens, 6_400)
        XCTAssertEqual(usage.outputTokens, 64)
        XCTAssertEqual(usage.reasoningTokens, 50)
        XCTAssertEqual(usage.totalCostUSD ?? -1, 0.0054434, accuracy: 0.0000001)
        XCTAssertNil(usage.contextWindowTokens)
        XCTAssertNil(usage.contextUsedTokens)
    }

    func testPermissionResponseSelectsTheExactAgentOption() {
        let response = ACPProtocol.permissionResponse(
            id: .string("permission-1"),
            optionID: "allow-once"
        )
        XCTAssertEqual(response["id"]?.stringValue, "permission-1")
        XCTAssertEqual(response["result"]?["outcome"]?["outcome"]?.stringValue, "selected")
        XCTAssertEqual(
            response["result"]?["outcome"]?["optionId"]?.stringValue,
            "allow-once"
        )
    }

    func testConfigOptionsProjectAndSetWithStableACPShape() {
        let result: JSONValue = .object(["configOptions": .array([.object([
            "id": .string("mode"), "name": .string("Mode"),
            "type": .string("select"), "category": .string("mode"),
            "currentValue": .string("ask"),
            "options": .array([
                .object(["value": .string("ask"), "name": .string("Ask")]),
                .object(["value": .string("code"), "name": .string("Code")])
            ])
        ])])])
        let state = ACPCapabilityProjector().state(from: result, harness: .openCode)
        XCTAssertEqual(state.selectors.first?.currentValue, "ask")
        let request = ACPProtocol.setConfigOption(
            id: 4, providerSessionID: "session-1", configID: "mode", value: "code"
        )
        XCTAssertEqual(request["method"]?.stringValue, "session/set_config_option")
        XCTAssertEqual(request["params"]?["value"]?.stringValue, "code")
    }

    func testGrokModelsAndReasoningMetadataProjectIntoLiveControls() {
        let result = grokSessionResult()
        let state = ACPCapabilityProjector().state(from: result, harness: .grokBuild)

        XCTAssertEqual(state.selectors.map(\.id), ["model", "reasoning_effort"])
        XCTAssertEqual(state.selectors[0].currentValue, "grok-4.6")
        XCTAssertEqual(state.selectors[0].choices.map(\.value), ["grok-4.6", "grok-4.5"])
        XCTAssertEqual(state.selectors[1].currentValue, "high")
        XCTAssertEqual(state.selectors[1].choices.map(\.value), ["xhigh", "high", "low"])
        XCTAssertEqual(state.notes.count, 2)

        let switched = ACPCapabilityProjector().state(
            from: result,
            harness: .grokBuild,
            selectedModelID: "grok-4.5"
        )
        XCTAssertEqual(switched.selectors[0].currentValue, "grok-4.5")
        XCTAssertEqual(switched.selectors[1].choices.map(\.value), ["high", "low"])
    }

    func testGrokSetModelCarriesReasoningEffortExtension() {
        let request = ACPProtocol.setModel(
            id: 7,
            providerSessionID: "grok-session",
            modelID: "grok-4.6",
            reasoningEffort: "low"
        )

        XCTAssertEqual(request["method"]?.stringValue, "session/set_model")
        XCTAssertEqual(request["params"]?["modelId"]?.stringValue, "grok-4.6")
        XCTAssertEqual(
            request["params"]?["_meta"]?["reasoningEffort"]?.stringValue,
            "low"
        )
    }

    private func grokSessionResult() -> JSONValue {
        .object([
            "sessionId": .string("grok-session"),
            "models": .object([
                "currentModelId": .string("grok-4.6"),
                "availableModels": .array([
                    grokModel(
                        id: "grok-4.6",
                        name: "Grok 4.6",
                        currentEffort: "high",
                        efforts: [("xhigh", false), ("high", true), ("low", false)]
                    ),
                    grokModel(
                        id: "grok-4.5",
                        name: "Grok 4.5",
                        currentEffort: "high",
                        efforts: [("high", true), ("low", false)]
                    )
                ])
            ])
        ])
    }

    private func grokModel(
        id: String,
        name: String,
        currentEffort: String,
        efforts: [(String, Bool)]
    ) -> JSONValue {
        .object([
            "modelId": .string(id),
            "name": .string(name),
            "_meta": .object([
                "supportsReasoningEffort": .bool(true),
                "reasoningEffort": .string(currentEffort),
                "reasoningEfforts": .array(efforts.map { effort in
                    .object([
                        "id": .string(effort.0),
                        "value": .string(effort.0),
                        "label": .string(effort.0.capitalized),
                        "default": .bool(effort.1)
                    ])
                })
            ])
        ])
    }
}
