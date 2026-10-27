import Foundation
import XCTest
@testable import NativeHarnessClient

final class TranscriptBuilderTests: XCTestCase {
    func testTurnCompletionExpiresUnansweredPermissionWithoutChangingPriorDecisions() {
        var builder = TranscriptBuilder()
        let allowed = PermissionRequest(id: "allowed", title: "Allowed", detail: nil, command: nil)
        let pending = PermissionRequest(id: "canceled", title: "Canceled tool", detail: nil, command: nil)
        builder.apply(.permissionRequested(allowed))
        builder.resolvePermission(id: allowed.id, decision: .allow)
        builder.apply(.permissionRequested(pending))
        builder.apply(.turnCompleted)
        builder.resolvePermission(id: pending.id, decision: .allow)
        XCTAssertEqual(builder.entries.map(\.content), [
            .permission(allowed, state: .allowed), .permission(pending, state: .expired)
        ])
    }

    func testRuntimeEndExpiresPendingApprovalAndRetainsPartialResponse() {
        var builder = TranscriptBuilder()
        let allowed = PermissionRequest(id: "allowed", title: "Already allowed", detail: nil, command: nil)
        let pending = PermissionRequest(id: "pending", title: "No longer answerable", detail: nil, command: nil)
        builder.apply(.permissionRequested(allowed))
        builder.resolvePermission(id: allowed.id, decision: .allow)
        builder.apply(.permissionRequested(pending))
        builder.apply(.assistantDelta("Partial response 👩🏽‍💻"))
        builder.endRuntime()
        XCTAssertEqual(builder.entries.map(\.content), [
            .permission(allowed, state: .allowed), .permission(pending, state: .expired),
            .assistant(text: "Partial response 👩🏽‍💻", isStreaming: false)
        ])
        builder.resolvePermission(id: pending.id, decision: .allow)
        XCTAssertEqual(builder.entries[1].content, .permission(pending, state: .expired))
    }

    func testRestoredTranscriptClosesStreamingAndOmitsUnauthoritativeRuntimeCards() {
        let activity = HarnessActivity(
            id: "activity",
            kind: "Bash",
            title: "Build",
            detail: nil
        )
        let permission = PermissionRequest(
            id: "permission",
            title: "Run command",
            detail: nil,
            command: "swift test"
        )
        let builder = TranscriptBuilder(entries: [
            TranscriptEntry(content: .assistant(text: "partial", isStreaming: true)),
            TranscriptEntry(content: .activity(activity, state: .running)),
            TranscriptEntry(content: .permission(permission, state: .pending))
        ])

        XCTAssertEqual(
            builder.entries.map(\.content),
            [.assistant(text: "partial", isStreaming: false)]
        )
    }

    func testCoalescesAssistantDeltasAndFinalMessageWithoutDuplication() {
        var builder = TranscriptBuilder()
        builder.apply(.assistantDelta("hel"))
        builder.apply(.assistantDelta("lo"))

        XCTAssertEqual(
            builder.entries.map(\.content),
            [.assistant(text: "hello", isStreaming: true)]
        )

        builder.apply(.assistantMessageCompleted("hello"))
        XCTAssertEqual(
            builder.entries.map(\.content),
            [.assistant(text: "hello", isStreaming: false)]
        )
    }

    func testUpdatesActivityAndPermissionInPlace() {
        var builder = TranscriptBuilder()
        let activity = HarnessActivity(
            id: "tool-1",
            kind: "Bash",
            title: "Run tests",
            detail: "swift test"
        )
        let permission = PermissionRequest(
            id: "permission-1",
            title: "Run command",
            detail: nil,
            command: "swift test"
        )
        builder.apply(.activityStarted(activity))
        builder.apply(.activityCompleted(activity))
        builder.apply(.permissionRequested(permission))
        builder.resolvePermission(id: permission.id, decision: .deny)

        XCTAssertEqual(builder.entries.count, 2)
        XCTAssertEqual(builder.entries[0].content, .activity(activity, state: .completed))
        XCTAssertEqual(builder.entries[1].content, .permission(permission, state: .denied))
    }

    func testUserMessageFinishesPriorAssistantStream() {
        var builder = TranscriptBuilder()
        builder.apply(.assistantDelta("answer"))
        builder.appendUser("follow-up")

        XCTAssertEqual(builder.entries.map(\.content), [
            .assistant(text: "answer", isStreaming: false),
            .user(text: "follow-up")
        ])
    }

