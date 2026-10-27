import XCTest
@testable import NativeHarnessClient

/// Chromium's passkey dialog is a window of the browser host. The person must see it and be able to
/// close it whether they pressed the button themselves or the agent did while they were elsewhere.
final class ChromiumWindowPresentationTests: XCTestCase {
    func testYardletInFrontHandsTheDialogTheKeyboard() {
        var presentation = ChromiumWindowPresentation()
        XCTAssertEqual(presentation.windowChanged(isShown: true, appIsActive: true), [.raise, .handOver])
        XCTAssertEqual(presentation.appCameToFront(), [.raise], "back in Yardlet, the dialog stays over it without the keyboard")
        XCTAssertEqual(presentation.windowChanged(isShown: false, appIsActive: true), [])
        XCTAssertEqual(presentation.appCameToFront(), [], "nothing to show once it closed")
    }

    func testADialogOpenedWhileTheAgentWorkedWaitsForYardletToComeToTheFront() {
        var presentation = ChromiumWindowPresentation()
        XCTAssertEqual(presentation.windowChanged(isShown: true, appIsActive: false), [],
                       "the person's focus in another app stays where it is")
        XCTAssertEqual(presentation.appCameToFront(), [.raise, .handOver], "they see it, and Escape closes it")
        XCTAssertEqual(presentation.appCameToFront(), [.raise])
        XCTAssertEqual(presentation.windowChanged(isShown: true, appIsActive: false), [], "a new dialog")
        XCTAssertEqual(presentation.appCameToFront(), [.raise, .handOver])
    }
}
