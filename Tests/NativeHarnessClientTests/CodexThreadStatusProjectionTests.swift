import XCTest
@testable import NativeHarnessClient

final class CodexThreadStatusProjectionTests: XCTestCase {
    func testKnownRuntimeStatusesHaveStablePresentation() {
        let notLoaded = CodexThreadStatusProjection.presentation(for: .notLoaded)
        XCTAssertEqual(notLoaded.title, L10n.string("Not loaded"))
        XCTAssertEqual(notLoaded.symbolName, "arrow.down.circle")
        XCTAssertEqual(notLoaded.tone, .neutral)

        let idle = CodexThreadStatusProjection.presentation(for: .idle)
        XCTAssertEqual(idle.title, L10n.string("Ready"))
        XCTAssertEqual(idle.symbolName, "checkmark.circle")

        let error = CodexThreadStatusProjection.presentation(for: .systemError)
        XCTAssertEqual(error.title, L10n.string("Runtime error"))
        XCTAssertEqual(error.symbolName, "exclamationmark.triangle")
        XCTAssertEqual(error.tone, .error)
    }

    func testActiveFlagsRemainVisibleToAccessibilityWithoutInventingState() {
        let presentation = CodexThreadStatusProjection.presentation(
            for: .active(flags: ["turn", " approval ", ""])
        )

        XCTAssertEqual(presentation.title, L10n.string("Running"))
        XCTAssertEqual(presentation.tone, .active)
        XCTAssertTrue(presentation.accessibilityValue.contains("turn"))
        XCTAssertTrue(presentation.accessibilityValue.contains("approval"))
        XCTAssertFalse(presentation.accessibilityValue.contains(", ,"))
    }

    func testUnknownRuntimeStatusFailsClosedToWarningCopy() {
        let presentation = CodexThreadStatusProjection.presentation(
            for: .unknown(.object(["type": .string("futureStatus")]))
        )

        XCTAssertEqual(presentation.title, L10n.string("Unknown"))
        XCTAssertEqual(presentation.accessibilityValue, L10n.string("Unknown"))
        XCTAssertEqual(presentation.tone, .warning)
    }
}
