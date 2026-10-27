import Foundation
import XCTest
@testable import NativeHarnessClient

final class HarnessProtocolSchemaTests: XCTestCase {
    func testCatalogPreservesModelsModesFeaturesAndDeclaredExtensions() throws {
        let manifest = makeManifest(
            extraCapabilities: [.modelCatalog, .modeCatalog],
            extensionNamespaces: ["fixture.testing"]
        )
        let catalog = makeCatalog()

        try HarnessProtocolCatalogValidator.validate(catalog, manifest: manifest)
        let codec = HarnessProtocolPayloadCodec()
        let roundTrip = try codec.decode(
            HarnessProtocolCatalog.self,
            from: codec.encode(catalog)
        )

        XCTAssertEqual(roundTrip, catalog)
        XCTAssertEqual(roundTrip.defaultModelID, "fixture-model")
        XCTAssertEqual(roundTrip.features.first?.value, .string("balanced"))
    }

    func testCatalogRejectsMissingDefaultsAndInvalidFeatureValues() {
        let manifest = makeManifest(extraCapabilities: [.modelCatalog])
        let invalidDefault = HarnessProtocolCatalog(
            models: [],
            modes: [],
            features: [],
            defaultModelID: "missing",
            defaultModeID: nil,
            extensionValues: [:]
        )
        XCTAssertThrowsError(
            try HarnessProtocolCatalogValidator.validate(invalidDefault, manifest: manifest)
        ) { error in
            XCTAssertEqual(
                error as? HarnessProtocolCatalogViolation,
                .missingDefaultModel("missing")
            )
        }

        let invalidFeature = HarnessProtocolCatalog(
            models: [],
            modes: [],
            features: [
                HarnessProtocolFeatureDefinition(
                    id: "thinking",
                    displayName: "Thinking",
                    description: nil,
                    kind: .toggle,
                    value: .string("yes"),
                    options: [],
                    extensionValues: [:]
                )
            ],
            defaultModelID: nil,
            defaultModeID: nil,
            extensionValues: [:]
        )
        XCTAssertThrowsError(
            try HarnessProtocolCatalogValidator.validate(invalidFeature, manifest: manifest)
        ) { error in
            XCTAssertEqual(
                error as? HarnessProtocolCatalogViolation,
                .invalidFeatureValue("thinking")
            )
        }
    }

    func testAllContentBlockKindsHaveStableTypedRoundTrips() throws {
        let blocks: [HarnessProtocolContentBlock] = [
            .text("hello"),
            .inlineData(mimeType: "image/png", base64Data: "aGVsbG8="),
            .file(path: "/tmp/input.txt", mimeType: "text/plain"),
            .remoteURL(URL(string: "https://example.com/image.png")!, mimeType: "image/png")
        ]
        let codec = HarnessProtocolPayloadCodec()

        XCTAssertEqual(
            try codec.decode([HarnessProtocolContentBlock].self, from: codec.encode(blocks)),
            blocks
        )
    }

    func testTypedTurnRequestPassesHostAdmission() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let manifest = makeManifest()
        var connection = HarnessProtocolHostConnection(now: now)
        _ = try connection.accept(.hello(manifest), at: now)
        let params = HarnessProtocolTurnSubmitParams(
            localSessionID: UUID(),
            clientMessageID: "message-1",
            content: [.text("hello")]
        )
        let request = try HarnessProtocolRequest(
            id: "request-1",
            method: .sessionSend,
            typedParams: params
        )

