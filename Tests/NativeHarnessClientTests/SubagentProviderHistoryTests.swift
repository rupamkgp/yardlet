import Foundation
import XCTest
@testable import NativeHarnessClient

/// A `run_agent` subagent leaves no history with its harness (decision of 2026-10-16); Yardlet
/// keeps its conversation with the calling task. Each harness's own way, read
/// from `--help` and the App Server schema only:
///
/// - Claude Code 2.1.299: `--no-session-persistence` ("sessions will not be saved to disk and cannot
///   be resumed (only works with --print)"), and Yardlet launches with `--print`.
/// - Codex 0.163 App Server: `ThreadStartParams.ephemeral`, `Thread.ephemeral` "should not be
///   materialized on disk"; such a thread is not named either.
/// - Pi 0.84.1: `--no-session` ("Don't save session (ephemeral)"), one process per session.
/// - The rest have no such option, or only one for the whole shared process, and say false.
final class SubagentProviderHistoryTests: XCTestCase {
    func testClaudeLaunchesASubagentWithoutSessionPersistenceAndATaskAsBefore() {
        let task = ClaudeLaunchConfiguration(providerSessionID: "s1", workspaceURL: URL(filePath: "/tmp/p"),
                                             resumesExistingSession: false)
        let taskArguments = ClaudeProcessTransport.arguments(for: task)
        XCTAssertFalse(taskArguments.contains("--no-session-persistence"), "A task's history is kept as always")

        var subagent = task
        subagent.keepsNoHistory = true
        let arguments = ClaudeProcessTransport.arguments(for: subagent)
        XCTAssertTrue(arguments.contains("--print"), "The flag works only in print mode")
        XCTAssertEqual(arguments.filter { $0 == "--no-session-persistence" }.count, 1)
        XCTAssertEqual(arguments.filter { $0 != "--no-session-persistence" }, taskArguments,
                       "Nothing else about the launch changes")

        // `--mcp-config` takes several values and must stay last.
        subagent.agentToolConfigPath = "/tmp/yardlet-mcp.json"
        let withTools = ClaudeProcessTransport.arguments(for: subagent)
        XCTAssertEqual(withTools.suffix(2), ["--mcp-config", "/tmp/yardlet-mcp.json"])
        XCTAssertTrue(withTools.contains("--no-session-persistence"))
    }

