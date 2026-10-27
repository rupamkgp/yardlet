import Foundation
import XCTest
@testable import NativeHarnessClient

/// Results Codex already sent must stay readable: a child agent's message in "Copy item details",
/// and an MCP tool's `resource_link` in the result body (2026-10-22 audit F05 copy, F06).
final class CodexRestoredResultsTests: XCTestCase {
    // MARK: - F05: child results in the copied item details

    func testCopiedCollaborationDetailsCarryEachChildStatusAndMessage() throws {
        let item = collaborationItem(receivers: ["child-a", "child-b", "child-c"], states: [
            "child-a": .object(["status": .string("completed"), "message": .string("A: tests pass")]),
            "child-b": .object(["status": .string("errored"), "message": .string("B: build failed\nline 2")]),
            "child-c": .object(["status": .string("running"), "message": .null])
        ])
        let payload = try XCTUnwrap(CodexWorkSurfaceProjection.itemHandoff(for: item, turnID: "turn")?.payload)

        XCTAssertTrue(payload.contains("child-a: completed\nA: tests pass"), payload)
        XCTAssertTrue(payload.contains("child-b: errored\nB: build failed\nline 2"), payload)
        XCTAssertTrue(payload.contains("child-c: running"), payload)
        XCTAssertFalse(payload.contains("null"), "A child without a message adds no placeholder")
        // The receivers' own order, the order the card lists them in.
        let order = ["child-a:", "child-b:", "child-c:"].compactMap { payload.range(of: $0)?.lowerBound }
        XCTAssertEqual(order, order.sorted())
        XCTAssertEqual(order.count, 3)
    }

    func testCopiedCollaborationDetailsSkipEmptyMessagesAndKeepStatesOutsideTheReceivers() throws {
        let item = collaborationItem(receivers: ["child-a"], states: [
            "child-a": .object(["status": .string("pendingInit"), "message": .string("  \n")]),
            "child-z": .object(["status": .string("notFound")]),
            "child-y": .object(["message": .string("no status")])
        ])
        let payload = try XCTUnwrap(CodexWorkSurfaceProjection.itemHandoff(for: item, turnID: "turn")?.payload)

        XCTAssertTrue(payload.contains("child-a: pendingInit"), payload)
        XCTAssertFalse(payload.contains("child-a: pendingInit\n  "), "A blank message is left out")
        XCTAssertTrue(payload.contains("child-y\nno status"), payload)
        XCTAssertTrue(payload.contains("child-z: notFound"), payload)
        XCTAssertLessThan(try XCTUnwrap(payload.range(of: "child-y")).lowerBound,
                          try XCTUnwrap(payload.range(of: "child-z")).lowerBound)
    }

    func testCollaborationWithoutStatesCopiesAsBefore() throws {
        let item = collaborationItem(receivers: [], states: [:])
        let payload = try XCTUnwrap(CodexWorkSurfaceProjection.itemHandoff(for: item, turnID: "turn")?.payload)
        XCTAssertEqual(payload, "itemId: collab\ntype: collabAgentToolCall\nwait\nstatus: completed\nCheck the build")
    }

    func testConversationCopyDetailsKeepTheChildResult() {
        let item = collaborationItem(receivers: ["child"], states: [
            "child": .object(["status": .string("completed"), "message": .string("AUDIT child result: tests pass")])
        ])
        let projected = CodexConversationProjection.item(item, turnID: "turn", isTurnFinished: true,
            workspaceURL: URL(filePath: "/tmp"), changes: [], isHistoryMatch: false)
        XCTAssertTrue(projected.copyDetails?.contains("AUDIT child result: tests pass") == true)
    }

