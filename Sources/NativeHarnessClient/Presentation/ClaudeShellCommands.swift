import Foundation
import Observation

/// One bash-mode command of a Claude task while Yardlet runs it, keyed by its conversation entry.
/// The entry's text is what Claude receives; this is what the running row shows meanwhile.
@MainActor
@Observable
final class ClaudeShellCommandRun: Identifiable {
    enum State: Equatable {
        case running
        case finished
        /// Stopped by the user. As in the Claude app, a stopped command is not sent to Claude.
        case stopped
        /// The shell did not start. Claude is still told why, as the Claude app sends the error.
        case failed(String)
    }

    let id: UUID
    let sessionID: UUID
    let command: String
    var output = ""
    var state: State = .running
    var exitCode: Int32?

    init(id: UUID, sessionID: UUID, command: String) {
        self.id = id
        self.sessionID = sessionID
        self.command = command
    }
}

/// A finished bash-mode command whose message waits to be sent to Claude: the conversation entry
/// that shows it, and the message. Saved with the task's queued follow-ups.
struct ClaudeShellDelivery: Codable, Equatable, Sendable {
    let entryID: UUID
    let text: String
}
