import Foundation
import XCTest
@testable import NativeHarnessClient

final class SessionTitleProjectionTests: XCTestCase {
    func testProvisionalTitleUsesFirstNormalizedLineAndBoundedLength() {
        let title = SessionTitleProjection.provisionalTitle(
            from: "  First   title line  \nSecond line"
        )
        XCTAssertEqual(title, "First title line")
        XCTAssertLessThanOrEqual(
            SessionTitleProjection.provisionalTitle(from: String(repeating: "가", count: 100)).count,
            72
        )
    }

    func testProviderTitleRejectsPlaceholdersAndNormalizesQuotes() {
        XCTAssertNil(SessionTitleProjection.normalizedProviderTitle("New task"))
        XCTAssertNil(SessionTitleProjection.normalizedProviderTitle("Untitled"))
        XCTAssertEqual(
            SessionTitleProjection.normalizedProviderTitle("  “Fix   OAuth callback race” "),
            "Fix OAuth callback race"
        )
    }

    func testFallbackTitleIsDeterministicWithoutModelCall() {
        XCTAssertEqual(
            SessionTitleProjection.fallbackTitle(
                firstUserMessage: "잘 작동하니?",
                workspaceURL: URL(filePath: "/tmp/storefront")
            ),
            "storefront 작동 상태 확인"
        )
        XCTAssertEqual(
            SessionTitleProjection.fallbackTitle(
                firstUserMessage: "Could you fix the OAuth callback race?",
                workspaceURL: URL(filePath: "/tmp/app")
            ),
            "Fix the OAuth callback race"
        )
        // A request the fallback cannot shorten is told apart from the provisional label by
        // its folder; a provider title that arrives later replaces it.
        XCTAssertEqual(
            SessionTitleProjection.fallbackTitle(
                firstUserMessage: "test_calc.py를 실행해서 고쳐줘",
                workspaceURL: URL(filePath: "/tmp/yardlet-sandbox")
            ),
            "yardlet-sandbox · test_calc.py를 실행해서 고쳐줘"
        )
    }
}
