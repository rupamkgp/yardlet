import Foundation
import XCTest
@testable import NativeHarnessClient

final class ClaudeProtocolTests: XCTestCase {
    private let codec = ClaudeWireCodec()

    func testDecodesPartialTextFixture() throws {
        let data = Data(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}},"session_id":"session-1"}"#.utf8)
        let value = try codec.decodeLine(data)

        XCTAssertEqual(value["type"]?.stringValue, "stream_event")
        XCTAssertEqual(value["event"]?["delta"]?["text"]?.stringValue, "hello")
        XCTAssertEqual(
            ClaudeEventProjector().payloads(from: value),
            [.assistantDelta("hello")]
        )
    }

    func testDecodesPermissionFixtureAndEncodesDenial() throws {
        let data = Data(#"{"type":"control_request","request_id":"permission-1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"git status"},"title":"Run command"}}"#.utf8)
        let value = try codec.decodeLine(data)

        XCTAssertEqual(value["request"]?["subtype"]?.stringValue, "can_use_tool")
        XCTAssertEqual(value["request"]?["input"]?["command"]?.stringValue, "git status")

        let denial = ClaudeProtocol.permissionResponse(
            requestID: "permission-1",
            decision: .deny,
            originalInput: value["request"]?["input"] ?? .object([:])
        )
        XCTAssertEqual(denial["response"]?["response"]?["behavior"]?.stringValue, "deny")
        XCTAssertEqual(denial["response"]?["request_id"]?.stringValue, "permission-1")
    }

    func testUserMessageAndControlRequestsUseDocumentedWireShape() {
        let user = ClaudeProtocol.userMessage("hello", sessionID: "session-1")
        XCTAssertEqual(user["type"]?.stringValue, "user")
        XCTAssertEqual(user["message"]?["role"]?.stringValue, "user")
        XCTAssertEqual(user["message"]?["content"]?.stringValue, "hello")

        let initialize = ClaudeProtocol.initialize(id: "init-1")
        XCTAssertEqual(initialize["type"]?.stringValue, "control_request")
        XCTAssertEqual(initialize["request"]?["subtype"]?.stringValue, "initialize")

        let interrupt = ClaudeProtocol.interrupt(id: "interrupt-1")
        XCTAssertEqual(interrupt["request"]?["subtype"]?.stringValue, "interrupt")
    }
}
