import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class ArchivedTaskRenderingTests: XCTestCase {
    func testArchivedListSearchMatchesTitleProjectAndHarness() {
        let codex = ArchivedSessionRecord(
            session: SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/parser"),
                runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Fix the parser"),
            archivedAt: nil, isProviderArchived: false)
        let claude = ArchivedSessionRecord(
            session: SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/site"),
                runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Landing page"),
            archivedAt: nil, isProviderArchived: false)
        let name: (SessionRecord) -> String = { $0.workspaceURL.lastPathComponent == "site" ? "Website" : "Parser" }
        XCTAssertEqual(ArchivedTaskFilter.matches([codex, claude], query: "  ", projectName: name), [codex, claude])
        XCTAssertEqual(ArchivedTaskFilter.matches([codex, claude], query: "PARSER", projectName: name), [codex])
        XCTAssertEqual(ArchivedTaskFilter.matches([codex, claude], query: "web", projectName: name), [claude])
        XCTAssertEqual(ArchivedTaskFilter.matches([codex, claude], query: "claude", projectName: name), [claude])
        XCTAssertEqual(ArchivedTaskFilter.matches([codex, claude], query: "nothing", projectName: name), [])
    }

    func testSidebarEntryArchivedListAndRestoreRowRenderWithoutAWindow() throws {
        let codex = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/yardlet"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Fix the session index migration",
            providerSessionID: "codex-thread")
        let claude = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/site"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Landing page copy",
            providerSessionID: "claude-session")
        let restoring = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/yardlet"),
            runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Review the split view", providerSessionID: "claude-2")
        let archived = [codex, claude, restoring].map {
            ArchivedSessionRecord(session: $0, archivedAt: Date(), isProviderArchived: $0.harness == .codex)
        }
        let active = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/yardlet"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "Keyboard shortcuts", status: .completed,
            hasUnreadUpdate: true)
        let groups = TaskNavigationProjection.workspaceGroups(from: [active])
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, splits: [], isFiltering: false)
        let projectName: (SessionRecord) -> String = { $0.workspaceURL.lastPathComponent }
        let directory = try WindowlessRender.directory("archived-tasks-qa")

        for appearance in [ColorScheme.light, .dark] {
            let view = HStack(alignment: .top, spacing: 0) {
                TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(active.id),
                    searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                    projects: ProjectStore(), onEditProject: { _ in },
                    onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                    onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in })
                    .frame(width: ParityTheme.sidebarWidth)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                ArchivedTaskList(archived: archived, errorMessage: nil, restoringIDs: [restoring.id],
                    searchText: .constant(""), projectName: projectName, onBack: {}, onUnarchive: { _ in })
                    .frame(width: ParityTheme.sidebarWidth)
                Rectangle().fill(ParityTheme.separator).frame(width: 1)
                VStack(spacing: 0) {
                    ArchivedTaskList(archived: [], errorMessage: nil, restoringIDs: [],
                        searchText: .constant(""), projectName: projectName, onBack: {}, onUnarchive: { _ in })
                        .frame(height: 150)
                    ArchivedTaskList(archived: nil, errorMessage: nil, restoringIDs: [],
                        searchText: .constant("nothing"), projectName: projectName, onBack: {}, onUnarchive: { _ in })
                        .frame(height: 150)
                    ArchivedTaskRow(record: archived[0], projectName: "yardlet", isRestoring: false,
                        onUnarchive: {}, isHovering: true)
                        .padding(4)
                        .background(ParityTheme.sidebar)
                    Spacer(minLength: 0)
                }
                .frame(width: ParityTheme.sidebarWidth)
            }
            .frame(width: ParityTheme.sidebarWidth * 3 + 2, height: 420)
            .environment(\.colorScheme, appearance)

            let host = WindowlessRender.Host(view, size: NSSize(width: ParityTheme.sidebarWidth * 3 + 2, height: 420),
                                             appearance: WindowlessRender.Appearance(appearance))
            defer { host.close() }
            host.settle(passes: 1, interval: 0.1)
            let capture = try host.capture()
            let bitmap = capture.bitmap
            try WindowlessRender.writePNG(bitmap,
                to: directory.appending(path: appearance == .dark ? "archived-dark.png" : "archived-light.png"))
            XCTAssertEqual(bitmap.pixelsWide, Int(host.hosting.bounds.width * capture.backingScaleFactor))
            XCTAssertGreaterThan(bitmap.pixelsHigh, 400)
        }
    }
}
