import Foundation
import XCTest
@testable import NativeHarnessClient

final class CodexTurnProgressProjectionTests: XCTestCase {
    func testElapsedSecondsClampBeforeStartAndAdvanceByWholeSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            CodexTurnProgressProjection.elapsedSeconds(
                startedAt: start,
                now: start.addingTimeInterval(-2)
            ),
            0
        )
        XCTAssertEqual(
            CodexTurnProgressProjection.elapsedSeconds(
                startedAt: start,
                now: start.addingTimeInterval(7.9)
            ),
            7
        )
    }

    func testThinkingIsOnlyVisibleBeforeFirstAgentOutputOfRunningTurn() {
        XCTAssertTrue(
            CodexTurnProgressProjection.showsThinking(
                status: .inProgress,
                hasAgentOutput: false
            )
        )
        XCTAssertFalse(
            CodexTurnProgressProjection.showsThinking(
                status: .inProgress,
                hasAgentOutput: true
            )
        )
        XCTAssertFalse(
            CodexTurnProgressProjection.showsThinking(
                status: .completed,
                hasAgentOutput: false
            )
        )
    }

    func testCompletedDurationUsesProviderMillisecondsAndHumanScaleBuckets() {
        XCTAssertEqual(
            CodexTurnProgressProjection.completedDuration(
                durationMilliseconds: 22_000,
                startedAt: nil,
                completedAt: nil
            ),
            .seconds(22)
        )
        XCTAssertEqual(
            CodexTurnProgressProjection.completedDuration(
                durationMilliseconds: 93_000,
                startedAt: nil,
                completedAt: nil
            ),
            .minutes(1)
        )
        XCTAssertEqual(
            CodexTurnProgressProjection.completedDuration(
                durationMilliseconds: 7_400_000,
                startedAt: nil,
                completedAt: nil
            ),
            .hours(2)
        )
    }

    /// The Codex app's `localConversation.userStoppedAfter` replaces "Worked for" on a turn the
    /// person stopped, so a stopped turn never reads as finished work.
    func testAStoppedTurnReadsAsStoppedRatherThanWorked() {
        typealias Projection = CodexTurnProgressProjection
        XCTAssertEqual(Projection.finishedTitle(status: .completed, duration: .seconds(22)),
                       L10n.format("Worked for %lld seconds", Int64(22)))
        XCTAssertEqual(Projection.finishedTitle(status: .interrupted, duration: .seconds(22)),
                       L10n.format("You stopped after %lld seconds", Int64(22)))
        XCTAssertEqual(Projection.finishedTitle(status: .interrupted, duration: .minutes(3)),
                       L10n.format("You stopped after %lld minutes", Int64(3)))
        XCTAssertEqual(Projection.finishedTitle(status: .interrupted, duration: .hours(1)),
                       L10n.format("You stopped after %lld hours", Int64(1)))
        XCTAssertEqual(Projection.finishedTitle(status: .interrupted, duration: nil), L10n.string("Stopped"))
        XCTAssertEqual(Projection.finishedTitle(status: .failed, duration: nil), L10n.string("Failed"))
        XCTAssertEqual(
            String(format: L10n.string("You stopped after %lld seconds", languageCode: "ko"), Int64(22)),
            "22초 후 중지함"
        )
        XCTAssertEqual(
            String(format: L10n.string("You stopped after %lld seconds", languageCode: "en"), Int64(22)),
            "You stopped after 22 seconds"
        )
    }

    func testCompletedDurationFallsBackToProviderTimestamps() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            CodexTurnProgressProjection.completedDuration(
                durationMilliseconds: nil,
                startedAt: start,
                completedAt: start.addingTimeInterval(7.9)
            ),
            .seconds(7)
        )
        XCTAssertNil(
            CodexTurnProgressProjection.completedDuration(
                durationMilliseconds: nil,
                startedAt: start,
                completedAt: start.addingTimeInterval(-1)
            )
        )
    }
}
