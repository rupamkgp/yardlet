import Foundation
import XCTest
@testable import NativeHarnessClient

final class PiRPCProtocolTests: XCTestCase {
    func testCommandsAndStrictJSONLCodecMatchPiAndOMP() throws {
        let codec = PiRPCWireCodec()
        let prompt = PiRPCProtocol.prompt(id: "req-1", text: "hello")
        let encoded = try codec.encodeLine(prompt)
        XCTAssertEqual(encoded.last, 0x0A)
        XCTAssertEqual(try codec.decodeLine(Data(encoded.dropLast()))["type"]?.stringValue, "prompt")
        XCTAssertEqual(prompt["id"]?.stringValue, "req-1")
        XCTAssertEqual(prompt["message"]?.stringValue, "hello")

        var crlf = Data(#"{"type":"agent_start"}"#.utf8)
        crlf.append(0x0D)
        XCTAssertEqual(try codec.decodeLine(crlf)["type"]?.stringValue, "agent_start")

        let confirmation = PiRPCProtocol.extensionConfirmation(id: "ui-1", confirmed: false)
        XCTAssertEqual(confirmation["type"]?.stringValue, "extension_ui_response")
        XCTAssertEqual(confirmation["confirmed"]?.boolValue, false)
    }

    func testProjectsTextAndToolLifecycle() {
        let projector = PiRPCEventProjector()
        XCTAssertEqual(
            projector.payloads(from: .object([
                "type": .string("message_update"),
                "assistantMessageEvent": .object([
                    "type": .string("text_delta"),
                    "delta": .string("hello")
                ])
            ])),
            [.assistantDelta("hello")]
        )
        XCTAssertEqual(
            projector.payloads(from: .object([
                "type": .string("message_end"),
                "message": .object([
                    "role": .string("assistant"),
                    "content": .array([
                        .object(["type": .string("text"), "text": .string("done")])
                    ])
                ])
            ])),
            [.assistantMessageCompleted("done")]
        )

        let activity = HarnessActivity(
            id: "tool-1",
            kind: "bash",
            title: "bash",
            detail: "git status",
            input: "git status"
        )
        XCTAssertEqual(
            projector.payloads(from: .object([
                "type": .string("tool_execution_start"),
                "toolCallId": .string("tool-1"),
                "toolName": .string("bash"),
                "args": .object(["command": .string("git status")])
            ])),
            [.activityStarted(activity)]
        )
    }

    func testProjectsNestedProviderErrorInsteadOfDroppingFailedMessage() {
        let nestedError = """
        {"error":{"message":"{\\"error\\":{\\"message\\":\\"API key not valid\\"}}"}}
        """
        let payloads = PiRPCEventProjector().payloads(
            from: .object([
                "type": .string("message_end"),
                "message": .object([
                    "role": .string("assistant"),
                    "content": .array([]),
                    "stopReason": .string("error"),
                    "errorMessage": .string(nestedError)
                ])
            ])
        )

        XCTAssertEqual(payloads, [.error(message: "API key not valid", recoverable: true)])
    }
}
