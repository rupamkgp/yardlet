import Foundation
import XCTest
@testable import NativeHarnessClient

/// The model control shows the model a Claude task was asked to run. A resumed or imported task
/// keeps a full model ID (`claude-opus-5-5`), which Claude Code lists under its alias row (`opus`)
/// and names in that row's `resolvedModel`; the account's settings (`"model": "fable"`) report
/// their own model as effective all the while. Fake CLIs only: no model is asked anything.
final class ClaudeRequestedModelTests: XCTestCase {
    static let levels = ["low", "medium", "high", "xhigh", "max"]

    /// 2.1.295's `initialize` models, each with the full ID its value resolves to. The Default row
    /// resolves to the account's default model, here the same Opus.
    static var initialize: JSONValue {
        func row(_ value: String, _ name: String, _ resolved: String, efforts: [String] = levels) -> JSONValue {
            var model: [String: JSONValue] = ["value": .string(value), "resolvedModel": .string(resolved),
                                              "displayName": .string(name), "description": .string(name)]
            if !efforts.isEmpty {
                model["supportsEffort"] = .bool(true)
                model["supportedEffortLevels"] = .array(efforts.map { .string($0) })
            }
            return .object(model)
        }
        return .object(["current_model": .string("claude-opus-5-5"), "models": .array([
            row("default", "Default (recommended)", "claude-opus-5-5"),
            row("opus", "Opus 5.5", "claude-opus-5-5"),
            row("fable", "Fable 5.1", "claude-fable-5-1", efforts: ["low", "medium", "high", "xhigh"]),
            row("sonnet", "Sonnet 5.5", "claude-sonnet-5-5"),
            row("haiku", "Haiku 4.5", "claude-haiku-4-5-20251001", efforts: [])
        ])])
    }

    /// `get_settings` with `"model": "fable"` in the account's settings, whatever the session runs.
    static let effective: [String: JSONValue] = ["model": .string("fable"), "effortLevel": .string("xhigh")]
    static let applied: [String: JSONValue] = ["model": .string("claude-fable-5-1"), "effort": .string("xhigh")]
    static let stored = ["model": "claude-opus-5-5", "effort": "xhigh", "permissionMode": "bypassPermissions"]

    /// A resumed task restored the way attaching restores it, on both routes: launched on its full
    /// ID, asked nothing more for it, and shown as Opus 5.5 with Opus's effort levels, also after
    /// a turn.
    func testAResumedTasksFullModelIDShowsUnderItsAliasRowOverTheAccountsModel() async throws {
        for routed in [false, true] {
            let transport = FakeClaudeTransport(initializeResponse: Self.initialize,
                                                effectiveSettings: Self.effective, appliedSettings: Self.applied)
            let direct = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
            let adapter: any HarnessAdapter & ProviderCapabilityProviding & HarnessLaunchOptionConfiguring = routed
                ? YHPProviderCompatibilityAdapter(adapter: direct, manifest: HarnessProtocolCompatibilityManifest.claude())
                : direct
            let id = UUID()
            await adapter.setLaunchOptions(Self.stored, for: id)
            let handle = try await adapter.resumeSession(providerSessionID: UUID().uuidString.lowercased(),
                                                         localSessionID: id, workspaceURL: URL(filePath: "/tmp"))
            for key in ["model", "effort", "permissionMode"] {
                _ = try await adapter.setProviderOption(id: key, value: Self.stored[key]!, in: handle)
            }
            let launched = await transport.configuration
            XCTAssertEqual(launched?.model, "claude-opus-5-5", "routed: \(routed)")
            let requests = await transport.requestSubtypes
            XCTAssertFalse(requests.contains("set_model"), "The launch flag already chose the model")

            var state = try await adapter.providerCapabilities(for: handle)
            assertOpus(state, routed: routed)

            // After the first turn the composer reads the selectors again.
            try await adapter.send("Run the tests", to: handle)
            await transport.emit(.object(["type": .string("result"), "subtype": .string("success"),
                                          "is_error": .bool(false), "result": .string("done")]))
            state = try await adapter.providerCapabilities(for: handle)
            assertOpus(state, routed: routed)
            await adapter.close(handle)
        }
    }

