import Foundation

/// Claude Code negotiates no protocol version on its stream-json control channel, and the
/// Claude Desktop bundled runtime updates on its own schedule, so Yardlet keeps a minimum
/// runtime floor instead of an exact prefix pin. Runtimes at or above the floor connect;
/// versions whose live behaviour was verified are reported separately so the Account Center can
/// show when the selected runtime is newer than anything Yardlet has exercised.
struct ClaudeRuntimeCompatibility: HarnessRuntimeCompatibility, Equatable {
    typealias Rule = HarnessRuntimeVersionRule
    typealias Version = HarnessRuntimeVersion

    /// `claude --version` prints `2.1.275 (Claude Code)`; the trailing product name identifies
    /// the runtime, so a binary that prints anything else is refused.
    static let marker = "(Claude Code)"

    static let restorationBaseline = ClaudeRuntimeCompatibility(
        minimum: "2.1.0",
        verified: [
            // Streaming, structured permissions, interrupt, and resume smoke.
            .exact("2.1.227"),
            // No-prompt lifecycle through the current YHP route.
            .exact("2.1.239"),
            // Empty separate account environment left existing accounts untouched.
            .exact("2.1.270"),
            .exact("2.1.273"),
            // Model-free native attach and a permission-mode round trip.
            .exact("2.1.275"),
            // The same, plus the CLI's own announcement of the mode change, with launch flags
            // and the `can_use_tool` shapes unchanged from 2.1.273 in the embedded source.
            .exact("2.1.281")
        ]
    )

    /// Lowest Claude Code release core whose control contract Yardlet supports.
    let minimum: String
    /// Versions whose live attach and control behaviour were verified against this source.
    let verified: [HarnessRuntimeVersionRule]

    func version(from output: String) -> String? {
        Self.version(from: output)
    }

    static func version(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(marker),
              let first = trimmed.split(whereSeparator: \.isWhitespace).first
        else { return nil }
        return String(first)
    }

    /// Runs `claude --version` and returns its trimmed output. No home, account, or session is
    /// touched.
    static func readVersionOutput(executableURL: URL) throws -> String {
        try HarnessRuntimeVersionProbe.output(executableURL: executableURL)
    }
}
