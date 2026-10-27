import Foundation

/// Codex App Server does not negotiate a protocol version during `initialize`, so Yardlet keeps
/// a minimum runtime floor instead of an exact allow list. Runtimes at or above the floor connect;
/// versions whose live behaviour was verified are reported separately so the Account Center can
/// show when the selected runtime is newer than anything Yardlet has exercised.
struct CodexRuntimeCompatibility: HarnessRuntimeCompatibility, Equatable {
    typealias Rule = HarnessRuntimeVersionRule
    typealias Version = HarnessRuntimeVersion

    /// `codex --version` prints `codex-cli <version>`; the marker identifies the runtime, so a
    /// binary that prints anything else is refused.
    static let marker = "codex-cli"

    static let restorationBaseline = CodexRuntimeCompatibility(
        minimum: "0.147.0",
        verified: [
            .prefix("0.147."),
            .prefix("0.148."),
            .prefix("0.149."),
            .exact("0.152.1"),
            .exact("0.153.4"),
            // Generated 426-schema contract and persisted paginated-history reads verified.
            .exact("0.154.0-alpha.6.2"),
            // Generated request schema, existing paginated history, and native attach verified.
            .exact("0.155.0-alpha.2.6"),
            // Same three checks on 2026-09-21: 25 used request methods unchanged, 76-turn
            // paginated history read, and a model-free native attach.
            .exact("0.155.0-alpha.9.2"),
            // Same three checks on 2026-09-26: 25 used request methods and 11 server requests
            // unchanged, 76-turn paginated history read, and a model-free native attach.
            .exact("0.155.0-alpha.16.4"),
            // Same three checks on 2026-09-28 through ChatGPT's codex-cli/bin/codex launcher:
            // 25 used request methods, 11 server requests, and the thread `config` field
            // unchanged, 76-turn paginated history read, and a model-free native attach.
            .exact("0.158.0-alpha.2.1")
        ]
    )

    /// Lowest `codex-cli` release core whose App Server contract Yardlet supports.
    let minimum: String
    /// Versions whose live attach and history behaviour were verified against this source.
    let verified: [HarnessRuntimeVersionRule]

    func version(from output: String) -> String? {
        Self.version(from: output)
    }

    static func version(from output: String) -> String? {
        let tokens = output.split(whereSeparator: \.isWhitespace)
        guard let markerIndex = tokens.firstIndex(of: Substring(marker)),
              tokens.indices.contains(tokens.index(after: markerIndex))
        else { return nil }
        return String(tokens[tokens.index(after: markerIndex)])
    }

    /// Runs `codex --version` and returns its trimmed output. No home, account, or thread is touched.
    static func readVersionOutput(executableURL: URL) throws -> String {
        try HarnessRuntimeVersionProbe.output(executableURL: executableURL)
    }
}
