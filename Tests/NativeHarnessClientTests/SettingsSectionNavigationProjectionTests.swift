import XCTest
@testable import NativeHarnessClient

final class SettingsSectionNavigationProjectionTests: XCTestCase {
    private let sectionIDs = ["general", "appearance", "git", "notifications"]

    func testUpAndDownFollowStableSectionOrder() {
        XCTAssertEqual(
            SettingsSectionNavigationProjection.targetSectionID(
                in: sectionIDs,
                focusedID: "appearance",
                offset: -1
            ),
            "general"
        )
        XCTAssertEqual(
            SettingsSectionNavigationProjection.targetSectionID(
                in: sectionIDs,
                focusedID: "appearance",
                offset: 1
            ),
            "git"
        )
    }

    func testMissingOrStaleFocusFallsBackToFirstAndEdgesClamp() {
        XCTAssertEqual(
            SettingsSectionNavigationProjection.focusedIndex(sectionIDs: sectionIDs, focusedID: nil),
            0
        )
        XCTAssertEqual(
            SettingsSectionNavigationProjection.targetSectionID(
                in: sectionIDs,
                focusedID: "removed",
                offset: 1
            ),
            "appearance"
        )
        XCTAssertNil(
            SettingsSectionNavigationProjection.targetSectionID(
                in: sectionIDs,
                focusedID: "general",
                offset: -1
            )
        )
        XCTAssertNil(
            SettingsSectionNavigationProjection.targetSectionID(
                in: sectionIDs,
                focusedID: "notifications",
                offset: 1
            )
        )
        XCTAssertNil(
            SettingsSectionNavigationProjection.targetSectionID(in: [], focusedID: nil, offset: 1)
        )
    }
}
