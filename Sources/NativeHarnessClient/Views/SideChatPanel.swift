import SwiftUI

struct SideChatPanel: View {
    let workspaceURL: URL
    let harness: HarnessKind
    let childID: UUID?
    let isLoading: Bool
    let errorMessage: String?
    let parentFocus: TaskKeyboardFocus
    let childFocus: TaskKeyboardFocus?
    let onCreate: () -> Void
    let onClose: () -> Void
    let content: AnyView?
    @FocusState private var isCreateFocused: Bool

    private struct FocusDelivery: Equatable {
        let childID: UUID?
        let request: TaskKeyboardFocus.Request?
        let isLoading: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkSurfaceHeader(title: L10n.string("Side chat"), systemName: "bubble.left.and.bubble.right",
                              workspaceURL: workspaceURL, onClose: onClose) { EmptyView() }
            HarnessIdentityLabel(harness: harness, size: 14)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 6)
            if let content {
                content
            } else {
                VStack(spacing: 12) {
                    if isLoading { ProgressView().controlSize(.small) }
                    else {
                        if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.secondary) }
                        Button(L10n.string(errorMessage == nil ? "Side chat" : "Retry"), action: onCreate)
                            .focused($isCreateFocused)
                    }
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ParityTheme.canvas)
        .task(id: FocusDelivery(childID: childID, request: parentFocus.request, isLoading: isLoading)) {
            guard let request = parentFocus.request, request.target == .sideChat else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            if let childFocus {
                if parentFocus.consume(request) { childFocus.move(to: .chat) }
            } else {
                isCreateFocused = !isLoading
            }
        }
    }
}
