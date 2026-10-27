import SwiftUI

/// The same provider-owned choices serve the + menu and a typed slash prefix. This view has no
/// submission or provider action: its only action returns a choice to the draft's composer.
struct ComposerCommandPicker: View {
    let commands: [ProviderComposerCommand]
    var query = ""
    var isLoading = false
    var error: String?
    /// The row Return and Tab choose; arrow keys in the composer move it.
    var highlightedIndex: Int? = nil
    let onSelect: (ProviderComposerCommand) -> Void
    @State private var rowsHeight: CGFloat = 0

    private var matches: [ProviderComposerCommand] { ComposerCommands.matching(commands, query: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("Loading commands…")).foregroundStyle(.secondary)
                }
                .padding(8)
            } else if let error, !error.isEmpty {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled).padding(8)
            } else if matches.isEmpty {
                Text(L10n.string("No commands")).foregroundStyle(.secondary).padding(8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        ComposerCommandRows(commands: matches, highlightedIndex: highlightedIndex, onSelect: onSelect)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                    }
                    // A short list keeps its own height; a long one scrolls within the bound.
                    .frame(height: min(rowsHeight, 240))
                    .onChange(of: highlightedIndex) { _, index in
                        if let index, matches.indices.contains(index) { proxy.scrollTo(matches[index].id) }
                    }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The rows with their group headings (the Codex app lists Skills under its own heading).
/// Renderable outside the scroll container.
struct ComposerCommandRows: View {
    let commands: [ProviderComposerCommand]
    var highlightedIndex: Int? = nil
    var onSelect: (ProviderComposerCommand) -> Void = { _ in }

    private struct Line: Identifiable {
        let index: Int
        let command: ProviderComposerCommand
        /// The group heading shown above this row, when the row starts a group.
        let heading: String?
        var id: String { command.id }
    }

    private var lines: [Line] {
        commands.enumerated().map { index, command in
            let starts = index == 0 || commands[index - 1].group != command.group
            return Line(index: index, command: command, heading: starts ? command.group : nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                if let heading = line.heading {
                    Text(heading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.top, line.index == 0 ? 2 : 8).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                Button { onSelect(line.command) } label: {
                    ComposerCommandRow(command: line.command, isHighlighted: line.index == highlightedIndex)
                }
                .buttonStyle(.plain)
                .parityPointer()
                .id(line.command.id)
                .accessibilityLabel(line.command.displayTitle)
                .accessibilityValue(line.command.description)
                .accessibilityAddTraits(line.index == highlightedIndex ? .isSelected : [])
            }
        }
    }
}

/// Shared row content, also renderable independently of the platform's scroll container.
struct ComposerCommandRow: View {
    let command: ProviderComposerCommand
    var isHighlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(command.displayTitle).font(.callout.weight(.medium)).lineLimit(1).layoutPriority(1)
                if !command.argumentHint.isEmpty {
                    Text(command.argumentHint).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !command.description.isEmpty {
                Text(command.description).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(isHighlighted ? ParityTheme.selectedFill : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }
}
