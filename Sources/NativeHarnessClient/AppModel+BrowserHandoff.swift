import Foundation

/// A browser tab the agent hands to the person (`browser_handoff`, docs/AGENT_BROWSER_TOOLS.md, "Tools"): the task's side panel shows the
/// tab, with the agent's reason and Done and Decline in a bar over the page, and a notification tells the person; a
/// click opens the task, whose panel already shows the tab. The notification goes when the handoff ends.
extension AppModel: BrowserHandoffPresenting {
    func handoffStarted(session: UUID, tabKey: UUID?, reason: String, notice: String) {
        if let tabKey {
            let workspace = taskWorkspaces.state(for: session)
            workspace.setPanels(TaskSurfaceNavigationProjection.showing(
                TaskSurfaceNavigationProjection.browserTabID(tabKey), in: workspace.panels))
        }
        let title = store.sessions.first { $0.id == session }?.title ?? ""
        BrowserHandoffNotices.pending.insert(notice)
        Task {
            guard (await systemNotificationCenter.authorization()).isDeliverable,
                  BrowserHandoffNotices.pending.contains(notice) else { return }
            await systemNotificationCenter.post(SystemNotification(
                title: L10n.string("The agent needs you in the browser"),
                body: title.isEmpty ? reason : "\(title): \(reason)",
                identifier: notice, target: SystemNotificationTarget(sessionID: session)))
            // The handoff may have ended while the notification was on its way.
            if !BrowserHandoffNotices.pending.contains(notice) {
                systemNotificationCenter.removeNotifications(identifiers: [notice])
            }
        }
    }

    func handoffEnded(notice: String) {
        BrowserHandoffNotices.pending.remove(notice)
        systemNotificationCenter.removeNotifications(identifiers: [notice])
    }

    func handoffWaitCeiling(for session: UUID) -> Duration {
        let harness = store.sessions.first { $0.id == session }?.harness ?? .claudeCode
        return sessionToolWaitCeiling(for: harness)
    }
}

extension AppModel {
    /// One of Chromium's windows (a passkey dialog, a site's sign-in window) came over a tab of a task whose panel is
    /// not on screen: the task's panel shows that tab, as `browser_handoff` leaves it, so the person finds the window
    /// over its tab when they come to the task. The task in front stays.
    func showBrowserTab(_ tabKey: UUID, under session: UUID) {
        let workspace = taskWorkspaces.state(for: session)
        workspace.setPanels(TaskSurfaceNavigationProjection.showing(
            TaskSurfaceNavigationProjection.browserTabID(tabKey), in: workspace.panels))
    }
}

/// The handoffs whose notification may still be shown.
@MainActor
enum BrowserHandoffNotices {
    static var pending: Set<String> = []
}
