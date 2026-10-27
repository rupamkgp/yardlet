import SwiftUI
import XCTest
@testable import NativeHarnessClient

final class AppearancePreferenceTests: XCTestCase {
    func testAppearancePreferenceMapsToRequestedColorScheme() {
        XCTAssertNil(YardletAppearancePreference.system.colorScheme)
        XCTAssertEqual(YardletAppearancePreference.light.colorScheme, .light)
        XCTAssertEqual(YardletAppearancePreference.dark.colorScheme, .dark)
    }

    func testInterfaceSizesIncreaseInStableOrder() {
        XCTAssertLessThan(
            YardletInterfaceSizePreference.compact.scale,
            YardletInterfaceSizePreference.standard.scale
        )
        XCTAssertLessThan(
            YardletInterfaceSizePreference.standard.scale,
            YardletInterfaceSizePreference.large.scale
        )
        XCTAssertEqual(YardletInterfaceSizePreference.standard.scale, 1)
        XCTAssertEqual(YardletInterfaceSizePreference.standard.dynamicTypeSize, .large)
    }
}
