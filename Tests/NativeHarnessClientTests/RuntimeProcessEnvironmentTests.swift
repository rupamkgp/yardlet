import Foundation
import XCTest
@testable import NativeHarnessClient

final class RuntimeProcessEnvironmentTests: XCTestCase {
    func testRuntimePathIncludesExecutableDirectoryAndCommonNodeLocations() {
        let environment = RuntimeProcessEnvironment.values(
            executableURL: URL(filePath: "/custom/runtime/pi"),
            base: ["HOME": "/Users/test", "PATH": "/existing/bin:/usr/bin"]
        )
        let paths = environment["PATH"]?.split(separator: ":").map(String.init)

        XCTAssertEqual(paths?.first, "/custom/runtime")
        XCTAssertTrue(paths?.contains("/opt/homebrew/bin") ?? false)
        XCTAssertTrue(paths?.contains("/usr/local/bin") ?? false)
        XCTAssertTrue(paths?.contains("/existing/bin") ?? false)
        XCTAssertEqual(paths?.filter { $0 == "/usr/bin" }.count, 1)
    }

    func testRuntimeOverridesWinWithoutDiscardingAugmentedPath() {
        let environment = RuntimeProcessEnvironment.values(
            executableURL: URL(filePath: "/opt/homebrew/bin/pi"),
            base: ["HOME": "/Users/test", "PATH": "/usr/bin"],
            overrides: ["PAGER": "cat", "CUSTOM": "value"]
        )

        XCTAssertEqual(environment["PAGER"], "cat")
        XCTAssertEqual(environment["CUSTOM"], "value")
        XCTAssertTrue(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") ?? false)
    }
}
