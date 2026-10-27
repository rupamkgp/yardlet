import AppKit
import Foundation
@preconcurrency import SwiftTerm
import XCTest
@testable import NativeHarnessClient

/// The one launch Yardlet's two shells share (plan B10): the terminal panel's interactive shell and
/// bash mode's per-task shell start the person's login shell the same way, in the task's folder,
/// with the same terminal variables. The shells here are zsh with a temporary `ZDOTDIR`, so no rc
/// file of the person's runs and nothing typed reaches their `~/.zsh_history`.
@MainActor
final class ShellLaunchEnvironmentTests: XCTestCase {
    // MARK: - The launch

    /// The app's variables, then the terminal variables, then what a runner adds, then the
    /// overrides, each over the one before.
    func testTheEnvironmentLayersTheAppsTheTerminalsTheRunnersAndTheOverrides() {
        let launch = ShellLaunchEnvironment(executable: "/bin/zsh", arguments: ["-l"],
                                            overrides: ["ZDOTDIR": "/tmp/zdot", "GIT_PAGER": "less"])
        let base = ["PATH": "/usr/bin:/bin", "TERM": "dumb", "PAGER": "less", "ZDOTDIR": "/Users/someone",
                    "HISTORY_IGNORE": "app"]
        let environment = launch.environment(base: base, adding: ["HISTORY_IGNORE": "( *)", "TERM": "vt100"])
        XCTAssertEqual(environment, [
            "PATH": "/usr/bin:/bin",
            "TERM": "vt100",
            "COLORTERM": "truecolor",
            "PAGER": "cat",
            "GIT_PAGER": "less",
            "ZDOTDIR": "/tmp/zdot",
            "HISTORY_IGNORE": "( *)"
        ])
        XCTAssertEqual(ShellLaunchEnvironment.terminalVariables,
                       ["TERM": "xterm-256color", "COLORTERM": "truecolor", "PAGER": "cat", "GIT_PAGER": "cat"])
    }

    /// What a runner hands SwiftTerm: the shell, `-l`, the variables as sorted `NAME=value` lines,
    /// the shell's name, and the folder without its trailing slash.
    func testTheStartIsALoginShellInTheFolder() {
        let launch = ShellLaunchEnvironment(executable: "/bin/zsh", arguments: ["-l"], overrides: ["B": "2"])
        let start = launch.start(in: URL(filePath: "/tmp/yardlet/../yardlet-b10/", directoryHint: .isDirectory),
                                 base: ["A": "1"])
        XCTAssertEqual(start.executable, "/bin/zsh")
        XCTAssertEqual(start.arguments, ["-l"])
        XCTAssertEqual(start.processName, "zsh")
        XCTAssertEqual(start.currentDirectory, "/tmp/yardlet-b10")
        XCTAssertEqual(start.environment, ["A=1", "B=2", "COLORTERM=truecolor", "GIT_PAGER=cat", "PAGER=cat",
                                           "TERM=xterm-256color"])
        XCTAssertEqual(ShellLaunchEnvironment(executable: "/opt/homebrew/bin/fish", arguments: ["-l"])
            .start(in: URL(filePath: "/"), base: [:]).processName, "fish")
        XCTAssertEqual(ShellLaunchEnvironment.directoryPath(URL(filePath: "/")), "/")
    }

    /// The person's login shell is the account's, whatever `$SHELL` says, and both shells start it
    /// unless a test gives them another.
    func testBothShellsStartThePersonsLoginShell() async {
        let login = ShellLaunchEnvironment.userLoginShell(environment: ["SHELL": "/no/such/shell"])
        XCTAssertEqual(login.arguments, ["-l"])
        XCTAssertTrue(login.executable.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: login.executable))
        XCTAssertEqual(login, .userLoginShell(), "The user database comes before $SHELL")
        XCTAssertTrue(login.overrides.isEmpty)

        XCTAssertEqual(NativeTerminalSession(workspaceURL: FileManager.default.temporaryDirectory).launch, login,
                       "The terminal panel's shell")
        let model = AppModel(store: SessionStore(repository: InMemorySessionRepository()),
                             runtimeSelections: RuntimeSelectionStore(discoversRuntimes: false),
                             restoresIndexOnLaunch: false)
        XCTAssertEqual(model.shellCommandLaunch, login, "Bash mode's shell")
        await model.shutdown()
    }

    // MARK: - The two shells

    /// Started from one launch, the terminal panel's shell and a bash-mode shell are the same login
    /// shell in the same folder with the same terminal variables. What the test types into either
    /// stays out of the person's `~/.zsh_history`.
    func testTheTerminalAndBashModeShellsRunWithTheSameEnvironment() async throws {
        let folder = try temporaryFolder()
        let launch = ShellLaunchEnvironment.isolatedZsh(in: try temporaryFolder())
        let token = "yardlet-b10-\(UUID().uuidString.prefix(8))"
        let probe = #"printf 'B10<%s|%s|%s|%s|%s>\n' "$TERM" "$COLORTERM" "$PAGER" "$GIT_PAGER" "$ZSH_ARGZERO"; "#
            + #"printf 'B10D<%s>\n' "${PWD:t}"; : "#
            + token
        let expected = ["B10<xterm-256color|truecolor|cat|cat|zsh>", "B10D<\(folder.lastPathComponent)>"]

        let shell = TaskShellProcess(workingDirectory: folder, launch: launch)
        addTeardownBlock { @MainActor in shell.close() }
        let command = shell.command(probe, note: nil)
        var result: ShellCommandResult?
        command.onFinish = { result = $0 }
        command.start()
        try await waitUntil(timeout: .seconds(20)) { result != nil }
        XCTAssertEqual(result?.output.components(separatedBy: "\n"), expected, "Bash mode")

        let session = NativeTerminalSession(workspaceURL: folder, launch: launch)
        let view = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 400),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: 200)
        )
        session.attach(view)
        defer { session.stop() }
        session.send(probe + "\n")
        try await waitUntil(timeout: .seconds(10)) { expected.allSatisfy { session.bufferText.contains($0) } }
        for line in expected { XCTAssertTrue(session.bufferText.contains(line), "Terminal: \(session.bufferText)") }
        session.send("exit\n")
        try await waitUntil { !session.isRunning }

        let history = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".zsh_history")
        if let saved = FileManager.default.contents(atPath: history.path(percentEncoded: false)) {
            XCTAssertNil(saved.range(of: Data(token.utf8)), "A test's command reached ~/.zsh_history")
        }
    }

    // MARK: - Helpers

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "yardlet-launch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Timed out")
    }
}
