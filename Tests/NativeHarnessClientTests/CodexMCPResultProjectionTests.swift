import Foundation
import XCTest
@testable import NativeHarnessClient

/// The MCP tool call card has to show the result body a plugin returned. Codex passes
/// `McpToolCallResult.content` through as MCP content blocks, so a computer-use screenshot
/// arrives as an `image` block beside the tool's own `text`.
final class CodexMCPResultProjectionTests: XCTestCase {
    private let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    func testCompletedToolCallShowsItsTextAndImageContentInOrder() throws {
        let item = try XCTUnwrap(mcpItem(result: .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string("Captured the frontmost window.")
                ]),
                .object([
                    "type": .string("image"),
                    "mimeType": .string("image/png"),
                    "data": .string(onePixelPNG)
                ])
            ])
        ])))
        let projection = CodexMCPResultProjection(result: item.result, itemID: "item-1")

        XCTAssertEqual(projection.textBlockCount, 1)
        XCTAssertEqual(projection.imageBlockCount, 1)
        XCTAssertEqual(projection.blocks.map(\.id), ["item-1#0", "item-1#1"])
        guard case let .text(_, text) = projection.blocks[0] else {
            return XCTFail("The tool's own report must stay the first block")
        }
        XCTAssertEqual(text, "Captured the frontmost window.")
        guard case let .image(_, data, mimeType) = projection.blocks[1] else {
            return XCTFail("An image block must decode into displayable data")
        }
        XCTAssertEqual(mimeType, "image/png")
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testImageBlocksArriveAsBareBase64OrAsADataURL() {
        let bare = CodexMCPResultProjection(result: .object([
            "content": .array([
                .object(["type": .string("image"), "data": .string(onePixelPNG)])
            ])
        ]))
        let dataURL = CodexMCPResultProjection(result: .object([
            "content": .array([
                .object([
                    "type": .string("image"),
                    "mimeType": .string("image/jpeg"),
                    "data": .string("data:image/png;base64,\(onePixelPNG)")
                ])
            ])
        ]))

        guard case let .image(_, bareData, bareType) = bare.blocks.first,
              case let .image(_, urlData, urlType) = dataURL.blocks.first
        else { return XCTFail("Both encodings carry the same image") }
        XCTAssertEqual(bareData, urlData)
        XCTAssertEqual(bareType, "image/png", "An undeclared MIME type falls back to PNG")
        XCTAssertEqual(urlType, "image/png", "The data URL's own type wins over the block's")
    }

    func testEmbeddedResourcesFollowTheirOwnTextOrImagePayload() {
        let projection = CodexMCPResultProjection(result: .object([
            "content": .array([
                .object([
                    "type": .string("resource"),
                    "resource": .object([
                        "uri": .string("file:///tmp/report.md"),
                        "mimeType": .string("text/markdown"),
                        "text": .string("# Report")
                    ])
                ]),
                .object([
                    "type": .string("resource"),
                    "resource": .object([
                        "uri": .string("file:///tmp/shot.png"),
                        "mimeType": .string("image/png"),
                        "blob": .string(onePixelPNG)
                    ])
                ]),
                .object([
                    "type": .string("resource"),
                    "resource": .object([
                        "uri": .string("file:///tmp/clip.wav"),
                        "mimeType": .string("audio/wav"),
                        "blob": .string(onePixelPNG)
                    ])
                ])
            ])
        ]))

        XCTAssertEqual(projection.textBlockCount, 1)
        XCTAssertEqual(
            projection.imageBlockCount,
            1,
            "A non-image blob is not rendered as a picture; the copy action still carries it"
        )
    }

    func testAMissingResultOrAnErrorOnlyCallLeavesTheCardAsItWas() throws {
        let inProgress = try XCTUnwrap(mcpItem(result: nil))
        XCTAssertTrue(CodexMCPResultProjection(result: inProgress.result).isEmpty)
        XCTAssertNil(inProgress.errorMessage)

        let failed = try XCTUnwrap(mcpItem(
            status: "failed",
            result: nil,
            error: .object(["message": .string("The plugin server exited.")])
        ))
        XCTAssertTrue(CodexMCPResultProjection(result: failed.result).isEmpty)
        XCTAssertEqual(
            failed.errorMessage,
            "The plugin server exited.",
            "McpToolCallError is an object; only older history carried a bare string"
        )

        let legacy = try XCTUnwrap(mcpItem(
            status: "failed",
            result: nil,
            error: .string("Timed out")
        ))
        XCTAssertEqual(legacy.errorMessage, "Timed out")

        let emptyContent = CodexMCPResultProjection(result: .object(["content": .array([])]))
        XCTAssertTrue(emptyContent.isEmpty)
        XCTAssertTrue(
            CodexMCPResultProjection(result: .object([
                "content": .array([.object(["type": .string("resource_link")])])
            ])).isEmpty,
            "A block this client cannot render stays out of the card instead of being faked"
        )
    }

    func testReducerKeepsTheResultBodyOnTheDecodedTimelineItem() throws {
        var state = CodexTaskState.empty
        let reducer = CodexTaskReducer()
        _ = reducer.applySnapshot(.object([
            "id": .string("thread-1"),
            "turns": .array([
                .object([
                    "id": .string("turn-1"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "id": .string("mcp-1"),
                            "type": .string("mcpToolCall"),
                            "server": .string("computer-use"),
                            "tool": .string("app_screenshot"),
                            "status": .string("completed"),
                            "arguments": .object(["app": .string("Yardlet")]),
                            "pluginId": .string("computer-use@openai-bundled"),
                            "result": .object([
                                "content": .array([
                                    .object([
                                        "type": .string("text"),
                                        "text": .string("Captured 1 window.")
                                    ])
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ]), to: &state)

        let item = try XCTUnwrap(state.thread?.turns.first?.items.first)
        guard case let .mcpToolCall(tool) = item.content else {
            return XCTFail("The snapshot must decode as an MCP tool call")
        }
        XCTAssertEqual(tool.pluginID, "computer-use@openai-bundled")
        let projection = CodexMCPResultProjection(result: tool.result, itemID: item.id)
        XCTAssertEqual(projection.blocks, [.text(id: "mcp-1#0", text: "Captured 1 window.")])
    }

    private func mcpItem(
        status: String = "inProgress",
        result: JSONValue?,
        error: JSONValue? = nil
    ) -> CodexMCPToolItem? {
        var payload: [String: JSONValue] = [
            "id": .string("mcp-1"),
            "type": .string("mcpToolCall"),
            "server": .string("computer-use"),
            "tool": .string("app_screenshot"),
            "status": .string(status),
            "arguments": .object([:])
        ]
        if let result { payload["result"] = result }
        if let error { payload["error"] = error }
        let item = CodexTaskDecoder().item(
            from: .object(payload),
            fallbackID: "mcp-1",
            lifecycle: .completed
        )
        guard case let .mcpToolCall(tool) = item.content else { return nil }
        return tool
    }
}
