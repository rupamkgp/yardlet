import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class ReasoningTranscriptTests: XCTestCase {
    func testReasoningStaysInItsOwnBlockAndNeverMergesIntoTheAnswer() {
        var builder = TranscriptBuilder()
        builder.appendUser("Why?")
        builder.apply(.reasoningDelta("Checking "))
        builder.apply(.reasoningDelta("the build."))
        builder.apply(.assistantDelta("Because "))
        builder.apply(.assistantMessageCompleted("Because the build is stale."))
        builder.apply(.turnCompleted)
        XCTAssertEqual(builder.entries.map(\.content), [
            .user(text: "Why?"),
            .reasoning(text: "Checking the build.", isStreaming: false),
            .assistant(text: "Because the build is stale.", isStreaming: false)
        ])
    }

    func testCompletedReasoningReplacesTheStreamedThoughtInsteadOfAppending() {
        var builder = TranscriptBuilder()
        builder.apply(.reasoningDelta("partial"))
        builder.apply(.reasoningCompleted("partial thought, finished"))
        XCTAssertEqual(builder.entries.map(\.content), [
            .reasoning(text: "partial thought, finished", isStreaming: false)
        ])
    }

    /// Finished thinking folds with the turn's settled work, in the model and in the conversation.
    func testRestoredTranscriptStopsStreamingReasoningAndCollapsesItWithCompletedWork() throws {
        var builder = TranscriptBuilder()
        builder.appendUser("Explain")
        builder.apply(.reasoningDelta("thinking"))
        let restored = TranscriptBuilder(entries: builder.entries).entries
        XCTAssertEqual(restored.map(\.content), [
            .user(text: "Explain"),
            .reasoning(text: "thinking", isStreaming: false)
        ])

        builder.apply(.assistantMessageCompleted("Done"))
        let presentation = TranscriptConversationProjection.presentation(
            from: builder.entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        )
        let turn = try XCTUnwrap(presentation.turns.last)
        XCTAssertTrue(turn.foldsWork)
        XCTAssertTrue(turn.work.contains { item in
            if case .reasoning = item.kind { return true }
            return false
        })

        // The conversation draws the thinking folded under "Work details".
        let drawing = try ConversationDrawing.draw(
            TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet"),
                                 entries: builder.entries, sessionStatus: .ready, latestTurnIsComplete: true),
            size: NSSize(width: 640, height: 400), appearance: .light
        )
        let text = drawing.elements.map(\.description).joined(separator: "\n")
        XCTAssertTrue(text.contains(L10n.string("Work details")), text)
        XCTAssertTrue(text.contains("Done"), text)
        XCTAssertFalse(text.contains("thinking"), "folded thinking is not drawn:\n\(text)")
    }

    func testClaudeProjectsThinkingDeltasAndTheCompletedThinkingBlock() throws {
        let codec = ClaudeWireCodec()
        let projector = ClaudeEventProjector()
        let delta = try codec.decodeLine(Data(
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"weighing options"}}}"#.utf8
        ))
        XCTAssertEqual(projector.payloads(from: delta), [.reasoningDelta("weighing options")])

        let message = try codec.decodeLine(Data(
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"weighing options carefully"},{"type":"text","text":"Here is the plan."}]}}"#.utf8
        ))
        XCTAssertEqual(projector.payloads(from: message), [
            .reasoningCompleted("weighing options carefully"),
            .assistantMessageCompleted("Here is the plan.")
        ])
    }

    func testACPAndPiProjectProviderThoughtChunks() {
        XCTAssertEqual(
            ACPEventProjector().payloads(from: .object([
                "sessionUpdate": .string("agent_thought_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string("inspecting the repository")
                ])
            ])),
            [.reasoningDelta("inspecting the repository")]
        )
        XCTAssertEqual(
            PiRPCEventProjector().payloads(from: .object([
                "type": .string("message_update"),
                "assistantMessageEvent": .object([
                    "type": .string("thinking_delta"),
                    "delta": .string("reading the file")
                ])
            ])),
            [.reasoningDelta("reading the file")]
        )
    }

    func testReasoningReachesTheTranscriptThroughTheProtocolBridge() async throws {
        let adapter = ReasoningOnlyAdapter()
        let bridged = YHPProviderCompatibilityAdapter(
            adapter: adapter,
            manifest: HarnessProtocolCompatibilityManifest.claude()
        )
        let handle = try await bridged.createSession(
            CreateHarnessSessionRequest(
                localSessionID: UUID(),
                workspaceURL: URL(filePath: NSTemporaryDirectory()),
                initialPrompt: nil
            )
        )
        var payloads: [HarnessEventPayload] = []
        for await event in await bridged.events(for: handle) {
            payloads.append(event.payload)
            if case .progressUpdateCompleted = event.payload { break }
        }
        await bridged.close(handle)
        XCTAssertTrue(payloads.contains(.reasoningDelta("half a thought")))
        XCTAssertTrue(payloads.contains(.reasoningCompleted("half a thought, finished")))
        XCTAssertTrue(payloads.contains(.progressUpdateCompleted("A note before the next call.")))

        // A note the model wrote between tool calls streams as thinking and completes as its words.
        var builder = TranscriptBuilder()
        payloads.forEach { builder.apply($0) }
        XCTAssertEqual(builder.entries.map(\.content), [
            .reasoning(text: "half a thought, finished", isStreaming: false),
            .reasoning(text: "A note before the next call.", isStreaming: false)
        ])
        XCTAssertEqual(builder.entries.map(\.isProgressUpdate), [nil, true])
    }
}

private actor ReasoningOnlyAdapter: HarnessAdapter {
    nonisolated let kind = HarnessKind.claudeCode

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
                hasPlans: false,
                acceptsImages: false,
                hasSubagents: false
            ),
            fingerprint: "reasoning"
        )
    }

    func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
        HarnessSessionHandle(
            harness: kind,
            localSessionID: request.localSessionID,
            providerSessionID: "reasoning",
            workspaceURL: request.workspaceURL
        )
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
        let payloads: [HarnessEventPayload] = [
            .sessionStarted(session),
            .reasoningDelta("half a thought"),
            .reasoningCompleted("half a thought, finished"),
            .reasoningDelta("A note"),
            .progressUpdateCompleted("A note before the next call.")
        ]
        for (index, payload) in payloads.enumerated() {
            stream.continuation.yield(
                HarnessEventEnvelope(
                    localSessionID: session.localSessionID,
                    sequence: UInt64(index),
                    payload: payload
                )
            )
        }
        return stream.stream
    }

    func close(_ session: HarnessSessionHandle) async {}
}
