import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class MultiHarnessLiveTests: XCTestCase {
    func testLiveTwoHarnessSessionsStayIsolated() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let codexPath = environment["NHC_CODEX_LIVE_BINARY"],
              let claudePath = environment["NHC_CLAUDE_LIVE_BINARY"] else {
            throw XCTSkip(
                "Set NHC_CODEX_LIVE_BINARY and NHC_CLAUDE_LIVE_BINARY for the bounded two-harness smoke"
            )
        }
        let claudeURL = URL(filePath: claudePath)
        guard try Self.isClaudeLoggedIn(claudeURL) else {
            throw XCTSkip("The selected official Claude CLI is not logged in")
        }

        let rootURL = FileManager.default.temporaryDirectory
            .appending(
                path: "nhc-two-harness-live-smoke-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let codexWorkspaceURL = rootURL.appending(path: "codex", directoryHint: .isDirectory)
        let claudeWorkspaceURL = rootURL.appending(path: "claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: codexWorkspaceURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: claudeWorkspaceURL,
            withIntermediateDirectories: true
        )
        try Data("NHC_CODEX_ISOLATED".utf8).write(
            to: codexWorkspaceURL.appending(path: "workspace-marker.txt")
        )
        try Data("NHC_CLAUDE_ISOLATED".utf8).write(
            to: claudeWorkspaceURL.appending(path: "workspace-marker.txt")
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults)
        )
        addTeardownBlock { @MainActor in
            await model.shutdown()
        }

        await model.createSession(
            harness: .codex,
            workspaceURL: codexWorkspaceURL,
            runtimeExecutableURL: URL(filePath: codexPath),
            title: "Live Codex isolation"
        )
        await model.createSession(
            harness: .claudeCode,
            workspaceURL: claudeWorkspaceURL,
            runtimeExecutableURL: claudeURL,
            title: "Live Claude isolation"
        )
        let codex = try XCTUnwrap(model.store.sessions.first { $0.harness == .codex })
        let claude = try XCTUnwrap(model.store.sessions.first { $0.harness == .claudeCode })
        XCTAssertNotEqual(codex.providerSessionID, claude.providerSessionID)
        XCTAssertTrue(model.isAttached(codex.id))
        XCTAssertTrue(model.isAttached(claude.id))

        await model.send(
            "Read workspace-marker.txt from the current working directory, then reply with "
                + "exactly its contents and nothing else.",
            to: codex
        )
        await model.send(
            "Read workspace-marker.txt from the current working directory, then reply with "
                + "exactly its contents and nothing else.",
            to: claude
        )
        try await waitUntil(timeout: .seconds(90)) {
            Self.assistantText(in: model.transcriptBySessionID[codex.id] ?? [])
                .contains("NHC_CODEX_ISOLATED")
                && Self.assistantText(in: model.transcriptBySessionID[claude.id] ?? [])
                    .contains("NHC_CLAUDE_ISOLATED")
        }

        let codexText = Self.assistantText(in: model.transcriptBySessionID[codex.id] ?? [])
        let claudeText = Self.assistantText(in: model.transcriptBySessionID[claude.id] ?? [])
        XCTAssertFalse(codexText.contains("NHC_CLAUDE_ISOLATED"))
        XCTAssertFalse(claudeText.contains("NHC_CODEX_ISOLATED"))
    }

    private func waitUntil(
        timeout: Duration,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            guard clock.now < deadline else {
                throw HarnessAdapterError.invalidProviderEvent(
                    "Two-harness live smoke timed out"
                )
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private nonisolated static func assistantText(in entries: [TranscriptEntry]) -> String {
        entries.compactMap { entry -> String? in
            switch entry.content {
            case let .assistant(text, _): text
            default: nil
            }
        }.joined(separator: "\n")
    }

    private nonisolated static func isClaudeLoggedIn(_ binaryURL: URL) throws -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = binaryURL
        process.arguments = ["auth", "status"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return value["loggedIn"] as? Bool == true
    }
}
