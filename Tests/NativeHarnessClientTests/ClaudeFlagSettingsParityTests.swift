import Foundation
import XCTest
@testable import NativeHarnessClient

final class ClaudeFlagSettingsParityTests: XCTestCase {
    func testNativeEffortReadbackThroughBothRoutesDoesNotEnableUnsupportedFastMode() async throws {
        for routed in [false, true] {
            let transport = FakeClaudeTransport(initializeResponse: .object([
                "current_model": .string("opus"), "fast_mode_state": .string("off"),
                "fast_mode_disabled_reason": .string("sdk_opt_in_required"),
                "models": .array([.object(["value": .string("opus"), "displayName": .string("Opus"),
                    "supportsEffort": .bool(true), "supportedEffortLevels": .array([.string("low"), .string("high"), .string("max")]),
                    "supportsFastMode": .bool(true)])])
            ]))
            let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
            let adapter: any HarnessAdapter = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude()) : direct
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let provider = try XCTUnwrap(adapter as? any ProviderCapabilityProviding)
            let initial = try await provider.providerCapabilities(for: handle)
            XCTAssertEqual(initial.selectors.first { $0.id == "effort" }?.choices.map(\.value), ["default", "low", "high", "max"])
            XCTAssertNil(initial.selectors.first { $0.id == "fastMode" })
            let applied = try await provider.setProviderOption(id: "effort", value: "high", in: handle)
            XCTAssertEqual(applied.selectors.first { $0.id == "effort" }?.currentValue, "high")
            do { _ = try await provider.setProviderOption(id: "fastMode", value: "on", in: handle); XCTFail() } catch {}
            let requests = await transport.requestedValues
            XCTAssertEqual(requests.first { $0["request"]?["subtype"] == .string("apply_flag_settings") }?["request"]?["settings"],
                .object(["effortLevel": .string("high")]))
            XCTAssertFalse(requests.contains { $0["request"]?["settings"]?["fastMode"] == .bool(true) })
            let inputs = await transport.sentValues; XCTAssertTrue(inputs.isEmpty)
            await adapter.close(handle)
        }
    }

    func testModelReadbackMatchesTheAliasOrTheResumedSessionsFullID() async throws {
        let fable: (String) -> JSONValue = { value in .object(["value": .string(value), "displayName": .string("Fable 5.1"),
            "supportsEffort": .bool(true), "supportedEffortLevels": .array([.string("high"), .string("xhigh")])]) }
        let defaultModel: JSONValue = .object(["value": .string("default"), "displayName": .string("Default (recommended)")])
        // A new session lists the alias; a resumed one lists the session's full model ID.
        for listed in ["fable", "claude-fable-5-1"] {
            let transport = FakeClaudeTransport(initializeResponse: .object(["models": .array([defaultModel, fable(listed)])]))
            await transport.setSettings(effective: ["model": .string("fable"), "effortLevel": .string("xhigh")],
                applied: ["model": .string("claude-fable-5-1")])
            let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
            let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"), initialPrompt: nil))
            let state = try await adapter.providerCapabilities(for: handle)
            XCTAssertEqual(state.selectors.first { $0.id == "model" }?.currentValue, listed)
            XCTAssertEqual(state.selectors.first { $0.id == "effort" }?.currentValue, "xhigh")
            await adapter.close(handle)
        }
    }
}
