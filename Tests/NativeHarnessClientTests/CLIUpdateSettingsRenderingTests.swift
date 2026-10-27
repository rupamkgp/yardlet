import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Settings › CLI Updates drawn offscreen (never shown) in both appearances into `.build/cli-update-qa`:
///
/// - `cli-updates-*.png`: the switch on, and six installs after one check: Codex (Homebrew cask)
///   back on 0.157.1 after 0.163.0 failed Yardlet's check, Claude Code inside the Claude app,
///   OpenCode (npm) updated, Cursor Agent that Yardlet cannot check, Antigravity CLI up to date, and
///   Grok Build waiting for its running task.
/// - `cli-update-notice-*.png`: the main window's notice for Codex.
///
/// Every install is a fixture in a temporary folder and every command goes to a fake runner.
@MainActor
final class CLIUpdateSettingsRenderingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "yardlet-cli-update-render-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheCLIUpdatesSectionDrawsEachInstallAfterACheck() async throws {
        let directory = try WindowlessRender.directory("cli-update-qa")
        let center = try await checkedCenter()

        XCTAssertEqual(center.rows.map(\.harness), [.codex, .claudeCode, .openCode, .cursorAgent, .antigravityCLI, .grokBuild])
        XCTAssertEqual(center.heldVersion(for: .codex)?.version, "0.157.1")
        XCTAssertEqual(center.row(for: .openCode)?.outcome, .updated(from: "1.2.0", to: "1.3.0"))
        XCTAssertEqual(center.row(for: .grokBuild)?.phase, .waitingForTasks)
        XCTAssertEqual(center.row(for: .cursorAgent)?.decision, .skip(.cannotVerify))
        XCTAssertEqual(center.row(for: .antigravityCLI)?.latest, .upToDate)

        let size = NSSize(width: 820, height: 900)
        let captures = try WindowlessRender.hostedInBothAppearances("cli-updates", in: directory, size: size) { appearance in
            settings(center).environment(\.colorScheme, appearance.colorScheme)
        }
        for capture in captures { XCTAssertTrue(WindowlessRender.drawsContent(capture.bitmap, step: 6)) }

        let host = WindowlessRender.Host(settings(center), size: size)
        defer { host.close() }
        host.settle()
        let labels = host.accessibilityElements().map(\.label)
        XCTAssertTrue(labels.contains(L10n.string("CLI automatic updates")), labels.description)
        XCTAssertTrue(labels.contains(L10n.format("Check %@ for updates", "Codex")), labels.description)

        let notice = try XCTUnwrap(center.notice)
        let bars = try WindowlessRender.hostedInBothAppearances("cli-update-notice", in: directory,
                                                                size: NSSize(width: 820, height: 44)) { appearance in
            WorktreeNoticeBar(message: notice.message, systemImage: "arrow.uturn.backward.circle", onDismiss: {})
                .frame(width: 820, height: 44)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, appearance.colorScheme)
        }
        for bar in bars { XCTAssertTrue(WindowlessRender.drawsContent(bar.bitmap, step: 4)) }
    }

    private func settings(_ center: CLIUpdateCenter) -> some View {
        SettingsCenterView(size: CGSize(width: 820, height: 900), initialSection: SettingsSection.cliUpdates.rawValue,
                           notificationCenter: MenuBarQuietNotificationCenter(), cliUpdates: center)
    }

    // MARK: - Fixtures

    private func checkedCenter() async throws -> CLIUpdateCenter {
        try write("opt/homebrew/bin/brew")
        try write("opt/homebrew/bin/npm")
        try write("opt/homebrew/Caskroom/codex/0.157.1/bin/codex", version: "0.157.1")
        let codex = try link("opt/homebrew/bin/codex", to: "../Caskroom/codex/0.157.1/bin/codex")
        let claude = try write("home/Library/Application Support/Claude/claude-code/2.1.293/claude.app/Contents/MacOS/claude",
                               version: "2.1.293")
        try write("opt/homebrew/lib/node_modules/opencode-ai/bin/opencode", version: "1.2.0")
        let opencode = try link("opt/homebrew/bin/opencode", to: "../lib/node_modules/opencode-ai/bin/opencode")
        try write("home/.local/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent", version: "2026.08.11-e8db854")
        let cursor = try link("home/.local/bin/cursor-agent", to: "../share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent")
        let agy = try write("home/.local/bin/agy", version: "1.4.0")
        try write("home/.grok/downloads/grok-1.0.30-macos-aarch64", version: "1.0.30")
        let grok = try link("home/.grok/bin/grok", to: "../downloads/grok-1.0.30-macos-aarch64")

        let base = root!
        let runner = FakeCLIRunner { command in
            let name = command.executable.lastPathComponent
            switch (name, command.arguments) {
            case (_, ["--version"]):
                return Self.ok(Self.version(of: command.executable) ?? "?")
            case ("brew", let arguments) where arguments.first == "outdated":
                return Self.ok(Self.version(of: codex) == "0.157.1"
                    ? #"{"formulae":[],"casks":[{"name":"codex","installed_versions":["0.157.1"],"current_version":"0.163.0"}]}"#
                    : #"{"formulae":[],"casks":[]}"#)
            case ("brew", let arguments) where arguments.first == "upgrade":
                try? Self.writeFile(base.appending(path: "opt/homebrew/Caskroom/codex/0.163.0/bin/codex"), version: "0.163.0")
                try? FileManager.default.removeItem(at: codex)
                try? FileManager.default.createSymbolicLink(atPath: codex.path(percentEncoded: false),
                    withDestinationPath: "../Caskroom/codex/0.163.0/bin/codex")
                try? FileManager.default.removeItem(at: base.appending(path: "opt/homebrew/Caskroom/codex/0.157.1"))
                return Self.ok("")
            case ("npm", let arguments) where arguments.first == "view":
                return Self.ok("\"1.3.0\"")
            case ("npm", let arguments) where arguments.first == "install":
                try? Self.writeFile(base.appending(path: "opt/homebrew/lib/node_modules/opencode-ai/bin/opencode"), version: "1.3.0")
                return Self.ok("")
            case (_, ["update", "--check", "--json"]):
                return Self.ok(#"{"currentVersion":"1.0.30","latestVersion":"1.0.60","updateAvailable":true,"error":null}"#)
            default:
                return Self.ok("")
            }
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("CLIUpdateSettingsRenderingTests")))
        let runtimes: [HarnessKind: URL] = [.codex: codex, .claudeCode: claude, .openCode: opencode,
                                            .cursorAgent: cursor, .antigravityCLI: agy, .grokBuild: grok]
        let center = CLIUpdateCenter(dependencies: .init(
            runtimes: { runtimes },
            busyHarnesses: { [.grokBuild] },
            runner: runner,
            verifier: FakeVerifier(failing: ["0.163.0"], verifiable: [.codex, .claudeCode, .openCode, .antigravityCLI, .grokBuild]),
            overrides: CLIRuntimeOverrides(defaults: defaults),
            defaults: defaults,
            previousVersionsDirectory: root.appending(path: "cli-previous"),
            environment: [:]))
        await center.checkAll()
        return center
    }

    nonisolated private static func ok(_ stdout: String) -> CLICommandResult {
        CLICommandResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    nonisolated private static func version(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8),
              let range = text.range(of: #"(?<=# version )\S+"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    nonisolated private static func writeFile(_ url: URL, version: String?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n# version \(version ?? "none")\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    @discardableResult
    private func write(_ relative: String, version: String? = nil) throws -> URL {
        let url = root.appending(path: relative)
        try Self.writeFile(url, version: version)
        return url
    }

    private func link(_ relative: String, to destination: String) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: url.path(percentEncoded: false), withDestinationPath: destination)
        return url
    }
}
