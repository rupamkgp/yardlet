import AppKit
import XCTest
@testable import NativeHarnessClient

/// "Unavailable" and the error card belong to the tab on screen and to the move that failed, and go
/// once a page commits (2026-10-23, a report of "Unavailable" staying while moving between pages).
/// The host's events are played to the panel's controller as Chromium sends them.
@MainActor
final class BrowserLoadErrorTests: XCTestCase {
    private final class FakeConnection: BrowserHostConnection {
        var eventHandler: ((BrowserHostEvent) -> Void)?
        var sent: [BrowserHostCommand] = []
        func send(_ command: BrowserHostCommand) { sent.append(command) }
        func terminate() {}
    }

    private let connection = FakeConnection()
    private var window: NSWindow?

    private func makePane() throws -> (BrowserHostPaneController, BrowserTab, BrowserHostClient) {
        let client = BrowserHostClient(idleGrace: .seconds(60)) { [unowned self] in self.connection }
        let task = UUID()
        let workspace = TaskWorkspaceStore(browserClient: { client }).state(for: task)
        let key = try XCTUnwrap(workspace.openBrowserTab(address: "https://app.test/"))
        let controller = BrowserHostPaneController(session: task, key: key, workspace: workspace, client: client)
        let view = BrowserHostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        self.window = window
        controller.attach(view)
        let tab = try XCTUnwrap(client.tab(key: key, forSession: task))
        XCTAssertTrue(controller.tab === tab)
        page(tab, "https://app.test/")
        return (controller, tab, client)
    }

    private func send(_ event: BrowserHostEvent) { connection.eventHandler?(event) }

    /// A page that loaded.
    private func page(_ tab: BrowserTab, _ url: String) {
        send(.loading(tab: tab.id, isLoading: true, canGoBack: true, canGoForward: false))
        send(.address(tab: tab.id, url: url))
        send(.loadEnd(tab: tab.id, url: url, status: 200))
        send(.loading(tab: tab.id, isLoading: false, canGoBack: true, canGoForward: false))
    }

    /// An error shows from the moment its failed address commits until a page commits elsewhere, in the
    /// order CEF 154 reports them (seen in the QA bundle's load-errors check).
    func testAnErrorShowsFromItsCommitUntilAPageCommitsElsewhere() throws {
        let (controller, tab, _) = try makePane()

        // An error arriving once nothing loads belongs to a move already replaced: dropped.
        page(tab, "https://app.test/second")
        send(.loadError(tab: tab.id, url: "https://app.test/first", code: -2, message: "net::ERR_FAILED"))
        send(.address(tab: tab.id, url: "https://app.test/first"))
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.notice)

        // A move that fails before committing (a refused scheme, a 204) leaves the page that works, with
        // a notice and no card over it.
        send(.loading(tab: tab.id, isLoading: true, canGoBack: true, canGoForward: false))
        send(.loadError(tab: tab.id, url: "x-other://open", code: -302, message: "net::ERR_UNKNOWN_URL_SCHEME"))
        send(.loading(tab: tab.id, isLoading: false, canGoBack: true, canGoForward: false))
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(controller.notice, L10n.format("Could not open %@.", "x-other://open"))

        // A refused port: no address change, the error page's load end without a status, then the error
        // page's own load, aborted, which before 2026-10-23 cleared the real failure.
        let failed = "http://127.0.0.1:9/"
        send(.loading(tab: tab.id, isLoading: true, canGoBack: true, canGoForward: false))
        send(.loadError(tab: tab.id, url: failed, code: -312, message: "net::ERR_UNSAFE_PORT"))
        send(.loadEnd(tab: tab.id, url: failed, status: 0))
        send(.loading(tab: tab.id, isLoading: false, canGoBack: true, canGoForward: false))
        XCTAssertNotNil(controller.errorMessage)
        send(.loading(tab: tab.id, isLoading: true, canGoBack: true, canGoForward: false))
        send(.loadError(tab: tab.id, url: failed, code: -3, message: "net::ERR_ABORTED"))
        send(.loading(tab: tab.id, isLoading: false, canGoBack: true, canGoForward: false))
        XCTAssertNotNil(controller.errorMessage, "the error page's own load keeps it")
        send(.loading(tab: tab.id, isLoading: true, canGoBack: true, canGoForward: false))
        send(.loadEnd(tab: tab.id, url: failed, status: 200))
        XCTAssertNil(controller.errorMessage, "the server answers again")

        // The error page commits at its address; the same page (a fragment, a trailing slash) keeps it,
        // and a page committing elsewhere clears it, also history.pushState, which does not load.
        send(.loading(tab: tab.id, isLoading: true, canGoBack: true, canGoForward: false))
        send(.loadError(tab: tab.id, url: "http://localhost:5173/chats", code: -102, message: "net::ERR_CONNECTION_REFUSED"))
        XCTAssertNil(controller.errorMessage, "not before the failed page commits")
        send(.address(tab: tab.id, url: "http://localhost:5173/chats"))
        send(.loading(tab: tab.id, isLoading: false, canGoBack: true, canGoForward: false))
        XCTAssertNotNil(controller.errorMessage)
        send(.address(tab: tab.id, url: "http://localhost:5173/chats/#top"))
        XCTAssertNotNil(controller.errorMessage, "the same page")
        send(.address(tab: tab.id, url: "http://localhost:5173/chats/2"))
        XCTAssertNil(controller.errorMessage, "pushState to another address")

        // The address first, then its error.
        send(.loading(tab: tab.id, isLoading: true, canGoBack: true, canGoForward: false))
        send(.address(tab: tab.id, url: "http://localhost:5173/fail"))
        send(.loadError(tab: tab.id, url: "http://localhost:5173/fail", code: -102, message: "net::ERR_CONNECTION_REFUSED"))
        send(.loadEnd(tab: tab.id, url: "http://localhost:5173/fail", status: 0))
        XCTAssertNotNil(controller.errorMessage)
        send(.loadEnd(tab: tab.id, url: "http://localhost:5173/", status: 200))
        XCTAssertNil(controller.errorMessage, "a page that loaded elsewhere")
    }

    func testAnotherTabsFailureNeverReachesTheShownPage() throws {
        let (controller, tab, client) = try makePane()
        let behind = try client.newTab(forSession: tab.session!, url: "about:blank", viewport: .offscreenDefault, select: false)
        var behindHeard: [BrowserHostEvent] = []
        behind.addEventObserver { behindHeard.append($0) }
        send(.failed(message: "Chromium could not create a browser for tab \(behind.id)", tab: behind.id))
        XCTAssertNil(controller.errorMessage, "the shown tab is not the one that failed")
        XCTAssertEqual(behindHeard.count, 1, "the tab that failed hears it")
        send(.loading(tab: behind.id, isLoading: true, canGoBack: false, canGoForward: false))
        send(.loadError(tab: behind.id, url: "http://127.0.0.1:9/", code: -102, message: "net::ERR_CONNECTION_REFUSED"))
        send(.address(tab: behind.id, url: "http://127.0.0.1:9/"))
        XCTAssertNil(controller.errorMessage)
        send(.failed(message: "The browser host could not start", tab: nil))
        XCTAssertNotNil(controller.errorMessage, "a failure of the whole host is every tab's")
    }
}
