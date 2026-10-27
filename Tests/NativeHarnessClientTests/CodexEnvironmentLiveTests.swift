import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class CodexEnvironmentLiveTests: XCTestCase {
    func testLiveYardletModelCreatesNativeCodexTask() async throws {
        guard let binaryPath = ProcessInfo.processInfo.environment[
            "NHC_CODEX_NATIVE_LIVE_BINARY"
        ] else {
            throw XCTSkip(
                "Set NHC_CODEX_NATIVE_LIVE_BINARY for the native-home Yardlet Codex smoke"
            )
        }

        let root = FileManager.default.temporaryDirectory.appending(
            path: "yardlet-codex-native-live-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        let yardletRoot = root.appending(path: ".yardlet", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A temporary original home proves the product route without reading account credentials
        // or creating a thread in the user's real Codex history. No model turn is sent.
        let nativeHome = root.appending(path: "native-codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nativeHome, withIntermediateDirectories: true)
        let paths = CodexEnvironmentPaths(
            nativeHomeURL: nativeHome,
            yardletRootURL: yardletRoot
        )
        let environmentManager = CodexEnvironmentManager(paths: paths)
        let suiteName = testDefaultsSuite("Yardlet.CodexEnvironmentLiveTests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let model = AppModel(
            store: SessionStore(repository: InMemorySessionRepository()),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults),
            codexEnvironmentManager: environmentManager,
            restoresIndexOnLaunch: false
        )

        let session = await model.createSession(
            harness: .codex,
            workspaceURL: workspace,
            runtimeExecutableURL: URL(filePath: binaryPath),
            title: "Native Codex live smoke"
        )
        let bootstrapError = model.bootstrapError
        let taskError = model.errorBySessionID.values.first
        await model.shutdown()

        let created = try XCTUnwrap(
            session,
            taskError ?? bootstrapError ?? "Codex task was not created"
        )
        XCTAssertEqual(created.harness, .codex)
        XCTAssertEqual(created.environmentScope, .native)
        XCTAssertEqual(created.status, .ready)
        XCTAssertFalse(try XCTUnwrap(created.providerSessionID).isEmpty)
        let snapshot = await environmentManager.currentSnapshot()
        XCTAssertNil(snapshot)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.runtimeHomeURL.path()
            ),
            "New native tasks must not materialize an isolated home"
        )
    }

    func testLiveIsolatedCodexTurnStreamsThroughYardletAdapter() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binaryPath = environment["NHC_CODEX_ISOLATED_LIVE_BINARY"],
              let authenticatedHome = environment[
                "NHC_CODEX_AUTHENTICATED_YARDLET_HOME"
              ] else {
            throw XCTSkip(
                "Set NHC_CODEX_ISOLATED_LIVE_BINARY and an authenticated "
                    + "NHC_CODEX_AUTHENTICATED_YARDLET_HOME"
            )
        }

        let root = FileManager.default.temporaryDirectory.appending(
            path: "yardlet-codex-isolated-turn-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
        let yardletRoot = URL(filePath: authenticatedHome).standardizedFileURL
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeHome = environment["YARDLET_NATIVE_CODEX_HOME"]
            .map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".codex", directoryHint: .isDirectory)
        let manager = CodexEnvironmentManager(paths: CodexEnvironmentPaths(
            nativeHomeURL: nativeHome,
            yardletRootURL: yardletRoot
        ))
        let adapter = CodexAdapter(
            executableURL: URL(filePath: binaryPath),
            environmentManager: manager,
            environmentScope: .yardlet
        )
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(),
            workspaceURL: workspace,
            initialPrompt: nil
        ))

        do {
            try await adapter.send(
                "Reply with exactly YARDLET_CODEX_OK. Do not use tools.",
                to: handle
            )
            let payloads = try await Self.collectTurn(from: await adapter.events(for: handle))
            let rendered = payloads.compactMap { payload -> String? in
                switch payload {
                case let .assistantDelta(text), let .assistantMessageCompleted(text): text
                default: nil
                }
            }.joined()
            XCTAssertTrue(
                rendered.contains("YARDLET_CODEX_OK"),
                "Rendered: \(rendered); payloads: \(payloads)"
            )
        } catch {
            await adapter.close(handle)
            throw error
        }
        await adapter.close(handle)
    }

    private nonisolated static func collectTurn(
        from stream: AsyncStream<HarnessEventEnvelope>
    ) async throws -> [HarnessEventPayload] {
        try await withThrowingTaskGroup(of: [HarnessEventPayload].self) { group in
            group.addTask {
                var payloads: [HarnessEventPayload] = []
                for await event in stream {
                    payloads.append(event.payload)
                    if event.payload == .turnCompleted { return payloads }
                }
                throw HarnessAdapterError.invalidProviderEvent(
                    "Codex event stream ended before turn completion"
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(90))
                throw HarnessAdapterError.invalidProviderEvent(
                    "Isolated Codex live turn timed out"
                )
            }
            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    }
}
