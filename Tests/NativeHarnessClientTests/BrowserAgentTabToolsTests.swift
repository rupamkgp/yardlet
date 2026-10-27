import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The tab tools list, open, front and close a task's tabs, and every page tool takes the tab it acts
/// on, as the Claude app's Browser pane tools (`tabs_context`, `tabs_create`, `tabs_select`,
/// `tabs_close`, and `tabId` on the others) do.
@MainActor
final class BrowserAgentTabToolsTests: XCTestCase {
    private final class FakeHostConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        /// Answers every CDP command with an empty result, as an idle page does.
        var answersDevTools = false
        func send(_ command: BrowserHostCommand) {
            sent.append(command)
            guard answersDevTools, case .devTools(let tab, let message) = command,
                  let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                  let id = object["id"] as? Int else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.eventHandler?(.devTools(tab: tab, message: #"{"id":\#(id),"result":{}}"#)) }
            }
        }
        func terminate() {}
    }

    private let connection = FakeHostConnection()
    private var client: BrowserHostClient!
    private var tools: BrowserAgentTools!
    private let task = UUID()

    override func setUp() async throws {
        let connection = connection
        client = BrowserHostClient(idleGrace: .seconds(60)) { connection }
        let client = client!
        tools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { client })
    }

    private func run(_ tool: String, _ arguments: [String: JSONValue] = [:]) async -> AgentToolResult {
        await tools.run(tool: tool, arguments: .object(arguments), sessionID: task)
    }

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    private func listing() async throws -> JSONValue {
        let result = await run(AgentToolCatalog.tabList)
        XCTAssertFalse(result.isError)
        let json = try XCTUnwrap(text(result).split(separator: "\n").first)
        return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    func testTheCatalogOffersTheTabToolsAndATabOnEveryPageTool() {
        XCTAssertEqual(AgentToolCatalog.tabToolNames,
                       ["browser_tab_list", "browser_tab_new", "browser_tab_select", "browser_tab_close"])
        for tool in AgentToolCatalog.browserTools where !AgentToolCatalog.tabToolNames.contains(tool.name) && tool.name != AgentToolCatalog.batch {
            XCTAssertNotNil(tool.inputSchema["properties"]?["tabId"], "\(tool.name) takes a tabId")
        }
        XCTAssertTrue(AgentToolCatalog.batchableNames.contains(AgentToolCatalog.tabNew), "a batch can open and switch tabs")
        XCTAssertEqual(AgentToolCatalog.definition(named: AgentToolCatalog.tabList)?.readOnly, true)
    }

    func testListingNewSelectingAndClosingTabs() async throws {
        let empty = try await listing()
        XCTAssertEqual(empty["tabs"]?.arrayValue?.count, 0)
        let emptyText = text(await run(AgentToolCatalog.tabList))
        XCTAssertTrue(emptyText.contains("no browser tab yet"))

        // The first page tool opens the task's tab, as before.
        let first = try BrowserAgentTabs { [client] in client }.page(for: task, tabID: nil)
        connection.eventHandler?(.address(tab: first.tabID, url: "https://example.com/private/path?q=1"))

        let opened = await run(AgentToolCatalog.tabNew)
        XCTAssertFalse(opened.isError)
        XCTAssertTrue(text(opened).contains("behind the active tab"))
        let tabs = client.tabs(forSession: task)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(client.tab(forSession: task)?.id, first.tabID, "background by default")

        let list = try await listing()
        XCTAssertEqual(list["panelOpen"]?.boolValue, false)
        XCTAssertEqual(list["tabs"]?.arrayValue?.first?["origin"]?.stringValue, "https://example.com", "origin only")
        XCTAssertEqual(list["tabs"]?.arrayValue?.first?["isActive"]?.boolValue, true)
        XCTAssertEqual(list["tabs"]?.arrayValue?.last?["origin"]?.stringValue, "about:blank")
        let closedPanel = text(await run(AgentToolCatalog.tabList))
        XCTAssertTrue(closedPanel.contains("panel is closed"))

        let second = String(tabs[1].id)
        let selected = await run(AgentToolCatalog.tabSelect, ["tabId": .string(second)])
        XCTAssertFalse(selected.isError)
        XCTAssertTrue(client.tab(forSession: task) === tabs[1])

        let foreground = await run(AgentToolCatalog.tabNew, ["foreground": .bool(true)])
        XCTAssertTrue(text(foreground).contains("It is the active tab"))
        XCTAssertTrue(client.tab(forSession: task) === client.tabs(forSession: task).last)

        let closed = await run(AgentToolCatalog.tabClose, ["tabId": .string(String(client.tabs(forSession: task)[2].id))])
        XCTAssertTrue(text(closed).contains("Tab \(second) is now the active tab"), text(closed))

        let missing = await run(AgentToolCatalog.tabSelect, ["tabId": .string("999")])
        XCTAssertTrue(missing.isError)
        XCTAssertTrue(text(missing).contains("browser_tab_list"))
        let otherTasksTab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        let foreign = await run(AgentToolCatalog.tabClose, ["tabId": .string(String(otherTasksTab.id))])
        XCTAssertTrue(foreign.isError, "another task's tab is not this task's to close")
        XCTAssertFalse(otherTasksTab.isClosed)
    }

    func testAPageToolActsOnTheTabItNames() async throws {
        _ = await run(AgentToolCatalog.tabNew, ["foreground": .bool(true)])
        _ = await run(AgentToolCatalog.tabNew)
        let tabs = client.tabs(forSession: task)
        let background = tabs[1]
        connection.sent = []
        // No CDP answers come in this test; the first command (enabling Page) times out quickly.
        tools.commandTimeout = .milliseconds(50)
        _ = await run(AgentToolCatalog.navigate, ["url": .string("https://example.com"), "tabId": .string(String(background.id))])
        let devTools = connection.sent.compactMap { if case .devTools(let tab, let message) = $0 { (tab, message) } else { nil } }
        XCTAssertFalse(devTools.isEmpty)
        XCTAssertTrue(devTools.allSatisfy { $0.0 == background.id }, "the named background tab, not the active one")
        XCTAssertTrue(connection.sent.contains(.visibility(tab: background.id, isHidden: false)) || background.isShown,
                      "a background tab the agent drives paints")
    }

    func testABatchCanOpenATabAndActInIt() async throws {
        let result = await run(AgentToolCatalog.batch, ["actions": .array([
            .object(["name": .string(AgentToolCatalog.tabNew), "input": .object(["foreground": .bool(true)])]),
            .object(["name": .string(AgentToolCatalog.tabList), "input": .object([:])])
        ])])
        XCTAssertFalse(result.isError, text(result))
        XCTAssertTrue(text(result).contains("1. browser_tab_new"))
        XCTAssertTrue(text(result).contains("2. browser_tab_list"))
        XCTAssertEqual(client.tabs(forSession: task).count, 1)
    }

    func testTheTabLimitComesBackAsAToolError() async {
        for _ in 0..<BrowserHostClient.maxTabsPerSession { _ = await run(AgentToolCatalog.tabNew) }
        let tenth = await run(AgentToolCatalog.tabNew)
        XCTAssertTrue(tenth.isError)
        XCTAssertTrue(text(tenth).contains("already has 9 browser tabs"), text(tenth))
    }

    func testOriginsKeepOnlySchemeHostAndPort() {
        XCTAssertEqual(BrowserAgentTabs.origin(of: "http://localhost:3000/app?x=1"), "http://localhost:3000")
        XCTAssertEqual(BrowserAgentTabs.origin(of: "about:blank"), "about:blank")
        XCTAssertEqual(BrowserAgentTabs.origin(of: "data:text/html,hi"), "data:")
        XCTAssertEqual(BrowserAgentTabs.origin(of: "file:///Users/me/a.html"), "file:")
    }

    // MARK: Chromium's passkey dialog

    func testAToolSaysAPasskeyDialogWaitsAndTheAgentCanCloseIt() async throws {
        _ = try BrowserAgentTabs { [client] in client }.page(for: task, tabID: nil)
        connection.answersDevTools = true
        // The page asked for a passkey on this device; Chromium says there is none and waits for "Close".
        connection.eventHandler?(.chromiumWindow(isShown: true, titles: ["패스키 없음"]))
        let listed = text(await run(AgentToolCatalog.tabList))
        XCTAssertFalse(listed.contains("passkey dialog"), "the tab tools do not act on a page")
        let consoleResult = text(await run(AgentToolCatalog.consoleMessages))
        XCTAssertTrue(consoleResult.contains("passkey dialog “패스키 없음” is open"), consoleResult)
        XCTAssertTrue(consoleResult.contains("browser_handle_dialog with accept false"), consoleResult)

        let accept = await run(AgentToolCatalog.handleDialog, ["accept": .bool(true)])
        XCTAssertTrue(accept.isError, "only the person can complete a passkey request")
        XCTAssertFalse(connection.sent.contains(.closeChromiumWindows))

        let close = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)])
        XCTAssertFalse(close.isError, text(close))
        XCTAssertTrue(text(close).contains("NotAllowedError"))
        XCTAssertEqual(connection.sent.last, .closeChromiumWindows)

        connection.eventHandler?(.chromiumWindow(isShown: false, titles: nil))
        XCTAssertTrue(client.chromiumWindowTitles.isEmpty)

        // A site's sign-in window for HTTP authentication is named as one, not as a passkey dialog.
        connection.eventHandler?(.chromiumWindow(isShown: true, titles: ["로그인"], kinds: ["signIn"]))
        let signIn = text(await run(AgentToolCatalog.consoleMessages))
        XCTAssertTrue(signIn.contains("sign-in window for the site's HTTP authentication “로그인” is open"), signIn)
        XCTAssertFalse(signIn.contains("passkey"), signIn)
        connection.eventHandler?(.chromiumWindow(isShown: false, titles: nil))
        let after = await run(AgentToolCatalog.handleDialog, ["accept": .bool(false)])
        XCTAssertTrue(text(after).contains("No JavaScript dialog is open"))
    }

    // MARK: The task's page across turns

    /// A page the agent loaded is still there at its next turn: the agent idle past every window, the
    /// panel opened and closed, and the next tool call reaches the same tab without opening another.
    /// Before 2026-10-22 an unwatched tab closed five minutes and a minute after the agent's last use
    /// and the next call opened a new about:blank tab (the Meta sign-in page that "went blank").
    func testThePageTheAgentLoadedIsThereAtItsNextTurn() async throws {
        let connection = connection
        let client = BrowserHostClient(idleGrace: .milliseconds(30), agentVisibleWindow: .milliseconds(20)) { connection }
        let tabs = BrowserAgentTabs { client }
        let first = try tabs.page(for: task, tabID: nil)
        connection.eventHandler?(.address(tab: first.tabID, url: "https://www.facebook.com/login/"))
        try await Task.sleep(for: .milliseconds(200))
        let tab = try XCTUnwrap(client.tab(forSession: task))
        client.attachPanel(to: tab)
        client.detachPanel(from: tab)
        try await Task.sleep(for: .milliseconds(200))
        let opensBefore = connection.sent.filter { if case .open = $0 { true } else { false } }.count

        let next = try tabs.page(for: task, tabID: nil)
        XCTAssertTrue(next === first, "the same page object, so the same tab")
        XCTAssertEqual(client.tab(forSession: task)?.currentURL, "https://www.facebook.com/login/")
        XCTAssertFalse(tab.isClosed)
        XCTAssertEqual(connection.sent.filter { if case .open = $0 { true } else { false } }.count, opensBefore,
                       "no new tab between turns")
        XCTAssertTrue(client.isHostRunning)
    }
}
