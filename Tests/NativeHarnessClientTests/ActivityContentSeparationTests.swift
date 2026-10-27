import Foundation
import XCTest
@testable import NativeHarnessClient

final class ActivityContentSeparationTests: XCTestCase {
    func testCachedActivityWithoutSeparatedFieldsStillDecodes() throws {
        let cached = Data(
            #"{"id":"tool","kind":"read","title":"Read","detail":"cat README.md"}"#.utf8
        )
        let activity = try JSONDecoder().decode(HarnessActivity.self, from: cached)
        XCTAssertEqual(activity.detail, "cat README.md")
        XCTAssertNil(activity.input)
        XCTAssertNil(activity.output)
        XCTAssertNil(activity.diff)
        XCTAssertFalse(activity.hasSeparatedContent)
    }

    func testSeparatedFieldsSurviveStorageRoundTrip() throws {
        let activity = HarnessActivity(
            id: "tool",
            kind: "edit",
            title: "Edit",
            detail: nil,
            input: "apply_patch README.md",
            output: "1 file changed",
            diff: HarnessActivityDiff(
                path: "README.md",
                oldText: "old",
                newText: "new",
                unified: "@@\n-old\n+new"
            )
        )
        let restored = try JSONDecoder().decode(
            HarnessActivity.self,
            from: JSONEncoder().encode(activity)
        )
        XCTAssertEqual(restored, activity)
        XCTAssertTrue(restored.hasSeparatedContent)
    }

    func testCompletionOutputDoesNotEraseTheInputFromTheStartEvent() {
        var builder = TranscriptBuilder()
        builder.appendUser("Read the file")
        builder.apply(.activityStarted(HarnessActivity(
            id: "tool-1",
            kind: "bash",
            title: "Bash",
            input: "cat README.md"
        )))
        builder.apply(.activityCompleted(HarnessActivity(
            id: "tool-1",
            kind: "bash",
            title: "Bash",
            output: "# Yardlet"
        )))
        guard case let .activity(activity, state) = builder.entries[1].content else {
            return XCTFail("expected an activity card")
        }
        XCTAssertEqual(state, .completed)
        XCTAssertEqual(activity.input, "cat README.md")
        XCTAssertEqual(activity.output, "# Yardlet")
    }

    func testACPKeepsTheFileChangeAsADiffAndTheCommandAsInput() {
        let update = JSONValue.object([
            "sessionUpdate": .string("tool_call_update"),
            "toolCallId": .string("call-1"),
            "title": .string("Edit README"),
            "kind": .string("edit"),
            "status": .string("completed"),
            "rawInput": .object([
                "command": .string("apply_patch"),
                "path": .string("README.md")
            ]),
            "locations": .array([
                .object(["path": .string("README.md"), "line": .integer(12)])
            ]),
            "content": .array([
                .object([
                    "type": .string("content"),
                    "content": .object([
                        "type": .string("text"),
                        "text": .string("Updated 1 file")
                    ])
                ]),
                .object([
                    "type": .string("diff"),
                    "path": .string("README.md"),
                    "oldText": .string("# Old"),
                    "newText": .string("# New")
                ])
            ])
        ])
        guard let activity = ACPEventProjector().activity(from: update) else {
            return XCTFail("expected an activity")
        }
        XCTAssertEqual(activity.input?.split(separator: "\n").first, "apply_patch")
        XCTAssertEqual(activity.input?.contains("README.md:12"), true)
        XCTAssertEqual(activity.output, "Updated 1 file")
        XCTAssertEqual(activity.diff?.path, "README.md")
        XCTAssertEqual(activity.diff?.oldText, "# Old")
        XCTAssertEqual(activity.diff?.newText, "# New")
    }

