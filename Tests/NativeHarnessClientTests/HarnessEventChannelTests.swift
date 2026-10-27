import Foundation
import XCTest
@testable import NativeHarnessClient

/// The per-session event channel every provider adapter shares: numbering, the capped replay a
/// late subscriber reads first, replacing a subscriber, finishing a stream, and closing a session.
final class HarnessEventChannelTests: XCTestCase {
    private let session = UUID()
    private let other = UUID()

    func testEachSessionNumbersItsEventsFromZeroAndKeepsThemWithoutASubscriber() {
        var channel = HarnessEventChannel()
        let first = channel.emit(.assistantDelta("a"), for: session)
        let elsewhere = channel.emit(.assistantDelta("x"), for: other)
        let second = channel.emit(.assistantDelta("b"), for: session, rawProviderEvent: Data("raw".utf8))

        XCTAssertEqual([first.sequence, second.sequence, elsewhere.sequence], [0, 1, 0])
        XCTAssertEqual([first.localSessionID, second.localSessionID, elsewhere.localSessionID],
                       [session, session, other])
        XCTAssertEqual(first.payload, .assistantDelta("a"))
        XCTAssertNil(first.rawProviderEvent)
        XCTAssertEqual(second.rawProviderEvent, Data("raw".utf8))
        XCTAssertEqual(channel.replay(for: session), [first, second])
        XCTAssertEqual(channel.replay(for: other), [elsewhere])
    }

    func testALateSubscriberReadsTheNewestEventsUpToTheLimitInOrderAndThenNewOnes() async {
        XCTAssertEqual(HarnessEventChannel().historyLimit, 500)
        var standard = HarnessEventChannel()
        for index in 0..<1_234 { standard.emit(.assistantDelta("\(index)"), for: session) }
        XCTAssertEqual(standard.replay(for: session).map(\.sequence), Array(734...1_233))

        // A limit of 8 keeps up to 10 before trimming; 37 events pass several trims.
        var channel = HarnessEventChannel(historyLimit: 8)
        for index in 0..<37 { channel.emit(.assistantDelta("\(index)"), for: session) }
        XCTAssertEqual(channel.replay(for: session).map(\.sequence), Array(29...36))
        XCTAssertEqual(channel.replay(for: session).map(\.payload), (29...36).map { .assistantDelta("\($0)") })

        let stream = channel.subscribe(to: session)
        let live = channel.emit(.assistantMessageCompleted("done"), for: session)
        let received = await collect(stream, count: 9)
        XCTAssertEqual(received.map(\.sequence), Array(29...37))
        XCTAssertEqual(received.last, live)
        XCTAssertEqual(channel.replay(for: session).map(\.sequence), Array(30...37))
    }

    func testANewSubscriberReplacesThePreviousOneWhoseStreamFinishes() async {
        var channel = HarnessEventChannel()
        let started = channel.emit(.sessionStatusChanged(.running), for: session)
        let first = channel.subscribe(to: session)
        let delta = channel.emit(.assistantDelta("one"), for: session)
        let second = channel.subscribe(to: session)
        let completed = channel.emit(.assistantMessageCompleted("one"), for: session)

        // The replaced stream ends after what it had received; it does not wait for more.
        let firstEvents = await collect(first)
        XCTAssertEqual(firstEvents, [started, delta])
        let secondEvents = await collect(second, count: 3)
        XCTAssertEqual(secondEvents, [started, delta, completed])
    }

    func testClosingFinishesTheStreamAndForgetsOnlyThatSessionsEventsAndNumbering() async {
        var channel = HarnessEventChannel()
        let before = channel.emit(.assistantDelta("before"), for: session)
        let kept = channel.emit(.assistantDelta("other"), for: other)
        let stream = channel.subscribe(to: session)
        channel.close(session)

        let received = await collect(stream)
        XCTAssertEqual(received, [before])
        XCTAssertEqual(channel.replay(for: session), [])
        XCTAssertEqual(channel.emit(.assistantDelta("again"), for: session).sequence, 0)
        XCTAssertEqual(channel.replay(for: other), [kept])
        channel.close(UUID())
        XCTAssertEqual(channel.replay(for: other), [kept])
    }

    /// Codex projects a provider frame into an envelope with the number it is handed. A frame that
    /// projects to no event still uses its number, as it did before the channel.
    func testAProjectedEventTakesTheNextNumberAndAFrameThatProjectsNothingStillUsesOne() async {
        var channel = HarnessEventChannel()
        let stream = channel.subscribe(to: session)
        let first = channel.emit(.sessionStatusChanged(.running), for: session)
        let nothing = channel.emit(for: session) { _ in nil }
        let projected = channel.emit(for: session) { sequence in
            HarnessEventEnvelope(
                localSessionID: self.session,
                sequence: sequence,
                payload: .assistantDelta("a"),
                rawProviderEvent: Data("frame".utf8)
            )
        }
        let next = channel.emit(.turnCompleted, for: session)

        XCTAssertNil(nothing)
        XCTAssertEqual(first.sequence, 0)
        XCTAssertEqual(projected?.sequence, 2)
        XCTAssertEqual(projected?.rawProviderEvent, Data("frame".utf8))
        XCTAssertEqual(next.sequence, 3)
        let kept = [first, projected, next].compactMap { $0 }
        XCTAssertEqual(channel.replay(for: session), kept)
        let received = await collect(stream, count: 3)
        XCTAssertEqual(received, kept)

        // A session's first frame can project to nothing too.
        XCTAssertNil(channel.emit(for: other) { _ in nil })
        XCTAssertEqual(channel.emit(.turnCompleted, for: other).sequence, 1)
        XCTAssertEqual(channel.replay(for: other).map(\.sequence), [1])
    }

    func testFinishingEndsTheStreamAndKeepsTheEventsAndNumberingForTheNextSubscriber() async {
        var channel = HarnessEventChannel()
        let before = channel.emit(.assistantDelta("before"), for: session)
        let stream = channel.subscribe(to: session)
        channel.finish(session)
        let unseen = channel.emit(.assistantDelta("after"), for: session)

        let received = await collect(stream)
        XCTAssertEqual(received, [before])
        XCTAssertEqual(unseen.sequence, 1)
        let next = channel.subscribe(to: session)
        let live = channel.emit(.turnCompleted, for: session)
        let resumed = await collect(next, count: 3)
        XCTAssertEqual(resumed, [before, unseen, live])

        // Finishing a session the channel has not seen leaves it unseen.
        channel.finish(other)
        XCTAssertEqual(channel.replay(for: other), [])
        XCTAssertEqual(channel.emit(.turnCompleted, for: other).sequence, 0)
    }

    /// The stream's events until it finishes, or its first `count`.
    private func collect(
        _ stream: AsyncStream<HarnessEventEnvelope>, count: Int = .max
    ) async -> [HarnessEventEnvelope] {
        var events: [HarnessEventEnvelope] = []
        for await event in stream.prefix(count) { events.append(event) }
        return events
    }
}
