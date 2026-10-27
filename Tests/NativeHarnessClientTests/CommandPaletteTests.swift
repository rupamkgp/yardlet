import XCTest
@testable import NativeHarnessClient

final class CommandPaletteTests: XCTestCase {
    func testDownArrowStartsAtFirstAndWrapsAtEnd() {
        XCTAssertEqual(
            CommandPaletteSelection.movedIndex(currentIndex: nil, count: 3, offset: 1),
            0
        )
        XCTAssertEqual(
            CommandPaletteSelection.movedIndex(currentIndex: 2, count: 3, offset: 1),
            0
        )
    }

    func testUpArrowStartsAtLastAndWrapsAtBeginning() {
        XCTAssertEqual(
            CommandPaletteSelection.movedIndex(currentIndex: nil, count: 3, offset: -1),
            2
        )
        XCTAssertEqual(
            CommandPaletteSelection.movedIndex(currentIndex: 0, count: 3, offset: -1),
            2
        )
    }

    func testSelectionReturnsNilForEmptyPalette() {
        XCTAssertNil(
            CommandPaletteSelection.movedIndex(currentIndex: nil, count: 0, offset: 1)
        )
    }
}
