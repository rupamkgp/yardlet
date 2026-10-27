import AppKit
import SwiftUI

/// A task's pull request as a small pill: its glyph and "PR #123" tinted by its state, and a dot
/// for its checks (`TaskPullRequestBadge`). Clicking it opens the pull request in the default
/// browser; its help gives the state, checks and review.
struct TaskPullRequestBadgeView: View {
    let badge: TaskPullRequestBadge
    var onOpen: (URL) -> Void = { NSWorkspace.shared.open($0) }
    @Environment(\.yardletInterfaceScale) private var interfaceScale
    @State private var isHovered = false

    var body: some View {
        Button { onOpen(badge.url) } label: {
            HStack(spacing: 4) {
                Image(systemName: badge.glyph.systemName)
                    .font(.system(size: 10.5 * interfaceScale, weight: .semibold))
                Text(badge.title)
                    .font(.system(size: 11.5 * interfaceScale, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                if let checks = badge.checksTone {
                    Circle()
                        .fill(Self.color(checks))
                        .frame(width: 6 * interfaceScale, height: 6 * interfaceScale)
                }
            }
            .foregroundStyle(Self.color(badge.tone))
            .padding(.horizontal, 7)
            .frame(height: 20 * interfaceScale)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .parityPointer()
        .fixedSize()
        .help(badge.help)
        .accessibilityLabel(badge.accessibilityLabel)
        .accessibilityValue(badge.accessibilityValue)
        .accessibilityAddTraits(.isLink)
    }

    private var fill: Color {
        let base = badge.tone == .neutral ? Color.primary : Self.color(badge.tone)
        return base.opacity(isHovered ? 0.16 : badge.tone == .neutral ? 0.06 : 0.11)
    }

    /// Yardlet's status colours, as the title bar and cards already use them.
    static func color(_ tone: TaskPullRequestBadge.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .success: .green
        case .pending: .orange
        case .failure: .red
        case .merged: .purple
        }
    }
}
