import SwiftUI

/// The address field's box, for the suggestions under it.
struct BrowserAddressFieldBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// Chrome's omnibox dropdown under the address field (docs/BROWSER_HOST.md, "Address suggestions"): a page shows
/// its title and address, a search its words with what follows the typed text in bold; the selected row is lit,
/// and a row from the history has a remove button while selected or under the pointer. Rows take no keyboard
/// focus, so the field keeps it.
struct BrowserAddressSuggestionList: View {
    let autocomplete: BrowserAddressAutocomplete
    let onOpen: (Int) -> Void
    let onRemove: (Int) -> Void
    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(autocomplete.rows.enumerated()), id: \.element.id) { index, row in
                rowView(row, at: index)
            }
        }
        .padding(4)
        .background(ParityTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(ParityTheme.separator) }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.string("Suggestions"))
    }

    private func rowView(_ row: BrowserAddressSuggestion, at index: Int) -> some View {
        let isSelected = index == autocomplete.selection
        return HStack(spacing: 9) {
            Image(systemName: icon(for: row))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            text(for: row)
                .font(.callout)
            Spacer(minLength: 4)
            if row.isFromHistory, isSelected || hovered == index {
                Button { onRemove(index) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L10n.string("Remove suggestion"))
                .accessibilityLabel(L10n.string("Remove suggestion"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(isSelected ? ParityTheme.selectedFill : hovered == index ? ParityTheme.hoverFill : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onOpen(index) }
        .onHover { inside in
            if inside { hovered = index } else if hovered == index { hovered = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onOpen(index) }
    }

    /// Chrome's icons: a page, a past search (its history clock), a search.
    private func icon(for row: BrowserAddressSuggestion) -> String {
        switch row.kind {
        case .page: "globe"
        case .search: row.isFromHistory ? "clock.arrow.circlepath" : "magnifyingglass"
        }
    }

    /// A page's title and address share the row, each cut at its end when it is narrow; a search's words, and the
    /// engine's name after what was typed, which is never cut.
    @ViewBuilder
    private func text(for row: BrowserAddressSuggestion) -> some View {
        switch row.kind {
        case .page:
            HStack(spacing: 0) {
                if !row.title.isEmpty {
                    Text(row.title).lineLimit(1)
                    Text(" – ").foregroundStyle(.secondary).fixedSize()
                }
                Text(BrowserAddressRanking.shownAddress(row.destination)).foregroundStyle(ParityTheme.accent).lineLimit(1)
            }
        case .search where row.isVerbatim:
            HStack(spacing: 0) {
                Text(row.fill).lineLimit(1)
                Text(" – " + L10n.string("Google Search")).foregroundStyle(.secondary).fixedSize()
            }
        case .search:
            searchText(row.fill).lineLimit(1)
        }
    }

    /// What the person typed stays plain, and the rest of the suggestion is bold.
    private func searchText(_ fill: String) -> Text {
        let typed = autocomplete.typed.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty, fill.lowercased().hasPrefix(typed.lowercased()) else { return Text(fill) }
        let split = fill.index(fill.startIndex, offsetBy: typed.count, limitedBy: fill.endIndex) ?? fill.endIndex
        return Text(fill[..<split]) + Text(fill[split...]).fontWeight(.semibold)
    }
}