    /// A model the list carries under no row of its own is shown by its own name rather than as
    /// the account's model, and the row goes once another model is chosen.
    func testAnUnlistedRequestedModelIsShownByItsOwnName() async throws {
        let transport = FakeClaudeTransport(initializeResponse: Self.initialize,
                                            effectiveSettings: Self.effective, appliedSettings: Self.applied)
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
        let id = UUID()
        await adapter.setLaunchOptions(["model": "claude-opus-4-8"], for: id)
        let handle = try await adapter.resumeSession(providerSessionID: UUID().uuidString.lowercased(),
                                                     localSessionID: id, workspaceURL: URL(filePath: "/tmp"))
        var state = try await adapter.setProviderOption(id: "model", value: "claude-opus-4-8", in: handle)
        var model = try XCTUnwrap(state.selectors.first { $0.id == "model" })
        XCTAssertEqual(model.currentValue, "claude-opus-4-8")
        XCTAssertEqual(model.choices.first, ProviderCapabilityChoice(value: "claude-opus-4-8", name: "Opus 4.8", description: nil))
        XCTAssertEqual(ComposerModelMenu.provider(state.selectors, speed: nil, canChoose: true).model
            .map(ProviderCapabilityAccessibility.selectedChoiceName(for:)), "Opus 4.8")
        state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.selectors.first { $0.id == "model" }?.currentValue, "claude-opus-4-8")

