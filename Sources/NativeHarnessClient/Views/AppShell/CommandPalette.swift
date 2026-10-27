import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemName: String
    let action: () -> Void
}

/// Pure keyboard-selection behavior for the command palette. Keeping the wraparound rule
/// outside the view makes the native keyboard path deterministic and directly testable.
enum CommandPaletteSelection {
    static func movedIndex(currentIndex: Int?, count: Int, offset: Int) -> Int? {
        guard count > 0, offset != 0 else { return count > 0 ? currentIndex ?? 0 : nil }
        let startingIndex = currentIndex ?? (offset > 0 ? -1 : count)
        return (startingIndex + offset).modulo(count)
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    let items: [CommandPaletteItem]
    let onSelect: (CommandPaletteItem) -> Void
    @State private var query = ""
    @State private var selectedIndex: Int?
    @FocusState private var isSearchFocused: Bool

    private var filteredItems: [CommandPaletteItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard !normalized.isEmpty else { return items }
        return items.filter {
            $0.title.localizedLowercase.contains(normalized)
                || $0.subtitle.localizedLowercase.contains(normalized)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField(L10n.string("Search commands"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($isSearchFocused)
                    .accessibilityLabel(L10n.string("Search commands"))
                    .onSubmit { runSelected() }
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1)
                        return .handled
                    }
                Button(L10n.string("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
            .padding(14)

            Rectangle().fill(ParityTheme.separator).frame(height: 1)

            if filteredItems.isEmpty {
                ContentUnavailableView(
                    L10n.string("No matching commands"),
                    systemImage: "command"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                Button {
                                    selectedIndex = index
                                    onSelect(item)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: item.systemName)
                                            .frame(width: 22)
                                            .foregroundStyle(.secondary)
                                        Text(item.title)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                            .help(item.title)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 36)
                                    .contentShape(Rectangle())
                                }
                                .id(item.id)
                                .buttonStyle(.borderless)
                                .parityPointer()
                                .background(
                                    index == selectedIndex
                                        ? ParityTheme.selectedFill
                                        : .clear,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(item.title)
                                .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selectedIndex) { _, index in
                        guard let index, filteredItems.indices.contains(index) else { return }
                        proxy.scrollTo(filteredItems[index].id)
                    }
                    .onChange(of: query) { _, _ in
                        if let first = filteredItems.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
        }
        .frame(width: 520, height: 420)
        .background(ParityTheme.canvas)
        .onAppear {
            isSearchFocused = true
            selectedIndex = filteredItems.isEmpty ? nil : 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = filteredItems.isEmpty ? nil : 0
        }
    }

    private func moveSelection(by offset: Int) {
        selectedIndex = CommandPaletteSelection.movedIndex(
            currentIndex: selectedIndex,
            count: filteredItems.count,
            offset: offset
        )
    }

    private func runSelected() {
        guard !filteredItems.isEmpty else { return }
        let index = min(max(selectedIndex ?? 0, 0), filteredItems.count - 1)
        let item = filteredItems[index]
        onSelect(item)
        dismiss()
    }
}