    func testSubagentCardOutputCarriesEachChildResultApartFromTheCallStatus() throws {
        let item = collaborationItem(receivers: ["child-a", "child-b", "child-c"], states: [
            "child-a": .object(["status": .string("completed"), "message": .string("A: tests pass")]),
            "child-b": .object(["status": .string("errored"), "message": .string("B: build failed")]),
            "child-c": .object(["status": .string("running"), "message": .string("")])
        ], status: "inProgress")
        let projected = CodexConversationProjection.item(item, turnID: "turn", isTurnFinished: false,
            workspaceURL: URL(filePath: "/tmp"), changes: [], isHistoryMatch: false)
        guard case let .subagent(agent) = projected.kind else { return XCTFail("Not a subagent") }

        XCTAssertEqual(agent.status, "inProgress", "The card's status is the wait call's own")
        XCTAssertEqual(agent.output, "child-a: completed\nA: tests pass\nchild-b: errored\nB: build failed\nchild-c: running")
        let copied = try XCTUnwrap(projected.copyDetails)
        XCTAssertTrue(copied.contains(try XCTUnwrap(agent.output)), "Card and copy read the same results")
        XCTAssertTrue(copied.contains("status: inProgress"))
    }

    func testSubagentCardWithoutChildStatesHasNoOutput() {
        let projected = CodexConversationProjection.item(collaborationItem(receivers: ["child"], states: [:]),
            turnID: "turn", isTurnFinished: true, workspaceURL: URL(filePath: "/tmp"), changes: [],
            isHistoryMatch: false)
        guard case let .subagent(agent) = projected.kind else { return XCTFail("Not a subagent") }
        XCTAssertNil(agent.output)
    }

    // MARK: - F06: resource_link in an MCP result

    func testResourceLinkOnlyResultIsNotEmpty() throws {
        let projection = CodexMCPResultProjection(result: content([link(
            name: "audit-report", title: "Audit report", uri: "https://example.com/report",
            description: "The full findings", mimeType: "text/html"
        )]), itemID: "mcp")

        XCTAssertFalse(projection.isEmpty)
        guard case let .resourceLink(id, value) = try XCTUnwrap(projection.blocks.first) else {
            return XCTFail("A resource link is its own block")
        }
        XCTAssertEqual(id, "mcp#0")
        XCTAssertEqual(value.name, "audit-report")
        XCTAssertEqual(value.label, "Audit report")
        XCTAssertEqual(value.uri, "https://example.com/report")
        XCTAssertEqual(value.description, "The full findings")
        XCTAssertEqual(value.mimeType, "text/html")
        XCTAssertEqual(value.openableURL, URL(string: "https://example.com/report"))
    }

    func testMixedResultKeepsBlockOrder() {
        let projection = CodexMCPResultProjection(result: content([
            .object(["type": .string("text"), "text": .string("Found 2 files")]),
            link(name: "App.swift", uri: "file:///tmp/work/App.swift", mimeType: "text/x-swift"),
            link(name: "", uri: ""),
            link(name: "notes", uri: "http://localhost:8080/notes")
        ]), itemID: "mcp")

        XCTAssertEqual(projection.blocks.map(\.id), ["mcp#0", "mcp#1", "mcp#3"],
                       "A link with neither a name nor a URI has nothing to show")
        guard projection.blocks.count == 3,
              case let .resourceLink(_, file) = projection.blocks[1],
              case let .resourceLink(_, local) = projection.blocks[2]
        else { return XCTFail("Both links stay links") }
        XCTAssertEqual(file.label, "App.swift")
        XCTAssertEqual(file.openableURL, URL(filePath: "/tmp/work/App.swift"))
        XCTAssertEqual(local.openableURL, URL(string: "http://localhost:8080/notes"))
    }

