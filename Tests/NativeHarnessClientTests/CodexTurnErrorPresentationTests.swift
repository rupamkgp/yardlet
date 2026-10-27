import Foundation
import XCTest
@testable import NativeHarnessClient

final class CodexTurnErrorPresentationTests: XCTestCase {
    func testRetryingErrorIsNotATaskFailureButAFinalErrorIs() {
        let projector = CodexEventProjector()
        let retrying = projector.project(
            notification(willRetry: true, error: ["message": .string("Reconnecting... 2/5")]),
            rawData: Data(), localSessionID: UUID(), sequence: 1
        )
        XCTAssertNil(retrying)

        let final = projector.project(
            notification(willRetry: false, error: [
                "message": .string("{\"error\":{\"message\":\"Upstream refused the request\"}}"),
                "codexErrorInfo": .string("badRequest")
            ]),
            rawData: Data(), localSessionID: UUID(), sequence: 2
        )
        XCTAssertEqual(final?.payload, .error(message: "Upstream refused the request", recoverable: false))

        // An older runtime sent the message at the top level.
        let flat = projector.project(
            CodexRPCIncomingMessage(id: nil, method: "error", params: .object([
                "message": .string("Flat runtime error")
            ]), result: nil, error: nil, emittedAtMs: nil),
            rawData: Data(), localSessionID: UUID(), sequence: 3
        )
        XCTAssertEqual(flat?.payload, .error(message: "Flat runtime error", recoverable: false))
    }

