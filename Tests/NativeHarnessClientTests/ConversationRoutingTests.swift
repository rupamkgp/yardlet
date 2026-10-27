import Foundation
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Every conversation is drawn by the one conversation renderer, `ConversationTimeline`: a Codex
/// task's before and after its first turn and while detached (plan M6, M7), every other harness's
/// (M9, M10), and the transcripts shown only to read (a subtask's panel, the reading fixtures, M8).
@MainActor
final class ConversationRoutingTests: XCTestCase {
    func testEveryConversationIsTheConversationTimeline() {
        let decoder = CodexTaskDecoder()
        var thread = decoder.thread(from: .object(["id": .string("thread-routing")]))!
        let empty = CodexTaskState(thread: thread)
        thread.turns = [decoder.turn(from: .object(["id": .string("turn-1"), "status": .string("completed")]),
                                     fallbackID: "turn-1")!]
        let withTurns = CodexTaskState(thread: thread)
        let entries = [TranscriptEntry(content: .user(text: "Hello"))]
        func drawn(_ harness: HarnessKind, _ state: CodexTaskState?) -> String {
            Self.drawnView(TaskConversationView(
                harness: harness, workspaceURL: URL(filePath: "/tmp"), entries: entries, codexTaskState: state
            ).body)
        }
        XCTAssertEqual(drawn(.codex, withTurns), "ConversationTimeline")
        XCTAssertEqual(drawn(.codex, empty), "ConversationTimeline")
        XCTAssertEqual(drawn(.codex, nil), "ConversationTimeline")
        for harness in HarnessCatalog.builtIns.map(\.id) where harness != .codex {
            XCTAssertEqual(drawn(harness, nil), "ConversationTimeline", "\(harness)")
        }
        for harness in [HarnessKind.claudeCode, .openCode, .grokBuild] {
            XCTAssertEqual(Self.drawnView(TranscriptConversationView(harness: harness, entries: entries).body),
                           "ConversationTimeline", "\(harness)")
        }
    }

    /// The view a `ViewBuilder` branch chose: the type inside its conditional content, through a
    /// `TranscriptConversationView`'s own body.
    static func drawnView(_ body: some View) -> String {
        var value: Any = body
        while true {
            if let transcript = value as? TranscriptConversationView { return drawnView(transcript.body) }
            let mirror = Mirror(reflecting: value)
            if String(describing: mirror.subjectType).hasPrefix("_ConditionalContent"),
               let storage = mirror.children.first?.value,
               let branch = Mirror(reflecting: storage).children.first?.value {
                value = branch
                continue
            }
            return String(describing: mirror.subjectType)
        }
    }
}
