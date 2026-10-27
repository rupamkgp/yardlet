import Darwin
import Foundation

/// Yardlet started from inside a Claude Code session (a terminal `swift run`, or an agent that opened
/// the app) inherits that session's variables. They describe the parent host, not Yardlet, and would
/// make every task Yardlet starts behave as that host's child (its config folder, its disabled
/// connectors, its messaging socket), so they are dropped once at launch.
enum HostSessionEnvironment {
    private static let names: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_CONFIG_DIR", "CLAUDE_EFFORT", "ENABLE_CLAUDEAI_MCP_SERVERS",
        "DISABLE_AUTOUPDATER", "DISABLE_MICROCOMPACT", "MCP_CONNECTION_NONBLOCKING", "MCP_SERVER_CONNECTION_BATCH_SIZE",
        "USE_STAGING_OAUTH", "USE_LOCAL_OAUTH", "AI_AGENT", "API_TIMEOUT_MS"
    ]
    private static let prefixes = ["CLAUDE_CODE_", "CLAUDE_AGENT_SDK_", "CLAUDE_PREVIEW_"]

    static func hostVariables(in environment: [String: String]) -> [String] {
        guard environment["CLAUDECODE"] != nil || environment["CLAUDE_CODE_ENTRYPOINT"] != nil else { return [] }
        return environment.keys.filter { key in
            names.contains(key) || prefixes.contains { key.hasPrefix($0) }
        }.sorted()
    }

    static func detachFromHostSession() {
        for key in hostVariables(in: ProcessInfo.processInfo.environment) { unsetenv(key) }
    }
}
