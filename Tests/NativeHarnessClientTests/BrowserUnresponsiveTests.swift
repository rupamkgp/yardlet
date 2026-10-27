import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// A tab whose page does not respond (2026-10-23, the ERP review's tab whose renderer stayed busy):
/// Chromium's hang monitor and a DevTools call its renderer did not answer both say so, the person
/// gets Chrome's Wait and a Reload, and the agent's tools say what is known and which tools act on the tab.
@MainActor
final class BrowserUnresponsiveTests: XCTestCase {
    private final class FakeConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        /// Answers DevTools calls with an empty result, as an idle page does; a busy page answers none.
        var answers = false
        func send(_ command: BrowserHostCommand) {
            sent.append(command)
            guard answers, case .devTools(let tab, let message) = command,
                  let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
                  let id = object["id"] as? Int else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.eventHandler?(.devTools(tab: tab, message: #"{"id":\#(id),"result":{}}"#)) }
            }
        }
        func terminate() {}
    }

    private let connection = FakeConnection()
    private func makeClient() -> BrowserHostClient {
        BrowserHostClient(idleGrace: .seconds(60)) { [unowned self] in self.connection }
    }

    /// Both signals mark the page and what clears it; Wait waits and Reload replaces the tab under the
    /// same side-panel tab; the panel's header says one state, Not responding first.
    func testAPageThatDoesNotRespondUntilItAnswersAndWaitOrReloadKeepItsTab() async throws {
        let client = makeClient()
        let task = UUID()
        let workspace = TaskWorkspaceStore(browserClient: { client }).state(for: task)
        var heard = 0
        _ = client.addTabsObserver(forSession: task) { heard += 1 }
        let first = try client.newTab(forSession: task, url: "https://a.test/", viewport: .offscreenDefault, select: false)
        let stuck = try client.newTab(forSession: task, url: "https://b.test/", viewport: .offscreenDefault, select: true)
        let third = try client.newTab(forSession: task, url: "https://c.test/", viewport: .offscreenDefault, select: false)
        workspace.setPanels(TaskSurfaceNavigationProjection.showing(TaskSurfaceNavigationProjection.browserTabID(stuck.key),
                                                                    in: workspace.panels))
        let panels = workspace.panels

        // Chromium's hang monitor (read by the host), heard by the panel and the side panel's tab.
        heard = 0
        connection.eventHandler?(.responsiveness(tab: stuck.id, isResponsive: false))
        XCTAssertEqual(stuck.unresponsive, .hangMonitor)
        XCTAssertEqual(heard, 1)
        connection.eventHandler?(.responsiveness(tab: stuck.id, isResponsive: true))
        XCTAssertNil(stuck.unresponsive)

        // A call the browser answers itself says nothing of the page; one its renderer answers does,
        // until an answer comes.
        _ = try? await stuck.devTools.send("Page.navigate", ["url": .string("https://b.test/x")], timeout: .milliseconds(30))
        XCTAssertNil(stuck.unresponsive)
        _ = try? await stuck.devTools.send("Runtime.evaluate", ["expression": .string("1")], timeout: .milliseconds(30))
        XCTAssertEqual(stuck.unresponsive, .unanswered(method: "Runtime.evaluate"))
        connection.answers = true
        _ = try await stuck.devTools.send("DOM.getDocument", [:], timeout: .seconds(2))
        XCTAssertNil(stuck.unresponsive, "the page answers again")
        connection.answers = false

        // A renderer that ended crashed (a failed CHECK traps); it is no longer a page that does not
        // respond, and a load starts another renderer.
        connection.eventHandler?(.responsiveness(tab: stuck.id, isResponsive: false))
        connection.eventHandler?(.pageCrashed(tab: stuck.id, reason: "SIGTRAP", status: "crashed", code: 5))
        XCTAssertNil(stuck.unresponsive)
        XCTAssertEqual(stuck.crash, BrowserTabCrash(status: "crashed", code: 5, errorCode: "SIGTRAP"))
        connection.eventHandler?(.loading(tab: stuck.id, isLoading: true, canGoBack: true, canGoForward: false))
        XCTAssertNil(stuck.crash)

        // Wait tells the hang monitor and hides it for 15 seconds, as Chrome's Wait.
        connection.eventHandler?(.responsiveness(tab: stuck.id, isResponsive: false))
        connection.sent = []
        client.waitForPage(stuck)
        XCTAssertEqual(connection.sent, [.unresponsive(tab: stuck.id, action: .wait)])
        XCTAssertNil(stuck.unresponsive)

        // Reload: the renderer the hang monitor holds ends, and the tab opens again in its place, in
        // front, under the same side-panel tab, and is no closed tab to reopen.
        connection.eventHandler?(.responsiveness(tab: stuck.id, isResponsive: false))
        connection.sent = []
        let replacement = try client.replace(stuck, url: "https://b.test/")
        XCTAssertEqual(connection.sent.prefix(2), [.unresponsive(tab: stuck.id, action: .terminate), .close(tab: stuck.id)])
        XCTAssertTrue(stuck.isClosed)
        XCTAssertEqual(replacement.key, stuck.key)
        XCTAssertEqual(client.tabs(forSession: task).map(\.id), [first.id, replacement.id, third.id])
        XCTAssertTrue(client.tab(forSession: task) === replacement)
        XCTAssertEqual(workspace.panels, panels)
        XCTAssertNil(try client.reopenClosedTab(forSession: task, viewport: .offscreenDefault))

        // The header's one state.
        typealias Pane = BrowserHostPaneController
        XCTAssertEqual(Pane.status(isUnresponsive: true, isCrashed: true, hasError: true, isLoading: true, hasTab: true),
                       L10n.string("Not responding"))
        XCTAssertEqual(Pane.status(isUnresponsive: false, isCrashed: true, hasError: true, isLoading: true, hasTab: true),
                       L10n.string("Crashed"))
        XCTAssertEqual(Pane.status(isUnresponsive: false, hasError: true, isLoading: true, hasTab: true), L10n.string("Unavailable"))
        XCTAssertEqual(Pane.status(isUnresponsive: false, hasError: false, isLoading: true, hasTab: true), L10n.string("Loading"))
        XCTAssertEqual(Pane.status(isUnresponsive: false, hasError: false, isLoading: false, hasTab: true), L10n.string("Ready"))
        XCTAssertNil(Pane.status(isUnresponsive: false, hasError: false, isLoading: false, hasTab: false))
    }

