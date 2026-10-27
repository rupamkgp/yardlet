import XCTest
@testable import NativeHarnessClient

@MainActor
final class SubtaskConversationActionsTests: XCTestCase {
    /// The subtask pane shows a child conversation; its menus must not edit or restore the parent.
    func testAReadOnlyChildConversationGetsNoRewindActions() {
        var parent = ConversationActions()
        parent.rewind = ConversationRewindActions(
            beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {},
            loadFilePoints: { [] }, previewFiles: { _ in throw CancellationError() },
            restoreFiles: { _ in throw CancellationError() })
        parent.providerNotices = TaskProviderNotices(canContinue: true)
        let child = parent.readOnlyChild
        XCTAssertNil(child.rewind)
        XCTAssertEqual(child.providerNotices?.canContinue, true)
    }
}
