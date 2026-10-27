import SwiftUI

/// "Move to project" with the projects a task can go to, and "Remove from <project>" when it can
/// go back to Chats (`TaskProjectMove`), for a task row's context menu and the task actions menu.
/// The Codex app's own words; nothing shows when there is no move to offer.
struct TaskProjectMoveMenuItems: View {
    let options: TaskProjectMove.Options
    let onMove: (Project?) -> Void

    var body: some View {
        if !options.destinations.isEmpty {
            Menu(TaskProjectMove.moveTitle) {
                ForEach(options.destinations) { project in
                    Button(project.name) { onMove(project) }
                }
            }
        }
        if let current = options.removableFrom {
            Button(TaskProjectMove.removeTitle(current)) { onMove(nil) }
        }
    }
}
