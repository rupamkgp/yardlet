import Foundation

/// How a bash-mode command ended.
struct ShellCommandResult: Equatable, Sendable {
    /// What the command printed, as a terminal shows it, with only the end of very long output.
    var output: String
    var exitCode: Int32?
    /// The signal that ended it, when one did.
    var signal: Int32?
    /// The user stopped it.
    var wasStopped = false
    /// The shell could not run it; nothing ran.
    var launchError: String?
}

/// One bash-mode command, run in its task's shell.
@MainActor
protocol ShellCommandRunning: AnyObject {
    /// Live output while it runs.
    var onOutput: ((String) -> Void)? { get set }
    /// Called once, when it has ended or could not start.
    var onFinish: ((ShellCommandResult) -> Void)? { get set }
    func start()
    /// The user's stop: Control-C to what runs in the foreground, then harder if it keeps running.
    func stop()
    /// Ends it at once, with its shell, as when its task goes away or the app quits.
    func terminate()
}

/// A task's bash-mode shell, as the Claude app keeps one per session: one hidden login shell in
/// the task's folder that runs the task's commands one after another, so `cd`, `export`, shell
/// variables and functions carry from one command to the next. The macOS implementation is a
/// pseudo-terminal (`TaskShellProcess` in Platform/macOS).
@MainActor
protocol TaskShell: AnyObject {
    /// The folder it started in.
    var workingDirectory: URL { get }
    /// False once the shell has exited or was ended; the task's next command starts a new one.
    var isAlive: Bool { get }
    /// It was ended because a command in it could not be stopped any other way.
    var wasReset: Bool { get }
    /// Processes it started still run, such as a server sent to the background.
    var hasOwnProcesses: Bool { get }
    /// One of its commands is running or waiting for it to start.
    var isRunningCommand: Bool { get }
    /// The shell's process while it runs, else 0. Task Resource Usage counts it, with what it
    /// started, toward its task.
    var processID: Int32 { get }
    /// A command to run in it, one at a time. `note` comes before its output.
    func command(_ command: String, note: String?) -> any ShellCommandRunning
    /// Ends it and whatever runs in it.
    func close()
}

extension TaskShell {
    var processID: Int32 { 0 }
}

/// Every task's bash-mode shell. A task's first command starts its shell; a shell that has exited
/// is replaced by the next command; a task whose folder changed gets a new shell there unless the
/// old one still runs processes of its own, as the Claude app's bash mode follows a session's
/// move to a worktree. A command in a new shell that replaced one says so first, in the Claude
/// app's words, so Claude knows the directory and environment were reset. Like the Claude app,
/// at most `limit` shells stay open; past that the one used longest ago with no command running
/// is closed.
@MainActor
final class TaskShells {
    /// The Claude app keeps 16 bash-mode shells.
    static let limit = 16
    var launch: ShellLaunchEnvironment
    var makeShell: (URL, ShellLaunchEnvironment) -> any TaskShell
    private var shells: [UUID: any TaskShell] = [:]
    /// The folder each task had when its shell last followed it.
    private var folders: [UUID: URL] = [:]
    /// Tasks by when their shell was last used, oldest first.
    private var recency: [UUID] = []

    init(launch: ShellLaunchEnvironment, makeShell: @escaping (URL, ShellLaunchEnvironment) -> any TaskShell) {
        self.launch = launch
        self.makeShell = makeShell
    }

    /// The task's shell, while it has one.
    func shell(for taskID: UUID) -> (any TaskShell)? {
        shells[taskID]
    }

    /// Each task's running shell process.
    func processIDs() -> [UUID: Int32] {
        shells.compactMapValues { $0.isAlive && $0.processID > 0 ? $0.processID : nil }
    }

    /// A command for the task's shell, starting or replacing the shell first when needed.
    func command(_ command: String, for taskID: UUID, in folder: URL) -> any ShellCommandRunning {
        let folder = folder.standardizedFileURL
        var note: String?
        if let shell = shells[taskID] {
            let previous = folders[taskID] ?? shell.workingDirectory
            if previous != folder, shell.isAlive, shell.hasOwnProcesses {
                note = "(the session moved to \(Self.path(folder)); this shell is still in \(Self.path(previous)) "
                    + "because it has processes running \u{2014} cd when they are done)"
                folders[taskID] = folder
            } else if previous != folder {
                shell.close()
                shells[taskID] = nil
                note = "(new shell in \(Self.path(folder)) \u{2014} the session moved out of \(Self.path(previous)), "
                    + "so the environment was reset)"
            } else if !shell.isAlive {
                shells[taskID] = nil
                if shell.wasReset {
                    note = "(new shell \u{2014} the previous command was still running and was stopped, "
                        + "so the directory and environment were reset)"
                }
            }
        }
        let shell: any TaskShell
        if let existing = shells[taskID] {
            shell = existing
        } else {
            shell = makeShell(folder, launch)
            shells[taskID] = shell
            folders[taskID] = folder
        }
        recency.removeAll { $0 == taskID }
        recency.append(taskID)
        if shells.count > Self.limit,
           let oldest = recency.first(where: { $0 != taskID && shells[$0]?.isRunningCommand == false }) {
            close(oldest)
        }
        return shell.command(command, note: note)
    }

    func close(_ taskID: UUID) {
        shells.removeValue(forKey: taskID)?.close()
        folders.removeValue(forKey: taskID)
        recency.removeAll { $0 == taskID }
    }

    func closeAll() {
        for taskID in Array(shells.keys) { close(taskID) }
    }

    private static func path(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
