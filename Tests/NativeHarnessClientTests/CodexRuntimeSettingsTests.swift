import Foundation
import XCTest
@testable import NativeHarnessClient

final class CodexRuntimeSettingsTests: XCTestCase {
    func testProjectorPreservesSafeEffectiveConfigValuesAndLayerCounts() {
        let snapshot = CodexRuntimeSettingsProjector().snapshot(from: .object([
            "config": .object([
                "model": .string("gpt-5.6-codex"),
                "model_provider": .string("openai"),
                "model_reasoning_effort": .string("high"),
                "approval_policy": .object(["granular": .object(["rules": .bool(true)])]),
                "sandbox_mode": .string("workspace-write"),
                "service_tier": .string("fast"),
                "web_search": .string("cached")
            ]),
            "origins": .object(["user": .object(["version": .string("1")])]),
            "layers": .array([.object(["version": .string("1")])])
        ]))

        XCTAssertEqual(snapshot.model, "gpt-5.6-codex")
        XCTAssertEqual(snapshot.modelProvider, "openai")
        XCTAssertEqual(snapshot.reasoningEffort, "high")
        XCTAssertEqual(snapshot.approvalPolicy, L10n.string("Granular"))
        XCTAssertEqual(snapshot.sandboxMode, "workspace-write")
        XCTAssertEqual(snapshot.serviceTier, "fast")
        XCTAssertEqual(snapshot.webSearch, "cached")
        XCTAssertEqual(snapshot.originCount, 1)
        XCTAssertEqual(snapshot.layerCount, 1)
        XCTAssertTrue(snapshot.requirements.isEmpty)
    }

    func testProjectorPreservesSafeConfigRequirementsWithoutPathsOrSecrets() {
        let snapshot = CodexRuntimeSettingsProjector().snapshot(
            from: .object(["config": .object(["model": .string("gpt-5.6-codex")])]),
            requirementsResult: .object([
                "requirements": .object([
                    "allowedApprovalPolicies": .array([
                        .string("on-request"),
                        .object(["granular": .object(["rules": .bool(true)])])
                    ]),
                    "allowedSandboxModes": .array([.string("read-only"), .string("workspace-write")]),
                    "allowedWebSearchModes": .array([.string("cached")]),
                    "allowedPermissionProfiles": .object([
                        "workspace": .bool(true),
                        "safe": .bool(false)
                    ]),
                    "defaultPermissions": .string(":workspace"),
                    "network": .object([
                        "enabled": .bool(true),
                        "managedAllowedDomainsOnly": .bool(true),
                        "domains": .object(["example.com": .string("allow")])
                    ]),
                    "featureRequirements": .object(["browser": .bool(false)])
                ])
            ])
        )

        XCTAssertTrue(snapshot.requirements.hasRequirements)
        XCTAssertEqual(snapshot.requirements.allowedApprovalPolicies, ["on-request", L10n.string("Granular")])
        XCTAssertEqual(snapshot.requirements.allowedSandboxModes, ["read-only", "workspace-write"])
        XCTAssertEqual(snapshot.requirements.allowedWebSearchModes, ["cached"])
        XCTAssertEqual(snapshot.requirements.permissionProfileCount, 2)
        XCTAssertEqual(snapshot.requirements.defaultPermissions, ":workspace")
        XCTAssertEqual(snapshot.requirements.networkEnabled, true)
        XCTAssertEqual(snapshot.requirements.networkManagedAllowedDomainsOnly, true)
        XCTAssertEqual(snapshot.requirements.networkDomainCount, 1)
        XCTAssertEqual(snapshot.requirements.featureRequirementCount, 1)
    }

    func testProjectorDoesNotInventValuesFromUnknownConfigShapes() {
        let snapshot = CodexRuntimeSettingsProjector().snapshot(from: .object([
            "config": .object([
                "model": .integer(5),
                "approval_policy": .array([]),
                "sandbox_mode": .string("read-only")
            ])
        ]))

        XCTAssertNil(snapshot.model)
        XCTAssertNil(snapshot.approvalPolicy)
        XCTAssertEqual(snapshot.sandboxMode, "read-only")
        XCTAssertEqual(snapshot.originCount, 0)
        XCTAssertEqual(snapshot.layerCount, 0)
        XCTAssertTrue(snapshot.requirements.isEmpty)
    }
}