    func testTheAgentHearsItsTabIsNotRespondingAndBrowserNavigateOpensItAgain() async throws {
        let client = makeClient()
        let task = UUID()
        let tools = BrowserAgentTools(usesMacEditingCommands: true, tabs: BrowserAgentTabs { client })
        tools.commandTimeout = .milliseconds(80)
        tools.loadTimeout = .milliseconds(120)
        func text(_ result: AgentToolResult) -> String {
            result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
        }

        // The page's main thread is busy: nothing it runs answers.
        let busy = await tools.run(tool: AgentToolCatalog.evaluate, arguments: .object(["function": .string("() => 1")]),
                                   sessionID: task)
        let tab = try XCTUnwrap(client.tab(forSession: task))
        XCTAssertTrue(busy.isError)
        XCTAssertTrue(text(busy).contains("This tab's page is not responding: its renderer did not answer Page.enable in time"),
                      text(busy))
        XCTAssertTrue(text(busy).contains("browser_navigate opens a page again in its place; browser_tab_close closes the tab."))
        XCTAssertFalse(text(busy).localizedCaseInsensitiveContains("should"), "facts and tools, no instructions")
        let listing = text(await tools.run(tool: AgentToolCatalog.tabList, arguments: .object([:]), sessionID: task))
        XCTAssertTrue(listing.contains(#""responding":false"#), listing)
        XCTAssertTrue(listing.contains("Not responding: tab \(tab.id)"), listing)

        // browser_navigate opens the page again in the stuck one's place.
        connection.answers = true
        let moved = await tools.run(tool: AgentToolCatalog.navigate, arguments: .object(["url": .string("https://app.test/")]),
                                    sessionID: task)
        let replacement = try XCTUnwrap(client.tab(forSession: task))
        XCTAssertFalse(replacement === tab)
        XCTAssertEqual(replacement.key, tab.key)
        XCTAssertTrue(text(moved).hasPrefix("Tab \(tab.id)'s page was not responding"), text(moved))
        XCTAssertTrue(text(moved).contains(#"as tabId "\#(replacement.id)""#))
        let after = text(await tools.run(tool: AgentToolCatalog.tabList, arguments: .object([:]), sessionID: task))
        XCTAssertTrue(after.contains(#""responding":true"#), after)
        XCTAssertFalse(after.contains("Not responding"))

        // Its renderer ends: the same facts, the error code and the same tools.
        connection.eventHandler?(.pageCrashed(tab: replacement.id, reason: "SIGTRAP", status: "crashed", code: 5))
        let crashed = text(await tools.run(tool: AgentToolCatalog.evaluate, arguments: .object(["function": .string("() => 1")]),
                                           sessionID: task))
        XCTAssertTrue(crashed.contains("This tab's page crashed: its renderer ended (error code SIGTRAP)."), crashed)
        XCTAssertFalse(crashed.localizedCaseInsensitiveContains("should"))
        let crashList = text(await tools.run(tool: AgentToolCatalog.tabList, arguments: .object([:]), sessionID: task))
        XCTAssertTrue(crashList.contains("Crashed: tab \(replacement.id) (SIGTRAP)"), crashList)
        XCTAssertFalse(crashList.contains("Not responding"))
    }
}
