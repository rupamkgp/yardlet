import Foundation
import XCTest
@testable import NativeHarnessClient

/// Codex owns installing and enabling its plugins, including the bundled ones a shared `~/.codex`
/// home brings to a Yardlet thread. The capability list only has to show them and say what state
/// the marketplace listing reports.
final class CodexPluginVisibilityTests: XCTestCase {
    private func bundledListing() -> JSONValue {
        .object([
            "marketplaces": .array([
                .object([
                    "name": .string("openai-bundled"),
                    "interface": .object(["displayName": .string("OpenAI Bundled")]),
                    "path": .string("/Users/tester/.codex/plugins/cache/openai-bundled"),
                    "plugins": .array([
                        .object([
                            "id": .string("computer-use@openai-bundled"),
                            "name": .string("computer-use"),
                            "installed": .bool(true),
                            "enabled": .bool(true),
                            "availability": .string("AVAILABLE"),
                            "interface": .object([
                                "displayName": .string("Computer use"),
                                "shortDescription": .string("Screenshots and input for macOS apps.")
                            ])
                        ]),
                        .object([
                            "id": .string("unified-computer-use@openai-bundled"),
                            "name": .string("unified-computer-use"),
                            "installed": .bool(true),
                            "enabled": .bool(true),
                            "availability": .string("AVAILABLE")
                        ]),
                        .object([
                            "id": .string("browser@openai-bundled"),
                            "name": .string("browser"),
                            "installed": .bool(true),
                            "enabled": .bool(false),
                            "availability": .string("AVAILABLE")
                        ]),
                        .object([
                            "id": .string("chrome@openai-bundled"),
                            "name": .string("chrome"),
                            "installed": .bool(false),
                            "enabled": .bool(false),
                            "availability": .string("AVAILABLE")
                        ])
                    ])
                ])
            ])
        ])
    }

    func testBundledMarketplacePluginsReachTheCapabilityListWithTheirMarketplace() {
        let plugins = CodexCapabilityProjector().plugins(from: bundledListing())

        XCTAssertEqual(
            Set(plugins.map(\.id)),
            [
                "computer-use@openai-bundled",
                "unified-computer-use@openai-bundled",
                "browser@openai-bundled",
                "chrome@openai-bundled"
            ]
        )
        let computerUse = plugins.first { $0.id == "computer-use@openai-bundled" }
        XCTAssertEqual(computerUse?.displayName, "Computer use")
        XCTAssertEqual(computerUse?.marketplace, "OpenAI Bundled")
        XCTAssertEqual(computerUse?.description, "Screenshots and input for macOS apps.")
        XCTAssertEqual(
            plugins.last?.id,
            "chrome@openai-bundled",
            "An uninstalled plugin sorts after the installed ones"
        )
        // An unnamed plugin still has to be identifiable in the list.
        XCTAssertEqual(
            plugins.first { $0.id == "unified-computer-use@openai-bundled" }?.displayName,
            "unified-computer-use"
        )
    }

    func testEachPluginRowStatesWhetherItIsInstalledAndEnabled() {
        let plugins = CodexCapabilityProjector().plugins(from: bundledListing())
        let labels = Dictionary(
            uniqueKeysWithValues: plugins.map { ($0.id, $0.statusLabels) }
        )

        XCTAssertEqual(labels["computer-use@openai-bundled"], [.installed])
        XCTAssertEqual(
            labels["browser@openai-bundled"],
            [.installed, .disabled],
            "An installed but disabled plugin must not read as ready to use"
        )
        XCTAssertEqual(labels["chrome@openai-bundled"], [.available])
        for label in [
            CodexPluginStatusLabel.installed, .available, .disabled
        ] {
            XCTAssertEqual(label.text, L10n.string(label.key))
            XCTAssertFalse(L10n.string(label.key, languageCode: "ko").isEmpty)
        }
    }
}
