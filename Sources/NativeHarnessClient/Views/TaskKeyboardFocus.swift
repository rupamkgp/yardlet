import SwiftUI
import Observation

enum TaskFocusTarget: Equatable {
    case chat, diff, terminal, browser, sideChat, files, features, permissions, intelligence, taskActions
    /// The side panel's launcher, and another task's conversation shown as a side-panel tab.
    case launcher, taskTab
    /// Not a focus: the composer's model menu opens (the Codex app's `composer.openModelPicker`, ⌃⇧M).
    case modelMenu

    static func destination(for surface: TaskSurface,
                            panels: TaskSurfaceNavigationProjection.PanelState) -> Self {
        switch surface {
        case .chat: return .chat
        case .diff where panels.trailingSurfaceID == "diff": return .diff
        case .browser where TaskSurfaceNavigationProjection.browserKey(inTab: panels.trailingSurfaceID) != nil: return .browser
        case .terminal where panels.isTerminalPresented: return .terminal
        default: return visibleContent(in: panels)
        }
    }

    static func visibleContent(in panels: TaskSurfaceNavigationProjection.PanelState) -> Self {
        if panels.trailingSurfaceID == "files" { return .files }
        if panels.trailingSurfaceID == "sideChat" { return .sideChat }
        if TaskSurfaceNavigationProjection.browserKey(inTab: panels.trailingSurfaceID) != nil { return .browser }
        if panels.trailingSurfaceID == "diff" { return .diff }
        if panels.trailingSurfaceID == TaskSurfaceNavigationProjection.launcherID { return .launcher }
        if let shown = panels.trailingSurfaceID, TaskSurfaceNavigationProjection.taskID(inTab: shown) != nil {
            return .taskTab
        }
        return panels.isTerminalPresented ? .terminal : .chat
    }
}

/// A task owns its pending keyboard handoff. Requests are consumed once and are never persisted.
@MainActor @Observable
final class TaskKeyboardFocus {
    struct Request: Equatable {
        let id = UUID()
        let target: TaskFocusTarget
    }
    private(set) var request: Request?
    @ObservationIgnored private var modalReturnTarget: TaskFocusTarget?

    func move(to target: TaskFocusTarget) { request = Request(target: target) }

    @discardableResult
    func consume(_ candidate: Request) -> Bool {
        guard request == candidate else { return false }
        request = nil
        return true
    }

    func rememberModalReturn(to target: TaskFocusTarget) { modalReturnTarget = target }

    func returnFromModal() {
        guard let target = modalReturnTarget else { return }
        modalReturnTarget = nil
        move(to: target)
    }

    func cancel() {
        request = nil
        modalReturnTarget = nil
    }
}

private struct TaskKeyboardFocusKey: EnvironmentKey {
    static let defaultValue: TaskKeyboardFocus? = nil
}

extension EnvironmentValues {
    var taskKeyboardFocus: TaskKeyboardFocus? {
        get { self[TaskKeyboardFocusKey.self] }
        set { self[TaskKeyboardFocusKey.self] = newValue }
    }
}

private struct TaskFocusReceiver: ViewModifier {
    private struct Delivery: Equatable {
        let request: TaskKeyboardFocus.Request?
        let enabled: Bool
    }
    let target: TaskFocusTarget
    let isFocused: FocusState<Bool>.Binding
    let enabled: Bool
    @Environment(\.taskKeyboardFocus) private var focus

    func body(content: Content) -> some View {
        content.task(id: Delivery(request: focus?.request, enabled: enabled)) {
            guard enabled, let request = focus?.request, request.target == target else { return }
            // Wait for the newly opened panel's control to join the window's focus system.
            await Task.yield()
            guard !Task.isCancelled, focus?.consume(request) == true else { return }
            isFocused.wrappedValue = true
        }
    }
}

extension View {
    func taskFocus(_ target: TaskFocusTarget, isFocused: FocusState<Bool>.Binding, enabled: Bool = true) -> some View {
        modifier(TaskFocusReceiver(target: target, isFocused: isFocused, enabled: enabled))
    }
}