    func testStructuredHeadlessKeepsTheWholeToolOutput() {
        let payload = String(repeating: "y", count: 900)
        let projection = StructuredHeadlessEventProjector(flavor: .cursor).project(
            .object([
                "type": .string("tool_call"),
                "subtype": .string("completed"),
                "call_id": .string("call-2"),
                "tool_call": .object([
                    "readToolCall": .object([
                        "args": .object(["path": .string("README.md")]),
                        "result": .object(["contents": .string(payload)])
                    ])
                ])
            ]),
            hasAssistantText: false
        )
        guard case let .activityCompleted(activity) = projection.payloads.first else {
            return XCTFail("expected a completed tool card")
        }
        XCTAssertEqual(activity.output?.contains(payload), true)
        XCTAssertEqual(activity.input?.contains("README.md"), true)
        XCTAssertEqual(activity.detail?.count ?? 0 <= 361, true)
    }

    func testLegacyDetailAndDiffSurviveTheProtocolRoundTrip() async throws {
        let recorded = HarnessActivity(
            id: "tool-2",
            kind: "edit",
            title: "Edit",
            detail: "legacy detail",
            input: "apply_patch",
            output: "done",
            diff: HarnessActivityDiff(path: "Sources/App.swift", oldText: "a", newText: "b")
        )
        let adapter = RecordedActivityAdapter(activity: recorded)
        let bridged = YHPProviderCompatibilityAdapter(
            adapter: adapter,
            manifest: HarnessProtocolCompatibilityManifest.acp(.openCode)
        )
        let handle = try await bridged.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: NSTemporaryDirectory()),
                initialPrompt: nil
            )
        )
        var projected: HarnessActivity?
        let stream = await bridged.events(for: handle)
        for await event in stream {
            if case let .activityCompleted(activity) = event.payload {
                projected = activity
                break
            }
        }
        await bridged.close(handle)
        XCTAssertEqual(projected, recorded)
    }
}

/// Minimal adapter that replays one completed tool call so the compatibility bridge round trip
/// can be asserted without a provider process.
private actor RecordedActivityAdapter: HarnessAdapter {
    nonisolated let kind = HarnessKind.openCode
    private let activity: HarnessActivity
    private var handle: HarnessSessionHandle?

    init(activity: HarnessActivity) {
        self.activity = activity
    }

    func probeRuntime() async throws -> HarnessRuntimeDescriptor {
        HarnessRuntimeDescriptor(
            harness: kind,
            executableURL: URL(filePath: "/usr/bin/true"),
            version: "0",
            capabilities: HarnessCapabilities(
                canResume: true,
                canInterrupt: true,
                hasStructuredPermissions: true,
                hasStructuredActivities: true,
                hasPlans: true,
                acceptsImages: false,
                hasSubagents: false
            ),
            fingerprint: "recorded"
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        let handle = HarnessSessionHandle(
            harness: kind,
            localSessionID: request.localSessionID,
            providerSessionID: "recorded",
            workspaceURL: request.workspaceURL
        )
        self.handle = handle
        return handle
    }

    func resumeSession(
        providerSessionID: String,
        localSessionID: UUID,
        workspaceURL: URL
    ) async throws -> HarnessSessionHandle {
        try await createSession(
            CreateHarnessSessionRequest(
                localSessionID: localSessionID,
                workspaceURL: workspaceURL,
                initialPrompt: nil
            )
        )
    }

    func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
    func interrupt(_ session: HarnessSessionHandle) async throws {}

    func respond(
        to permissionRequestID: String,
        decision: PermissionDecision,
        in session: HarnessSessionHandle
    ) async throws {}

    func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
        let stream = AsyncStream<HarnessEventEnvelope>.makeStream()
        stream.continuation.yield(
            HarnessEventEnvelope(
                localSessionID: session.localSessionID,
                sequence: 0,
                payload: .sessionStarted(session)
            )
        )
        stream.continuation.yield(
            HarnessEventEnvelope(
                localSessionID: session.localSessionID,
                sequence: 1,
                payload: .activityCompleted(activity)
            )
        )
        return stream.stream
    }

    func close(_ session: HarnessSessionHandle) async {
        handle = nil
    }
}
