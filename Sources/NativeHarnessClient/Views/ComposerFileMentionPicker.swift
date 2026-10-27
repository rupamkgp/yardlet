import SwiftUI

/// The list a typed `@word` opens above the composer text. It only reports a choice; the
/// composer turns that choice into the same context mention the `@` button adds.
struct ComposerFileMentionPicker: View {
    let search: ComposerFileMentionSearch
    /// With more than one root, each row names the root its file comes from.
    var showsRoot = false
    let onSelect: (WorkspaceFileMatch) -> Void
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if search.query?.isEmpty != false {
                status(L10n.string("Type to search for files"))
            } else if search.matches.isEmpty && search.isSearching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("Searching files…")).foregroundStyle(.secondary)
                }
                .padding(8)
            } else if search.failed {
                status(L10n.string("Unable to search files"))
            } else if search.matches.isEmpty {
                status(L10n.string("No matching files"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                    }
                    // A short list keeps its own height; a long one scrolls within the bound.
                    .frame(height: min(rowsHeight, 240))
                    .onChange(of: search.highlightedMatch?.id) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(search.matches.enumerated()), id: \.element.id) { index, match in
                Button { onSelect(match) } label: {
                    ComposerFileMentionRow(match: match, showsRoot: showsRoot,
                                           isHighlighted: index == search.highlightedIndex)
                }
                .buttonStyle(.plain)
                .parityPointer()
                .id(match.id)
                .accessibilityLabel(match.name)
                .accessibilityValue(match.relativePath)
                .accessibilityAddTraits(index == search.highlightedIndex ? .isSelected : [])
            }
        }
    }

    private func status(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(8)
    }
}

/// One file or folder; renderable on its own, outside the scroll container.
struct ComposerFileMentionRow: View {
    let match: WorkspaceFileMatch
    var showsRoot = false
    var isHighlighted = false

    private var location: String {
        let root = showsRoot ? match.root.lastPathComponent : ""
        return [root, match.folder].filter { !$0.isEmpty }.joined(separator: "/")
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: match.isDirectory ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(match.name).font(.callout.weight(.medium)).lineLimit(1).layoutPriority(1)
            if !location.isEmpty {
                Text(location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(isHighlighted ? ParityTheme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}
