import XCTest
@testable import NativeHarnessClient

final class TaskWorkspaceLayoutTests: XCTestCase {
    func testExpandedSidePanelKeepsTheChatOffscreenWithoutChangingTerminalHeight() {
        let layout = TaskWorkspaceMetrics.resolve(size: CGSize(width: 1000, height: 700), trailing: true, terminal: true, preferredWidth: 420, preferredHeight: 240, expanded: true)
        XCTAssertFalse(layout.showsChat)
        XCTAssertEqual(layout.chatWidth, 0)
        XCTAssertEqual(layout.trailingWidth, 1000)
        XCTAssertEqual(layout.terminalHeight, 240)
    }

    func testCompactPanelKeepsChatOffscreenAndFitsTerminalWithinBounds() {
        let layout = TaskWorkspaceMetrics.resolve(size: CGSize(width: 519, height: 510), trailing: true, terminal: true, preferredWidth: 900, preferredHeight: 900)
        XCTAssertFalse(layout.showsChat)
        XCTAssertEqual(layout.chatWidth, 0)
        XCTAssertEqual(layout.trailingWidth, 519)
        XCTAssertEqual(layout.upperHeight + layout.terminalHeight + 6, 510)
        XCTAssertGreaterThanOrEqual(layout.upperHeight, 180)
    }

    /// The Codex app's bounds: the panel keeps 320 and leaves the conversation 352 (`zZt`).
    func testWidePanelsRespectBothMinimumWidthsAndCloseRestoresChatWidth() {
        let layout = TaskWorkspaceMetrics.resolve(size: CGSize(width: 1000, height: 700), trailing: true, terminal: false, preferredWidth: 900, preferredHeight: 240)
        XCTAssertTrue(layout.showsChat)
        XCTAssertEqual(layout.chatWidth, 352)
        XCTAssertEqual(layout.trailingWidth, 642)
        let narrowest = TaskWorkspaceMetrics.resolve(size: CGSize(width: 1000, height: 700), trailing: true, terminal: false, preferredWidth: 100, preferredHeight: 240)
        XCTAssertEqual(narrowest.trailingWidth, 320)
        // Below 320 + 352 and the divider the panel takes the conversation's place.
        XCTAssertTrue(TaskWorkspaceMetrics.resolve(size: CGSize(width: 678, height: 700), trailing: true, terminal: false, preferredWidth: 420, preferredHeight: 240).showsChat)
        XCTAssertFalse(TaskWorkspaceMetrics.resolve(size: CGSize(width: 677, height: 700), trailing: true, terminal: false, preferredWidth: 420, preferredHeight: 240).showsChat)
        let closed = TaskWorkspaceMetrics.resolve(size: CGSize(width: 1000, height: 700), trailing: false, terminal: false, preferredWidth: 674, preferredHeight: 240)
        XCTAssertEqual(closed.chatWidth, 1000)
        XCTAssertEqual(closed.upperHeight, 700)
    }

    func testTallTerminalRetainsReadingRoomForReviewAndConversationAtEachInterfaceSize() {
        for scale in [0.94, 1.0, 1.08] {
            for trailing in [false, true] {
                let layout = TaskWorkspaceMetrics.resolve(
                    size: CGSize(width: 659, height: 650), trailing: trailing, terminal: true,
                    preferredWidth: 420, preferredHeight: 1000, interfaceScale: scale
                )
                XCTAssertEqual(layout.upperHeight, (trailing ? 320 : 280) * scale, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(layout.terminalHeight, 180)
                XCTAssertEqual(layout.upperHeight + layout.terminalHeight + 6, 650, accuracy: 0.001)
            }
        }
    }

    func testCompactExpandedPanelAndResizeUseTheSameHeightLimit() {
        let height: CGFloat = 538
        let resized = TaskWorkspaceMetrics.constrainedTerminalHeight(
            900, availableHeight: height, trailing: true, interfaceScale: 1.08
        )
        let layout = TaskWorkspaceMetrics.resolve(
            size: CGSize(width: 519, height: height), trailing: true, terminal: true,
            preferredWidth: 420, preferredHeight: resized, expanded: true, interfaceScale: 1.08
        )
        XCTAssertFalse(layout.showsChat)
        XCTAssertEqual(layout.terminalHeight, resized)
        XCTAssertEqual(layout.upperHeight, 345.6, accuracy: 0.001)
        let reduced = TaskWorkspaceMetrics.constrainedTerminalHeight(
            resized - 30, availableHeight: height, trailing: true, interfaceScale: 1.08
        )
        XCTAssertEqual(reduced, 160, "the Codex app's bottom panel keeps 160")
    }

    func testSmallHeightTransitionAndClosingTerminalStayWithinAvailableBounds() {
        for height: CGFloat in [100, 300, 400, 538] {
            let layout = TaskWorkspaceMetrics.resolve(
                size: CGSize(width: 519, height: height), trailing: true, terminal: true,
                preferredWidth: 420, preferredHeight: 1000, interfaceScale: 1.08
            )
            XCTAssertGreaterThanOrEqual(layout.upperHeight, 0)
            XCTAssertGreaterThanOrEqual(layout.terminalHeight, 0)
            XCTAssertEqual(layout.upperHeight + layout.terminalHeight + 6, height, accuracy: 0.001)
            let closed = TaskWorkspaceMetrics.resolve(
                size: CGSize(width: 519, height: height), trailing: true, terminal: false,
                preferredWidth: 420, preferredHeight: 1000, interfaceScale: 1.08
            )
            XCTAssertEqual(closed.upperHeight, height)
            XCTAssertEqual(closed.terminalHeight, 0)
        }
    }
}
