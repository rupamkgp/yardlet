import XCTest
@testable import NativeHarnessClient

@MainActor
final class TaskKeyboardFocusTests: XCTestCase {
    func testOnlyNewestRequestCanMoveFocusAndCanBeConsumedOnce() throws {
        let focus = TaskKeyboardFocus()
        focus.move(to: .browser)
        let stale = try XCTUnwrap(focus.request)
        focus.move(to: .chat)
        let current = try XCTUnwrap(focus.request)
        XCTAssertFalse(focus.consume(stale))
        XCTAssertEqual(focus.request?.target, .chat)
        XCTAssertTrue(focus.consume(current))
        XCTAssertFalse(focus.consume(current))
        XCTAssertNil(focus.request)
    }

    func testTaskSwitchCancelsPendingAndModalReturnWithoutAffectingAnotherTask() {
        let first = TaskWorkspaceState()
        let second = TaskWorkspaceState()
        first.keyboardFocus.move(to: .terminal)
        first.keyboardFocus.rememberModalReturn(to: .features)
        second.keyboardFocus.move(to: .browser)
        first.keyboardFocus.cancel()
        first.keyboardFocus.returnFromModal()
        XCTAssertNil(first.keyboardFocus.request)
        XCTAssertEqual(second.keyboardFocus.request?.target, .browser)
        XCTAssertEqual(first.snapshot, TaskWorkspaceSnapshot(panelsRevision: TaskWorkspaceSnapshot.browserTabsPanelsRevision))
    }

    func testModalReturnUsesItsOriginOnce() throws {
        let focus = TaskKeyboardFocus()
        focus.rememberModalReturn(to: .permissions)
        focus.returnFromModal()
        let request = try XCTUnwrap(focus.request)
        XCTAssertEqual(request.target, .permissions)
        focus.consume(request)
        focus.returnFromModal()
        XCTAssertNil(focus.request)
    }

    func testClosingPanelRoutesFocusToRemainingVisibleSurface() {
        XCTAssertEqual(TaskFocusTarget.destination(for: .browser, panels: .init()), .chat)
        XCTAssertEqual(TaskFocusTarget.destination(for: .browser, panels: .init(isTerminalPresented: true)), .terminal)
        XCTAssertEqual(TaskFocusTarget.destination(for: .terminal, panels: .init(trailingSurfaceID: "diff")), .diff)
        XCTAssertEqual(TaskFocusTarget.destination(for: .terminal, panels: .init(
            trailingSurfaceID: TaskSurfaceNavigationProjection.browserTabID(UUID()))), .browser)
        XCTAssertEqual(TaskFocusTarget.destination(for: .chat, panels: .init()), .chat)
        XCTAssertEqual(TaskFocusTarget.destination(for: .diff, panels: .init(trailingSurfaceID: "diff", isTerminalPresented: true)), .diff)
    }
}
