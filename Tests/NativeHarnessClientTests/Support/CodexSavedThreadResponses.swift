import Foundation
@testable import NativeHarnessClient

/// What a real App Server (codex-cli 0.157.1) answers for a saved thread a detached task reads:
/// `thread/read` without its turns (`includeTurns: false` gives `turns: []` and the rollout `path`),
/// and `thread/turns/list` pages asked newest first (`data` newest first, `nextCursor` for the turns
/// before the page, `backwardsCursor` for the ones after it).
enum CodexSavedThreadResponses {
    /// The `thread/read` result for `thread` without its turns.
    static func metadata(_ thread: JSONValue) -> JSONValue {
        guard case var .object(fields) = thread else { return .object(["thread": thread]) }
        fields["turns"] = .array([])
        return .object(["thread": .object(fields)])
    }

    /// The `thread/turns/list` result for `thread`'s turns before `cursor` ("before-<index>", nil for
    /// the newest), `limit` of them, newest first.
    static func page(_ thread: JSONValue, before cursor: String? = nil, limit: Int = 5) -> JSONValue {
        let turns = thread["turns"]?.arrayValue ?? []
        let end = cursor.flatMap { Int($0.dropFirst("before-".count)) } ?? turns.count
        let start = max(0, end - limit)
        return .object([
            "data": .array(Array(turns[start..<end].reversed())),
            "nextCursor": start > 0 ? .string("before-\(start)") : .null,
            "backwardsCursor": .string("after-\(end)")
        ])
    }
}
