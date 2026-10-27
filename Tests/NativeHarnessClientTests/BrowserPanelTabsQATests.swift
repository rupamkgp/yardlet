import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Each browser tab a tab of the task's side panel, in the whole main window with the CEF panel's own
/// views over a stand-in browser host (no Chromium: pages are the host's events, frames none), light
/// and dark, into `.build/browser-panel-tabs-qa/<phase>/` (`BROWSER_PANEL_TABS_QA_PHASE`, "after" by
/// default), with what the strip shows at each step (`report.md`). Buttons are pressed through
/// accessibility and keys go to the page as the keyboard sends them.
@MainActor
final class BrowserPanelTabsQATests: XCTestCase {
    private typealias Navigation = TaskSurfaceNavigationProjection
    private static let size = NSSize(width: 1280, height: 760)
    private static var folder: String {
        "browser-panel-tabs-qa/" + (ProcessInfo.processInfo.environment["BROWSER_PANEL_TABS_QA_PHASE"] ?? "after")
    }

    /// The browser host as the panel sees it: tabs open, and the test reports their pages.
    private final class StandInHost: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        func send(_ command: BrowserHostCommand) {
            sent.append(command)
            // A person's close asks the page first (2026-10-25); these pages do not ask, so the host closes the
            // tab and says so, as Chromium does.
            if case .requestClose(let tab) = command {
                DispatchQueue.main.async { self.eventHandler?(.closed(tab: tab)) }
            }
        }
        func terminate() { eventHandler?(.terminated(reason: "signal 15")) }

        var opened: [(tab: BrowserTabID, url: String)] {
            sent.compactMap { if case .open(let tab, let url, _, _) = $0 { (tab, url) } else { nil } }
        }
        /// The tabs asked to close, once each: a person's close is a request, and the client's own close
        /// follows when the host says the tab closed.
        var closed: [BrowserTabID] {
            var seen = Set<BrowserTabID>()
            return sent.compactMap {
                switch $0 {
                case .close(let tab), .requestClose(let tab): seen.insert(tab).inserted ? tab : nil
                default: nil
                }
            }
        }