    func testClaudeKeepsNoHistoryForTheSessionAskedBeforeItStartsDirectAndRouted() async throws {
        for routed in [false, true] {
            let transport = FakeClaudeTransport()
            let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude())
                : direct
            let id = UUID()
            let history = try XCTUnwrap(adapter as? any HarnessHistoryFreeSessionConfiguring)
            let kept = await history.keepNoHistory(for: id)
            XCTAssertTrue(kept)
            let handle = try await adapter.createSession(CreateHarnessSessionRequest(
                localSessionID: id, workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil))
            let configuration = await transport.configuration
            XCTAssertEqual(configuration?.keepsNoHistory, true, "routed: \(routed)")
            let again = await history.keepNoHistory(for: id)
            XCTAssertFalse(again, "A running session keeps what it has")
            await adapter.close(handle)

            let other = FakeClaudeTransport()
            let plain = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in other })
            _ = try await plain.createSession(CreateHarnessSessionRequest(
                localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil))
            let plainConfiguration = await other.configuration
            XCTAssertEqual(plainConfiguration?.keepsNoHistory, false)
        }
    }

    func testCodexStartsASubagentThreadEphemeralAndDoesNotNameIt() async throws {
        let plain = CodexProtocol.startThread(id: 1, workspaceURL: URL(filePath: "/tmp/p"))
        XCTAssertEqual(plain.params["ephemeral"], .bool(false), "A task's thread is saved as always")
        let ephemeral = CodexProtocol.startThread(id: 2, workspaceURL: URL(filePath: "/tmp/p"), ephemeral: true)
        XCTAssertEqual(ephemeral.params["ephemeral"], .bool(true))
        XCTAssertEqual(ephemeral.params["approvalPolicy"], plain.params["approvalPolicy"])
        XCTAssertEqual(ephemeral.params["sandbox"], plain.params["sandbox"])

        for (routed, keepsNoHistory) in [(false, true), (true, true), (false, false)] {
            let transport = FakeCodexTransport(responses: Self.codexResponses)
            let direct = CodexAdapter(executableURL: URL(filePath: "/tmp/codex"), transport: transport, namesNewThreads: true)
            let adapter: any HarnessAdapter = routed
                ? YHPCodexCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.codex())
                : direct
            let id = UUID()
            if keepsNoHistory {
                let history = try XCTUnwrap(adapter as? any HarnessHistoryFreeSessionConfiguring)
                let kept = await history.keepNoHistory(for: id)
                XCTAssertTrue(kept)
            }
            let handle = try await adapter.createSession(CreateHarnessSessionRequest(
                localSessionID: id, workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil))
            let requests = await transport.requests
            let start = try XCTUnwrap(requests.first { $0.method == "thread/start" })
            XCTAssertEqual(start.params["ephemeral"], .bool(keepsNoHistory), "routed: \(routed)")

            try await adapter.send("Summarize README.md", to: handle)
            // A named thread asks for the model list and a side thread next; give it the chance.
            if keepsNoHistory {
                try await Task.sleep(for: .milliseconds(150))
            } else {
                try await waitUntil { await transport.requestMethods.drop { $0 != "turn/start" }.count > 1 }
            }
            let methods = await transport.requestMethods
            let afterTurn = methods.drop { $0 != "turn/start" }.dropFirst()
            if keepsNoHistory {
                XCTAssertTrue(afterTurn.isEmpty, "An ephemeral thread is in no list, so it is not named: \(methods)")
                XCTAssertFalse(methods.contains("thread/name/set"))
            } else {
                XCTAssertFalse(afterTurn.isEmpty, "A task's new thread is named as before: \(methods)")
            }
            await adapter.close(handle)
        }
    }

    func testPiRunsASubagentWithoutASessionFile() async throws {
        let transport = FakePiRPCTransport(sessionFile: "/tmp/pi-session.jsonl")
        let adapter = PiRPCAdapter(kind: .pi, executableURL: URL(filePath: "/tmp/fake-pi"),
                                   transportFactory: { _ in transport })
        let id = UUID()
        let kept = await adapter.keepNoHistory(for: id)
        XCTAssertTrue(kept)
        _ = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: id, workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil))
        let configuration = await transport.configuration
        XCTAssertEqual(configuration?.arguments, ["--mode", "rpc", "--no-session"])
        let plainArguments = await adapter.launchArguments(for: UUID())
        XCTAssertEqual(plainArguments, ["--mode", "rpc"], "A task launches as before")

        // In memory, Pi may name no session file; the subagent still starts, under its session id.
        let memory = FakePiRPCTransport(sessionFile: "/tmp/ignored.jsonl")
        await memory.forgetSessionFile()
        let inMemory = PiRPCAdapter(kind: .pi, executableURL: URL(filePath: "/tmp/fake-pi"),
                                    transportFactory: { _ in memory })
        let memoryID = UUID()
        _ = await inMemory.keepNoHistory(for: memoryID)
        let handle = try await inMemory.createSession(CreateHarnessSessionRequest(
            localSessionID: memoryID, workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil))
        XCTAssertEqual(handle.providerSessionID, "ignored")
        do {
            _ = try await inMemory.createSession(CreateHarnessSessionRequest(
                localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/project"), initialPrompt: nil))
            XCTFail("A task still needs a saved session")
        } catch {}
    }

    func testHarnessesWithoutAWayKeepTheirHistoryAndSaySo() async throws {
        // ACP agents share one process and `session/new` has no such field; the headless CLIs
        // (Cursor, Antigravity) have no such flag.
        let acp = YHPProviderCompatibilityAdapter(
            adapter: ACPAdapter(kind: .openCode, executableURL: URL(filePath: "/tmp/opencode")),
            manifest: HarnessProtocolCompatibilityManifest.acp(.openCode))
        let acpKept = await acp.keepNoHistory(for: UUID())
        XCTAssertFalse(acpKept)
        XCTAssertNil(ACPAdapter(kind: .openCode, executableURL: URL(filePath: "/tmp/opencode")) as Any
            as? any HarnessHistoryFreeSessionConfiguring)
        XCTAssertNil(StructuredHeadlessAdapter(kind: .cursorAgent, executableURL: URL(filePath: "/tmp/agent")) as Any
            as? any HarnessHistoryFreeSessionConfiguring)
        XCTAssertNil(MuseAdapter(kind: .museCode, executableURL: URL(filePath: "/tmp/muse")) as Any
            as? any HarnessHistoryFreeSessionConfiguring,
            "Muse's --no-session-log is for the whole shared host process")
    }

    private static var codexResponses: [String: [JSONValue]] {
        let thread = JSONValue.object(["thread": .object(["id": .string("thread-1"),
            "status": .object(["type": .string("idle")]), "turns": .array([])])])
        return ["initialize": [.object(["platformOs": .string("macos")])],
                "thread/start": [thread, thread],
                "turn/start": [.object(["turn": .object(["id": .string("turn-1")])])]]
    }
}
