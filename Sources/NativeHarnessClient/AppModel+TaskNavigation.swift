import Foundation

extension AppModel {
    /// A person opened a task from an app-level surface, such as a notification,
    /// resource window, or import sheet. Keep this distinct from index updates.
    func revealTask(_ sessionID: UUID) {
        guard store.sessions.contains(where: { $0.id == sessionID }) else { return }
        splits.activate(.session(sessionID))
        taskSurfaceRevealRequest += 1
    }

    func revealNewTask() {
        splits.showNewTask()
        taskSurfaceRevealRequest += 1
    }
}