    func testFileLinkKeepsItsLineAndColumnAndAnyPath() throws {
        let cases: [(uri: String, path: String, fragment: String?)] = [
            ("file:///tmp/work/Report.swift#L12", "/tmp/work/Report.swift", "L12"),
            ("file:///tmp/work/Report.swift#L12C3", "/tmp/work/Report.swift", "L12C3"),
            ("file://localhost/tmp/work/Report.swift#L7", "/tmp/work/Report.swift", "L7"),
            ("file:///tmp/%ED%95%9C%EA%B8%80%20%ED%8F%B4%EB%8D%94/%EB%B3%B4%EA%B3%A0%EC%84%9C.md#L3",
             "/tmp/한글 폴더/보고서.md", "L3"),
            ("file:///tmp/한글 폴더/보고서.md#L4C2", "/tmp/한글 폴더/보고서.md", "L4C2"),
            ("file:///tmp/work/Report.swift", "/tmp/work/Report.swift", nil)
        ]
        let projection = CodexMCPResultProjection(result: content(cases.map { link(name: "r", uri: $0.uri) }))
        XCTAssertEqual(projection.blocks.count, cases.count)
        for (block, expected) in zip(projection.blocks, cases) {
            guard case let .resourceLink(_, value) = block else { return XCTFail("\(expected.uri) is not a link") }
            let url = try XCTUnwrap(value.openableURL, expected.uri)
            XCTAssertTrue(url.isFileURL, expected.uri)
            XCTAssertNil(url.host(), expected.uri)
            XCTAssertEqual(url.path(percentEncoded: false), expected.path, expected.uri)
            XCTAssertEqual(url.fragment(), expected.fragment, expected.uri)
            XCTAssertEqual(value.uri, expected.uri, "The URI is shown as written")
            // The files panel reads the line and column from the fragment it is handed.
            let location = try WorkspaceFileLocation.resolve(url, in: URL(filePath: "/tmp"))
            XCTAssertEqual(location.line, expected.fragment.flatMap { Int($0.dropFirst().prefix { $0.isNumber }) },
                           expected.uri)
            XCTAssertEqual(location.column, expected.fragment?.split(separator: "C").dropFirst().first.flatMap { Int($0) },
                           expected.uri)
        }
    }

    func testUnsafeAndUnknownSchemesStayReadableText() {
        let uris = [
            "javascript:alert(1)",
            "JavaScript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "vscode://file/tmp/x",
            "x-apple.systempreferences:com.apple.preference.security",
            "postgres://db/table",
            "ssh://host",
            "file://other-mac/tmp/x",
            "mailto:someone@example.com",
            "file:relative/path",
            "https://",
            "not a uri at all",
            "/tmp/no-scheme"
        ]
        let projection = CodexMCPResultProjection(result: content(uris.map { link(name: $0, uri: $0) }))

        XCTAssertEqual(projection.blocks.count, uris.count)
        for (block, uri) in zip(projection.blocks, uris) {
            guard case let .resourceLink(_, value) = block else { return XCTFail("\(uri) is not a link block") }
            XCTAssertEqual(value.uri, uri, "The URI is kept as written")
            XCTAssertNil(value.openableURL, "\(uri) must not open")
        }
    }

    func testLinkFallsBackToItsURIWhenUnnamed() throws {
        let projection = CodexMCPResultProjection(result: content([
            .object(["type": .string("resource_link"), "uri": .string("https://example.com/a")])
        ]))
        guard case let .resourceLink(_, value) = try XCTUnwrap(projection.blocks.first) else {
            return XCTFail("A link with only a URI still shows")
        }
        XCTAssertEqual(value.label, "https://example.com/a")
        XCTAssertNil(value.description)
        XCTAssertNil(value.mimeType)
    }

    func testOtherResultConsumersStillReadOnlyText() {
        // run_agent, spawn_task and create_scheduled_task read the text blocks; a link beside them
        // must not change what they parse.
        let tool = mcpTool(result: content([
            link(name: "report", uri: "https://example.com/r"),
            .object(["type": .string("text"), "text": .string("ok")])
        ]))
        let texts = CodexMCPResultProjection(result: tool.result).blocks.compactMap { block -> String? in
            if case let .text(_, text) = block { return text }
            return nil
        }
        XCTAssertEqual(texts, ["ok"])
    }

