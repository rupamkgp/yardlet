import Foundation

/// How Yardlet starts a person's shell. Its two shells share it: the terminal panel's interactive
/// shell (`NativeTerminalSession`) and bash mode's hidden one per task (`TaskShellProcess`). Both
/// are the person's login shell (`userLoginShell()`, in Platform/macOS), started as a login shell
/// in the task's folder on a pseudo-terminal, with the app's environment, the terminal variables
/// below, and then whatever the launch overrides.
///
/// The two runners stay apart: bash mode captures a command's output for Claude, the terminal is
/// a terminal the person types in.
struct ShellLaunchEnvironment: Equatable, Sendable {
    var executable: String
    /// The arguments that start it as a login shell.
    var arguments: [String]
    /// Set last, over the app's environment, the terminal variables and the runner's own: a test's
    /// `ZDOTDIR` and `HISTFILE`, so its shells read none of the person's startup files and write
    /// nothing to their history.
    var overrides: [String: String] = [:]

    /// What every Yardlet shell is told on top of the app's environment: a terminal with 256
    /// colours and true colour, and `cat` as the pager. Bash mode's output has nobody to press a
    /// pager's keys; the terminal panel has always set the same.
    static let terminalVariables: [String: String] = [
        "TERM": "xterm-256color",
        "COLORTERM": "truecolor",
        "PAGER": "cat",
        "GIT_PAGER": "cat"
    ]

    /// What a runner passes to start the shell.
    struct Start: Equatable, Sendable {
        let executable: String
        let arguments: [String]
        /// `NAME=value`, in name order.
        let environment: [String]
        /// `argv[0]`: the shell's own name. `-l` makes it a login shell; a dash before the name as well
        /// would make tcsh refuse `-l`.
        let processName: String
        let currentDirectory: String
    }

    /// The shell's variables: `base` (the app's own), the terminal variables, what the runner adds,
    /// and the overrides last.
    func environment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        adding runnerVariables: [String: String] = [:]
    ) -> [String: String] {
        base.merging(Self.terminalVariables) { $1 }
            .merging(runnerVariables) { $1 }
            .merging(overrides) { $1 }
    }

    /// How to start the shell in `folder`.
    func start(
        in folder: URL,
        base: [String: String] = ProcessInfo.processInfo.environment,
        adding runnerVariables: [String: String] = [:]
    ) -> Start {
        Start(
            executable: executable,
            arguments: arguments,
            environment: environment(base: base, adding: runnerVariables).map { "\($0.key)=\($0.value)" }.sorted(),
            processName: URL(filePath: executable).lastPathComponent,
            currentDirectory: Self.directoryPath(folder)
        )
    }

    /// A folder's path as a shell is started in it and `cd`s to it: standardized, with no slash at
    /// the end.
    static func directoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
