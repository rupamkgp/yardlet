import Foundation

enum RuntimeProcessEnvironment {
    static func values(
        executableURL: URL,
        base: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var values = base
        let home = base["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let preferredPaths = [
            executableURL.deletingLastPathComponent().path(percentEncoded: false),
            URL(filePath: home).appending(path: ".local/bin").path(percentEncoded: false),
            URL(filePath: home).appending(path: ".bun/bin").path(percentEncoded: false),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].map(normalizedPath)
        let existingPaths = (base["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { normalizedPath(String($0)) }
        var seen = Set<String>()
        values["PATH"] = (preferredPaths + existingPaths)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        if CLIRuntimeOverrides.isYardletCopy(executableURL) {
            // An earlier version Yardlet kept after an update failed its check must stay that
            // version: its own updater would replace it with the one that failed.
            values["AGY_CLI_DISABLE_AUTO_UPDATE"] = "true"
            values["DISABLE_AUTOUPDATER"] = "1"
        }
        return accountScoped(values.merging(overrides) { _, new in new })
    }

    static func accountScoped(_ environment: [String: String]) -> [String: String] {
        guard environment["YARDLET_ACCOUNT_ENVIRONMENT"] == "isolated" else { return environment }
        var result = environment
        for key in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
                    "OPENAI_CODEX_OAUTH_TOKEN", "OPENROUTER_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY",
                    "XAI_API_KEY", "AZURE_OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_API_BASE",
                    "ANTHROPIC_BASE_URL", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
                    "OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG_CONTENT"] {
            result.removeValue(forKey: key)
        }
        return result
    }

    private static func normalizedPath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }
}
