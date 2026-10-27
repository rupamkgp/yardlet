import Foundation
import Darwin
import XCTest
@testable import NativeHarnessClient

/// Opt-in native CLI probes. They create anonymous homes and synthetic histories, deny
/// networking/keychain/account-home access, and never send a model input or restore real files.
final class NativeConversationRewindProbeTests: XCTestCase {
    func testNativeClaudePlannedEmptyEditIdentityInitializesThroughBothRoutesWithoutAResumeOrModelInput() async throws {
        let binary = try binaryPath("NHC_CLAUDE_REWIND_PROBE_BINARY")
        for routed in [false, true] {
            let fixture = try NativeRewindFixture(binary: binary, harness: .claudeCode)
            defer { fixture.cleanup() }
            let direct = ClaudeAdapter(executableURL: fixture.wrapper)
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude()) : direct
            let localID = UUID(), plannedID = UUID().uuidString.lowercased()
            let preparing = try XCTUnwrap(adapter as? any HarnessNewSessionConfiguring)
            try await preparing.setNewSessionID(plannedID, for: localID)
            let handle = try await adapter.resumeSession(providerSessionID: plannedID,
                localSessionID: localID, workspaceURL: fixture.workspace)
            XCTAssertEqual(handle.providerSessionID, plannedID)
            XCTAssertEqual(try Data(contentsOf: fixture.workingFile), fixture.workingBytes)
            await adapter.close(handle)
        }
    }

    func testNativeCodexEditPersistsOrRejectsLegacyHistoryThroughBothRoutesWithoutChangingFiles() async throws {
        let binary = try binaryPath("NHC_CODEX_REWIND_PROBE_BINARY")
        for routed in [false, true] {
            for paginated in [false, true] {
                let fixture = try NativeRewindFixture(binary: binary, harness: .codex)
                defer { fixture.cleanup() }
                let starter = CodexAdapter(executableURL: fixture.wrapper)
                let localID = UUID()
                let original = try await starter.createSession(.init(localSessionID: localID,
                    workspaceURL: fixture.workspace, initialPrompt: nil))
                let path: String
                do {
                    let state = try await starter.presentationState(for: original)
                    path = try XCTUnwrap(state.thread?.raw["path"]?.stringValue)
                } catch { await starter.close(original); throw error }
                await starter.close(original)
                let previousID = UUID().uuidString.lowercased()
                let targetID = UUID().uuidString.lowercased()
                try fixture.writeCodexHistory(path: path, providerID: original.providerSessionID,
                    previousID: previousID, targetID: targetID, paginated: paginated)
                let direct = CodexAdapter(executableURL: fixture.wrapper)
                let adapter: any HarnessAdapter = routed
                    ? YHPCodexCompatibilityAdapter(adapter: direct,
                        manifest: HarnessProtocolCompatibilityManifest.codex()) : direct
                let handle = try await adapter.resumeSession(providerSessionID: original.providerSessionID,
                    localSessionID: localID, workspaceURL: fixture.workspace)
                var expectedIDs = [previousID]
                do {
                    let controller = try XCTUnwrap(adapter as? any CodexConversationEditing)
                    let session = SessionRecord(id: localID, harness: .codex, workspaceURL: fixture.workspace,
                        runtimeExecutableURL: fixture.wrapper, title: "Synthetic native edit",
                        providerSessionID: original.providerSessionID)
                    let edit = ConversationEditState(session: session, targetID: targetID,
                        previousID: previousID, originalText: "Replace this request", draft: .init(), entries: [])
                    let nativeBefore = try await direct.loadTurns(for: handle, cursor: nil, limit: 50)
                    XCTAssertEqual(nativeBefore.turns.map(\.id), [previousID, targetID])
                    XCTAssertTrue(nativeBefore.turns.allSatisfy(\.hasNativeUserMessage))
                    do { try await controller.prepareConversationEdit(edit, in: handle) }
                    catch {
                        guard !paginated, error.localizedDescription == L10n.string(
                            "This Codex runtime cannot edit legacy conversations. Your draft and conversation are preserved.") else { throw error }
                        expectedIDs = [previousID, targetID]
                    }
                    let after = try await direct.loadTurns(for: handle, cursor: nil, limit: 50)
                    XCTAssertEqual(after.turns.map(\.id), expectedIDs)
                    XCTAssertEqual(handle.providerSessionID, original.providerSessionID)
                    XCTAssertEqual(try Data(contentsOf: fixture.workingFile), fixture.workingBytes)
                    // A lost acknowledgement/retry at this retained head must not remove it again.
                    if expectedIDs == [previousID] {
                        try await controller.prepareConversationEdit(edit, in: handle)
                        let retried = try await direct.loadTurns(for: handle, cursor: nil, limit: 50)
                        XCTAssertEqual(retried.turns.map(\.id), [previousID])
                    }
                } catch { await adapter.close(handle); throw error }
                await adapter.close(handle)

                let restarted = CodexAdapter(executableURL: fixture.wrapper)
                let restored = try await restarted.resumeSession(providerSessionID: original.providerSessionID,
                    localSessionID: localID, workspaceURL: fixture.workspace)
                do {
                    let persisted = try await restarted.loadTurns(for: restored, cursor: nil, limit: 50)
                    XCTAssertEqual(persisted.turns.map(\.id), expectedIDs)
                    XCTAssertEqual(try Data(contentsOf: fixture.workingFile), fixture.workingBytes)
                } catch { await restarted.close(restored); throw error }
                await restarted.close(restored)
            }
        }
    }

    func testNativeClaudeMissingCheckpointStaysUnavailableThroughBothRoutes() async throws {
        let binary = try binaryPath("NHC_CLAUDE_REWIND_PROBE_BINARY")
        for routed in [false, true] {
            let fixture = try NativeRewindFixture(binary: binary, harness: .claudeCode)
            defer { fixture.cleanup() }
            let direct = ClaudeAdapter(executableURL: fixture.wrapper)
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct,
                    manifest: HarnessProtocolCompatibilityManifest.claude()) : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(),
                workspaceURL: fixture.workspace, initialPrompt: nil))
            do {
                let controller = try XCTUnwrap(adapter as? any HarnessFileRewinding)
                let userID = UUID().uuidString.lowercased()
                let preview = try await controller.previewFileRewind(userMessageID: userID, in: handle)
                XCTAssertFalse(preview.canRewind)
                XCTAssertNotNil(preview.error)
                do {
                    _ = try await controller.restoreFiles(userMessageID: userID, expecting: preview, in: handle)
                    XCTFail("An absent native checkpoint cannot be restored")
                } catch {}
                XCTAssertEqual(try Data(contentsOf: fixture.workingFile), fixture.workingBytes)
                XCTAssertEqual(handle.harness, .claudeCode)
            } catch { await adapter.close(handle); throw error }
            await adapter.close(handle)
        }
    }

    private func binaryPath(_ variable: String) throws -> String {
        guard let binary = ProcessInfo.processInfo.environment[variable] else {
            throw XCTSkip("Set \(variable) for the anonymous, network-denied native CLI probe")
        }
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw HarnessAdapterError.runtimeNotFound(URL(filePath: binary))
        }
        return binary
    }
}

