import Foundation

/// What the Task menu acts on right now. The shell builds it from the rows its sidebar lists, so
/// a command is disabled exactly when it has nothing to act on, and availability can be checked
/// without a window.
struct TaskCommandTargets: Equatable, Sendable {
    /// The row Pin acts on: the shown task, or the split view the shown task is in.
    enum PinTarget: Equatable, Sendable {
        case session(UUID, isPinned: Bool)
        case split(UUID, isPinned: Bool)

        var isPinned: Bool {
            switch self {
            case let .session(_, isPinned), let .split(_, isPinned): isPinned
            }
        }
    }

    var previousRow: WindowItem?
    var nextRow: WindowItem?
    var sessionNeedingAttention: UUID?
    var pin: PinTarget?
    /// The shown task, unless it is already unread.
    var markUnread: UUID?
    /// The shown task; in a split view, the focused pane's.
    var archive: UUID?

    /// - Parameters:
    ///   - layout: the rows the sidebar lists, in order.
    ///   - selection: what the window shows.
    ///   - shownSession: the shown task, or the focused pane's task in a split view.
    ///   - sidebarSessions: every task the sidebar can list, whatever a search shows.
    ///   - details: what each task's latest turn waits on, for "Next task needing attention".
    ///   - shellBusy: the tasks running a bash-mode command.
    static func make(
        layout: SidebarProjection.Layout,
        selection: WindowItem,
        shownSession: SessionRecord?,
        sidebarSessions: [SessionRecord],
        splits: [SplitGroup],
        details: [UUID: TaskAttentionDetail] = [:],
        shellBusy: Set<UUID> = []
    ) -> TaskCommandTargets {
        let shown = selection == .home ? nil : shownSession
        // A list of tasks (the activity view) has no split rows; the focused pane's task stands for one.
        let selectedRow = SidebarProjection.row(for: selection, in: layout)
            ?? shown.flatMap { SidebarProjection.row(for: .session($0.id), in: layout) }
            ?? selection
        var pin: PinTarget?
        if case let .split(id) = selection, let split = splits.first(where: { $0.id == id }) {
            pin = .split(id, isPinned: split.isPinned)
        } else if let shown {
            pin = .session(shown.id, isPinned: shown.isPinned)
        }
        return TaskCommandTargets(
            previousRow: SidebarProjection.adjacentRow(in: layout, selected: selectedRow, offset: -1),
            nextRow: SidebarProjection.adjacentRow(in: layout, selected: selectedRow, offset: 1),
            sessionNeedingAttention: TaskAttentionProjection.nextSession(
                in: sidebarSessions,
                excluding: shown?.id,
                details: details,
                shellBusy: shellBusy
            ),
            pin: pin,
            markUnread: shown.flatMap { $0.hasUnreadUpdate ? nil : $0.id },
            archive: shown?.id
        )
    }
}
