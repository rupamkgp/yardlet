import XCTest
@testable import NativeHarnessClient

final class CommonComposerMenuTests: XCTestCase {
    func testPermissionAndSessionModesRetainSeparateRolesAndOriginalValues() {
        let mode = selector("mode", category: "mode", values: ["provider-build", "provider-plan"])
        let permission = selector("permissionMode", category: "mode", values: ["manual", "acceptEdits", "dontAsk"])
        let chrome = selector("chromeIntegration", category: "mode", values: ["off", "on"])
        let state = ProviderCapabilityState(selectors: [chrome, permission, mode])
        let projected = ConversationSessionStatusProjection.inlineSelectors(from: state)
        XCTAssertEqual(projected.map(\.id), ["mode", "permissionMode"])
        XCTAssertEqual(projected[0].choices.map(\.value), ["provider-build", "provider-plan"])
        XCTAssertEqual(projected[1].choices.map(\.value), ["manual", "acceptEdits", "dontAsk"])
        XCTAssertEqual(projected[0].currentValue, "provider-build")
        XCTAssertEqual(ConversationSessionStatusProjection.role(for: mode), .mode)
        XCTAssertEqual(ConversationSessionStatusProjection.role(for: permission), .permission)
        XCTAssertNil(ConversationSessionStatusProjection.role(for: chrome), "Launch flags must not become work modes")
    }

    func testCommonModelMenuUsesCodexModelValuesNotDisplayOrCatalogIDs() {
        let catalog = models()
        let model = CodexModelMenuProjection.model(catalog)
        XCTAssertEqual(model.choices.map(\.value), ["model/large", "model/small"])
        XCTAssertEqual(model.choices.map(\.name), ["Large UI name", "Small UI name"])
        XCTAssertEqual(CodexModelMenuProjection.selection(id: model.id, value: "model/small", catalog: catalog),
            .init(model: "model/small", reasoningEffort: "low"))
        XCTAssertNil(CodexModelMenuProjection.selection(id: model.id, value: "Small UI name", catalog: catalog))
        XCTAssertNil(CodexModelMenuProjection.selection(id: model.id, value: "small-catalog-id", catalog: catalog))
    }

    func testCommonEffortMenuCannotSwitchTheModelOrOfferUnsupportedEffort() throws {
        let catalog = models()
        let selector = try XCTUnwrap(CodexModelMenuProjection.reasoning(catalog))
        XCTAssertEqual(selector.choices.map(\.value), ["high", "ultra"])
        XCTAssertEqual(CodexModelMenuProjection.selection(id: selector.id, value: "ultra", catalog: catalog),
            .init(model: "model/large", reasoningEffort: "ultra"))
        XCTAssertNil(CodexModelMenuProjection.selection(id: selector.id, value: "low", catalog: catalog))
        XCTAssertNil(CodexModelMenuProjection.selection(id: "permissionMode", value: "ultra", catalog: catalog))
    }

    private func models() -> CodexModelCatalog {
        .init(models: [
            .init(id: "large-catalog-id", model: "model/large", displayName: "Large UI name", defaultReasoningEffort: "high",
                  supportedReasoningEfforts: ["high", "ultra"], isDefault: true),
            .init(id: "small-catalog-id", model: "model/small", displayName: "Small UI name", defaultReasoningEffort: "low",
                  supportedReasoningEfforts: ["low"], isDefault: false)
        ], selection: .init(model: "model/large", reasoningEffort: "ultra"))
    }

    private func selector(_ id: String, category: String, values: [String]) -> ProviderCapabilitySelector {
        .init(id: id, name: id, description: nil, category: category, currentValue: values[0],
            choices: values.map { .init(value: $0, name: "Native " + $0, description: nil) })
    }
}