private struct NativeRewindFixture {
    let root: URL
    let workspace: URL
    let wrapper: URL
    let workingFile: URL
    let workingBytes = Data("Keep unrelated current file changes.\n".utf8)

    init(binary: String, harness: HarnessKind) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "Yardlet.NativeRewind.\(UUID())")
            .resolvingSymlinksInPath()
        workspace = root.appending(path: "workspace")
        wrapper = root.appending(path: "runtime.sh")
        workingFile = workspace.appending(path: "keep.txt")
        for name in ["workspace", "home", "codex", "claude", "xdg"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        try workingBytes.write(to: workingFile)
        try Data("""
        model = "probe-model"
        model_provider = "probe"
        [model_providers.probe]
        name = "Offline probe"
        base_url = "http://127.0.0.1:1/v1"
        wire_api = "responses"
        requires_openai_auth = false
        [analytics]
        enabled = false

        """.utf8).write(to: root.appending(path: "codex/config.toml"))
        let realHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let profile = "(version 1)(allow default)(deny network*)(deny mach-lookup (global-name \"com.apple.securityd\"))"
            + "(deny file-read* file-write* (subpath \"\(realHome)/.codex\") (subpath \"\(realHome)/.claude\")"
            + " (literal \"\(realHome)/.claude.json\") (subpath \"\(realHome)/.yardlet\"))"
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=\(root.appending(path: "home").path)",
            "CODEX_HOME=\(root.appending(path: "codex").path)", "CLAUDE_CONFIG_DIR=\(root.appending(path: "claude").path)",
            "XDG_CONFIG_HOME=\(root.appending(path: "xdg").path)", "TMPDIR=\(root.path)", "LANG=en_US.UTF-8",
            "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING=true", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1",
            "DISABLE_TELEMETRY=1", "DISABLE_AUTOUPDATER=1", "ANTHROPIC_BASE_URL=http://127.0.0.1:1"]
        let extra = harness == .claudeCode ? " --strict-mcp-config --mcp-config '{\"mcpServers\":{}}'" : ""
        let command = "#!/bin/sh\ncd " + Self.quote(workspace.path) + " || exit 1\nexec /usr/bin/env -i "
            + environment.map(Self.quote).joined(separator: " ")
            + " /usr/bin/sandbox-exec -p " + Self.quote(profile) + " " + Self.quote(binary) + " \"$@\"" + extra + "\n"
        try Data(command.utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    }

    func writeCodexHistory(path: String, providerID: String, previousID: String,
        targetID: String, paginated: Bool) throws {
        // Foundation normalizes /private/var to /var, while the native CLI reports realpath.
        // Compare the CLI's raw absolute path to the existing anonymous home's POSIX path.
        guard let canonical = realpath(root.appending(path: "codex").path, nil) else {
            throw HarnessAdapterError.invalidProviderEvent("Cannot resolve the anonymous probe home")
        }
        defer { free(canonical) }
        let home = String(cString: canonical)
        let destination = URL(filePath: path)
        guard path.hasPrefix(home + "/"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw HarnessAdapterError.invalidProviderEvent("Probe rollout escaped the anonymous home: \(path)")
        }
        var rows: [[String: Any]] = [["timestamp": "2026-10-04T00:00:00.000Z", "ordinal": 0,
            "type": "session_meta", "payload": ["id": providerID, "timestamp": "2026-10-04T00:00:00.000Z",
                "cwd": workspace.path, "originator": "yardlet-native-rewind-probe", "cli_version": "0.160.0",
                "source": "vscode", "model_provider": "probe", "history_mode": paginated ? "paginated" : "legacy"]]]
        for (index, id) in [previousID, targetID].enumerated() {
            let request = index == 0 ? "Keep this request" : "Replace this request"
            let answer = index == 0 ? "Keep this answer" : "Replace this answer"
            for payload: [String: Any] in [["type": "task_started", "turn_id": id],
                ["type": "user_message", "message": request, "images": [], "local_images": [], "text_elements": []],
                ["type": "agent_message", "message": answer],
                ["type": "task_complete", "turn_id": id, "last_agent_message": answer]] {
                rows.append(["timestamp": "2026-10-04T00:00:00.000Z", "ordinal": rows.count,
                    "type": "event_msg", "payload": payload])
                if paginated, payload["type"] as? String == "user_message" {
                    // Paginated full-item pages use the native item lifecycle, while legacy
                    // narrative events alone populate only the summary projection.
                    rows.append(["timestamp": "2026-10-04T00:00:00.000Z", "ordinal": rows.count,
                        "type": "event_msg", "payload": ["type": "item_completed",
                            "thread_id": providerID, "turn_id": id,
                            "item": ["type": "UserMessage", "id": "user-\(id)",
                                "content": [["type": "text", "text": request, "text_elements": []]]]]])
                }
            }
        }
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
}
