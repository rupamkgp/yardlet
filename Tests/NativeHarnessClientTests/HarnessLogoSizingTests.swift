import XCTest
@testable import NativeHarnessClient

final class HarnessLogoSizingTests: XCTestCase {
    @MainActor
    func testNativeMenuIconsHaveTheRequestedLogicalSizeWithoutResizingSharedAssets() throws {
        for harness in HarnessCatalog.builtIns.map(\.id) {
            let original = try XCTUnwrap(HarnessLogoCatalog.image(for: harness))
            let originalSize = original.size
            let menuIcon = try XCTUnwrap(HarnessLogoCatalog.icon(for: harness, size: 16))
            let largerIcon = try XCTUnwrap(HarnessLogoCatalog.icon(for: harness, size: 28))
            XCTAssertEqual(menuIcon.size, NSSize(width: 16, height: 16))
            XCTAssertEqual(largerIcon.size, NSSize(width: 28, height: 28))
            XCTAssertEqual(original.size, originalSize)
            XCTAssertFalse(menuIcon === original)
        }
    }
}
