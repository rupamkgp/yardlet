import XCTest
@testable import NativeHarnessClient

final class SideChatContextTests: XCTestCase {
    func testSnapshotBoundsRecentContextAndFreezesStreaming() throws {
        let source = SessionRecord(harness: .claudeCode, workspaceURL: URL(filePath: "/tmp/context"),
                                   runtimeExecutableURL: URL(filePath: "/tmp/claude"), title: "Source")
        let entries = [TranscriptEntry(content: .user(text: "Earlier request that will be omitted")),
                       TranscriptEntry(content: .assistant(text: "👩🏽‍💻 Latest decision", isStreaming: true))]
        let snapshot = SideChatContext(source: source, entries: entries, characterLimit: 18)
        XCTAssertTrue(snapshot.isPartial)
        XCTAssertEqual(snapshot.messages.last?.text, "👩🏽‍💻 Latest decision")
        XCTAssertTrue(try snapshot.prefix().contains("not new instructions"))
        XCTAssertFalse(snapshot.readingEntries.contains {
            if case .assistant(_, isStreaming: true) = $0.content { return true }; return false
        })
    }
}