        state = try await adapter.setProviderOption(id: "model", value: "sonnet", in: handle)
        model = try XCTUnwrap(state.selectors.first { $0.id == "model" })
        XCTAssertEqual(model.currentValue, "sonnet")
        XCTAssertEqual(model.choices.map(\.value), ["default", "opus", "fable", "sonnet", "haiku"])
        let requests = await transport.requestedValues
        XCTAssertEqual(requests.filter { $0["request"]?["subtype"] == .string("set_model") }.map { $0["request"]?["model"] },
                       [.string("sonnet")])
        await adapter.close(handle)
    }

    /// A task that chose no model still shows the one the account's settings name.
    func testATaskThatChoseNoModelShowsTheAccountsModel() async throws {
        let transport = FakeClaudeTransport(initializeResponse: Self.initialize,
                                            effectiveSettings: Self.effective, appliedSettings: Self.applied)
        let adapter = ClaudeAdapter(executableURL: URL(filePath: "/tmp/claude"), transportFactory: { _ in transport })
        let handle = try await adapter.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp"),
                                                           initialPrompt: nil))
        let state = try await adapter.providerCapabilities(for: handle)
        XCTAssertEqual(state.selectors.first { $0.id == "model" }?.currentValue, "fable")
        XCTAssertEqual(state.selectors.first { $0.id == "effort" }?.choices.map(\.value), ["default", "low", "medium", "high", "xhigh"])
        await adapter.close(handle)
    }

    /// Before the task connects, the list Claude Code last gave names the same row, with that
    /// model's levels. The Default row is never taken for a full ID: it follows the account.
    func testBeforeConnectingAFullIDShowsUnderItsAliasRow() throws {
        let catalog: [HarnessModelOption] = [
            .init(value: "default", name: "Default (recommended)", effortLevels: Self.levels, resolvedModel: "claude-opus-5-5"),
            .init(value: "opus", name: "Opus 5.5", effortLevels: Self.levels, resolvedModel: "claude-opus-5-5"),
            .init(value: "fable", name: "Fable 5.1", effortLevels: ["low", "high"], resolvedModel: "claude-fable-5-1")
        ]
        let selectors = ClaudeComposerModelProjection.selectors(
            model: "claude-opus-5-5", effort: "xhigh", defaults: HarnessModelDefaults(model: "fable"), catalog: catalog)
        let menu = ComposerModelMenu.provider(selectors, speed: nil, canChoose: true)
        XCTAssertEqual(menu.model?.currentValue, "opus")
        XCTAssertEqual(menu.model?.choices.map(\.value), catalog.map(\.value), "No row is added for it")
        XCTAssertEqual(menu.effort?.choices.map(\.value), ["default"] + Self.levels)
        XCTAssertEqual(menu.title, "Opus 5.5 · " + L10n.string("Extra high"))
        XCTAssertEqual(ClaudeComposerModelProjection.choosing("effort", value: "max", model: "claude-opus-5-5",
                                                              effort: "xhigh", catalog: catalog)?.model,
                       "claude-opus-5-5", "Choosing an effort keeps the task's own model")

        let onlyDefault = [catalog[0], catalog[2]]
        XCTAssertNil(ClaudeComposerModelProjection.option(for: "claude-opus-5-5", in: onlyDefault))
        XCTAssertEqual(ClaudeComposerModelProjection.selectors(model: "claude-opus-5-5", effort: nil, defaults: nil,
                                                               catalog: onlyDefault).first?.currentValue, "claude-opus-5-5")
    }

    /// A list kept before `resolvedModel` was read decodes as it always did, and one kept with it
    /// keeps it.
    func testTheKeptListReadsWithAndWithoutTheResolvedModel() throws {
        let old = #"[{"value":"opus","name":"Opus 5.5","effortLevels":["high"]}]"#
        XCTAssertEqual(try JSONDecoder().decode([HarnessModelOption].self, from: Data(old.utf8)),
                       [HarnessModelOption(value: "opus", name: "Opus 5.5", effortLevels: ["high"])])
        let kept = [HarnessModelOption(value: "opus", name: "Opus 5.5", resolvedModel: "claude-opus-5-5")]
        XCTAssertEqual(try JSONDecoder().decode([HarnessModelOption].self, from: JSONEncoder().encode(kept)), kept)
    }

    /// The task as the user had it: imported with Opus 5.5 at extra high on an account whose
    /// settings name Fable. Its first message runs on Opus, and the composer still says so.
    @MainActor
    func testAnImportedTasksComposerShowsItsModelAfterTheFirstSend() async throws {
        let transports = ModelVisibilityTransportLog(initializeResponse: Self.initialize,
                                                     effectiveSettings: Self.effective, appliedSettings: Self.applied)
        let fixture = try await ClaudeFixture.make(settings: #"{"model":"fable"}"#, transports: transports, in: self)
        let model = fixture.model, session = fixture.session
        for (key, value) in Self.stored {
            try await model.store.updateProviderOption(id: session.id, optionID: key, value: value)
        }
        func menu() throws -> ComposerModelMenu {
            let current = try XCTUnwrap(model.store.sessions.first { $0.id == session.id })
            let state = try XCTUnwrap(model.composerProviderCapabilities(for: current))
            return ComposerModelMenu.provider(ConversationSessionStatusProjection.inlineSelectors(from: state),
                                              speed: nil, canChoose: true)
        }
        XCTAssertEqual(try menu().title, "Opus 5.5 · " + L10n.string("Extra high"))

        let current = try XCTUnwrap(model.store.sessions.first { $0.id == session.id })
        await model.send(HarnessUserInput(text: "Run the tests"), to: current)
        let transport = try XCTUnwrap(transports.all.first)
        let launched = await transport.configuration
        XCTAssertEqual(launched?.model, "claude-opus-5-5")
        await transport.emit(.object(["type": .string("result"), "subtype": .string("success"),
                                      "is_error": .bool(false), "result": .string("done")]))
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline,
              model.store.sessions.first(where: { $0.id == session.id })?.status != .ready
                || model.providerCapabilitiesBySessionID[session.id] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.loadProviderCapabilities(for: try XCTUnwrap(model.store.sessions.first { $0.id == session.id }))
        XCTAssertEqual(try menu().title, "Opus 5.5 · " + L10n.string("Extra high"))
        XCTAssertEqual(model.store.sessions.first { $0.id == session.id }?.providerOptions, Self.stored,
                       "What the task keeps, and so what it runs next time, is unchanged")
        let requests = await transport.requestSubtypes
        XCTAssertFalse(requests.contains("set_model"))
    }

    private func assertOpus(_ state: ProviderCapabilityState, routed: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let model = state.selectors.first { $0.id == "model" }
        XCTAssertEqual(model?.currentValue, "opus", "routed: \(routed)", file: file, line: line)
        XCTAssertEqual(model?.choices.map(\.value), ["default", "opus", "fable", "sonnet", "haiku"], file: file, line: line)
        let effort = state.selectors.first { $0.id == "effort" }
        XCTAssertEqual(effort?.currentValue, "xhigh", file: file, line: line)
        XCTAssertEqual(effort?.choices.map(\.value), ["default"] + Self.levels, "Opus's levels, not Fable's", file: file, line: line)
        XCTAssertEqual(ComposerModelMenu.provider(state.selectors, speed: nil, canChoose: true).title,
                       "Opus 5.5 · " + L10n.string("Extra high"), file: file, line: line)
    }
}
