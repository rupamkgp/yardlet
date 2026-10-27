import Foundation
import XCTest
@testable import NativeHarnessClient

@MainActor
final class RuntimeSelectionStoreTests: XCTestCase {
    func testMuseAcceptsExplicitOfficialExecutableName() {
        XCTAssertTrue(
            RuntimeSelectionStore.isCompatibleRuntime(
                URL(filePath: "/tmp/muse"),
                for: .museCode
            )
        )
    }

    func testConnectedDescriptorsContainOnlyExecutableSelections() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "nhc-connected-runtimes-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let codex = root.appending(path: "codex")
        let claude = root.appending(path: "claude")
        for executable in [codex, claude] {
            XCTAssertTrue(fileManager.createFile(atPath: executable.path, contents: Data()))
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let store = RuntimeSelectionStore(
            defaults: defaults,
            discoversRuntimes: false,
            loadsPersistedSelections: false
        )
        store.select(codex, for: .codex)
        store.select(claude, for: .claudeCode)

        XCTAssertEqual(store.connectedDescriptors.map(\.id), [.codex, .claudeCode])
    }

    func testDeletedSelectedRuntimeCannotRemainAvailable() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "nhc-missing-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appending(path: "pi")
        XCTAssertTrue(fileManager.createFile(atPath: executable.path, contents: Data()))
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        let store = RuntimeSelectionStore(defaults: defaults)
        store.select(executable, for: .pi)
        XCTAssertEqual(store.selectedURL(for: .pi), executable.standardizedFileURL)

        try fileManager.removeItem(at: executable)

        XCTAssertNil(store.selectedURL(for: .pi))
    }

    func testAntigravityRejectsLegacyIDELauncherAndAcceptsOfficialAgyCLI() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appending(path: "nhc-antigravity-runtime-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: root) }

        let legacy = root
            .appending(path: ".antigravity/antigravity/bin", directoryHint: .isDirectory)
            .appending(path: "antigravity")
        let agy = root.appending(path: "agy")
        try fileManager.createDirectory(
            at: legacy.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for executable in [legacy, agy] {
            XCTAssertTrue(fileManager.createFile(atPath: executable.path, contents: Data()))
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }

        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        defaults.set(
            legacy.path,
            forKey: "runtime.antigravity-cli.executablePath"
        )
        let store = RuntimeSelectionStore(
            defaults: defaults,
            discoversRuntimes: false,
            loadsPersistedSelections: true
        )

        XCTAssertNil(store.selectedURL(for: .antigravityCLI))
        XCTAssertNil(defaults.string(forKey: "runtime.antigravity-cli.executablePath"))
        XCTAssertFalse(RuntimeSelectionStore.isCompatibleRuntime(legacy, for: .antigravityCLI))
        XCTAssertTrue(RuntimeSelectionStore.isCompatibleRuntime(agy, for: .antigravityCLI))

        store.select(agy, for: .antigravityCLI)
        XCTAssertEqual(store.selectedURL(for: .antigravityCLI), agy.standardizedFileURL)
        store.select(legacy, for: .antigravityCLI)
        XCTAssertEqual(store.selectedURL(for: .antigravityCLI), agy.standardizedFileURL)
    }

    /// A removed harness's saved runtime choice is forgotten; the other choices stay.
    func testRemovedHarnessRuntimeChoiceIsForgotten() throws {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: testDefaultsSuite("NativeHarnessClientTests"))
        )
        defaults.set("/tmp/gjc", forKey: "runtime.gajae-code.executablePath")
        defaults.set("/usr/bin/true", forKey: "runtime.pi.executablePath")
        let store = RuntimeSelectionStore(
            defaults: defaults,
            discoversRuntimes: false,
            loadsPersistedSelections: true
        )

        XCTAssertNil(defaults.string(forKey: "runtime.gajae-code.executablePath"))
        XCTAssertEqual(defaults.string(forKey: "runtime.pi.executablePath"), "/usr/bin/true")
        XCTAssertEqual(store.selectedURL(for: .pi), URL(filePath: "/usr/bin/true"))
    }

    func testCodexCandidatesPreferUserManagedInstallsBeforeChatGPTBundle() {
        let home = URL(filePath: "/Users/example")
        let candidates = RuntimeSelectionStore.codexCandidates(
            home: home,
            searchPath: "/custom/bin:/other/bin"
        ).map { $0.path(percentEncoded: false) }

        XCTAssertEqual(candidates, [
            "/Users/example/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/custom/bin/codex",
            "/other/bin/codex",
            // ChatGPT moved its bundled runtime in September 2026; the older layout stays last.
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex"
        ])
    }

    func testClaudeDesktopCandidatesPreferNewestExecutableVersion() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appending(path: "nhc-runtime-selection-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: home) }

        for version in ["2.1.99", "2.1.227", "2.1.195"] {
            let executable = home
                .appending(path: "Library", directoryHint: .isDirectory)
                .appending(path: "Application Support", directoryHint: .isDirectory)
                .appending(path: "Claude", directoryHint: .isDirectory)
                .appending(path: "claude-code", directoryHint: .isDirectory)
                .appending(path: version, directoryHint: .isDirectory)
                .appending(path: "claude.app", directoryHint: .isDirectory)
                .appending(path: "Contents", directoryHint: .isDirectory)
                .appending(path: "MacOS", directoryHint: .isDirectory)
                .appending(path: "claude")
            try fileManager.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(
                fileManager.createFile(
                    atPath: executable.path(percentEncoded: false),
                    contents: Data()
                )
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path(percentEncoded: false)
            )
        }

        let candidates = RuntimeSelectionStore.claudeDesktopCandidates(
            home: home,
            fileManager: fileManager
        )

        XCTAssertEqual(
            candidates.map { $0.pathComponents.dropLast(4).last },
            ["2.1.227", "2.1.195", "2.1.99"]
        )
    }
}
