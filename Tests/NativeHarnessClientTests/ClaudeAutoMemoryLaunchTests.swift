import Foundation
import XCTest
@testable import NativeHarnessClient

/// Claude Code's auto memory is the CLI's own: the memory section of its system prompt, the agent's
/// own writes, and the post-turn pass gated by its remote flags. The Claude app (3.1623.3) starts a
/// local Code session with no memory variable, no memory setting and no memory text of its own
/// (2026-10-23 bundle and CLI 2.1.291/2.1.299/2.1.304 reads), so Yardlet starts Claude Code the same
/// way: it neither turns any of it off nor adds any of its own, and a switch the person set reaches
/// the CLI unchanged.
final class ClaudeAutoMemoryLaunchTests: XCTestCase {
    /// The variables the CLI reads for memory: its off switches, the hosted post-turn pass, a
    /// redirected memory folder, and the Cowork memory the Claude app gives only its VM sessions.
    static let memoryVariables = [
        "CLAUDE_CODE_DISABLE_AUTO_MEMORY", "CLAUDE_CODE_SIMPLE",
        "CLAUDE_CODE_POST_TURN_MEMORY", "CLAUDE_CODE_POST_TURN_MEMORY_CONFIG", "CLAUDE_CODE_POST_TURN_MEMORY_SYNC",
        "CLAUDE_CODE_REMOTE_MEMORY_DIR", "CLAUDE_MEMORY_STORES",
        "CLAUDE_COWORK_MEMORY_PATH_OVERRIDE", "CLAUDE_COWORK_MEMORY_GUIDELINES",
        "CLAUDE_COWORK_MEMORY_EXTRA_GUIDELINES", "CLAUDE_COWORK_MEMORY_INDEX_CONTENT"
    ]

    func testYardletAddsNoMemoryVariableOfItsOwn() {
        for claudeAIConnectors in [false, true] {
            let environment = ClaudeProcessTransport.environment(
                base: [:], overrides: ["CLAUDE_CONFIG_DIR": "/tmp/claude-account"],
                claudeAIConnectors: claudeAIConnectors
            )
            for name in Self.memoryVariables {
                XCTAssertNil(environment[name], "\(name) is the CLI's to read, not Yardlet's to set")
            }
            XCTAssertEqual(environment["CLAUDE_CODE_ENTRYPOINT"], "native-harness-client")
        }
    }

    /// `CLAUDE_CODE_DISABLE_AUTO_MEMORY` is the person's own documented off switch, from the
    /// environment Yardlet started with or from an account's variables.
    func testThePersonsOwnMemorySwitchReachesTheCLIUnchanged() {
        let fromShell = ClaudeProcessTransport.environment(
            base: ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"], overrides: [:]
        )
        XCTAssertEqual(fromShell["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "1")
        let fromAccount = ClaudeProcessTransport.environment(
            base: [:], overrides: ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "0"]
        )
        XCTAssertEqual(fromAccount["CLAUDE_CODE_DISABLE_AUTO_MEMORY"], "0")
    }

    /// A task started through the adapter's own process path, with Yardlet's connectors standing
    /// in for a server and Yardlet 지침 set, runs a stand-in CLI that records what it was given.
    func testAStartedTaskGivesTheCLINothingAboutMemory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-claude-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let record = root.appending(path: "launch.txt")
        let executable = try Self.standIn(recordingTo: record, in: root)
        let configDirectory = root.appending(path: "config", directoryHint: .isDirectory)
        let privateDirectory = root.appending(path: "private", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)

        let adapter = ClaudeAdapter(
            executableURL: executable,
            environmentOverrides: ["CLAUDE_CONFIG_DIR": configDirectory.path(percentEncoded: false)],
            asksForNextMessageSuggestions: { false }
        )
        let localID = UUID()
        await adapter.setAgentToolServer(AgentToolServerLaunch(
            command: "/usr/bin/true", environment: [:], privateDirectory: privateDirectory,
            leftOutServerURLs: [try XCTUnwrap(URL(string: "https://mcp.linear.app/mcp"))]
        ), for: localID)
        let instructions = "Answer in Korean."
        await adapter.setYardletInstructions(YardletInstructionsDelivery(text: instructions), for: localID)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: localID, workspaceURL: root, initialPrompt: nil
        ))
        let lines = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        await adapter.close(handle)

        let arguments = lines.filter { $0.hasPrefix("ARG\t") }.map { String($0.dropFirst(4)) }
        var environment: [String: String] = [:]
        for line in lines where line.hasPrefix("ENV\t") {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            environment[String(fields[1])] = fields.count > 2 ? String(fields[2]) : ""
        }

        // Headless like the Claude app's own Code sessions, in the CLI's full mode.
        XCTAssertTrue(arguments.contains("--print"))
        XCTAssertEqual(arguments.firstIndex(of: "--input-format").map { arguments[$0 + 1] }, "stream-json")
        XCTAssertFalse(arguments.contains("--bare"))
        XCTAssertFalse(arguments.contains("--safe-mode"))
        XCTAssertFalse(
            arguments.contains { $0.lowercased().contains("memory") },
            "No launch argument concerns memory"
        )
        // The process's settings document carries only the stood-in servers.
        let settingsText = try XCTUnwrap(arguments.firstIndex(of: "--settings").map { arguments[$0 + 1] })
        let settings = try JSONSerialization.jsonObject(with: Data(settingsText.utf8)) as? [String: Any]
        XCTAssertEqual(settings.map { Set($0.keys) }, ["deniedMcpServers"])
        XCTAssertEqual(arguments.filter { $0.hasPrefix("--append-system-prompt") },
                       ["--append-system-prompt=\(instructions)"])

        XCTAssertEqual(environment["CLAUDE_CODE_ENTRYPOINT"], "native-harness-client")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], configDirectory.path(percentEncoded: false))
        let inherited = ProcessInfo.processInfo.environment
        for name in Self.memoryVariables {
            XCTAssertEqual(environment[name], inherited[name], "\(name) passes through as Yardlet received it")
        }
    }

    /// A stand-in CLI that writes its arguments and the variables it was given that concern memory
    /// (never the whole environment, which carries credentials), then answers each control request
    /// with an empty success until its input closes.
    private static func standIn(recordingTo record: URL, in folder: URL) throws -> URL {
        let names = (["CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CONFIG_DIR"] + memoryVariables).joined(separator: " ")
        let path = record.path(percentEncoded: false)
        let script = """
        #!/bin/sh
        record='\(path)'
        for argument in "$@"; do printf 'ARG\\t%s\\n' "$argument"; done > "$record.part"
        for name in \(names); do
          eval "present=\\${$name+set}"
          if [ "$present" = set ]; then eval "value=\\$$name"; printf 'ENV\\t%s\\t%s\\n' "$name" "$value"; fi
        done >> "$record.part"
        mv "$record.part" "$record"
        while IFS= read -r line; do
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"request_id" *: *"\\([^"]*\\)".*/\\1/p')
          if [ -n "$id" ]; then
            printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{}}}\\n' "$id"
          fi
        done
        """
        let executable = folder.appending(path: "claude")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path(percentEncoded: false))
        return executable
    }
}
