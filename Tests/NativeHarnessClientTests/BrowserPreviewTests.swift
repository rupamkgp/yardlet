import WebKit
import XCTest
@testable import NativeHarnessClient

final class BrowserPreviewTests: XCTestCase {
    func testLoopbackPolicyAcceptsIPv6AndRejectsDomainsThatOnlyBeginWith127() throws {
        XCTAssertEqual(try BrowserPreviewAddress.resolve("[::1]:3000").absoluteString, "http://[::1]:3000")
        XCTAssertTrue(BrowserPreviewAddress.isAllowed(URL(string: "http://[::1]:3000")!))
        XCTAssertTrue(BrowserPreviewAddress.isAllowed(URL(string: "http://127.12.34.56:3000")!))
        for host in ["127.foo.bar.com", "127.0.0.example", "127.0.0.256", "127..0.1"] {
            XCTAssertThrowsError(try BrowserPreviewAddress.resolve("http://\(host)"))
            XCTAssertFalse(BrowserPreviewAddress.isAllowed(URL(string: "http://\(host)")!))
        }
    }

    @MainActor
    func testBlockedNavigationFinishingAtBlankDoesNotReportReady() {
        let model = BrowserPreviewModel()
        let view = RecordingBrowserView(frame: .zero)
        model.attach(view)
        model.address = "localhost:1"
        model.navigate()
        view.reportedURL = URL(string: "about:blank")
        model.webView(view, didFinish: nil)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.displayedURL)
        XCTAssertEqual(model.requestedURL?.absoluteString, "http://localhost:1")
        XCTAssertFalse(model.isLoading)
        model.terminateForApplicationShutdown()
    }

    @MainActor
    func testPanelRemountKeepsPageAndDoesNotReloadOrStopIt() {
        let model = BrowserPreviewModel()
        let view = RecordingBrowserView(frame: .zero)
        model.attach(view)
        model.address = "localhost:8080/page-a"
        model.navigate()
        let firstHost = BrowserWebViewHost(webView: model.acquireWebView())
        firstHost.unmount()
        XCTAssertTrue(model.isLoading)
        let secondHost = BrowserWebViewHost(webView: model.acquireWebView())
        firstHost.unmount() // Old representable teardown can arrive after the next mount.
        XCTAssertTrue(view.superview === secondHost)
        XCTAssertEqual(view.requests.count, 1)
        XCTAssertEqual(view.stopCount, 0)
        XCTAssertTrue(model.acquireWebView() === view)
        secondHost.unmount()
        XCTAssertTrue(view.navigationDelegate === model)
        model.terminateForApplicationShutdown()
        XCTAssertNil(view.navigationDelegate)
        XCTAssertEqual(view.stopCount, 1)
    }

    @MainActor
    func testPendingAddressLoadsExactlyOnceWhenPageIsMounted() {
        let model = BrowserPreviewModel()
        model.address = "localhost:8080/first"
        model.navigate()
        model.address = "localhost:8080/latest"
        model.navigate()
        let view = RecordingBrowserView(frame: .zero)
        model.attach(view)
        model.attach(view)
        _ = model.acquireWebView()
        XCTAssertEqual(view.requests.map(\.url?.path), ["/latest"])
        model.terminateForApplicationShutdown()
    }

    @MainActor
    func testStopBeforeMountCancelsPendingNavigation() {
        let model = BrowserPreviewModel()
        model.address = "localhost:8080"
        model.navigate()
        model.stop()
        let view = RecordingBrowserView(frame: .zero)
        model.attach(view)
        XCTAssertTrue(view.requests.isEmpty)
        XCTAssertFalse(model.isLoading)
        model.terminateForApplicationShutdown()
    }

    @MainActor
    func testRestoredAddressDoesNotCreateOrNavigateWebKit() {
        let model = BrowserPreviewModel(preferences: .init(address: "  localhost:8080/초안  "))
        XCTAssertEqual(model.address, "  localhost:8080/초안  ")
        XCTAssertNil(model.requestedURL)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasAttachedWebView)
        let view = RecordingBrowserView(frame: .zero)
        model.attach(view)
        XCTAssertTrue(view.requests.isEmpty)
        model.terminateForApplicationShutdown()
    }

    @MainActor
    func testFinishingNavigationPreservesAddressEditedWhilePageLoads() {
        let model = BrowserPreviewModel()
        let view = RecordingBrowserView(frame: .zero)
        model.attach(view)
        model.address = "localhost:8080/first"
        model.navigate()
        model.webView(view, didStartProvisionalNavigation: nil)
        model.address = "  localhost:8080/다음 주소  "
        model.webView(view, didFinish: nil)
        XCTAssertEqual(model.address, "  localhost:8080/다음 주소  ")
        XCTAssertEqual(model.displayedURL, view.url)
        XCTAssertFalse(model.isLoading)
        model.terminateForApplicationShutdown()
    }

    @MainActor
    func testReloadUsesWebKitReloadWithoutAddingAnotherHistoryEntry() {
        let model = BrowserPreviewModel()
        let view = RecordingBrowserView(frame: .zero)
        model.attach(view)
        model.address = "localhost:8080/first"
        model.navigate()
        model.webView(view, didFinish: nil)
        model.reload()
        XCTAssertEqual(view.requests.count, 1)
        XCTAssertEqual(view.reloadCount, 1)
        model.terminateForApplicationShutdown()
    }

    @MainActor
    func testClosingTabClearsPageAndRejectsLateCallbacks() {
        let model = BrowserPreviewModel()
        let view = RecordingBrowserView(frame: .zero)
        model.attach(view)
        model.address = "localhost:8080/first"
        model.navigate()
        model.closeTab()
        model.webView(view, didFinish: nil)
        model.webView(view, didFailProvisionalNavigation: nil, withError: NSError(domain: "fixture", code: 1))
        XCTAssertEqual(model.address, "")
        XCTAssertNil(model.requestedURL)
        XCTAssertNil(model.displayedURL)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasAttachedWebView)
        XCTAssertNil(view.navigationDelegate)
        XCTAssertNil(view.uiDelegate)
    }

    @MainActor
    func testInvalidFirstAddressHasVisibleValidationWithoutStartingWebKit() {
        let model = BrowserPreviewModel()
        model.address = "file:///tmp/example.html"
        model.navigate()
        XCTAssertNotNil(model.addressError)
        XCTAssertNil(model.requestedURL)
        XCTAssertFalse(model.hasAttachedWebView)
        XCTAssertFalse(model.isLoading)
        model.address = "localhost:8080"
        XCTAssertNil(model.addressError)
        model.navigate()
        XCTAssertEqual(model.requestedURL?.absoluteString, "http://localhost:8080")
        XCTAssertTrue(model.isLoading)
        model.stop()
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testInvalidNewAddressDoesNotReplaceTheLastRequestedPage() {
        let model = BrowserPreviewModel()
        model.address = "localhost:8080"
        model.navigate()
        model.stop()
        model.address = "javascript:alert(1)"
        model.navigate()
        XCTAssertEqual(model.requestedURL?.absoluteString, "http://localhost:8080")
        XCTAssertNotNil(model.addressError)
        XCTAssertNil(model.errorMessage)
    }

    func testAddressPolicyDefaultsToHTTPSAndAllowsLoopbackHTTP() throws {
        XCTAssertEqual(
            try BrowserPreviewAddress.resolve("example.com/docs").absoluteString,
            "https://example.com/docs"
        )
        XCTAssertEqual(
            try BrowserPreviewAddress.resolve("localhost:3000").absoluteString,
            "http://localhost:3000"
        )
        XCTAssertEqual(
            try BrowserPreviewAddress.resolve("127.0.0.1:8080/health").absoluteString,
            "http://127.0.0.1:8080/health"
        )
    }

    func testAddressPolicyRejectsUnsafeSchemesCredentialsAndRemoteHTTP() {
        XCTAssertThrowsError(try BrowserPreviewAddress.resolve("javascript:alert(1)")) {
            XCTAssertEqual($0 as? BrowserPreviewAddressError, .unsupportedScheme)
        }
        XCTAssertThrowsError(try BrowserPreviewAddress.resolve("file:///tmp/index.html")) {
            XCTAssertEqual($0 as? BrowserPreviewAddressError, .unsupportedScheme)
        }
        XCTAssertThrowsError(try BrowserPreviewAddress.resolve("https://user:secret@example.com")) {
            XCTAssertEqual($0 as? BrowserPreviewAddressError, .containsCredentials)
        }
        XCTAssertThrowsError(try BrowserPreviewAddress.resolve("http://example.com")) {
            XCTAssertEqual($0 as? BrowserPreviewAddressError, .insecureRemoteHTTP)
        }
    }

    @MainActor
    func testPreviewModelExplicitlyAttachesAndDetachesOneWebView() {
        let model = BrowserPreviewModel()
        let first = WKWebView(frame: .zero)
        let second = WKWebView(frame: .zero)

        model.attach(first)
        XCTAssertTrue(model.hasAttachedWebView)
        XCTAssertTrue(first.navigationDelegate === model)
        model.attach(second)
        XCTAssertTrue(model.hasAttachedWebView)
        XCTAssertNil(first.navigationDelegate)
        XCTAssertNil(first.uiDelegate)
        XCTAssertTrue(second.navigationDelegate === model)

        model.detach(second)
        XCTAssertFalse(model.hasAttachedWebView)
        XCTAssertNil(second.navigationDelegate)
        XCTAssertNil(second.uiDelegate)
    }

    @MainActor
    func testApplicationShutdownDetachesBrowserSurface() {
        let model = BrowserPreviewModel()
        let webView = WKWebView(frame: .zero)

        model.attach(webView)
        model.terminateForApplicationShutdown()

        XCTAssertFalse(model.hasAttachedWebView)
        XCTAssertNil(webView.navigationDelegate)
        XCTAssertNil(webView.uiDelegate)
    }
}

@MainActor
private final class RecordingBrowserView: WKWebView {
    var requests: [URLRequest] = []
    var stopCount = 0
    var reloadCount = 0
    var reportedURL: URL?
    override var url: URL? { reportedURL ?? requests.last?.url }
    override func load(_ request: URLRequest) -> WKNavigation? {
        requests.append(request)
        return nil
    }
    override func stopLoading() { stopCount += 1 }
    override func reloadFromOrigin() -> WKNavigation? { reloadCount += 1; return nil }
}
