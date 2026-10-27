import Foundation
import XCTest
@testable import NativeHarnessClient

final class TaskCommandTargetsTests: XCTestCase {
    private func task(
        _ title: String,
        at time: TimeInterval,
        status: SessionStatus = .ready,
        unread: Bool = false,
        pinned: Bool = false,
        folder: String = "/tmp/commands"
    ) -> SessionRecord {
        SessionRecord(harness: .codex, workspaceURL: URL(filePath: folder),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: title, status: status,
            updatedAt: Date(timeIntervalSince1970: time), hasUnreadUpdate: unread, isPinned: pinned)
    }

    private func layout(_ sessions: [SessionRecord], splits: [SplitGroup] = []) -> SidebarProjection.Layout {
        let groups = TaskNavigationProjection.workspaceGroups(from: sessions)
        return SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: splits, isFiltering: false)
    }

    func testPreviousAndNextFollowSidebarRowsAndStopAtTheEnds() {
        let pinned = task("Pinned", at: 10, pinned: true)
        let newest = task("Newest", at: 30)
        let oldest = task("Oldest", at: 20)
        let rows = layout([oldest, pinned, newest])
        XCTAssertEqual(rows.rows.map(\.id), [.session(pinned.id), .session(newest.id), .session(oldest.id)])

        func targets(_ selection: WindowItem, shown: SessionRecord?) -> TaskCommandTargets {
            TaskCommandTargets.make(layout: rows, selection: selection, shownSession: shown,
                sidebarSessions: [oldest, pinned, newest], splits: [])
        }
        let middle = targets(.session(newest.id), shown: newest)
        XCTAssertEqual(middle.previousRow, .session(pinned.id))
        XCTAssertEqual(middle.nextRow, .session(oldest.id))
        let first = targets(.session(pinned.id), shown: pinned)
        XCTAssertNil(first.previousRow, "Previous stops at the first row instead of wrapping")
        XCTAssertEqual(first.nextRow, .session(newest.id))
        let last = targets(.session(oldest.id), shown: oldest)
        XCTAssertEqual(last.previousRow, .session(newest.id))
        XCTAssertNil(last.nextRow, "Next stops at the last row instead of wrapping")
        let home = targets(.home, shown: nil)
        XCTAssertEqual(home.nextRow, .session(pinned.id))
        XCTAssertEqual(home.previousRow, .session(oldest.id))

        let empty = TaskCommandTargets.make(layout: layout([]), selection: .home, shownSession: nil,
            sidebarSessions: [], splits: [])
        XCTAssertEqual(empty, TaskCommandTargets(), "With no tasks every Task command is disabled")
    }

    func testTaskActionsApplyToTheShownTaskOnly() {
        let read = task("Read", at: 20)
        let unread = task("Unread", at: 10, status: .completed, unread: true, pinned: true)
        let rows = layout([read, unread])

        let home = TaskCommandTargets.make(layout: rows, selection: .home, shownSession: read,
            sidebarSessions: [read, unread], splits: [])
        XCTAssertNil(home.pin)
        XCTAssertNil(home.markUnread)
        XCTAssertNil(home.archive)

        let shownRead = TaskCommandTargets.make(layout: rows, selection: .session(read.id), shownSession: read,
            sidebarSessions: [read, unread], splits: [])
        XCTAssertEqual(shownRead.pin, .session(read.id, isPinned: false))
        XCTAssertEqual(shownRead.markUnread, read.id)
        XCTAssertEqual(shownRead.archive, read.id)

        let shownUnread = TaskCommandTargets.make(layout: rows, selection: .session(unread.id), shownSession: unread,
            sidebarSessions: [read, unread], splits: [])
        XCTAssertEqual(shownUnread.pin, .session(unread.id, isPinned: true))
        XCTAssertNil(shownUnread.markUnread, "An unread task cannot be marked unread again")
        XCTAssertEqual(shownUnread.archive, unread.id)
    }

    func testInASplitViewPinActsOnTheSplitRowAndArchiveOnTheFocusedTask() {
        let left = task("Left", at: 20)
        let right = task("Right", at: 10)
        let other = task("Other", at: 5)
        let rightPane = SplitPane(sessionID: right.id)
        let split = SplitGroup(isPinned: true, anchorSessionID: left.id,
            root: .branch(axis: .horizontal, children: [.pane(SplitPane(sessionID: left.id)), .pane(rightPane)],
                fractions: [1, 1]),
            focusedPaneID: rightPane.id)
        let rows = layout([left, right, other], splits: [split])
        XCTAssertEqual(rows.rows.map(\.id), [.split(split.id), .session(other.id)])

        let targets = TaskCommandTargets.make(layout: rows, selection: .split(split.id), shownSession: right,
            sidebarSessions: [left, right, other], splits: [split])
        XCTAssertEqual(targets.pin, .split(split.id, isPinned: true))
        XCTAssertEqual(targets.archive, right.id)
        XCTAssertEqual(targets.markUnread, right.id)
        XCTAssertNil(targets.previousRow)
        XCTAssertEqual(targets.nextRow, .session(other.id))
    }

    func testNextTaskNeedingAttentionPrefersWaitingThenUnreadByRecencyAndSkipsTheShownTask() {
        let olderWaiting = task("Older approval", at: 10, status: .waitingForApproval)
        let newerWaiting = task("Newer question", at: 20, status: .waitingForApproval)
        let newestUnread = task("Finished", at: 40, status: .completed, unread: true)
        let failedUnread = task("Failed", at: 30, status: .failed, unread: true)
        let running = task("Running", at: 50, status: .running)
        let read = task("Read", at: 60, status: .completed)
        let all = [olderWaiting, newerWaiting, newestUnread, failedUnread, running, read]

        XCTAssertEqual(TaskAttentionProjection.nextSession(in: all, excluding: nil), newerWaiting.id)
        XCTAssertEqual(TaskAttentionProjection.nextSession(in: all, excluding: newerWaiting.id), olderWaiting.id)
        let noneWaiting = [newestUnread, failedUnread, running, read]
        XCTAssertEqual(TaskAttentionProjection.nextSession(in: noneWaiting, excluding: nil), newestUnread.id)
        XCTAssertEqual(TaskAttentionProjection.nextSession(in: noneWaiting, excluding: newestUnread.id), failedUnread.id)
        XCTAssertNil(TaskAttentionProjection.nextSession(in: [running, read], excluding: nil))
        XCTAssertNil(TaskAttentionProjection.nextSession(in: [newerWaiting], excluding: newerWaiting.id),
                     "The task already shown is never the target")

        // A running turn has no finished result to read yet, even with an older one unread; a Codex
        // turn that asked a question waits though its status still says running.
        let runningUnread = task("Running, unread", at: 70, status: .running, unread: true)
        XCTAssertNil(TaskAttentionProjection.nextSession(in: [running, runningUnread, read], excluding: nil))
        let asking = task("Asking", at: 5, status: .running)
        XCTAssertEqual(TaskAttentionProjection.nextSession(
            in: [asking, newestUnread], excluding: nil,
            details: [asking.id: TaskAttentionDetail(pendingRequest: .input)]), asking.id)
    }

    func testTheTaskMenuFollowsTheActivityListWhileItIsShown() {
        let waiting = task("Waiting", at: 10, status: .waitingForApproval)
        let unread = task("Unread", at: 30, status: .completed, unread: true)
        let idle = task("Idle", at: 40)
        let sessions = [waiting, unread, idle]
        let activity = SidebarProjection.Layout.list(
            TaskAttentionProjection.activityList(in: sessions).map { SidebarRow(content: .session($0)) })
        XCTAssertEqual(activity.rows.map(\.id), [.session(waiting.id), .session(unread.id)])
        let targets = TaskCommandTargets.make(layout: activity, selection: .session(waiting.id), shownSession: waiting,
            sidebarSessions: sessions, splits: [])
        XCTAssertNil(targets.previousRow)
        XCTAssertEqual(targets.nextRow, .session(unread.id))
        XCTAssertEqual(targets.sessionNeedingAttention, unread.id, "⌥⌘A skips the task shown")
    }
}
