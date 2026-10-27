import XCTest
@testable import NativeHarnessClient

final class CodexTimelineNavigationTests: XCTestCase {
    func testKeyboardNavigationUsesLatestDefaultAndClampsAtEdges() {
        let turnIDs = ["first", "middle", "latest"]
        XCTAssertEqual(
            CodexTimelineNavigation.targetID(turnIDs: turnIDs, focusedID: nil, offset: -1),
            "middle"
        )
        XCTAssertEqual(
            CodexTimelineNavigation.targetID(turnIDs: turnIDs, focusedID: "first", offset: -1),
            nil
        )
        XCTAssertEqual(
            CodexTimelineNavigation.targetID(turnIDs: turnIDs, focusedID: "latest", offset: 1),
            nil
        )
    }

    func testUnfocusedTimelineStartsAtLatestTurn() {
        let turnIDs = ["first", "latest"]
        XCTAssertEqual(
            CodexTimelineNavigation.focusedIndex(turnIDs: turnIDs, focusedID: nil),
            1
        )
        XCTAssertEqual(
            CodexTimelineNavigation.targetID(turnIDs: turnIDs, focusedID: nil, offset: -1),
            "first"
        )
        XCTAssertNil(
            CodexTimelineNavigation.targetID(turnIDs: turnIDs, focusedID: nil, offset: 1)
        )
    }

    func testUnknownFocusFallsBackToLatestWithoutInventingTurnIDs() {
        let turnIDs = ["first", "latest"]
        XCTAssertEqual(
            CodexTimelineNavigation.focusedIndex(turnIDs: turnIDs, focusedID: "removed"),
            1
        )
        XCTAssertNil(
            CodexTimelineNavigation.targetID(turnIDs: [], focusedID: nil, offset: -1)
        )
    }

    func testExplicitFocusMovesOnlyWithinAvailableTurns() {
        let turnIDs = ["first", "middle", "latest"]
        XCTAssertEqual(
            CodexTimelineNavigation.targetID(turnIDs: turnIDs, focusedID: "middle", offset: -1),
            "first"
        )
        XCTAssertEqual(
            CodexTimelineNavigation.targetID(turnIDs: turnIDs, focusedID: "middle", offset: 1),
            "latest"
        )
    }
}
