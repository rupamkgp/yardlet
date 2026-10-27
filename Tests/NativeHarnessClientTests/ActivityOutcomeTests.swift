import Foundation
import XCTest
@testable import NativeHarnessClient

final class ActivityOutcomeTests: XCTestCase {
    func testActualYHPRoutePreservesToolFailureAndTerminalFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/fixtures/antigravity-tool-error.py")
        let executable = root.appending(path: "agy")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path())
        let adapter = await HarnessRegistry().adapter(for: .antigravityCLI, executableURL: executable)
        let handle = try await adapter.createSession(CreateHarnessSessionRequest(
            localSessionID: UUID(), workspaceURL: root, initialPrompt: nil))
        let recorder = ActivityOutcomeRecorder()
        let collector = Task {
            for await event in await adapter.events(for: handle) { await recorder.append(event.payload) }
        }
        try await adapter.send("permission failure", to: handle)
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await recorder.values.contains(.sessionStatusChanged(.failed))), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let payloads = await recorder.values
        await adapter.close(handle)
        collector.cancel()
        XCTAssertTrue(payloads.contains(.sessionStatusChanged(.failed)))
        XCTAssertFalse(payloads.contains(.turnCompleted))
        var builder = TranscriptBuilder()
        payloads.forEach { builder.apply($0) }
        let states = builder.entries.compactMap { entry -> TranscriptActivityState? in
            guard case let .activity(_, state) = entry.content else { return nil }
            return state
        }
        XCTAssertEqual(states, [.failed, .stopped])
        XCTAssertTrue(builder.entries.contains { entry in
            guard case let .activity(activity, .failed) = entry.content else { return false }
            return activity.detail?.contains("user denied permission") == true
                && activity.detail?.contains(String(repeating: "x", count: 800)) == false
        })
    }

    func testOldActivitiesDecodeAndFailureSurvivesStorageAndLaterSuccess() throws {
        let old = Data(#"{"id":"tool","kind":"read","title":"Read"}"#.utf8)
        var activity = try JSONDecoder().decode(HarnessActivity.self, from: old)
        XCTAssertNil(activity.outcome)
        activity.outcome = .failed
        let saved = try JSONEncoder().encode(activity)
        activity = try JSONDecoder().decode(HarnessActivity.self, from: saved)
        var builder = TranscriptBuilder()
        builder.appendUser("Read the folder")
        builder.apply(.activityCompleted(activity))
        builder.apply(.assistantMessageCompleted("The folder could not be read."))
        builder.apply(.turnCompleted)
        XCTAssertEqual(builder.entries[1].content, .activity(activity, state: .failed))
        XCTAssertEqual(TranscriptBuilder(entries: builder.entries).entries[1].content,
                       .activity(activity, state: .failed))
        let turn = TranscriptConversationProjection.presentation(
            from: builder.entries, harness: .claudeCode, status: .ready, latestTurnIsComplete: true
        ).turns[0]
        XCTAssertEqual(turn.work.map(\.phase), [.failed], "the call still reads as failed")
    }

    func testAntigravityFailureIsTerminalWithoutSuccessEvent() {
        let projector = StructuredHeadlessEventProjector(flavor: .antigravity)
        for event: JSONValue in [
            .object(["event": .string("result"), "result": .object([
                "status": .string("ERROR"), "error": .string("permission denied")])]),
            .object(["type": .string("result"), "status": .string("error"),
                     "error": .string("permission denied")])
        ] {
            let result = projector.project(event, hasAssistantText: false)
            XCTAssertTrue(result.isTerminal)
            XCTAssertEqual(result.payloads, [.error(message: "permission denied", recoverable: true)])
        }
    }
}

private actor ActivityOutcomeRecorder {
    var values: [HarnessEventPayload] = []
    func append(_ value: HarnessEventPayload) { values.append(value) }
}