    func testKnownCategoriesGetAPlainHeadlineAndKeepTheProviderMessage() throws {
        let usage = try XCTUnwrap(CodexTurnErrorPresentation(.object([
            "message": .string("Your plan's limit resets at 3:05 PM."),
            "codexErrorInfo": .string("usageLimitExceeded")
        ])))
        XCTAssertEqual(usage.category, .usageLimit)
        XCTAssertEqual(usage.headline, L10n.string("You've hit your usage limit."))
        XCTAssertEqual(usage.text, "\(L10n.string("You've hit your usage limit."))\nYour plan's limit resets at 3:05 PM.")

        let window = try XCTUnwrap(CodexTurnErrorPresentation(.object([
            "message": .string(""),
            "codexErrorInfo": .string("contextWindowExceeded")
        ])))
        XCTAssertEqual(window.text, L10n.string("This conversation exceeds the model's context window."))

        let busy = try XCTUnwrap(CodexTurnErrorPresentation(.object([
            "message": .string("Selected model is at capacity."),
            "codexErrorInfo": .string("serverOverloaded")
        ])))
        XCTAssertEqual(busy.headline, L10n.string("Server is busy."))

        let other = try XCTUnwrap(CodexTurnErrorPresentation(.object([
            "message": .string("Stream disconnected"),
            "codexErrorInfo": .object(["responseStreamDisconnected": .object(["httpStatusCode": .integer(502)])])
        ])))
        XCTAssertNil(other.headline)
        XCTAssertEqual(other.text, "Stream disconnected")
        XCTAssertNil(CodexTurnErrorPresentation(.null))
    }

    func testUsageLimitMessageThatAlreadySaysSoIsNotRepeated() throws {
        let english = try XCTUnwrap(CodexTurnErrorPresentation(.object([
            "message": .string("You've hit your usage limit. Try again later."),
            "codexErrorInfo": .string("usageLimitExceeded")
        ])))
        let headline = try XCTUnwrap(english.headline)
        if headline == "You've hit your usage limit." {
            XCTAssertEqual(english.text, "You've hit your usage limit. Try again later.")
        } else {
            XCTAssertEqual(english.text, "\(headline)\nYou've hit your usage limit. Try again later.")
        }
    }

    func testReconnectStatusFollowsTheCodexAppWording() {
        XCTAssertEqual(
            CodexTurnErrorPresentation.reconnectStatus(.object(["message": .string("Reconnecting... 2/5")])),
            L10n.format("Reconnecting %@", "2/5")
        )
        XCTAssertEqual(
            CodexTurnErrorPresentation.reconnectStatus(.object([
                "message": .string("Reconnecting... 1/5"),
                "codexErrorInfo": .string("serverOverloaded")
            ])),
            L10n.format("Server is busy, reconnecting %@", "1/5")
        )
        XCTAssertEqual(
            CodexTurnErrorPresentation.reconnectStatus(.object([
                "message": .string("Model is overloaded"),
                "codexErrorInfo": .string("serverOverloaded")
            ])),
            L10n.string("Server is busy, reconnecting")
        )
        XCTAssertEqual(
            CodexTurnErrorPresentation.reconnectStatus(.object(["message": .string("stream closed; retrying")])),
            "stream closed; retrying"
        )
        XCTAssertNil(CodexTurnErrorPresentation.reconnectStatus(nil))
        XCTAssertNil(CodexTurnErrorPresentation.reconnectProgress("Reconnecting soon"))
    }

    func testReducerShowsReconnectUntilTheStreamResumesAndKeepsTheFinalError() throws {
        let reducer = CodexTaskReducer()
        var state = CodexTaskState.empty
        reducer.applyNotification(method: "turn/started", params: .object([
            "threadId": .string("thread"),
            "turn": .object(["id": .string("turn"), "status": .string("inProgress")])
        ]), sequence: 1, to: &state)

        let retrying = errorParams(willRetry: true, message: "Reconnecting... 1/5")
        XCTAssertTrue(reducer.applyNotification(method: "error", params: retrying, sequence: 2, to: &state))
        XCTAssertEqual(state.thread?.turns.last?.retryingError?["message"]?.stringValue, "Reconnecting... 1/5")
        XCTAssertNil(state.thread?.turns.last?.error)
        XCTAssertEqual(state.thread?.turns.last?.status, .inProgress)

        // An error for a turn the thread does not hold makes no phantom turn.
        var unknown = errorParams(willRetry: true, message: "Reconnecting... 1/5")
        if case var .object(fields) = unknown { fields["turnId"] = .string("other"); unknown = .object(fields) }
        XCTAssertFalse(reducer.applyNotification(method: "error", params: unknown, sequence: 3, to: &state))
        XCTAssertEqual(state.thread?.turns.count, 1)

        XCTAssertTrue(reducer.applyNotification(method: "item/agentMessage/delta", params: .object([
            "threadId": .string("thread"), "turnId": .string("turn"),
            "itemId": .string("answer"), "delta": .string("Back")
        ]), sequence: 4, to: &state))
        XCTAssertNil(state.thread?.turns.last?.retryingError)

        reducer.applyNotification(method: "error", params: errorParams(willRetry: true, message: "Reconnecting... 5/5"),
                                  sequence: 5, to: &state)
        XCTAssertTrue(reducer.applyNotification(method: "error", params: errorParams(
            willRetry: false, message: "stream disconnected before completion"
        ), sequence: 6, to: &state))
        XCTAssertNil(state.thread?.turns.last?.retryingError)
        XCTAssertEqual(state.thread?.turns.last?.error?["message"]?.stringValue, "stream disconnected before completion")

        reducer.applyNotification(method: "turn/completed", params: .object([
            "threadId": .string("thread"),
            "turn": .object([
                "id": .string("turn"), "status": .string("failed"),
                "error": .object(["message": .string("stream disconnected before completion")])
            ])
        ]), sequence: 7, to: &state)
        XCTAssertEqual(state.thread?.turns.last?.status, .failed)
        XCTAssertEqual(state.thread?.turns.last?.error?["message"]?.stringValue, "stream disconnected before completion")
    }

    private func errorParams(willRetry: Bool, message: String) -> JSONValue {
        .object([
            "threadId": .string("thread"),
            "turnId": .string("turn"),
            "willRetry": .bool(willRetry),
            "error": .object(["message": .string(message)])
        ])
    }

    private func notification(willRetry: Bool, error: [String: JSONValue]) -> CodexRPCIncomingMessage {
        CodexRPCIncomingMessage(id: nil, method: "error", params: .object([
            "threadId": .string("thread"),
            "turnId": .string("turn"),
            "willRetry": .bool(willRetry),
            "error": .object(error)
        ]), result: nil, error: nil, emittedAtMs: nil)
    }
}
