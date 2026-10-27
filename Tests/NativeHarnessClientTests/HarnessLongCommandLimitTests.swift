import Foundation
import XCTest
@testable import NativeHarnessClient

/// Long and background command limits each harness's process starts with. Yardlet raises a
/// limit only through the harness's own documented per-process setting, only in the process it
/// starts, and never in a settings file.
final class HarnessLongCommandLimitTests: XCTestCase {
    /// Claude Code stops a background Bash command at `min(timeout ?? 30 min, ceiling)` when it runs
    /// headless under Yardlet's entrypoint; `BASH_MAX_TIMEOUT_MS` moves the ceiling to the CLI's own
    /// limit, so the model can let a command run as long as it needs.
    func testClaudeStartsWithTheBackgroundCommandCeilingLifted() {
        let environment = ClaudeProcessTransport.environment(
            base: ["HOME": "/Users/test", "PATH": "/usr/bin", "CLAUDECODE": "1"],
            overrides: ["CLAUDE_CONFIG_DIR": "/Users/test/claude-account"]
        )
        XCTAssertEqual(environment["BASH_MAX_TIMEOUT_MS"], "2147483647")
        XCTAssertEqual(environment["BASH_MAX_TIMEOUT_MS"], ClaudeProcessTransport.backgroundCommandCeilingMilliseconds)
        XCTAssertNil(environment["BASH_DEFAULT_TIMEOUT_MS"],
                     "The default also moves when a foreground command goes to the background, so it stays the CLI's")
        // The entrypoint stays Yardlet's own: the limit is not lifted by passing as the Claude app.
        XCTAssertEqual(environment["CLAUDE_CODE_ENTRYPOINT"], "native-harness-client")
        XCTAssertNil(environment["CLAUDECODE"])
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/Users/test/claude-account")
        XCTAssertEqual(environment["CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING"], "true")
    }

    /// The other harnesses start with the environment they always had: Codex stops no background
    /// terminal, and the ACP, Pi, Muse and headless harnesses have no documented per-process
    /// setting for one (checked 2026-10-15). Claude Code's variable reaches none of them.
    func testOnlyClaudeGetsTheVariable() {
        let base = ["HOME": "/Users/test", "PATH": "/usr/bin"]
        XCTAssertNil(RuntimeProcessEnvironment.values(executableURL: URL(filePath: "/opt/homebrew/bin/codex"),
                                                      base: base)["BASH_MAX_TIMEOUT_MS"])
        XCTAssertNil(RuntimeProcessEnvironment.accountScoped(base)["BASH_MAX_TIMEOUT_MS"])
        XCTAssertNil(RuntimeProcessEnvironment.accountScoped(base.merging(["YARDLET_ACCOUNT_ENVIRONMENT": "isolated"]) { $1 })[
            "BASH_MAX_TIMEOUT_MS"])
        XCTAssertNotNil(ClaudeProcessTransport.environment(base: base, overrides: [:])["BASH_MAX_TIMEOUT_MS"])
    }

    func testAValueTheUserSetForClaudeWins() {
        let fromShell = ClaudeProcessTransport.environment(base: ["BASH_MAX_TIMEOUT_MS": "900000"], overrides: [:])
        XCTAssertEqual(fromShell["BASH_MAX_TIMEOUT_MS"], "900000")
        let fromAccount = ClaudeProcessTransport.environment(base: [:], overrides: ["BASH_MAX_TIMEOUT_MS": "3600000"])
        XCTAssertEqual(fromAccount["BASH_MAX_TIMEOUT_MS"], "3600000")
    }
}
