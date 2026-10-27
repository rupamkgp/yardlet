import Foundation
import XCTest
@testable import NativeHarnessClient

/// Opt-in installed-runtime coverage for the product-default YHP route.
///
/// Unlike the existing live smokes, this test never sends a prompt. It proves that an official
/// process-owned runtime can negotiate, create an empty session, publish the canonical initial
/// lifecycle, and close through Yardlet's protocol boundary without consuming model quota.
final class HarnessProtocolLiveAttachTests: XCTestCase {
    private struct Target {
        let environmentKey: String
        let harness: HarnessKind
        let usesProviderCompatibilitySurface: Bool
    }

    func testConfiguredInstalledRuntimesAttachAndCloseWithoutModelTurn() async throws {
        let environment = ProcessInfo.processInfo.environment
        let targets = [
            Target(
                environmentKey: "NHC_YHP_CLAUDE_ATTACH_BINARY",
                harness: .claudeCode,
                usesProviderCompatibilitySurface: true
            ),
            Target(
                environmentKey: "NHC_YHP_MUSE_ATTACH_BINARY",
                harness: .museCode,
                usesProviderCompatibilitySurface: true
            ),
            Target(
                environmentKey: "NHC_YHP_OPENCODE_ATTACH_BINARY",
                harness: .openCode,
                usesProviderCompatibilitySurface: true
            ),
            Target(
                environmentKey: "NHC_YHP_KIMI_ATTACH_BINARY",
                harness: .kimiCode,
                usesProviderCompatibilitySurface: true
            ),
            Target(
                environmentKey: "NHC_YHP_GROK_ATTACH_BINARY",
                harness: .grokBuild,
                usesProviderCompatibilitySurface: true
            ),
            Target(
                environmentKey: "NHC_YHP_HERMES_ATTACH_BINARY",
                harness: .hermes,
                usesProviderCompatibilitySurface: true
            ),
            Target(
                environmentKey: "NHC_YHP_PI_ATTACH_BINARY",
                harness: .pi,
                usesProviderCompatibilitySurface: true
            ),
            Target(
                environmentKey: "NHC_YHP_CURSOR_ATTACH_BINARY",
                harness: .cursorAgent,
                usesProviderCompatibilitySurface: true
            ),
            Target(
                environmentKey: "NHC_YHP_ANTIGRAVITY_ATTACH_BINARY",
                harness: .antigravityCLI,
                usesProviderCompatibilitySurface: true
            )
        ].compactMap { target -> (Target, URL)? in
            guard let path = environment[target.environmentKey], !path.isEmpty else { return nil }
            return (target, URL(filePath: path))
        }

        guard !targets.isEmpty else {
            throw XCTSkip(
                "Set one or more NHC_YHP_*_ATTACH_BINARY variables for the model-free live attach smoke"
            )
        }

        for (target, executableURL) in targets {
            let workspaceURL = FileManager.default.temporaryDirectory.appending(
                path: "nhc-yhp-attach-\(target.harness.rawValue)-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: workspaceURL,
                withIntermediateDirectories: true
            )

            let registry = HarnessRegistry()
            let adapter = await registry.adapter(
                for: target.harness,
                executableURL: executableURL
            )
            if target.usesProviderCompatibilitySurface {
                XCTAssertTrue(
                    adapter is YHPProviderCompatibilityAdapter,
                    "\(target.harness.rawValue) must use the YHP provider route"
                )
            } else {
                XCTAssertTrue(
                    adapter is YHPCompatibilityAdapter,
                    "\(target.harness.rawValue) must use the YHP compatibility route"
                )
            }

            var handle: HarnessSessionHandle?
            do {
                let runtime = try await adapter.probeRuntime()
                XCTAssertEqual(runtime.harness, target.harness)

                let attached = try await adapter.createSession(
                    CreateHarnessSessionRequest(
                        localSessionID: UUID(),
                        workspaceURL: workspaceURL,
                        initialPrompt: nil
                    )
                )
                handle = attached
                XCTAssertEqual(attached.harness, target.harness)
                XCTAssertFalse(attached.providerSessionID.isEmpty)

                let payloads = try await Self.collectInitialLifecycle(
                    from: await adapter.events(for: attached),
                    harness: target.harness
                )
                XCTAssertTrue(payloads.contains { payload in
                    guard case let .sessionStarted(session) = payload else { return false }
                    return session == attached
                })
                XCTAssertTrue(payloads.contains(.sessionStatusChanged(.ready)))

                await adapter.close(attached)
                handle = nil
                await registry.invalidateAll()
                try FileManager.default.removeItem(at: workspaceURL)
            } catch {
                if let handle { await adapter.close(handle) }
                await registry.invalidateAll()
                try? FileManager.default.removeItem(at: workspaceURL)
                throw error
            }
        }
    }

    private nonisolated static func collectInitialLifecycle(
        from stream: AsyncStream<HarnessEventEnvelope>,
        harness: HarnessKind
    ) async throws -> [HarnessEventPayload] {
        try await withThrowingTaskGroup(of: [HarnessEventPayload].self) { group in
            group.addTask {
                var payloads: [HarnessEventPayload] = []
                for await event in stream {
                    payloads.append(event.payload)
                    if event.payload == .sessionStatusChanged(.ready) { return payloads }
                }
                throw HarnessAdapterError.invalidProviderEvent(
                    "\(harness.displayName) YHP attach stream ended before ready"
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw HarnessAdapterError.invalidProviderEvent(
                    "\(harness.displayName) YHP attach did not become ready within 30 seconds"
                )
            }
            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    }
}
