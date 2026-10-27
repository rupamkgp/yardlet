import SwiftUI

/// The review's rendered view of a Markdown file's change (`MarkdownReviewDiff`), read only: each
/// block drawn by the conversation's Markdown renderer, a block the change put in on the line diff's
/// green with a bar at its edge, one it took out on its red, faded, and runs of unchanged blocks
/// folded into a row that opens them.
struct MarkdownReviewView: View {
    let rows: [MarkdownReviewDiff.Row]
    /// The file's folder, which the document's relative links are read against.
    let documentFolder: URL?

    @State private var openedRuns: Set<Int> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !rows.contains(where: { if case .block = $0 { true } else { false } }) {
                    Text(L10n.string("The rendered document has no changed blocks."))
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
                ForEach(rows) { row in
                    switch row {
                    case let .block(block):
                        MarkdownReviewBlock(block: block)
                    case let .unchanged(id, blocks):
                        if openedRuns.contains(id) {
                            ForEach(blocks) { MarkdownReviewBlock(block: $0) }
                        } else {
                            foldedRun(id: id, count: blocks.count)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .environment(\.transcriptWorkspaceURL, documentFolder)
    }

    private func foldedRun(id: Int, count: Int) -> some View {
        Button { openedRuns.insert(id) } label: {
            Label(L10n.format("%d unchanged blocks", count), systemImage: "ellipsis")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ParityTheme.subtleFill)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .parityPointer()
        .help(L10n.string("Show unchanged blocks"))
    }
}

private struct MarkdownReviewBlock: View {
    let block: MarkdownReviewDiff.Block

    var body: some View {
        TranscriptMarkdownText(text: block.source)
            .opacity(block.change == .removed ? 0.6 : 1)
            .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint)
            .overlay(alignment: .leading) {
                if block.change != .unchanged { Rectangle().fill(bar).frame(width: 3) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityValue(accessibilityValue)
    }

    /// The line diff's colors (`DiffFileContent`).
    private var tint: Color {
        switch block.change {
        case .added: .green.opacity(0.075)
        case .removed: .red.opacity(0.075)
        case .unchanged: .clear
        }
    }

    private var bar: Color {
        block.change == .added ? .green : .red
    }

    private var accessibilityValue: String {
        switch block.change {
        case .added: L10n.string("Added")
        case .removed: L10n.string("Deleted")
        case .unchanged: ""
        }
    }
}

/// The control in a Markdown file's diff header that draws its change rendered, as the Codex app's
/// "Rich preview" toggle in its diff (`codex.diffView.richPreviewToggle`).
struct MarkdownReviewToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: "doc.richtext")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 24)
                .background(isOn ? ParityTheme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isOn ? .primary : .secondary)
        .parityPointer()
        .help(L10n.string("Rendered preview"))
        .accessibilityLabel(L10n.string("Rendered preview"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
