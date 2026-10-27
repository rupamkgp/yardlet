import Foundation
import XCTest
@testable import NativeHarnessClient

final class CodexWorkSurfaceProjectionTests: XCTestCase {
    func testEditorHandoffOutcomeIsExplicitAndLocalizedByTheView() {
        XCTAssertEqual(
            CodexEditorHandoffProjection.outcome(opened: true),
            .opened
        )
        XCTAssertEqual(
            CodexEditorHandoffProjection.outcome(opened: false),
            .failed
        )
        XCTAssertEqual(
            CodexEditorHandoffProjection.messageKey(for: .opened),
            "Editor launch requested."
        )
        XCTAssertEqual(
            CodexEditorHandoffProjection.messageKey(for: .failed),
            "Could not request editor launch."
        )
    }

    func testFileChangeProjectionVerifiesWorkspaceRelativePathsAndRejectsEscape() {
        let workspace = URL(filePath: "/tmp/codex-workspace")
        let snapshot: JSONValue = .object([
            "id": .string("thread"),
            "turns": .array([
                .object([
                    "id": .string("turn"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "id": .string("file"),
                            "type": .string("fileChange"),
                            "status": .string("completed"),
                            "changes": .array([
                                .object([
                                    "path": .string("Sources/App.swift"), "kind": .string("modified"),
                                    "line": .integer(42), "column": .integer(7)
                                ]),
                                .object(["path": .string("../outside.txt"), "kind": .string("modified")]),
                                .object(["path": .string("/tmp/absolute.txt"), "kind": .string("added")])
                            ])
                        ])
                    ])
                ])
            ])
        ])
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(snapshot, to: &state))

        let changes = CodexWorkSurfaceProjection.changes(from: state, workspaceURL: workspace)
        XCTAssertEqual(changes.map(\.relativePath), ["Sources/App.swift", "../outside.txt", "/tmp/absolute.txt"])
        XCTAssertEqual(changes.map(\.id), ["turn:file:0", "turn:file:1", "turn:file:2"])
        XCTAssertEqual(changes.map(\.isVerified), [true, false, false])
        XCTAssertEqual(
            changes.first?.verifiedURL?.path(percentEncoded: false),
            "/tmp/codex-workspace/Sources/App.swift"
        )
        XCTAssertEqual(changes.first?.line, 42)
        XCTAssertEqual(changes.first?.column, 7)
        XCTAssertEqual(changes.first?.locationLabel, "Sources/App.swift:42:7")

        // Existing directory URLs can carry a trailing slash. The verified handoff must not
        // turn that into a false "outside workspace" warning in the installed work surface.
        let existingDirectoryChanges = CodexWorkSurfaceProjection.changes(
            from: state,
            workspaceURL: URL(filePath: "/tmp")
        )
        XCTAssertTrue(existingDirectoryChanges.first?.isVerified ?? false)
        XCTAssertEqual(
            existingDirectoryChanges.first?.verifiedURL?.path(percentEncoded: false),
            "/tmp/Sources/App.swift"
        )
    }

    /// App Server and recorded Codex rollouts name files by absolute path. One inside the task's
    /// folder is the task's file, shown relative; an outside one stays unverified.
    func testAbsoluteAppServerPathsInsideTheTaskFolderAreVerified() {
        let workspace = URL(filePath: "/tmp/codex-workspace")
        let update: JSONValue = .object(["type": .string("update"), "move_path": .null])
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(.object([
            "id": .string("thread"), "preview": .string(""),
            "status": .object(["type": .string("idle")]),
            "turns": .array([.object([
                "id": .string("turn"), "status": .string("completed"),
                "items": .array([.object([
                    "id": .string("file"), "type": .string("fileChange"), "status": .string("completed"),
                    "changes": .array([
                        .object(["path": .string("/tmp/codex-workspace/Sources/App.swift"), "kind": update, "diff": .string("")]),
                        .object(["path": .string("/tmp/codex-workspace/../elsewhere.txt"), "kind": update, "diff": .string("")]),
                        .object(["path": .string("/tmp/other/App.swift"), "kind": .object(["type": .string("add")]), "diff": .string("")])
                    ])
                ])])
            ])])
        ]), to: &state))
        let changes = CodexWorkSurfaceProjection.changes(from: state, workspaceURL: workspace)
        XCTAssertEqual(changes.map(\.relativePath), [
            "Sources/App.swift", "/tmp/codex-workspace/../elsewhere.txt", "/tmp/other/App.swift"
        ])
        XCTAssertEqual(changes.map(\.isVerified), [true, false, false])
        XCTAssertEqual(changes.first?.verifiedURL?.path(percentEncoded: false), "/tmp/codex-workspace/Sources/App.swift")
        XCTAssertEqual(changes.map(\.status), ["update", "update", "add"])
    }

    func testItemHandoffCopiesHydratedDetailsWithoutDispatchingProviderWork() {
        let snapshot: JSONValue = .object([
            "id": .string("thread"),
            "turns": .array([
                .object([
                    "id": .string("turn"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "id": .string("command"),
                            "type": .string("commandExecution"),
                            "command": .string("swift test"),
                            "status": .string("completed"),
                            "aggregatedOutput": .string("all green")
                        ]),
                        .object([
                            "id": .string("search"),
                            "type": .string("webSearch"),
                            "query": .string("SwiftUI accessibility")
                        ]),
                        .object([
                            "id": .string("future"),
                            "type": .string("futureItem"),
                            "payload": .object(["stable": .bool(true)])
                        ])
                    ])
                ])
            ])
        ])
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(snapshot, to: &state))
        guard let turn = state.thread?.turns.first else {
            return XCTFail("expected hydrated turn")
        }

        let handoffs = turn.items.compactMap {
            CodexWorkSurfaceProjection.itemHandoff(for: $0, turnID: turn.id)
        }
        XCTAssertEqual(handoffs.map(\.id), ["turn:command", "turn:search", "turn:future"])
        XCTAssertTrue(handoffs[0].payload.contains("swift test"))
        XCTAssertTrue(handoffs[0].payload.contains("all green"))
        XCTAssertTrue(handoffs[1].payload.contains("SwiftUI accessibility"))
        XCTAssertTrue(handoffs[2].payload.contains("futureItem"))
        XCTAssertTrue(handoffs[2].payload.contains("stable"))
    }

    func testItemHandoffRetainsStructuredMCPAndDynamicToolDetails() {
        let snapshot: JSONValue = .object([
            "id": .string("thread"),
            "turns": .array([
                .object([
                    "id": .string("turn"),
                    "status": .string("completed"),
                    "items": .array([
                        .object([
                            "id": .string("mcp"),
                            "type": .string("mcpToolCall"),
                            "server": .string("filesystem"),
                            "tool": .string("read_file"),
                            "status": .string("completed"),
                            "arguments": .object(["path": .string("Sources/App.swift")]),
                            "result": .object(["content": .string("hello")]),
                            "pluginId": .string("fixture-plugin"),
                            "durationMs": .integer(42)
                        ]),
                        .object([
                            "id": .string("dynamic"),
                            "type": .string("dynamicToolCall"),
                            "tool": .string("lookup"),
                            "namespace": .string("web"),
                            "status": .string("failed"),
                            "arguments": .object(["query": .string("swift")]),
                            "contentItems": .array([.object(["text": .string("no result")])]),
                            "success": .bool(false),
                            "durationMs": .integer(17)
                        ])
                    ])
                ])
            ])
        ])
        var state = CodexTaskState.empty
        XCTAssertTrue(CodexTaskReducer().applySnapshot(snapshot, to: &state))
        guard let turn = state.thread?.turns.first else {
            return XCTFail("expected hydrated turn")
        }

        let handoffs = turn.items.compactMap {
            CodexWorkSurfaceProjection.itemHandoff(for: $0, turnID: turn.id)
        }

        XCTAssertEqual(handoffs.map(\.id), ["turn:mcp", "turn:dynamic"])
        XCTAssertTrue(handoffs[0].payload.contains("filesystem · read_file"))
        XCTAssertTrue(handoffs[0].payload.contains("Sources/App.swift"))
        XCTAssertTrue(handoffs[0].payload.contains("hello"))
        XCTAssertTrue(handoffs[0].payload.contains("pluginID: fixture-plugin"))
        XCTAssertTrue(handoffs[0].payload.contains("durationMilliseconds: 42"))
        XCTAssertTrue(handoffs[1].payload.contains("namespace: web"))
        XCTAssertTrue(handoffs[1].payload.contains("query"))
        XCTAssertTrue(handoffs[1].payload.contains("no result"))
        XCTAssertTrue(handoffs[1].payload.contains("succeeded: false"))
        XCTAssertTrue(handoffs[1].payload.contains("durationMilliseconds: 17"))
    }
}
