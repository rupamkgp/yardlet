import XCTest
@testable import NativeHarnessClient

final class CodexModelSelectionTests: XCTestCase {
    func testModelChangeRetainsOnlySupportedEffortAndRoundTripsAtomically() throws {
        let option = CodexModelOption(id: "fast-id", model: "fast", displayName: "Fast",
            defaultReasoningEffort: "low", supportedReasoningEfforts: ["low", "high"], isDefault: false)
        var catalog = CodexModelCatalog(models: [option], selection: .init(model: "large", reasoningEffort: "ultra"))
        XCTAssertEqual(catalog.selecting(option).reasoningEffort, "low")
        catalog.selection = .init(model: "large", reasoningEffort: "high")
        let selection = catalog.selecting(option)
        XCTAssertEqual(selection.reasoningEffort, "high")
        XCTAssertEqual(CodexModelSelection.restored(from: [CodexModelSelection.storageKey: try XCTUnwrap(selection.storedValue)]), selection)
        XCTAssertNil(CodexModelSelection.restored(from: [CodexModelSelection.storageKey: "broken"]))
    }

    func testProductCatalogPaginationSelectionForkAndResumeStayTaskScoped() async throws {
        let transport = FakeCodexTransport(responses: [
            "initialize": [.object(["platformOs": .string("macos")])],
            "thread/start": [thread("main", model: "large", effort: "high")],
            "model/list": [
                .object(["data": .array([model("large", efforts: ["high", "ultra"]), model("hidden", hidden: true)]), "nextCursor": .string("page-two")]),
                .object(["data": .array([model("fast", efforts: ["low", "high"])])])
            ],
            "thread/fork": [thread("child", model: "large", effort: "high")],
            "thread/resume": [thread("restored", model: "fast", effort: "low")],
            "turn/start": [.object(["turn": .object(["id": .string("main-turn")])]), .object(["turn": .object(["id": .string("child-turn")])])]
        ])
        let routed = YHPCodexCompatibilityAdapter(
            adapter: CodexAdapter(executableURL: URL(filePath: "/tmp/fake-codex"), transport: transport),
            manifest: HarnessProtocolCompatibilityManifest.codex()
        )
        let main = try await routed.createSession(.init(localSessionID: UUID(), workspaceURL: URL(filePath: "/tmp/models"), initialPrompt: nil))
        let initial = try await routed.modelCatalog(for: main)
        XCTAssertEqual(initial.models.map(\.model), ["large", "fast"])
        XCTAssertEqual(initial.selection, .init(model: "large", reasoningEffort: "high"))
        _ = try await routed.selectModel(.init(model: "fast", reasoningEffort: "low"), for: main)
        let child = try await routed.fork(main, newLocalSessionID: UUID())
        let inherited = try await routed.modelCatalog(for: child)
        XCTAssertEqual(inherited.selection, .init(model: "fast", reasoningEffort: "low"))
        _ = try await routed.selectModel(.init(model: "large", reasoningEffort: "ultra"), for: child)
        do {
            _ = try await routed.selectModel(.init(model: "fast", reasoningEffort: "ultra"), for: main)
            XCTFail("Unsupported effort must fail before a turn is sent")
        } catch {}
        do {
            _ = try await routed.selectModel(.init(model: "hidden", reasoningEffort: nil), for: main)
            XCTFail("Hidden model must not become a selectable choice")
        } catch {}
        try await routed.send("main", to: main)
        try await routed.send("child", to: child)
        let requests = await transport.requests
        let turns = requests.filter { $0.method == "turn/start" }
        XCTAssertEqual(turns.map { $0.params["model"]?.stringValue }, ["fast", "large"])
        XCTAssertEqual(turns.map { $0.params["effort"]?.stringValue }, ["low", "ultra"])
        XCTAssertTrue(turns.allSatisfy { $0.params["collaborationMode"] == nil })
        let pages = requests.filter { $0.method == "model/list" }
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.last?.params["cursor"]?.stringValue, "page-two")
        XCTAssertEqual(pages.first?.params["includeHidden"], .bool(false))
        let restored = try await routed.resumeSession(providerSessionID: "restored", localSessionID: UUID(), workspaceURL: main.workspaceURL)
        let resumed = try await routed.modelCatalog(for: restored)
        XCTAssertEqual(resumed.selection, .init(model: "fast", reasoningEffort: "low"))
        await routed.close(main)
        await routed.close(child)
        await routed.close(restored)
    }

    private func model(_ id: String, efforts: [String] = ["low"], hidden: Bool = false) -> JSONValue {
        .object(["id": .string(id), "model": .string(id), "displayName": .string(id.capitalized),
                 "hidden": .bool(hidden), "defaultReasoningEffort": .string(efforts[0]),
                 "supportedReasoningEfforts": .array(efforts.map { .object(["reasoningEffort": .string($0)]) })])
    }

    private func thread(_ id: String, model: String, effort: String) -> JSONValue {
        .object(["thread": .object(["id": .string(id), "turns": .array([])]), "model": .string(model), "reasoningEffort": .string(effort)])
    }
}
