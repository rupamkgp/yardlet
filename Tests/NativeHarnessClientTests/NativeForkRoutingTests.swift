import Foundation
import XCTest
@testable import NativeHarnessClient

final class NativeForkRoutingTests: XCTestCase {
    func testCodexSelectedBoundarySurvivesBothRoutesWithoutRollingBackTheSource() async throws {
        for routed in [false, true] {
            let transport = FakeCodexTransport(responses: [
                "initialize": [.object(["platformOs": .string("macos")])],
                "thread/start": [thread("original")],
                "thread/fork": [thread("child")]
            ])
            let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
            let adapter: any HarnessAdapter = routed
                ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex())
                : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let provider = try XCTUnwrap(adapter as? any CodexCapabilityProviding)
            let presentation = try XCTUnwrap(adapter as? any CodexPresentationProviding)
            let before = try await presentation.presentationState(for: handle)
            let child = try await provider.fork(handle, newLocalSessionID: UUID(), throughTurnID: "selected-turn")
            let after = try await presentation.presentationState(for: handle)
            let forked = try await presentation.presentationState(for: child)
            XCTAssertEqual(before.thread, after.thread)
            XCTAssertEqual(forked.thread?.turns.map(\.id), ["selected-turn"])
            let requests = await transport.requests
            let request = try XCTUnwrap(requests.first { $0.method == "thread/fork" })
            XCTAssertEqual(request.params["threadId"], .string("original"))
            XCTAssertEqual(request.params["lastTurnId"], .string("selected-turn"))
            XCTAssertEqual(request.params["excludeTurns"], .bool(true))
            XCTAssertEqual(child.providerSessionID, "child")
            XCTAssertEqual(handle.providerSessionID, "original")
            XCTAssertFalse(requests.contains { ["thread/rollback", "thread/revert", "turn/start"].contains($0.method) })
            await adapter.close(child)
            await adapter.close(handle)
        }
    }

    func testCodexRefusesAnActiveCutAndAReusedLocalIdentityBeforeDispatch() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])], "thread/start": [thread("original")],
            "turn/start": [.object(["turn": .object(["id": .string("live-turn")])])]
        ])
        let adapter = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport)
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
        try await adapter.send("Start fixture turn", to: handle)
        do {
            _ = try await adapter.fork(handle, newLocalSessionID: UUID(), throughTurnID: "live-turn")
            XCTFail("An active turn cannot be a fork boundary")
        } catch {}
        do {
            _ = try await adapter.fork(handle, newLocalSessionID: handle.localSessionID)
            XCTFail("The parent handle cannot be overwritten")
        } catch {}
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { $0.method == "thread/fork" })
        await adapter.close(handle)
    }

    func testClaudeFirstMessageEditStartsItsPlannedEmptyIdentityThroughBothRoutes() async throws {
        for routed in [false, true] {
            let transport = FakeClaudeTransport()
            let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude()) : direct
            let localID = UUID(), newID = UUID().uuidString.lowercased()
            let configurable = try XCTUnwrap(adapter as? any HarnessNewSessionConfiguring)
            try await configurable.setNewSessionID(newID, for: localID)
            let handle = try await adapter.resumeSession(providerSessionID: newID, localSessionID: localID, workspaceURL: URL(filePath: "/tmp"))
            let captured = await transport.configuration
            let configuration = try XCTUnwrap(captured)
            let arguments = ClaudeProcessTransport.arguments(for: configuration)
            XCTAssertEqual(handle.providerSessionID, newID)
            XCTAssertFalse(configuration.resumesExistingSession)
            XCTAssertTrue(arguments.contains("--session-id=\(newID)"))
            XCTAssertFalse(arguments.contains { $0.hasPrefix("--resume") || $0 == "--fork-session" })
            let inputs = await transport.sentValues; XCTAssertTrue(inputs.isEmpty)
            await adapter.close(handle)
        }
    }

    func testClaudeNewIdentityCannotReplaceAnotherResumeOrAnAttachedSession() async throws {
        let transport = FakeClaudeTransport()
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
        let localID = UUID(), planned = UUID().uuidString.lowercased()
        try await adapter.setNewSessionID(planned, for: localID)
        do { _ = try await adapter.resumeSession(providerSessionID: UUID().uuidString.lowercased(), localSessionID: localID,
            workspaceURL: URL(filePath: "/tmp")); XCTFail() } catch {}
        let before = await transport.configuration; XCTAssertNil(before)
        let handle = try await adapter.resumeSession(providerSessionID: planned, localSessionID: localID, workspaceURL: URL(filePath: "/tmp"))
        do { try await adapter.setNewSessionID(nil, for: localID); XCTFail() } catch {}
        await adapter.close(handle)
    }

    func testClaudeNativeForkLaunchUsesDistinctIdentityAndExactCheckpointThroughYHP() async throws {
        for routed in [false, true] {
            let transport = FakeClaudeTransport()
            let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude())
                : direct
            let childID = UUID().uuidString.lowercased()
            let localID = UUID()
            let source = HarnessSessionForkSource(providerSessionID: UUID().uuidString.lowercased(), throughMessageID: UUID().uuidString.lowercased())
            let configurable = try XCTUnwrap(adapter as? any HarnessSessionForkConfiguring)
            try await configurable.setSessionForkSource(source, for: localID)
            let handle = try await adapter.resumeSession(providerSessionID: childID, localSessionID: localID, workspaceURL: URL(filePath: "/tmp"))
            let captured = await transport.configuration
            let configuration = try XCTUnwrap(captured)
            let arguments = ClaudeProcessTransport.arguments(for: configuration)
            XCTAssertTrue(arguments.contains("--resume=\(source.providerSessionID)"))
            XCTAssertTrue(arguments.contains("--fork-session"))
            XCTAssertTrue(arguments.contains("--session-id=\(childID)"))
            XCTAssertTrue(arguments.contains("--resume-session-at=\(source.throughMessageID)"))
            XCTAssertEqual(handle.providerSessionID, childID)
            let preparedInputs = await transport.sentValues
            XCTAssertTrue(preparedInputs.isEmpty)
            try await adapter.send("Exact new request", to: handle)
            let inputs = await transport.sentValues
            XCTAssertEqual(inputs.last?["message"]?["content"], .string("Exact new request"))
            XCTAssertEqual(inputs.last?["session_id"], .string(childID))
            await adapter.close(handle)
        }
    }

    private func thread(_ id: String) -> JSONValue {
        let ids = id == "original" ? ["selected-turn", "later-turn"] : ["selected-turn"]
        return .object(["thread": .object(["id": .string(id), "turns": .array(ids.map {
            .object(["id": .string($0), "status": .string("completed"), "items": .array([])])
        })])])
    }
}
