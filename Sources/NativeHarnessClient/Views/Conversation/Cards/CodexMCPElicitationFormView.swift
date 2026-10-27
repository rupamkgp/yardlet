import SwiftUI

/// An MCP elicitation's form on the request card (`CodexMCPElicitationForm`): each field under the
/// server's title and description, with what it takes (required, a format, a range, a length or a
/// count of choices) and, once something is entered, why it cannot be sent yet. Submit stays off
/// until every required field is filled in and every field is valid (`ConversationRequest.route`).
/// An answered form shows what was sent, read-only, and no default as if it had been sent.
struct CodexMCPElicitationFormView: View {
    let form: CodexMCPElicitationForm
    @Binding var input: [String: CodexMCPElicitationFieldValue]
    let isAnswerable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(form.fields) { field in
                Group {
                    if form.recorded != nil {
                        sentRow(field)
                    } else {
                        fieldView(field)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(field.label)
            }
        }
        .disabled(!isAnswerable)
    }

    /// A field of an answered form: its title and the value sent, or that none was.
    private func sentRow(_ field: CodexMCPElicitationForm.Field) -> some View {
        let sent = sentText(field)
        return VStack(alignment: .leading, spacing: 3) {
            Text(field.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(sent ?? L10n.string("Not answered"))
                .font(.callout)
                .foregroundStyle(sent == nil ? .tertiary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sentText(_ field: CodexMCPElicitationForm.Field) -> String? {
        switch form.value(of: field, in: [:]) {
        case let .text(text)?: return text
        case let .flag(flag)?: return flag ? L10n.string("Yes") : L10n.string("No")
        case let .picked(picked)?:
            let options: [CodexMCPElicitationForm.Option] = switch field.kind {
            case let .choice(options), let .choices(options, _, _): options
            default: []
            }
            let titles = options.filter { picked.contains($0.value) }.map(\.title)
            return titles.isEmpty ? nil : titles.joined(separator: ", ")
        case nil: return nil
        }
    }

    @ViewBuilder
    private func fieldView(_ field: CodexMCPElicitationForm.Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .boolean = field.kind {
                Toggle(isOn: flag(field)) {
                    Text(field.label).font(.callout.weight(.medium))
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel(field.label)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(field.label)
                        .font(.callout.weight(.medium))
                    Text(field.isRequired ? L10n.string("Required") : L10n.string("Optional"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if let description = field.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control(field)
            if let hint = hint(field.kind) {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let issue = shownIssue(field) {
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel(issue.message)
            }
        }
    }

    @ViewBuilder
    private func control(_ field: CodexMCPElicitationForm.Field) -> some View {
        switch field.kind {
        case let .text(format, _, _):
            TextField(placeholder(format), text: text(field))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(field.label)
        case let .number(isInteger, _, _):
            TextField(isInteger ? L10n.string("Whole number") : L10n.string("Number"), text: text(field))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(field.label)
        case .boolean:
            EmptyView()
        case let .choice(options):
            optionList(field, options, isMultiple: false)
        case let .choices(options, _, _):
            optionList(field, options, isMultiple: true)
        }
    }

    private func optionList(
        _ field: CodexMCPElicitationForm.Field, _ options: [CodexMCPElicitationForm.Option], isMultiple: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.value) { option in
                let isSelected = picked(field).contains(option.value)
                Button {
                    toggle(option.value, in: field, isMultiple: isMultiple)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: isMultiple ? (isSelected ? "checkmark.square.fill" : "square")
                                                     : (isSelected ? "largecircle.fill.circle" : "circle"))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                        Text(option.title)
                            .font(.callout.weight(isSelected ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(isSelected ? ParityTheme.selectedFill : ParityTheme.subtleFill,
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .parityPointer()
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    // MARK: - Values

    private func text(_ field: CodexMCPElicitationForm.Field) -> Binding<String> {
        Binding {
            if case let .text(text)? = form.value(of: field, in: input) { return text }
            return ""
        } set: {
            input[field.id] = .text($0)
        }
    }

    private func flag(_ field: CodexMCPElicitationForm.Field) -> Binding<Bool> {
        Binding {
            if case let .flag(flag)? = form.value(of: field, in: input) { return flag }
            return false
        } set: {
            input[field.id] = .flag($0)
        }
    }

    private func picked(_ field: CodexMCPElicitationForm.Field) -> Set<String> {
        if case let .picked(picked)? = form.value(of: field, in: input) { return picked }
        return []
    }

    private func toggle(_ value: String, in field: CodexMCPElicitationForm.Field, isMultiple: Bool) {
        var picked = picked(field)
        if isMultiple {
            if picked.contains(value) { picked.remove(value) } else { picked.insert(value) }
        } else {
            picked = picked.contains(value) && !field.isRequired ? [] : [value]
        }
        input[field.id] = .picked(picked)
    }

    /// A field's issue once it holds something: an empty required field only keeps Submit off.
    private func shownIssue(_ field: CodexMCPElicitationForm.Field) -> CodexMCPElicitationForm.Issue? {
        guard let issue = form.issue(of: field, in: input), issue != .missing else { return nil }
        return issue
    }

    // MARK: - Words

    private func placeholder(_ format: CodexMCPElicitationForm.TextFormat?) -> String {
        switch format {
        case .email: "name@example.com"
        case .uri: "https://"
        case .date: L10n.string("YYYY-MM-DD")
        case .dateTime: L10n.string("YYYY-MM-DDThh:mm:ssZ")
        case nil: L10n.string("Answer")
        }
    }

    private func hint(_ kind: CodexMCPElicitationForm.Kind) -> String? {
        switch kind {
        case let .text(_, minLength?, maxLength?):
            L10n.format("%1$lld to %2$lld characters", Int64(minLength), Int64(maxLength))
        case let .text(_, minLength?, nil): L10n.format("At least %lld characters", Int64(minLength))
        case let .text(_, nil, maxLength?): L10n.format("Up to %lld characters", Int64(maxLength))
        case let .number(_, minimum?, maximum?):
            L10n.format("From %1$@ to %2$@", CodexMCPElicitationForm.text(minimum), CodexMCPElicitationForm.text(maximum))
        case let .number(_, minimum?, nil): L10n.format("%@ or more", CodexMCPElicitationForm.text(minimum))
        case let .number(_, nil, maximum?): L10n.format("%@ or less", CodexMCPElicitationForm.text(maximum))
        case let .choices(_, minItems?, maxItems?):
            L10n.format("Choose %1$lld to %2$lld", Int64(minItems), Int64(maxItems))
        case let .choices(_, minItems?, nil): L10n.format("Choose at least %lld", Int64(minItems))
        case let .choices(_, nil, maxItems?): L10n.format("Choose up to %lld", Int64(maxItems))
        case .choices: L10n.string("Choose one or more")
        default: nil
        }
    }
}
