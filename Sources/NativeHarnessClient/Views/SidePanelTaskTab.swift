import SwiftUI

/// What a task's side panel needs from the window to show other tasks' conversations as tabs.
struct SidePanelTaskServices {
    /// The task, while it is neither archived nor gone.
    let record: @MainActor (UUID) -> SessionRecord?
    /// The tasks the panel can open, most recent first, without the panel's own.
    let choices: @MainActor () -> [SessionRecord]
    let projectName: @MainActor (SessionRecord) -> String
    /// The tab for a task (`SidePanelTaskTab`), closing with the given action.
    let tab: @MainActor (SessionRecord, _ onClose: @escaping () -> Void) -> AnyView

    /// The + menu's Tasks submenu lists this many.
    static let menuCount = 8

    @MainActor func choiceTabs(limit: Int? = nil) -> [WorkSurfaceTab] {
        let tasks = choices()
        return (limit.map { Array(tasks.prefix($0)) } ?? tasks).map {
            TaskSidePanelTabs.taskTab($0, project: projectName($0))
        }
    }
}

/// Another task's conversation as a side-panel tab: its conversation and composer as its own view has
/// them (the `TaskDetail` a side chat shows, with that task's composer actions, so a reply queues or
/// steers as it would there), under the panel's tab strip. A task on screen in another pane of the
/// window shows a line saying so instead, as the Claude app shows "Showing in another pane", so its
/// draft, reading place and focus are in one place.
struct SidePanelTaskTab: View {
    let session: SessionRecord
    let projectName: String
    /// Shows the pane that has the task on screen; nil when no other pane does.
    let showOtherPane: (() -> Void)?
    let parentFocus: TaskKeyboardFocus
    let childFocus: TaskKeyboardFocus
    let onOpenTask: () -> Void
    let onClose: () -> Void
    let content: AnyView

    private struct FocusDelivery: Equatable {
        let id: UUID
        let request: TaskKeyboardFocus.Request?
        let isElsewhere: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(title: session.title, systemName: "text.bubble", harness: session.harness,
                              workspaceURL: session.workspaceURL, onClose: onClose) {
                ParityIconButton(systemName: "arrow.up.forward.square", help: L10n.string("Open task"),
                                 action: onOpenTask)
            }
            HStack(spacing: 6) {
                HarnessIdentityLabel(harness: session.harness, size: 14)
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text(projectName).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.vertical, 6)
            if let showOtherPane {
                VStack(spacing: 10) {
                    Text(L10n.string("Showing in another pane"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(L10n.string("Go to Pane"), action: showOtherPane)
                        .controlSize(.small)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                content
            }
        }
        .background(ParityTheme.canvas)
        .task(id: FocusDelivery(id: session.id, request: parentFocus.request, isElsewhere: showOtherPane != nil)) {
            guard let request = parentFocus.request, request.target == .taskTab, showOtherPane == nil else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            if parentFocus.consume(request) { childFocus.move(to: .chat) }
        }
    }
}
