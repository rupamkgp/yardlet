import Foundation
@testable import NativeHarnessClient

extension ShellLaunchEnvironment {
    /// zsh as a login shell that reads its startup files from `folder` and keeps its history
    /// there: none of the person's rc files run, and nothing a test types reaches their
    /// `~/.zsh_history`. The terminal panel's tests and bash mode's tests start their shells so.
    static func isolatedZsh(in folder: URL) -> ShellLaunchEnvironment {
        ShellLaunchEnvironment(executable: "/bin/zsh", arguments: ["-l"], overrides: [
            "ZDOTDIR": folder.path(percentEncoded: false),
            "HISTFILE": folder.appending(path: ".zsh_history").path(percentEncoded: false)
        ])
    }
}
