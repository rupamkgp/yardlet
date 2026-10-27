import AppKit
import Foundation

/// The quit confirmation for running tasks. With Settings › General › "Continue running work after
/// a restart" on, the tasks a quit only pauses (`RestartResumePolicy`) are named apart from those
/// it stops, and the confirmation says they continue when Yardlet opens again.
struct QuitConfirmation: Equatable {
    let title: String
    private(set) var message: String
    let quitButton: String

    /// - Parameters:
    ///   - active: the running tasks, in the order they are listed.
    ///   - continuing: those among them that continue after the restart.
    ///   - enabledSchedules: scheduled tasks that are on, which do not run while Yardlet is closed.
    init(active: [SessionRecord], continuing: Set<UUID>, enabledSchedules: Int = 0) {
        func list(_ sessions: [SessionRecord]) -> String {
            sessions.map { "• \($0.title) (\($0.harness.displayName))" }.joined(separator: "\n")
        }
        let stopping = active.filter { !continuing.contains($0.id) }
        let resuming = active.filter { continuing.contains($0.id) }
        title = L10n.string("Active tasks are still running")
        if resuming.isEmpty {
            message = L10n.format("Quitting will stop these local tasks:\n%@", list(stopping))
            quitButton = L10n.string("Quit and stop active work")
        } else if stopping.isEmpty {
            message = L10n.format(
                "Quitting pauses these tasks. They continue where they left off when Yardlet opens again:\n%@",
                list(resuming))
            quitButton = L10n.string("Quit and continue later")
        } else {
            message = L10n.format("Quitting will stop these local tasks:\n%@", list(stopping)) + "\n\n"
                + L10n.format("These continue where they left off when Yardlet opens again:\n%@", list(resuming))
            quitButton = L10n.string("Quit and stop active work")
        }
        if enabledSchedules > 0 {
            message += "\n\n" + L10n.format("%lld scheduled tasks do not run while Yardlet is closed.",
                                             Int64(enabledSchedules))
        }
    }

    /// The warning alert: quit first, Cancel second.
    @MainActor
    func alert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: quitButton)
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert
    }
}