        XCTAssertEqual(
            try connection.accept(.request(version: .v1, request), at: now),
            .acceptedRequest(request)
        )
        XCTAssertEqual(try request.decodeParams(HarnessProtocolTurnSubmitParams.self), params)
    }

    func testMalformedStandardPayloadFailsBeforeDispatch() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let manifest = makeManifest()
        var connection = HarnessProtocolHostConnection(now: now)
        _ = try connection.accept(.hello(manifest), at: now)
        let request = HarnessProtocolRequest(
            id: "request-1",
            method: .sessionSend,
            params: .object(["text": .string("missing identity")])
        )
        let schema = HarnessProtocolRequestSchemaError.invalidPayload(.sessionSend)

        XCTAssertThrowsError(
            try connection.accept(.request(version: .v1, request), at: now)
        ) { error in
            XCTAssertEqual(error as? HarnessProtocolHostError, .invalidRequest(schema))
        }
        XCTAssertEqual(connection.phase, .failed(.invalidRequest(schema)))
    }

    func testSessionConfigRejectsUndeclaredExtensionKeys() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let manifest = makeManifest(extensionNamespaces: ["fixture.testing"])
        var connection = HarnessProtocolHostConnection(now: now)
        _ = try connection.accept(.hello(manifest), at: now)
        let params = HarnessProtocolCreateSessionParams(
            localSessionID: UUID(),
            config: HarnessProtocolSessionConfig(
                workspacePath: "/tmp/yardlet-yhp-schema",
                modelID: nil,
                modeID: nil,
                featureValues: [:],
                extensionValues: ["other.testing.value": .bool(true)]
            ),
            initialPrompt: []
        )
        let request = try HarnessProtocolRequest(
            id: "request-1",
            method: .sessionCreate,
            typedParams: params
        )
        let violation = HarnessProtocolRequestSchemaError.invalidExtension(
            .undeclaredKey("other.testing.value")
        )

        XCTAssertThrowsError(
            try connection.accept(.request(version: .v1, request), at: now)
        ) { error in
            XCTAssertEqual(error as? HarnessProtocolHostError, .invalidRequest(violation))
        }
    }

    func testRichPermissionAndUsageSchemasRoundTrip() throws {
        let sessionID = UUID()
        let permission = HarnessProtocolPermissionRequest(
            id: "permission-1",
            localSessionID: sessionID,
            turnID: "turn-1",
            kind: .question,
            name: "deployment_target",
            title: "Choose a target",
            description: "Select exactly one environment.",
            input: .object(["current": .string("preview")]),
            suggestions: [.object(["current": .string("production")])],
            actions: [
                HarnessProtocolPermissionAction(
                    id: "preview",
                    label: "Preview",
                    behavior: .allow,
                    role: .primary,
                    intent: "select_preview"
                ),
                HarnessProtocolPermissionAction(
                    id: "cancel",
                    label: "Cancel",
                    behavior: .deny,
                    role: .secondary,
                    intent: nil
                )
            ],
            extensionValues: [:]
        )
        let usage = HarnessProtocolUsage(
            inputTokens: 100,
            cachedInputTokens: 80,
            outputTokens: 25,
            reasoningTokens: 10,
            totalCostUSD: 0.02,
            contextWindowTokens: 200_000,
            contextUsedTokens: 215,
            extensionValues: [:]
        )
        let codec = HarnessProtocolPayloadCodec()

        XCTAssertEqual(
            try codec.decode(
                HarnessProtocolPermissionRequest.self,
                from: codec.encode(permission)
            ),
            permission
        )
        XCTAssertEqual(
            try codec.decode(HarnessProtocolUsage.self, from: codec.encode(usage)),
            usage
        )
    }

    private func makeManifest(
        extraCapabilities: [HarnessCapabilityID] = [],
        extensionNamespaces: [String] = []
    ) -> HarnessAdapterManifest {
        HarnessAdapterManifest(
            adapterID: "com.yardlet.fixture",
            harness: HarnessKind(rawValue: "fixture"),
            displayName: "Fixture",
            protocolVersions: [.v1],
            capabilities: Array(HarnessAdapterManifestValidator.requiredCapabilities)
                + extraCapabilities,
            extensionNamespaces: extensionNamespaces
        )
    }

    private func makeCatalog() -> HarnessProtocolCatalog {
        HarnessProtocolCatalog(
            models: [
                HarnessProtocolModelDefinition(
                    id: "fixture-model",
                    displayName: "Fixture Model",
                    description: "Deterministic model",
                    isDefault: true,
                    contextWindowTokens: 200_000,
                    inputCapabilities: [.text, .image],
                    thinkingOptions: [
                        HarnessProtocolSelectOption(
                            id: "balanced",
                            label: "Balanced",
                            description: nil,
                            isDefault: true
                        )
                    ],
                    defaultThinkingOptionID: "balanced",
                    extensionValues: ["fixture.testing.model": .string("native")]
                )
            ],
            modes: [
                HarnessProtocolModeDefinition(
                    id: "default",
                    displayName: "Default",
                    description: nil,
                    isDefault: true,
                    isUnattended: false,
                    extensionValues: [:]
                )
            ],
            features: [
                HarnessProtocolFeatureDefinition(
                    id: "thinking",
                    displayName: "Thinking",
                    description: nil,
                    kind: .select,
                    value: .string("balanced"),
                    options: [
                        HarnessProtocolSelectOption(
                            id: "balanced",
                            label: "Balanced",
                            description: nil,
                            isDefault: true
                        )
                    ],
                    extensionValues: [:]
                )
            ],
            defaultModelID: "fixture-model",
            defaultModeID: "default",
            extensionValues: ["fixture.testing.catalog": .bool(true)]
        )
    }
}
