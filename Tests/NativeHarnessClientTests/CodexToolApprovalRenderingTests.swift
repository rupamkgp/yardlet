import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A Codex MCP tool approval card with the Codex app's answers (26.1016): Computer Use's
/// "Allow Computer Use to use "Whale"?" with Deny, Always allow and Allow this conversation, and
/// another connector's approval with Allow once last. Light and dark.
@MainActor
final class CodexToolApprovalRenderingTests: XCTestCase {
    static func request(connector: String, persist: [String]) -> ConversationRequest {
        CodexRequestResponseProjection.request(CodexServerRequestState(
            id: "s:cua", method: "mcpServer/elicitation/request", kind: .mcpElicitation,
            threadID: "thread", turnID: "turn", itemID: nil,
            params: .object([
                "threadId": .string("thread"), "turnId": .string("turn"), "serverName": .string("cua_repl"),
                "mode": .string("form"),
                "message": .string(connector == "computer-use"
                    ? "Allow Computer Use to use \"Whale\"?" : "Allow GitHub to run tool \"create_issue\"?"),
                "requestedSchema": .object(["type": .string("object"), "properties": .object([:])]),
                "_meta": .object([
                    "codex_approval_kind": .string("mcp_tool_call"), "connector_id": .string(connector),
                    "persist": .array(persist.map(JSONValue.string)), "tool_name": .string("js"),
                    "tool_params": .object(["app": .string("com.naver.Whale")])
                ])
            ]),
            resolution: .pending))
    }

    static func card(_ request: ConversationRequest, appearance: WindowlessRender.Appearance) -> some View {
        ConversationRequestCard(request: request, actions: ConversationActions())
            .padding(20)
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 640, height: 300, alignment: .top)
            .background(ParityTheme.canvas)
            .tint(Color.primary)
            .environment(\.controlActiveState, .key)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    func testToolApprovalCardsReadInBothAppearances() throws {
        let computerUse = Self.request(connector: "computer-use", persist: ["session", "always"])
        XCTAssertEqual(computerUse.responses.map(\.title),
                       [L10n.string("Deny"), L10n.string("Always allow"), L10n.string("Allow this conversation")])
        let other = Self.request(connector: "github", persist: ["session", "always"])
        XCTAssertEqual(other.responses.map(\.title), [L10n.string("Deny"), L10n.string("Always allow"),
                                                      L10n.string("Allow this conversation"), L10n.string("Allow once")])
        let directory = try WindowlessRender.directory("codex-approvals-qa")
        for (name, request) in [("computer-use", computerUse), ("connector", other)] {
            try WindowlessRender.hostedInBothAppearances("tool-approval-\(name)", in: directory,
                                                         size: NSSize(width: 640, height: 300)) {
                Self.card(request, appearance: $0)
            }
        }
    }
}
