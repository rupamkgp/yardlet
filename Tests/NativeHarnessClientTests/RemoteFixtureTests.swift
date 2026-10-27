import Foundation
import XCTest
@testable import YardletRemote

/// The fixture server's tasks behave as the Mac's do: a task waiting on a request is running (the
/// stop button applies) and stopping it expires the request, a waiting task's attention carries a
/// short summary, and a message sent to a running task waits as a queued item until the turn ends.
final class RemoteFixtureTests: XCTestCase {
    func testWaitingTasksRunAndStoppingExpiresTheirRequest() async throws {
        let fixture = RemoteFixtureBridge(speed: 50)
        let snapshot = await fixture.snapshot()
        for id in [RemoteFixtureBridge.ID.approval, RemoteFixtureBridge.ID.question] {
            let task = try XCTUnwrap(snapshot.tasks.first { $0.id == id })
            XCTAssertEqual(task.attention, .waiting)
            XCTAssertTrue(task.running, "A turn waiting on a request is running, as on the Mac")
        }
        XCTAssertEqual(snapshot.requestSummaries[RemoteFixtureBridge.ID.approval], "Bash: Run the migration tests")
        XCTAssertEqual(snapshot.requestSummaries[RemoteFixtureBridge.ID.question], "Which name should the release use?")

        let stop = await fixture.perform(.stopTurn(taskID: RemoteFixtureBridge.ID.question))
        XCTAssertNil(stop)
        let stopped = await fixture.snapshot().tasks.first { $0.id == RemoteFixtureBridge.ID.question }
        XCTAssertEqual(stopped?.running, false)
        XCTAssertEqual(stopped?.attention, .unread)
        let items = await fixture.conversation(of: RemoteFixtureBridge.ID.question)?.turns.last?.items ?? []
        XCTAssertEqual(items.first { $0.kind == .approval }?.status, "expired")
        XCTAssertEqual(items.first { $0.kind == .turn }?.status, "interrupted")
        let again = await fixture.perform(.stopTurn(taskID: RemoteFixtureBridge.ID.question))
        XCTAssertEqual(again?.code, .notRunning)
    }

    func testAMessageToARunningTaskWaitsQueuedUntilTheTurnEnds() async throws {
        let fixture = RemoteFixtureBridge(speed: 50)
        let approval = RemoteFixtureBridge.ID.approval
        let sent = await fixture.perform(.sendMessage(taskID: approval, text: "Also update the changelog"))
        XCTAssertNil(sent)
        let afterSending = await fixture.conversation(of: approval)
        let queued = try XCTUnwrap(afterSending?.turns.last?.items.last)
        XCTAssertEqual(queued.kind, .user)
        XCTAssertEqual(queued.queued, true)
        XCTAssertEqual(queued.text, "Also update the changelog")

        let answer = await fixture.perform(.answerApproval(taskID: approval, requestID: "toolu_fixture_1", answer: .deny))
        XCTAssertNil(answer)
        let deadline = Date().addingTimeInterval(5)
        var taken: RemoteItem?
        while taken == nil, Date() < deadline {
            let items = await fixture.conversation(of: approval)?.turns.flatMap(\.items) ?? []
            if !items.contains(where: { $0.queued == true }) {
                taken = items.last { $0.kind == .user && $0.text == "Also update the changelog" }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let message = try XCTUnwrap(taken, "The queued message was not taken when the turn ended")
        XCTAssertNil(message.queued)
        XCTAssertNotEqual(message.id, queued.id)
    }
}