    func testStructuredWorkBoundaryClosesAssistantBeforeFinalMessage() {
        var builder = TranscriptBuilder()
        let activity = HarnessActivity(
            id: "tool-1",
            kind: "read",
            title: "Read file",
            detail: nil
        )
        builder.apply(.assistantDelta("Inspecting."))
        builder.apply(.activityStarted(activity))
        builder.apply(.assistantDelta("Final answer."))
        builder.apply(.turnCompleted)

        XCTAssertEqual(builder.entries.map(\.content), [
            .assistant(text: "Inspecting.", isStreaming: false),
            .activity(activity, state: .stopped),
            .assistant(text: "Final answer.", isStreaming: false)
        ])
    }

    func testTerminalEventsStopOwnedRunningActivitiesWithoutInventingSuccess() {
        let activity = HarnessActivity(
            id: "tool-1",
            kind: "list_dir",
            title: "list dir",
            detail: "permission check failed"
        )

        var completedTurn = TranscriptBuilder()
        completedTurn.apply(.activityStarted(activity))
        completedTurn.apply(.assistantDelta("I could not list that directory."))
        completedTurn.apply(.turnCompleted)
        XCTAssertEqual(completedTurn.entries.map(\.content), [
            .activity(activity, state: .stopped),
            .assistant(text: "I could not list that directory.", isStreaming: false)
        ])

        var failedTurn = TranscriptBuilder()
        failedTurn.apply(.activityStarted(activity))
        failedTurn.apply(.error(message: "Harness process exited without a terminal result", recoverable: true))
        XCTAssertEqual(failedTurn.entries.map(\.content), [
            .activity(activity, state: .stopped),
            .error(message: "Harness process exited without a terminal result", recoverable: true)
        ])

        var disconnected = TranscriptBuilder()
        disconnected.apply(.activityStarted(activity))
        disconnected.endRuntime()
        XCTAssertEqual(disconnected.entries.map(\.content), [
            .activity(activity, state: .stopped)
        ])
    }

    func testPlanUpdatesReplaceWithinATurnAndStartAfterNextUserMessage() {
        var builder = TranscriptBuilder()
        builder.appendUser("first")
        builder.apply(.planUpdated("[ ] Inspect"))
        builder.apply(.planUpdated("[x] Inspect\n[~] Implement"))

        XCTAssertEqual(builder.entries.map(\.content), [
            .user(text: "first"),
            .plan("[x] Inspect\n[~] Implement")
        ])

        builder.appendUser("next")
        builder.apply(.planUpdated("[ ] Verify"))
        XCTAssertEqual(builder.entries.map(\.content), [
            .user(text: "first"),
            .plan("[x] Inspect\n[~] Implement"),
            .user(text: "next"),
            .plan("[ ] Verify")
        ])
    }

    func testTranscriptRenderWindowBoundsLargeMarkdownWithoutMutatingSource() {
        let source = String(repeating: "a", count: TranscriptRenderWindow.chunkCharacterLimit + 7)

        let first = TranscriptRenderWindow(
            text: source,
            characterLimit: TranscriptRenderWindow.chunkCharacterLimit
        )
        XCTAssertTrue(first.hasMore)
        XCTAssertTrue(first.isWindowed)
        XCTAssertEqual(
            first.text,
            String(repeating: "a", count: TranscriptRenderWindow.chunkCharacterLimit) + "\n\n…"
        )
        XCTAssertEqual(source.count, TranscriptRenderWindow.chunkCharacterLimit + 7)

        let expanded = TranscriptRenderWindow(
            text: source,
            characterLimit: TranscriptRenderWindow.chunkCharacterLimit * 2
        )
        XCTAssertFalse(expanded.hasMore)
        XCTAssertTrue(expanded.isWindowed)
        XCTAssertEqual(expanded.text, source)
    }

    func testTranscriptRenderWindowDoesNotWindowOrdinaryResponse() {
        let window = TranscriptRenderWindow(text: "**hello**", characterLimit: 32_000)
        let reusedExpandedWindow = TranscriptRenderWindow(text: "**hello**", characterLimit: 64_000)

        XCTAssertFalse(window.hasMore)
        XCTAssertFalse(window.isWindowed)
        XCTAssertEqual(window.text, "**hello**")
        XCTAssertFalse(reusedExpandedWindow.hasMore)
        XCTAssertFalse(reusedExpandedWindow.isWindowed)
        XCTAssertEqual(reusedExpandedWindow.text, "**hello**")
    }
}
