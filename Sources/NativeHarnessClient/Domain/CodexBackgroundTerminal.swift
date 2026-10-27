import Foundation

/// A command a Codex thread keeps running after the turn that started it, as the App Server lists it
/// (experimental `thread/backgroundTerminals/list`, App Server 0.163) and the Codex app's thread
/// summary shows under "Background processes". Yardlet's Codex timeline closes a command whose turn
/// ended (`CodexTaskReducer.reconcileTerminalActivityItems`), so the thread is asked instead.
struct CodexBackgroundTerminal: Equatable, Identifiable, Sendable {
    let processID: String
    /// The `commandExecution` item that started it, whose output the timeline holds.
    let itemID: String
    let command: String
    let workspacePath: String

    var id: String { processID }

    init(processID: String, itemID: String, command: String, workspacePath: String) {
        self.processID = processID
        self.itemID = itemID
        self.command = command
        self.workspacePath = workspacePath
    }

    /// A `ThreadBackgroundTerminal`; nil without its process, item or command.
    init?(json: JSONValue) {
        guard let processID = json["processId"]?.stringValue, !processID.isEmpty,
              let itemID = json["itemId"]?.stringValue,
              let command = json["command"]?.stringValue else { return nil }
        self.init(processID: processID, itemID: itemID, command: command,
                  workspacePath: json["cwd"]?.stringValue ?? "")
    }
}

/// Lists and stops a Codex thread's background terminals through its own App Server.
protocol CodexBackgroundTerminalControlling: Actor {
    func backgroundTerminals(in session: HarnessSessionHandle) async throws -> [CodexBackgroundTerminal]
    func terminateBackgroundTerminal(processID: String, in session: HarnessSessionHandle) async throws
    /// Stops every one of the thread's background terminals.
    func cleanBackgroundTerminals(in session: HarnessSessionHandle) async throws
}