        func load(_ tab: BrowserTabID, _ url: String, title: String, icon: Data? = nil) {
            eventHandler?(.loading(tab: tab, isLoading: true, canGoBack: false, canGoForward: false))
            eventHandler?(.address(tab: tab, url: url))
            eventHandler?(.title(tab: tab, title: title))
            if let icon { eventHandler?(.favicon(tab: tab, url: url + "icon.png", png: icon)) }
            eventHandler?(.loading(tab: tab, isLoading: false, canGoBack: false, canGoForward: false))
        }
    }

    private struct Fixture {
        let model: AppModel
        let task: SessionRecord
        let legacy: SessionRecord
        let host: () -> StandInHost?
        let client: BrowserHostClient
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "yardlet-browser-panel-tabs-\(UUID().uuidString)")
        let folder = root.appending(path: "yardlet")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = testDefaultsSuite("BrowserPanelTabsQA")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cli = root.appending(path: "codex")
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path(percentEncoded: false))
        let task = SessionRecord(harness: .codex, workspaceURL: folder, runtimeExecutableURL: cli,
                                 title: "로그인 화면 고치기")
        let legacy = SessionRecord(harness: .claudeCode, workspaceURL: folder, runtimeExecutableURL: cli,
                                   title: "이전 빌드에서 연 브라우저 탭")
        let sessions = [task, legacy]
        // A task saved by a build before side-panel browser tabs: one Browser tab holding three.
        defaults.set(Data(#"""
        {"version":1,"panelsRevision":2,
         "panels":{"trailingSurfaceID":"browser","isTerminalPresented":false,
                   "trailingTabs":["browser"],"recentTrailingTabs":["browser"]},
         "layout":{"panelWidth":420,"terminalHeight":280,"isExpanded":false},
         "transcript":{"fraction":0,"followsLatest":true},"codex":{"fraction":0,"followsLatest":true},
         "browser":{"address":"http://localhost:3000/","tabs":["https://docs.test/","http://localhost:3000/","https://status.test/"],"selectedTab":1}}
        """#.utf8), forKey: "Yardlet.taskWorkspace.\(legacy.id.uuidString)")
        var host: StandInHost?
        let client = BrowserHostClient(idleGrace: .seconds(60)) {
            let started = StandInHost()
            host = started
            return started
        }
        let model = AppModel(
            store: SessionStore(sessions: sessions, repository: InMemorySessionRepository(sessions: sessions)),
            runtimeSelections: RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false),
            registry: HarnessRegistry { _, _ in Recorder() },
            codexQueueRepository: UserDefaultsCodexQueueRepository(defaults: defaults, keyPrefix: "queue."),
            preferences: defaults,
            codexPendingRequestRepository: UserDefaultsCodexPendingServerRequestRepository(defaults: defaults),
            codexTimelineItemRepository: UserDefaultsCodexTimelineItemRepository(defaults: defaults),
            codexHistorySelectionRepository: UserDefaultsCodexHistorySelectionRepository(defaults: defaults,
                                                                                         keyPrefix: "history."),
            transcriptRepository: FileTranscriptRepository(directoryURL: root.appending(path: "transcripts")),
            taskWorkspaceRepository: UserDefaultsTaskWorkspaceRepository(defaults: defaults),
            sessionTitleResolver: { _ in nil },
            sessionTitleRetryCount: 0,
            restoresIndexOnLaunch: false,
            browserClient: { client }
        )
        addTeardownBlock { await model.shutdown() }
        _ = model.projects.ensureProject(forRoot: folder)
        return Fixture(model: model, task: task, legacy: legacy, host: { host }, client: client)
    }

    private func window(_ fixture: Fixture, _ appearance: WindowlessRender.Appearance) -> some View {
        MainWindow(model: fixture.model)
            .frame(width: Self.size.width, height: Self.size.height)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    // MARK: - Accessibility and keys

    private struct Control {
        let role: String
        let label: String
        let frame: NSRect
        let object: AnyObject
    }

    private static func withEnhancedInterface<T>(_ body: () -> T) -> T {
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
        return body()
    }

    private func controls<Content: View>(in host: WindowlessRender.Host<Content>) -> [Control] {
        host.hosting.layoutSubtreeIfNeeded()
        let windowFrame = host.window.frame
        return Self.withEnhancedInterface {
            var found: [Control] = []
            var visited = Set<ObjectIdentifier>()
            func visit(_ node: AnyObject) {
                for case let child as AnyObject in (node.accessibilityChildren?() ?? nil) ?? [] {
                    guard visited.insert(ObjectIdentifier(child)).inserted else { continue }
                    if let role = child.accessibilityRole?() ?? nil,
                       [.button, .menuButton, .popUpButton].contains(role) {
                        let screen = child.accessibilityFrame?() ?? .zero
                        let frame = NSRect(x: screen.minX - windowFrame.minX, y: windowFrame.maxY - screen.maxY,
                                           width: screen.width, height: screen.height)
                        if frame.height > 0 {
                            found.append(Control(role: role.rawValue, label: (child.accessibilityLabel?() ?? nil) ?? "",
                                                 frame: frame, object: child))
                        }
                    }
                    visit(child)
                }
            }
            visit(host.hosting)
            return found
        }
    }

    /// The side panel's tab strip: its buttons in the title bar's row, which the panel reaches since the
    /// one-row header (2026-10-24), right of the conversation, left to right.
    private func strip<Content: View>(in host: WindowlessRender.Host<Content>) -> [Control] {
        controls(in: host)
            .filter { $0.frame.maxY <= ParityTheme.titleBarHeight && $0.frame.minX > Self.size.width / 2 }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    @discardableResult
    private func press<Content: View>(_ label: String, in host: WindowlessRender.Host<Content>,
                                      among pool: [Control]? = nil) -> Bool {
        guard let control = (pool ?? controls(in: host)).first(where: { $0.label == label }) else { return false }
        let pressed = Self.withEnhancedInterface { control.object.accessibilityPerformPress?() ?? false }
        host.settle(passes: 12, interval: 0.03)
        return pressed
    }

    private func orderIn<Content: View>(_ host: WindowlessRender.Host<Content>) {
        host.window.alphaValue = 0
        host.window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        host.window.orderFrontRegardless()
        host.settle(passes: 10, interval: 0.03)
    }

    private func browserView(in view: NSView) -> BrowserHostView? {
        if let view = view as? BrowserHostView { return view }
        for subview in view.subviews {
            if let found = browserView(in: subview) { return found }
        }
        return nil
    }

    /// A key on the page, as the keyboard sends it: the page has the keyboard, so the panel's page keys
    /// go first.
    @discardableResult
    private func pageKey<Content: View>(_ character: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16,
                                        in host: WindowlessRender.Host<Content>) -> Bool {
        guard let page = browserView(in: host.hosting) else { return false }
        host.window.makeFirstResponder(page)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: host.window.windowNumber, context: nil,
                                           characters: character, charactersIgnoringModifiers: character,
                                           isARepeat: false, keyCode: keyCode) else { return false }
        let handled = host.window.performKeyEquivalent(with: event)
        host.settle(passes: 12, interval: 0.03)
        return handled
    }

    private func waitUntil<Content: View>(_ host: WindowlessRender.Host<Content>, _ condition: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            host.settle(passes: 1, interval: 0.03)
        }
        return condition()
    }

    // MARK: - Report

    private var report: [String] = []
    private var recordsReport = true

    private func describe(_ state: String, _ controls: [Control], notes: [String] = []) {
        guard recordsReport else { return }
        report.append("## \(state)")
        report.append("")
        report.append(contentsOf: controls.isEmpty ? ["- (버튼 없음)"]
                      : controls.map { "- \($0.label.isEmpty ? "(이름 없음)" : $0.label) [\($0.role)]" })
        for note in notes { report.append("- 확인: \(note)") }
        report.append("")
    }

    private func draw<Content: View>(_ host: WindowlessRender.Host<Content>, _ name: String,
                                     _ appearance: WindowlessRender.Appearance) throws {
        let directory = try WindowlessRender.directory(Self.folder)
        try WindowlessRender.writePNG(host.capture().bitmap,
                                      to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
    }

    // MARK: - States

    func testEachBrowserTabIsASidePanelTab() throws {
        for appearance in [WindowlessRender.Appearance.light, .dark] {
            recordsReport = appearance == .light
            try browserTabs(appearance)
        }
        let directory = try WindowlessRender.directory(Self.folder)
        try (["# 오른쪽 패널의 브라우저 탭", ""] + report).joined(separator: "\n")
            .write(to: directory.appending(path: "report.md"), atomically: true, encoding: .utf8)
    }

    /// A page that does not respond (Chromium's hang monitor, read by the host): Chrome's "Page
    /// Unresponsive" with Wait and Reload over the page, "Not responding" first in the header; Wait waits,
    /// Reload opens the page again in its place under the same side-panel tab.
    func testAPageThatDoesNotRespond() throws {
        for appearance in [WindowlessRender.Appearance.light, .dark] {
            let fixture = try makeFixture()
            let model = fixture.model
            let client = fixture.client
            let task = fixture.task
            let workspace = model.taskWorkspaces.state(for: task.id)
            model.splits.activate(.session(task.id))
            let host = WindowlessRender.Host(window(fixture, appearance), size: Self.size, appearance: appearance)
            orderIn(host)
            defer { host.close() }
            XCTAssertTrue(press(TaskCommandTitle.sidePanel(isShown: false), in: host))
            XCTAssertTrue(press(L10n.string("Browser"), in: host))
            let key = try XCTUnwrap(Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID))
            XCTAssertTrue(waitUntil(host) { client.tab(key: key, forSession: task.id) != nil })
            let tab = try XCTUnwrap(client.tab(key: key, forSession: task.id))
            let standIn = try XCTUnwrap(fixture.host())
            standIn.load(tab.id, "http://localhost:3100/erp/review", title: "ERPNext 검토")
            host.settle(passes: 8, interval: 0.03)

            // The page keeps its size through a load, a notice and the bar: each resize lays it out again.
            func resizes() -> Int { standIn.sent.filter { if case .resize = $0 { true } else { false } }.count }
            let resized = resizes()
            standIn.eventHandler?(.loading(tab: tab.id, isLoading: true, canGoBack: false, canGoForward: false))
            host.settle(passes: 6, interval: 0.03)
            standIn.eventHandler?(.loading(tab: tab.id, isLoading: false, canGoBack: false, canGoForward: false))
            standIn.eventHandler?(.navigationBlocked(tab: tab.id, url: "x-other://open"))
            host.settle(passes: 6, interval: 0.03)

            standIn.eventHandler?(.responsiveness(tab: tab.id, isResponsive: false))
            host.settle(passes: 10, interval: 0.03)
            func barButton(_ label: String) -> Control? {
                controls(in: host).filter { $0.label == label }.max { $0.frame.minY < $1.frame.minY }
            }
            XCTAssertNotNil(barButton(L10n.string("Wait")), "Chrome's Wait")
            try draw(host, "page-unresponsive", appearance)

            let wait = try XCTUnwrap(barButton(L10n.string("Wait")))
            let sentBefore = standIn.sent.count
            XCTAssertTrue(Self.withEnhancedInterface { wait.object.accessibilityPerformPress?() ?? false })
            host.settle(passes: 10, interval: 0.03)
            XCTAssertEqual(standIn.sent.dropFirst(sentBefore).last, .unresponsive(tab: tab.id, action: .wait))
            XCTAssertNil(barButton(L10n.string("Wait")), "Wait hides it for 15 seconds")
            XCTAssertEqual(resizes(), resized, "before, the loading row, the notice and the bar each resized the page")

            standIn.eventHandler?(.responsiveness(tab: tab.id, isResponsive: true))
            standIn.eventHandler?(.responsiveness(tab: tab.id, isResponsive: false))
            host.settle(passes: 10, interval: 0.03)
            let reload = try XCTUnwrap(barButton(L10n.string("Reload")))
            XCTAssertTrue(Self.withEnhancedInterface { reload.object.accessibilityPerformPress?() ?? false })
            host.settle(passes: 12, interval: 0.03)
            let replacement = try XCTUnwrap(client.tab(key: key, forSession: task.id))
            XCTAssertFalse(replacement === tab, "the stuck page's tab was replaced")
            XCTAssertTrue(standIn.closed.contains(tab.id))
            XCTAssertEqual(standIn.opened.last?.url, "http://localhost:3100/erp/review")
            XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(key), "the same side-panel tab")
            XCTAssertNil(barButton(L10n.string("Wait")))
            standIn.load(replacement.id, "http://localhost:3100/erp/review", title: "ERPNext 검토")
            host.settle(passes: 8, interval: 0.03)
            try draw(host, "page-reloaded", appearance)
        }
    }

    private func browserTabs(_ appearance: WindowlessRender.Appearance) throws {
        let fixture = try makeFixture()
        let model = fixture.model
        let client = fixture.client
        let task = fixture.task
        let workspace = model.taskWorkspaces.state(for: task.id)
        let browserTitle = L10n.string("Browser")
        let blue = BrowserPanelTabsTests.icon(.systemBlue)
        let green = BrowserPanelTabsTests.icon(.systemGreen)

        model.splits.activate(.session(task.id))
        let host = WindowlessRender.Host(window(fixture, appearance), size: Self.size, appearance: appearance)
        orderIn(host)
        defer { host.close() }

        // The launcher, then its Browser: a new browser tab, its address field ready.
        XCTAssertTrue(press(TaskCommandTitle.sidePanel(isShown: false), in: host))
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.launcherID)
        XCTAssertTrue(press(browserTitle, in: host), "the launcher's Browser")
        let first = try XCTUnwrap(Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID))
        XCTAssertTrue(waitUntil(host) { client.tab(key: first, forSession: task.id) != nil }, "the pane opened it")
        let firstTab = try XCTUnwrap(client.tab(key: first, forSession: task.id))
        let standIn = try XCTUnwrap(fixture.host())
        XCTAssertEqual(standIn.opened.last?.url, "about:blank")
        try draw(host, "new-tab", appearance)
        describe("런처의 브라우저 → 새 탭", strip(in: host), notes: [
            "패널 탭 \(workspace.panels.trailingTabs.count)개, 보이는 탭 = 새 브라우저 탭, 엔진 탭 about:blank"
        ])
        standIn.load(firstTab.id, "http://localhost:3000/", title: "Login — Dev")
        host.settle(passes: 10, interval: 0.03)

        // The launcher's Browser always opens another one (the Codex app's); so does ⌘T on the page.
        XCTAssertTrue(pageKey("t", .command, keyCode: 17, in: host), "⌘T on the page")
        let second = try XCTUnwrap(Navigation.browserKey(inTab: workspace.panels.trailingSurfaceID))
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(waitUntil(host) { client.tab(key: second, forSession: task.id) != nil })
        let secondTab = try XCTUnwrap(client.tab(key: second, forSession: task.id))
        standIn.load(secondTab.id, "https://docs.test/", title: "Docs", icon: blue)

        // The agent opens a tab behind (browser_tab_new): it joins the strip; the panel keeps its tab.
        let agentTab = try client.newTab(forSession: task.id, url: "https://status.test/", viewport: .offscreenDefault,
                                         select: false)
        standIn.load(agentTab.id, "https://status.test/", title: "Status", icon: green)
        host.settle(passes: 12, interval: 0.03)
        XCTAssertEqual(Navigation.browserKeys(in: workspace.panels), [first, second, agentTab.key])
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(second))
        let threeTabs = strip(in: host)
        XCTAssertTrue(threeTabs.contains { $0.label == "Login — Dev" }, "\(threeTabs.map(\.label))")
        XCTAssertTrue(threeTabs.contains { $0.label == "Status" })
        try draw(host, "three-tabs", appearance)
        describe("브라우저 탭 셋(⌘T로 하나, 에이전트가 뒤에 하나)", threeTabs, notes: [
            "패널 탭: \(Navigation.browserKeys(in: workspace.panels).map { TaskSidePanelTabs.browserTab($0, in: workspace.browserTabs).title })",
            "보이는 탭 Docs(파비콘 파랑), 에이전트 탭 Status(파비콘 초록)는 뒤에, 브라우저 칸 안 탭 줄 없음"
        ])

        // A background tab pressed in the strip shows; the engine fronts it for the agent's tools.
        XCTAssertTrue(press("Login — Dev", in: host, among: threeTabs))
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(first))
        XCTAssertTrue(client.tab(forSession: task.id) === firstTab)
        try draw(host, "background-tab-pressed", appearance)
        describe("배경 탭 'Login — Dev' 누름", strip(in: host), notes: [
            "보이는 탭 = Login — Dev, 엔진의 앞 탭도 같은 탭(에이전트 도구의 기본 탭)"
        ])

        // ⌃Tab and ⌃⇧Tab on the page go to the next and previous browser tab, ⌘9 to the last. (⌘1–⌘4
        // stay the window's: the task's panels, as before.)
        XCTAssertTrue(pageKey("\t", .control, keyCode: 48, in: host), "⌃Tab")
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(second))
        XCTAssertTrue(pageKey("9", .command, keyCode: 25, in: host), "⌘9")
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(agentTab.key))
        XCTAssertTrue(pageKey("\t", [.control, .shift], keyCode: 48, in: host), "⌃⇧Tab")
        XCTAssertTrue(pageKey("\t", [.control, .shift], keyCode: 48, in: host), "⌃⇧Tab")
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(first))

        // The agent fronts its tab (browser_tab_select): the panel, on a browser tab, shows it.
        agentTab.select()
        host.settle(passes: 10, interval: 0.03)
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(agentTab.key))
        try draw(host, "agent-fronted", appearance)

        // ⌘W on the page closes its tab and its page; the panel goes to the tab used before.
        XCTAssertTrue(pageKey("w", .command, keyCode: 13, in: host), "⌘W on the page")
        XCTAssertEqual(standIn.closed, [agentTab.id])
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(first))
        XCTAssertEqual(Navigation.browserKeys(in: workspace.panels), [first, second])

        // ⌘⇧T opens it again as a new tab, shown.
        XCTAssertTrue(pageKey("t", [.command, .shift], keyCode: 17, in: host), "⌘⇧T")
        let reopened = try XCTUnwrap(client.tab(forSession: task.id))
        XCTAssertEqual(standIn.opened.last?.url, "https://status.test/")
        XCTAssertEqual(workspace.panels.trailingSurfaceID, Navigation.browserTabID(reopened.key))

        // Review beside them; closing the browser tabs one by one leaves Review shown, not a hidden panel.
        workspace.setPanels(Navigation.showing("diff", in: workspace.panels))
        host.settle(passes: 10, interval: 0.03)
        for key in Navigation.browserKeys(in: workspace.panels) {
            workspace.setPanels(Navigation.showing(Navigation.browserTabID(key), in: workspace.panels))
            host.settle(passes: 10, interval: 0.03)
            let shownStrip = strip(in: host)
            XCTAssertTrue(press(L10n.string("Close tab"), in: host, among: shownStrip), "the shown tab's close")
        }
        XCTAssertEqual(workspace.panels.trailingTabs, ["diff"])
        XCTAssertEqual(workspace.panels.trailingSurfaceID, "diff", "the panel stays with Review")
        XCTAssertTrue(client.tabs(forSession: task.id).isEmpty, "each tab's page closed with it")
        try draw(host, "browser-tabs-closed", appearance)
        describe("브라우저 탭을 모두 닫음(검토 남음)", strip(in: host), notes: [
            "패널은 숨지 않고 검토를 보임, 엔진 탭 0개, 닫은 엔진 탭 \(standIn.closed.count)개"
        ])

        // A task a build before saved with one Browser tab of three: three tabs, the front one shown; it
        // opens with the others, under their keys.
        model.splits.activate(.session(fixture.legacy.id))
        host.settle(passes: 20, interval: 0.03)
        let legacy = model.taskWorkspaces.state(for: fixture.legacy.id)
        let legacyKeys = Navigation.browserKeys(in: legacy.panels)
        XCTAssertEqual(legacyKeys.count, 3)
        XCTAssertEqual(legacy.panels.trailingSurfaceID, Navigation.browserTabID(legacyKeys[1]))
        XCTAssertTrue(waitUntil(host) { client.tabs(forSession: fixture.legacy.id).count == 3 })
        XCTAssertEqual(client.tabs(forSession: fixture.legacy.id).map(\.key), legacyKeys)
        XCTAssertEqual(client.tab(forSession: fixture.legacy.id)?.key, legacyKeys[1])
        let legacyStrip = strip(in: host)
        try draw(host, "migrated", appearance)
        describe("이전 빌드의 '브라우저' 탭 하나(브라우저 탭 셋)", legacyStrip, notes: [
            "패널 탭 셋으로, 앞 탭(localhost:3000)이 보임, 셋이 같은 키로 함께 열림"
        ])
    }

    /// A Claude adapter that starts sessions and sends nothing.
    private actor Recorder: HarnessAdapter {
        nonisolated let kind = HarnessKind.claudeCode
        func probeRuntime() async throws -> HarnessRuntimeDescriptor {
            HarnessRuntimeDescriptor(harness: kind, executableURL: URL(filePath: "/tmp/stub"), version: "stub",
                                     capabilities: .unavailable, fingerprint: "stub")
        }
        func createSession(_ request: CreateHarnessSessionRequest) async throws -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: request.localSessionID,
                                 providerSessionID: UUID().uuidString, workspaceURL: request.workspaceURL)
        }
        func resumeSession(providerSessionID: String, localSessionID: UUID, workspaceURL: URL) async throws
            -> HarnessSessionHandle {
            HarnessSessionHandle(harness: kind, localSessionID: localSessionID, providerSessionID: providerSessionID,
                                 workspaceURL: workspaceURL)
        }
        func send(_ prompt: String, to session: HarnessSessionHandle) async throws {}
        func interrupt(_ session: HarnessSessionHandle) async throws {}
        func respond(to permissionRequestID: String, decision: PermissionDecision, in session: HarnessSessionHandle)
            async throws {}
        /// Open until the task closes, as a live harness's are: a finished stream reads as a lost connection.
        private var streams: [AsyncStream<HarnessEventEnvelope>.Continuation] = []
        func events(for session: HarnessSessionHandle) async -> AsyncStream<HarnessEventEnvelope> {
            let (stream, continuation) = AsyncStream<HarnessEventEnvelope>.makeStream()
            streams.append(continuation)
            return stream
        }
        func close(_ session: HarnessSessionHandle) async {
            streams.forEach { $0.finish() }
            streams.removeAll()
        }
    }
}