    func testResourceLinkSurvivesRereadingTheThreadAndTheYHPProjection() throws {
        var state = CodexTaskState()
        _ = CodexTaskReducer().applySnapshot(.object([
            "id": .string("thread-1"),
            "turns": .array([.object([
                "id": .string("turn-1"), "status": .string("completed"),
                "items": .array([mcpPayload(result: content([
                    .object(["type": .string("text"), "text": .string("See the report")]),
                    link(name: "report", title: "Report", uri: "https://example.com/r",
                         description: "Weekly", mimeType: "application/pdf")
                ]))])
            ])])
        ]), to: &state)
        let reread = try XCTUnwrap(state.thread?.turns.first?.items.first)

        let wire = CodexPresentationWire.snapshot(state, localSessionID: UUID(), answerableServerRequestIDs: [])
        let decoded = try JSONDecoder().decode(
            HarnessProtocolCodexPresentationSnapshot.self, from: JSONEncoder().encode(wire)
        )
        let projected = try XCTUnwrap(CodexYHPProjection.presentation(decoded).thread?.turns.first?.items.first)

        for item in [reread, projected] {
            guard case let .mcpToolCall(tool) = item.content else { return XCTFail("Not an MCP call") }
            let projection = CodexMCPResultProjection(result: tool.result, itemID: item.id)
            XCTAssertEqual(projection.blocks.count, 2)
            guard case let .resourceLink(_, value) = projection.blocks[1] else { return XCTFail("Link lost") }
            XCTAssertEqual(value.label, "Report")
            XCTAssertEqual(value.description, "Weekly")
            XCTAssertEqual(value.mimeType, "application/pdf")
            XCTAssertNotNil(value.openableURL)

            let card = CodexConversationProjection.item(item, turnID: "turn-1", isTurnFinished: true,
                workspaceURL: URL(filePath: "/tmp"), changes: [], isHistoryMatch: false)
            guard case let .tool(line) = card.kind else { return XCTFail("Not a tool line") }
            XCTAssertEqual(line.mcpResult?.blocks.count, 2)
            XCTAssertTrue(card.copyDetails?.contains("https://example.com/r") == true)
        }
    }

    // MARK: - Fixtures

    private func collaborationItem(
        receivers: [String], states: [String: JSONValue], status: String = "completed"
    ) -> CodexItemState {
        CodexTaskDecoder().item(from: .object([
            "id": .string("collab"), "type": .string("collabAgentToolCall"), "tool": .string("wait"),
            "status": .string(status), "senderThreadId": .string("parent"),
            "receiverThreadIds": .array(receivers.map(JSONValue.string)),
            "prompt": .string("Check the build"),
            "agentsStates": .object(states)
        ]), fallbackID: "collab", lifecycle: .completed)
    }

    private func content(_ blocks: [JSONValue]) -> JSONValue {
        .object(["content": .array(blocks)])
    }

    private func link(
        name: String, title: String? = nil, uri: String, description: String? = nil, mimeType: String? = nil
    ) -> JSONValue {
        var value: [String: JSONValue] = [
            "type": .string("resource_link"), "name": .string(name), "uri": .string(uri)
        ]
        if let title { value["title"] = .string(title) }
        if let description { value["description"] = .string(description) }
        if let mimeType { value["mimeType"] = .string(mimeType) }
        return .object(value)
    }

    private func mcpPayload(result: JSONValue) -> JSONValue {
        .object([
            "id": .string("mcp-1"), "type": .string("mcpToolCall"), "server": .string("docs"),
            "tool": .string("find"), "status": .string("completed"), "arguments": .object([:]),
            "result": result
        ])
    }

    private func mcpTool(result: JSONValue) -> CodexMCPToolItem {
        let item = CodexTaskDecoder().item(from: mcpPayload(result: result), fallbackID: "mcp-1", lifecycle: .completed)
        guard case let .mcpToolCall(tool) = item.content else { fatalError("Not an MCP call") }
        return tool
    }
}
