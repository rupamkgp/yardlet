import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Renders the sidebar offscreen into `.build/move-project-qa`, light and dark, before and after a
/// chat moves into a project (the Codex app thread the person had moved to `13주`). The repository
/// renders no context menus, so the sidebar shows the move. No provider, app launch, or window
/// server interaction.
@MainActor
final class TaskProjectMoveRenderingTests: XCTestCase {
    func testTheSidebarShowsAMovedChatUnderItsNewProject() throws {
        let home = URL(filePath: "/tmp/move-project-qa/home", directoryHint: .isDirectory)
        let thirteen = URL(filePath: "/tmp/move-project-qa/13weeks", directoryHint: .isDirectory)
        let sandbox = URL(filePath: "/tmp/move-project-qa/yardlet-sandbox", directoryHint: .isDirectory)
        let projects = ProjectStore(chatWorkspaceHome: home)
        let thirteenProject = projects.ensureProject(forRoot: thirteen, name: "13주")
        _ = projects.ensureProject(forRoot: sandbox)
        let now = Date()
        func task(_ title: String, _ harness: HarnessKind, in folder: URL, minutesAgo: Double,
                  projectID: UUID? = nil, status: SessionStatus = .ready, unread: Bool = false) -> SessionRecord {
            SessionRecord(harness: harness, workspaceURL: folder,
                          runtimeExecutableURL: URL(filePath: "/tmp/\(harness.rawValue)"),
                          title: title, titleOrigin: .provider, status: status,
                          updatedAt: now.addingTimeInterval(-minutesAgo * 60), hasUnreadUpdate: unread,
                          completionState: unread ? .completed : .none, projectID: projectID)
        }
        let game = task("OpenAI Game 2026 웹게임 완성", .codex,
                        in: home.appending(path: "Documents/Codex/2026-08-25/new-chat", directoryHint: .isDirectory),
                        minutesAgo: 2)
        let trip = task("Plan the weekend trip", .claudeCode,
                        in: home.appending(path: "Library/Application Support/Claude/scratch-workspaces/a/b/scratch-1",
                                           directoryHint: .isDirectory), minutesAgo: 4)
        let weekly = task("주차별 학습 계획 정리", .codex, in: thirteen, minutesAgo: 30, projectID: thirteenProject.id,
                          unread: true)
        let sandboxTask = task("Nest task rows under their project", .claudeCode, in: sandbox, minutesAgo: 8,
                               status: .running)
        let before = [game, trip, weekly, sandboxTask]
        let options = TaskProjectMove.options(
            for: game, visibleProjects: projects.visibleGroups(sessions: before).compactMap(\.project),
            projects: projects.projects, home: home)
        XCTAssertTrue(options.allows(thirteenProject))
        let moved = TaskProjectMove.moved(game, to: thirteenProject)
        let after = [moved, trip, weekly, sandboxTask]
        XCTAssertEqual(projects.chats(sessions: before).map(\.id), [game.id, trip.id])
        XCTAssertEqual(projects.chats(sessions: after).map(\.id), [trip.id])

        let suite = testDefaultsSuite("move-project-qa")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let disclosure = SidebarDisclosureStore(defaults: defaults)
        func sidebar(_ sessions: [SessionRecord]) -> TaskSidebar {
            let groups = projects.visibleGroups(sessions: sessions)
            let chats = projects.chats(sessions: sessions)
            let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, chats: chats, splits: [],
                                                  isFiltering: false, disclosure: disclosure.disclosure,
                                                  selection: .session(game.id))
            return TaskSidebar(layout: layout, allGroups: groups, isRestoring: false, selection: .session(game.id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in },
                onArchiveProjectChats: { _ in }, onRemoveProject: { _ in }, onTogglePinned: { _ in },
                onArchive: { _ in }, onDelete: { _ in }, onRename: { _ in }, onMarkRead: { _ in },
                disclosure: disclosure)
        }

        let size = NSSize(width: ParityTheme.sidebarWidth, height: 420)
        let directory = try WindowlessRender.directory("move-project-qa")
        for (name, sessions) in [("sidebar-before-move", before), ("sidebar-after-move", after)] {
            try WindowlessRender.hostedInBothAppearances(name, in: directory, size: size) {
                sidebar(sessions)
                    .environment(\.colorScheme, $0.colorScheme)
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .background(ParityTheme.sidebar)
            }
        }

        // What the sidebar exposes after the move: the chat is under 13주, below Projects, and Chats
        // holds only the other chat.
        let host = WindowlessRender.Host(
            sidebar(after).frame(width: size.width, height: size.height, alignment: .top), size: size)
        defer { host.close() }
        host.settle()
        let elements = host.accessibilityElements()
        func index(where matches: (WindowlessRender.AccessibilityElement) -> Bool, _ what: String) throws -> Int {
            try XCTUnwrap(elements.firstIndex(where: matches), "\(what): \(elements)")
        }
        func index(of text: String) throws -> Int {
            try index(where: { $0.label == text || $0.value == text }, text)
        }
        let chatsTitle = try index(of: L10n.string("Chats"))
        let projectsTitle = try index(of: L10n.string("Projects"))
        let movedRow = try index(of: "OpenAI Game 2026 웹게임 완성, Codex")
        XCTAssertTrue((chatsTitle..<projectsTitle).contains(try index(of: "Plan the weekend trip, Claude Code")))
        XCTAssertGreaterThan(movedRow, projectsTitle)
        XCTAssertGreaterThan(movedRow, try index(where: { $0.label.contains("13주") }, "13주"))
        XCTAssertLessThan(movedRow, try index(where: { $0.label.contains("yardlet-sandbox") }, "yardlet-sandbox"))
    }
}
