import Foundation
import XCTest
@testable import NativeHarnessClient

/// A `CodexTaskReducer` for the reducer tests that keeps every state its calls leave behind. Each
/// test's sequence then goes through the conversation projection's cache step by step, as a
/// renderer follows a stream of updates, so the notification sequences those tests already spell
/// out serve as projection fixtures as they are.
final class CodexReducerSteps {
    private(set) var states: [(step: String, state: CodexTaskState)] = []
    private let reducer = CodexTaskReducer()

    var recording: Recorder { Recorder(steps: self) }

    struct Recorder {
        let steps: CodexReducerSteps

        @discardableResult
        func applySnapshot(_ value: JSONValue, to state: inout CodexTaskState) -> Bool {
            steps.record("snapshot", &state) { steps.reducer.applySnapshot(value, to: &$0) }
        }

        @discardableResult
        func applyNotification(method: String, params: JSONValue, sequence: UInt64, to state: inout CodexTaskState) -> Bool {
            steps.record(method, &state) {
                steps.reducer.applyNotification(method: method, params: params, sequence: sequence, to: &$0)
            }
        }

        @discardableResult
        func applyServerRequest(
            id: CodexRPCID, method: String, params: JSONValue?, sequence: UInt64, to state: inout CodexTaskState
        ) -> Bool {
            steps.record(method, &state) {
                steps.reducer.applyServerRequest(id: id, method: method, params: params, sequence: sequence, to: &$0)
            }
        }

        @discardableResult
        func resolveServerRequest(id: String, response: JSONValue?, in state: inout CodexTaskState) -> Bool {
            steps.record("resolve \(id)", &state) { steps.reducer.resolveServerRequest(id: id, response: response, in: &$0) }
        }

        @discardableResult
        func rejectServerRequest(id: String, code: Int64, message: String, in state: inout CodexTaskState) -> Bool {
            steps.record("reject \(id)", &state) {
                steps.reducer.rejectServerRequest(id: id, code: code, message: message, in: &$0)
            }
        }

        func reconcileResolvedServerRequestItems(in state: inout CodexTaskState) {
            steps.record("reconcile resolved requests", &state) { steps.reducer.reconcileResolvedServerRequestItems(in: &$0) }
        }

        func reconcileTerminalActivityItems(in state: inout CodexTaskState) {
            steps.record("reconcile terminal activity", &state) { steps.reducer.reconcileTerminalActivityItems(in: &$0) }
        }

        func mergeTurnPage(_ page: CodexTurnPage, prepending: Bool = false, into state: inout CodexTaskState) {
            steps.record("turn page", &state) { steps.reducer.mergeTurnPage(page, prepending: prepending, into: &$0) }
        }
    }

    private func record<Result>(_ step: String, _ state: inout CodexTaskState, _ body: (inout CodexTaskState) -> Result) -> Result {
        let result = body(&state)
        states.append((step: "\(states.count + 1). \(step)", state: state))
        return result
    }

    /// A cache following the recorded steps gives what a fresh projection gives at every step.
    func assertCacheFollowsEveryStep(file: StaticString = #filePath, line: UInt = #line) {
        Self.assertCacheFollows(states, file: file, line: line)
    }

    /// Projects `states` in order through one cache, as a renderer would over a stream of updates,
    /// and checks each result against a projection made without it.
    static func assertCacheFollows(
        _ states: [(step: String, state: CodexTaskState)],
        workspaceURL: URL = URL(filePath: "/tmp/yardlet-codex-projection", directoryHint: .isDirectory),
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let cache = ConversationProjectionCache()
        for (step, state) in states {
            let cached = cache.codex(state, workspaceURL: workspaceURL, historySelection: nil)
            let fresh = CodexConversationProjection.presentation(state, workspaceURL: workspaceURL, historySelection: nil)
            if cached != fresh {
                XCTFail("\(step): the cached projection differs from a fresh one", file: file, line: line)
            }
        }
    }
}
