import XCTest
@testable import NativeHarnessClient

final class CodexCapabilitySectionNavigationProjectionTests: XCTestCase {
    /// The sheet's sections; history moved to the import sheet (B18).
    private let sections = ["controls", "skills", "plugins"]

    func testUnknownFocusFallsBackToFirstSection() {
        XCTAssertEqual(
            CodexCapabilitySectionNavigationProjection.focusedIndex(
                sectionIDs: sections,
                focusedID: "removed"
            ),
            0
        )
        XCTAssertEqual(
            CodexCapabilitySectionNavigationProjection.targetSectionID(
                in: sections,
                focusedID: "removed",
                offset: 1
            ),
            "skills"
        )
    }

    func testLeftAndRightNavigationClampAtSectionEdges() {
        XCTAssertNil(
            CodexCapabilitySectionNavigationProjection.targetSectionID(
                in: sections,
                focusedID: "controls",
                offset: -1
            )
        )
        XCTAssertEqual(
            CodexCapabilitySectionNavigationProjection.targetSectionID(
                in: sections,
                focusedID: "skills",
                offset: -1
            ),
            "controls"
        )
        XCTAssertEqual(
            CodexCapabilitySectionNavigationProjection.targetSectionID(
                in: sections,
                focusedID: "skills",
                offset: 1
            ),
            "plugins"
        )
        XCTAssertNil(
            CodexCapabilitySectionNavigationProjection.targetSectionID(
                in: sections,
                focusedID: "plugins",
                offset: 1
            )
        )
    }

    func testEmptySectionsHaveNoTarget() {
        XCTAssertNil(
            CodexCapabilitySectionNavigationProjection.focusedIndex(
                sectionIDs: [],
                focusedID: nil
            )
        )
        XCTAssertNil(
            CodexCapabilitySectionNavigationProjection.targetSectionID(
                in: [],
                focusedID: nil,
                offset: 1
            )
        )
    }
}
