import XCTest
@testable import NativeHarnessClient

/// A session tab paints only while a panel shows it or the agent used it recently.
@MainActor
final class BrowserHostVisibilityTests: XCTestCase {
    private final class FakeConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        func send(_ command: BrowserHostCommand) { sent.append(command) }
        func terminate() {}
    }

    private let connection = FakeConnection()

    private func makeClient(visibleWindow: Duration = .milliseconds(80)) -> BrowserHostClient {
        BrowserHostClient(idleGrace: .seconds(60), agentVisibleWindow: visibleWindow) {
            [unowned self] in self.connection
        }
    }

    private func visibility(of tab: BrowserTab) -> [Bool] {
        connection.sent.compactMap { if case .visibility(let id, let hidden) = $0, id == tab.id { hidden } else { nil } }
    }

    private func wait(_ duration: Duration) async throws { try await Task.sleep(for: duration) }

    func testAgentTabIsHiddenAfterTheAgentStopsAndShownBeforeItsNextCommand() async throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        tab.noteAgentActivity()
        XCTAssertEqual(visibility(of: tab), [], "a new tab starts shown")
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [true], "hidden once the agent is idle")

        tab.noteAgentActivity()
        tab.send(.devTools(tab: tab.id, message: "{}"))
        XCTAssertEqual(visibility(of: tab), [true, false])
        guard let shown = connection.sent.lastIndex(of: .visibility(tab: tab.id, isHidden: false)),
              let command = connection.sent.lastIndex(of: .devTools(tab: tab.id, message: "{}")) else {
            return XCTFail("missing commands")
        }
        XCTAssertLessThan(shown, command, "shown before the agent's command reaches the engine")
    }

    func testPanelKeepsTheTabShownAndClosingItHidesAnIdleTab() async throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        client.attachPanel(to: tab)
        XCTAssertEqual(visibility(of: tab), [false], "attaching asks for a fresh frame")
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [false], "a panel keeps it shown past the agent window")
        client.detachPanel(from: tab)
        XCTAssertEqual(visibility(of: tab), [false, true])
        XCTAssertFalse(tab.isClosed, "hidden, not closed: the tab stays for the grace period")
    }

    /// A task's tab lost with the host leaves its page for the panel and the agent to open again.
    func testATabLostWithTheHostLeavesItsAddressForTheNextTab() throws {
        let client = makeClient()
        let session = UUID()
        let tab = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        connection.eventHandler?(.address(tab: tab.id, url: "https://www.facebook.com/login"))
        connection.eventHandler?(.address(tab: tab.id, url: "about:blank"))
        XCTAssertEqual(client.lastAddress(forSession: session), "https://www.facebook.com/login", "about:blank is no page")
        connection.eventHandler?(.terminated(reason: "crashed"))
        XCTAssertTrue(tab.isClosed)
        XCTAssertEqual(client.lastAddress(forSession: session), "https://www.facebook.com/login", "kept when the host ends")

        _ = try client.openTab(forSession: session, url: "about:blank", viewport: .offscreenDefault)
        XCTAssertNil(client.lastAddress(forSession: session), "a new tab for the task replaces what the host lost")
    }

    func testAnOccludedPanelHidesTheTabUntilItIsOnScreenAgain() async throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        client.attachPanel(to: tab)
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [false])

        client.setPanelOccluded(true, on: tab)
        XCTAssertEqual(visibility(of: tab), [false, true], "a miniaturized or covered panel stops the painting")
        XCTAssertTrue(tab.isPanelAttached, "the panel still holds the tab")
        XCTAssertEqual(tab.visiblePanelCount, 0)

        tab.noteAgentActivity()
        XCTAssertEqual(visibility(of: tab), [false, true, false], "the agent's use shows it like a panel-less tab")
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [false, true, false, true], "and it hides again after the agent window")

        client.setPanelOccluded(false, on: tab)
        XCTAssertEqual(visibility(of: tab), [false, true, false, true, false], "back on screen: shown, with a fresh frame")
        client.detachPanel(from: tab)
        XCTAssertEqual(visibility(of: tab).last, true)
    }

    func testAPanelsOwnTabHidesAsSoonAsThePanelIsOffScreen() throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        client.attachPanel(to: tab)
        client.setPanelOccluded(true, on: tab)
        XCTAssertEqual(visibility(of: tab), [false, true], "no agent window from the opening once a panel showed it")
    }

    func testDetachingAnOccludedPanelKeepsTheCountsConsistent() async throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        client.attachPanel(to: tab)
        try await wait(.milliseconds(250))
        client.setPanelOccluded(true, on: tab)
        client.detachPanel(from: tab, occluded: true)
        XCTAssertEqual(tab.visiblePanelCount, 0)
        XCTAssertEqual(visibility(of: tab), [false, true], "no second hide for the detach")

        client.attachPanel(to: tab)
        XCTAssertEqual(tab.visiblePanelCount, 1, "a new panel starts on screen")
        XCTAssertEqual(visibility(of: tab), [false, true, false])
        client.setPanelOccluded(false, on: tab)
        XCTAssertEqual(tab.visiblePanelCount, 1, "an unmatched un-occlude changes nothing")
        client.detachPanel(from: tab)
    }

    func testAPanelAttachingToAHiddenAgentTabShowsItAgain() async throws {
        let client = makeClient()
        let tab = try client.openTab(forSession: UUID(), url: "about:blank", viewport: .offscreenDefault)
        tab.noteAgentActivity()
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [true], "hidden once the agent is idle")
        client.attachPanel(to: tab)
        XCTAssertEqual(visibility(of: tab), [true, false], "the panel shows the agent's tab and asks for a fresh frame")
        XCTAssertTrue(tab.isShown)
        XCTAssertTrue(tab.isPanelAttached)
    }

    func testTabsWithoutASessionStayShown() async throws {
        let client = makeClient()
        let tab = try client.openTab(url: "about:blank", viewport: .offscreenDefault)
        try await wait(.milliseconds(250))
        XCTAssertEqual(visibility(of: tab), [])
        tab.close()
    }
}
