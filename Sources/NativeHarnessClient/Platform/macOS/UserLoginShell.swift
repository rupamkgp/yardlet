import Darwin
import Foundation

extension ShellLaunchEnvironment {
    /// The person's login shell as a login shell (`-l`), as the Claude app starts its bash-mode
    /// shell (`$SHELL -l`) and Terminal starts a window's. On a terminal it is interactive, so the
    /// aliases, functions and PATH the person's own terminal has are there.
    static func userLoginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> ShellLaunchEnvironment {
        ShellLaunchEnvironment(executable: loginShellPath(environment: environment), arguments: ["-l"])
    }

    /// The account's shell from the user database, then `$SHELL`, then zsh, macOS's default.
    static func loginShellPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let path = String(cString: raw)
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let path = environment["SHELL"], path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/bin/zsh"
    }
}
