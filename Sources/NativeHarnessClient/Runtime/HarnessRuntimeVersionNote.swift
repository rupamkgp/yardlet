import Foundation

/// Read-only standing of a selected harness runtime for the Account Center. It only runs
/// `<runtime> --version`; it never opens a home, reads an account, or starts a thread.
struct HarnessRuntimeVersionNote: Equatable, Sendable {
    enum Standing: Equatable, Sendable {
        case verified
        case unverified
        case belowMinimum
    }

    let version: String
    let standing: Standing
    let minimum: String

    /// The harnesses whose runtime version Yardlet reports. Both keep a minimum floor instead of
    /// exact pins, so the Account Center says whether the selected version is one Yardlet verified.
    static func compatibility(for harness: HarnessKind) -> (any HarnessRuntimeCompatibility)? {
        switch harness {
        case .codex: CodexRuntimeCompatibility.restorationBaseline
        case .claudeCode: ClaudeRuntimeCompatibility.restorationBaseline
        default: nil
        }
    }

    static func note(
        versionOutput: String,
        compatibility: any HarnessRuntimeCompatibility
    ) -> HarnessRuntimeVersionNote? {
        guard let version = compatibility.version(from: versionOutput) else { return nil }
        let standing: Standing
        if !compatibility.accepts(versionOutput: versionOutput) {
            standing = .belowMinimum
        } else if compatibility.isVerified(versionOutput: versionOutput) {
            standing = .verified
        } else {
            standing = .unverified
        }
        return HarnessRuntimeVersionNote(
            version: version,
            standing: standing,
            minimum: compatibility.minimum
        )
    }

    static func read(
        executableURL: URL,
        compatibility: any HarnessRuntimeCompatibility
    ) -> HarnessRuntimeVersionNote? {
        guard let output = try? compatibility.readVersionOutput(executableURL: executableURL) else {
            return nil
        }
        return note(versionOutput: output, compatibility: compatibility)
    }

    var text: String {
        switch standing {
        case .verified:
            L10n.format("Version %@", version)
        case .unverified:
            L10n.format("Version %@ · newer than any version verified with Yardlet", version)
        case .belowMinimum:
            L10n.format("Version %@ · below the supported minimum %@", version, minimum)
        }
    }
}
