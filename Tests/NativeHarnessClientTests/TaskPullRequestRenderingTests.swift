import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A task's pull request where Yardlet shows it, drawn without a window on screen, a provider, an
/// account, `gh` or user data: the title bar's badge in each state, the sidebar rows' quiet mark,
/// and the new-task warning about a task already running in the chosen folder — light and dark,
/// into `.build/pr-badge-qa/`.
@MainActor
final class TaskPullRequestRenderingTests: XCTestCase {
    private static let workspace = URL(filePath: "/tmp/pr-badge-qa/yardlet", directoryHint: .isDirectory)
    private static let url = URL(string: "https://github.com/example-org/yardlet/pull/123")!

    /// Each state the badge draws, named for its image row.
    static let states: [(name: String, pullRequest: TaskPullRequest)] = [
        ("no gh", .init(number: 123, url: url, repository: nil)),
        ("open", .init(number: 123, url: url, repository: nil, state: .open)),
        ("open, checks running", .init(number: 123, url: url, repository: nil, state: .open, checks: .pending)),
        ("open, checks failing", .init(number: 123, url: url, repository: nil, state: .open, checks: .failing)),
        ("changes requested", .init(number: 123, url: url, repository: nil, state: .open, checks: .passing,
                                    review: .changesRequested)),
        ("approved, checks passing", .init(number: 123, url: url, repository: nil, state: .open, checks: .passing,
                                           review: .approved)),
        ("draft, checks failing", .init(number: 123, url: url, repository: nil, state: .draft, checks: .failing)),
        ("merged", .init(number: 123, url: url, repository: nil, state: .merged, checks: .passing, review: .approved)),
        ("closed", .init(number: 123, url: url, repository: nil, state: .closed))
    ]

    private static func session(status: SessionStatus = .ready, title: String = "Show the task's pull request",
                                harness: HarnessKind = .claudeCode, in folder: URL = workspace) -> SessionRecord {
        SessionRecord(harness: harness, workspaceURL: folder, runtimeExecutableURL: URL(filePath: "/tmp/claude"),
                      title: title, titleOrigin: .provider, status: status)
    }

    func testTheTitleBarBadgeRendersInEachState() throws {
        let directory = try WindowlessRender.directory("pr-badge-qa")
        let width: CGFloat = 900
        let size = NSSize(width: width, height: ParityTheme.titleBarHeight * CGFloat(Self.states.count))
        let session = Self.session()
        for appearance in WindowlessRender.Appearance.allCases {
            let sheet = VStack(spacing: 0) {
                ForEach(Array(Self.states.enumerated()), id: \.offset) { _, state in
                    TitleBarShowcase(session: session, pullRequest: state.pullRequest)
                        .frame(width: width)
                }
            }
            .frame(width: width, height: size.height, alignment: .top)
            .background(ParityTheme.canvas)
            .environment(\.colorScheme, appearance.colorScheme)
            let capture = try WindowlessRender.hosted(sheet, size: size, appearance: appearance, passes: 4)
            try WindowlessRender.writePNG(capture.bitmap, to: directory.appending(path: "title-bar-\(appearance.suffix).png"))
        }

        // The badge is a link named for its pull request, valued with what GitHub said.
        let failing = try XCTUnwrap(Self.states.first { $0.name == "open, checks failing" }?.pullRequest)
        let host = WindowlessRender.Host(TitleBarShowcase(session: session, pullRequest: failing).frame(width: width),
                                         size: NSSize(width: width, height: ParityTheme.titleBarHeight), appearance: .light)
        defer { host.close() }
        host.settle(passes: 4)
        let elements = host.accessibilityElements()
        let badge = try XCTUnwrap(elements.first { $0.label == L10n.format("Pull request #%@", String(123)) }, "\(elements)")
        XCTAssertEqual(badge.value, [L10n.string("Pull request state open"), L10n.string("Checks failing")]
            .joined(separator: ", "))

        // No pull request, no badge.
        let none = WindowlessRender.Host(TitleBarShowcase(session: session, pullRequest: nil).frame(width: width),
                                         size: NSSize(width: width, height: ParityTheme.titleBarHeight), appearance: .light)
        defer { none.close() }
        none.settle(passes: 4)
        XCTAssertFalse(none.accessibilityElements().contains { $0.label.hasPrefix(L10n.format("Pull request #%@", String(123))) })
    }

