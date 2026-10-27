import Foundation
import YardletAgentTools

/// What Claude Code's request card says for a Gmail call that sends or changes labels, as the
/// Claude app's Gmail cards say it (2.42304.0 `gmailSendMessage`, `gmailLabelThread`): which
/// account, the recipients and subject over the body, or the labels. Claude Code asks before each
/// such call; the card offers no "always allow", as for a scheduled-task change.
enum GmailToolApproval {
    /// The Gmail tool behind a Claude Code name that asks every time, with its account; nil for
    /// any other tool.
    static func tool(named claudeToolName: String?,
                     labels: ConnectorToolLabels = .shared) -> (tool: String, account: String?)? {
        guard let claudeToolName, let label = labels.label(forClaudeTool: claudeToolName),
              label.localService == .gmail, GmailToolCatalog.approvalRequired.contains(label.tool) else { return nil }
        return (label.tool, label.account)
    }

    static func request(toolName: String?, input: JSONValue,
                        labels: ConnectorToolLabels = .shared) -> (title: String, detail: String)? {
        guard let (tool, account) = tool(named: toolName, labels: labels) else { return nil }
        let mailbox = account ?? "Gmail"
        var lines: [String] = []
        func list(_ key: String) -> [String] {
            switch input[key] {
            case .array(let values)?: values.compactMap(\.stringValue)
            case .string(let value)?: [value]
            default: []
            }
        }
        switch tool {
        case GmailToolCatalog.sendMessage:
            let to = list("to"), cc = list("cc"), bcc = list("bcc")
            if !to.isEmpty { lines.append(L10n.format("To: %@", to.joined(separator: ", "))) }
            if !cc.isEmpty { lines.append(L10n.format("Cc: %@", cc.joined(separator: ", "))) }
            if !bcc.isEmpty { lines.append(L10n.format("Bcc: %@", bcc.joined(separator: ", "))) }
            if let subject = input["subject"]?.stringValue, !subject.isEmpty {
                lines.append(L10n.format("Subject: %@", subject))
            }
            if input["replyToMessageId"]?.stringValue?.isEmpty == false {
                lines.append(L10n.string("Replies in the message's thread."))
            }
            var detail = lines.joined(separator: "\n")
            let body = input["body"]?.stringValue ?? input["htmlBody"]?.stringValue.map(GmailText.plainText(fromHTML:))
            if let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                let preview = body.count > 1_200 ? String(body.prefix(1_200)) + "…" : body
                detail += (detail.isEmpty ? "" : "\n\n") + preview
            }
            return (L10n.format("Allow Claude to send an email from %@?", mailbox), detail)
        case GmailToolCatalog.sendDraft:
            let draft = input["draftId"]?.stringValue ?? ""
            return (L10n.format("Allow Claude to send a draft from %@?", mailbox),
                    draft.isEmpty ? "" : L10n.format("Draft %@", draft))
        default:
            if let thread = input["threadId"]?.stringValue, !thread.isEmpty {
                lines.append(L10n.format("Thread %@", thread))
            } else if let message = input["messageId"]?.stringValue, !message.isEmpty {
                lines.append(L10n.format("Message %@", message))
            }
            let add = list("addLabelIds"), remove = list("removeLabelIds")
            if !add.isEmpty { lines.append(L10n.format("Adds: %@", add.joined(separator: ", "))) }
            if !remove.isEmpty { lines.append(L10n.format("Removes: %@", remove.joined(separator: ", "))) }
            if remove.contains("INBOX") { lines.append(L10n.string("Archives it.")) }
            if remove.contains("UNREAD") { lines.append(L10n.string("Marks it read.")) }
            if add.contains("UNREAD") { lines.append(L10n.string("Marks it unread.")) }
            return (L10n.format("Allow Claude to change labels in %@?", mailbox), lines.joined(separator: "\n"))
        }
    }
}
