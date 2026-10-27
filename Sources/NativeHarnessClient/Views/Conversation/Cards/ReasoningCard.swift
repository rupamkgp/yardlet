import SwiftUI

/// The provider's own reasoning. It stays collapsed so it never competes with the answer, and
/// it carries no control of its own beyond the disclosure the transcript already uses. The Codex
/// timeline reuses it for raw reasoning content, so both surfaces fold thought the same way.
struct ReasoningCard: View {
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var isExpanded = false
    let text: String
    let isStreaming: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.system(size: 12 * interfaceScale))
                .foregroundStyle(.secondary)
                .lineSpacing(ParityTheme.proseLineSpacing * interfaceScale)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "brain")
                    .font(.system(size: 11, weight: .medium))
                Text(L10n.string("Thought process"))
                if isStreaming {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(L10n.string("Thought process"))
        .accessibilityHint(
            isExpanded
                ? L10n.string("Hide the thought process")
                : L10n.string("Show the thought process")
        )
    }
}