    func testPressingTheBadgeOpensThePullRequest() throws {
        var opened: [URL] = []
        let badge = TaskPullRequestBadgeView(badge: TaskPullRequestBadge(Self.states[1].pullRequest)) { opened.append($0) }
        let host = WindowlessRender.Host(badge.padding(4), size: NSSize(width: 120, height: 30), appearance: .light)
        defer { host.close() }
        host.settle(passes: 2)
        // As an assistive app presses it; a click takes the same action.
        XCTAssertTrue(Self.press(L10n.format("Pull request #%@", String(123)), in: host.hosting))
        host.settle(passes: 2)
        XCTAssertEqual(opened, [Self.url])
    }

    /// Presses the first accessibility element under the view with this label
    /// (`CodexDirectiveRenderingTests` does the same).
    private static func press(_ label: String, in view: NSView) -> Bool {
        let attribute = "AXEnhancedUserInterface" as NSString
        let app = NSApplication.shared
        let previous = (app.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute)?
            .takeUnretainedValue() as? NSNumber)?.boolValue ?? false
        _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true),
                        with: attribute)
        defer {
            _ = app.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                            with: NSNumber(value: previous), with: attribute)
        }
        func visit(_ node: AnyObject) -> AnyObject? {
            for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                if (child.accessibilityLabel?() ?? nil) == label { return child }
                if let found = visit(child) { return found }
            }
            return nil
        }
        return visit(view)?.accessibilityPerformPress?() ?? false
    }

    /// Rows mark their pull request with the Claude app's state glyph and no number, for every state
    /// GitHub gave (2026-10-16, the person asked for no number in the list); the number stays in
    /// the row's help and accessibility value.
    func testSidebarRowsShowTheStateGlyphWithoutTheNumber() throws {
        let directory = try WindowlessRender.directory("pr-badge-qa")
        let home = URL(filePath: "/tmp/pr-badge-qa/home", directoryHint: .isDirectory)
        let projects = ProjectStore(chatWorkspaceHome: home)
        _ = projects.ensureProject(forRoot: Self.workspace)
        let rows: [(String, TaskPullRequest?)] = [
            ("Open pull request", Self.states[1].pullRequest),
            ("Draft pull request", .init(number: 98, url: Self.url, repository: nil, state: .draft)),
            ("Checks failing", .init(number: 131, url: Self.url, repository: nil, state: .open, checks: .failing)),
            ("Changes requested", .init(number: 140, url: Self.url, repository: nil, state: .open,
                                        review: .changesRequested)),
            ("Merged pull request", .init(number: 77, url: Self.url, repository: nil, state: .merged)),
            ("Closed pull request", .init(number: 60, url: Self.url, repository: nil, state: .closed)),
            ("No gh", .init(number: 55, url: Self.url, repository: nil)),
            ("No pull request", nil)
        ]
        let now = Date()
        var sessions: [SessionRecord] = []
        let monitor = TaskPullRequestMonitor()
        for (index, row) in rows.enumerated() {
            var session = Self.session(title: row.0, harness: index.isMultiple(of: 2) ? .claudeCode : .codex)
            session.updatedAt = now.addingTimeInterval(Double(-index) * 60)
            sessions.append(session)
            monitor.setPullRequest(row.1, for: session.id)
        }
        let groups = projects.visibleGroups(sessions: sessions)
        let layout = SidebarProjection.layout(visibleGroups: groups, allGroups: groups, chats: [], splits: [],
                                              isFiltering: false, selection: .session(sessions[0].id))
        let size = NSSize(width: ParityTheme.sidebarWidth, height: 470)
        for appearance in WindowlessRender.Appearance.allCases {
            let sidebar = TaskSidebar(
                layout: layout, allGroups: groups, isRestoring: false, selection: .session(sessions[0].id),
                searchText: .constant(""), onNewTask: {}, onActivate: { _ in }, onNewTaskInProject: { _ in },
                projects: projects, onEditProject: { _ in }, onArchiveProjectChats: { _ in },
                onRemoveProject: { _ in }, onTogglePinned: { _ in }, onArchive: { _ in }, onDelete: { _ in },
                onRename: { _ in }, onMarkRead: { _ in })
                .environment(monitor)
                .frame(width: size.width, height: size.height)
                .background(ParityTheme.sidebar)
                .environment(\.colorScheme, appearance.colorScheme)
            let host = WindowlessRender.Host(sidebar, size: size, appearance: appearance)
            defer { host.close() }
            host.settle(passes: 6)
            try WindowlessRender.writePNG(try host.capture().bitmap,
                                          to: directory.appending(path: "sidebar-rows-\(appearance.suffix).png"))
            guard appearance == .light else { continue }
            let values = host.accessibilityElements().map(\.value)
            for (number, shows) in [(123, true), (98, true), (131, true), (140, true), (77, true), (60, true), (55, false)] {
                let name = L10n.format("Pull request #%@", String(number))
                XCTAssertEqual(values.contains { $0.contains(name) }, shows, "#\(number): \(values)")
            }
        }
    }

    func testTheNewTaskWarningRendersBesideARunningTaskInTheChosenFolder() throws {
        let directory = try WindowlessRender.directory("pr-badge-qa")
        let root = FileManager.default.temporaryDirectory.appending(path: "pr-badge-qa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appending(path: "yardlet", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: repository.appending(path: ".git/HEAD"))
        let project = Project(name: "yardlet", primaryRoot: repository)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: testDefaultsSuite("TaskPullRequestRenderingTests")))
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        runtimes.select(URL(filePath: "/usr/bin/true"), for: .claudeCode)
        let running = Self.session(status: .running, title: "Fix the parser", in: repository)
        // The warning is now the "In this folder" row, the Claude app's first-turn line.
        let warning = L10n.string("Another session is running here")

        func host(worktree: Bool, sessions: [SessionRecord], scheme: ColorScheme) -> (WindowlessRender.Host<some View>, NewTaskDraft) {
            let draft = NewTaskDraft()
            draft.harness = .claudeCode
            draft.workspaceURL = repository
            draft.projectID = project.id
            draft.text = "Add the PR badge"
            draft.setStartsInNewWorktree(worktree, projectID: project.id)
            let view = NewTaskHome(recentSessions: [], projects: [project], draft: draft, runtimeSelections: runtimes,
                                   onSelectSession: { _ in }, onChooseWorkspace: { _ in }, onShowHarnesses: {},
                                   onCreate: { _ in nil }, activity: NewTaskHomeActivity(sessions: sessions),
                                   readFolderGit: { _ in NewTaskFolderGitState(isRepository: true, branch: "main",
                                                                               isDefaultBranch: true) })
                .frame(width: 720, height: 300)
                .background(ParityTheme.canvas)
                .environment(\.colorScheme, scheme)
            let host = WindowlessRender.Host(view, size: NSSize(width: 720, height: 300),
                                             appearance: WindowlessRender.Appearance(scheme))
            host.settle(passes: 1, interval: 0.15)
            return (host, draft)
        }
        func showsWarning(_ host: WindowlessRender.Host<some View>) -> Bool {
            host.accessibilityElements().contains { $0.label.contains(warning) || $0.value.contains(warning) }
        }

        for scheme in [ColorScheme.light, .dark] {
            let (shown, _) = host(worktree: false, sessions: [running], scheme: scheme)
            defer { shown.close() }
            try WindowlessRender.writePNG(try shown.capture().bitmap, to: directory.appending(
                path: "new-task-warning-\(WindowlessRender.Appearance(scheme).suffix).png"))
            XCTAssertTrue(showsWarning(shown), "\(shown.accessibilityElements())")
        }
        // Starting in a new worktree, or nothing running there: no warning.
        let (worktree, _) = host(worktree: true, sessions: [running], scheme: .light)
        defer { worktree.close() }
        XCTAssertFalse(showsWarning(worktree))
        var finished = running
        finished.status = .completed
        let (idle, _) = host(worktree: false, sessions: [finished], scheme: .light)
        defer { idle.close() }
        XCTAssertFalse(showsWarning(idle))
    }
}

/// The title bar as the window puts it, without an app model.
private struct TitleBarShowcase: View {
    let session: SessionRecord
    let pullRequest: TaskPullRequest?
    @State private var panels = TaskSurfaceNavigationProjection.PanelState()
    @FocusState private var focusedSurface: TaskSurface?

    var body: some View {
        HStack(spacing: 0) {
            TitleBarSidebarPart(isSidebarVisible: true, width: ParityTheme.sidebarWidth, onToggleSidebar: {},
                                onNewTask: {})
            Rectangle().fill(ParityTheme.separator).frame(width: 1)
            IntegratedTitleBar(
                session: session, isSidebarVisible: true, isAttached: true, showsSessionRail: false,
                onToggleSessionRail: {}, panelState: $panels, focusedSurface: $focusedSurface,
                onToggleSidebar: {}, onNewTask: {}, onResume: { _ in }, onRename: { _ in },
                onTogglePinned: { _ in }, onArchive: { _ in }, onBackToConversation: { _ in },
                pullRequest: pullRequest, onOpenPullRequest: { _ in }
            )
        }
    }
}
