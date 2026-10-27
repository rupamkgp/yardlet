import Foundation
import YardletAgentTools

/// What Claude Code's request card says for a Google tool that writes: a Gmail send or label change
/// (`GmailToolApproval`), a Calendar event created, changed, deleted, or answered, or a Drive file
/// created, copied, or changed. It names the account and what the call would do. Claude Code asks
/// before each such call; the card offers no "always allow", as for a scheduled-task change.
enum GoogleToolApproval {
    static func request(toolName: String?, input: JSONValue,
                        labels: ConnectorToolLabels = .shared) -> (title: String, detail: String)? {
        if let gmail = GmailToolApproval.request(toolName: toolName, input: input, labels: labels) { return gmail }
        guard let toolName, let label = labels.label(forClaudeTool: toolName),
              let service = label.localService, service.approvalRequiredTools.contains(label.tool) else { return nil }
        let account = label.account ?? service.name
        switch service {
        case .gmail: return nil
        case .googleCalendar: return calendar(label.tool, account: account, input: input)
        case .googleDrive: return drive(label.tool, account: account, input: input)
        }
    }

    private static func text(_ input: JSONValue, _ key: String) -> String? {
        guard let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func list(_ input: JSONValue, _ key: String) -> [String] {
        switch input[key] {
        case .array(let values)?: values.compactMap { $0.stringValue ?? $0["email"]?.stringValue }
        case .string(let value)?: [value]
        default: []
        }
    }

    private static func preview(_ text: String, limit: Int = 600) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    private static func calendar(_ tool: String, account: String, input: JSONValue) -> (title: String, detail: String) {
        var lines: [String] = []
        if let summary = text(input, "summary") { lines.append(L10n.format("Title: %@", summary)) }
        let start = text(input, "startTime"), end = text(input, "endTime")
        if let start {
            lines.append(L10n.format("When: %@", end.map { "\(start) – \($0)" } ?? start))
        } else if let end {
            lines.append(L10n.format("Ends: %@", end))
        }
        if let zone = text(input, "timeZone") { lines.append(L10n.format("Time zone: %@", zone)) }
        let invited = list(input, "attendees") + list(input, "attendeeEmails") + list(input, "addedAttendees")
            + list(input, "addedAttendeeEmails")
        if !invited.isEmpty { lines.append(L10n.format("Invites: %@", invited.joined(separator: ", "))) }
        let removed = list(input, "removedAttendeeEmails")
        if !removed.isEmpty { lines.append(L10n.format("Removes: %@", removed.joined(separator: ", "))) }
        if input["addGoogleMeetUrl"] == .bool(true) { lines.append(L10n.string("Adds a Google Meet link.")) }
        if let location = text(input, "location") { lines.append(L10n.format("Location: %@", location)) }
        if let event = text(input, "eventId"), tool != GoogleCalendarToolCatalog.createEvent {
            lines.insert(L10n.format("Event %@", event), at: 0)
        }
        switch text(input, "notificationLevel") ?? "ALL" {
        case "NONE": lines.append(L10n.string("Google emails no one about it."))
        case "EXTERNAL_ONLY": lines.append(L10n.string("Google emails guests outside the organization."))
        default: lines.append(L10n.string("Google emails the guests."))
        }
        let title: String
        switch tool {
        case GoogleCalendarToolCatalog.createEvent:
            title = L10n.format("Allow Claude to create an event in %@'s calendar?", account)
        case GoogleCalendarToolCatalog.updateEvent:
            title = L10n.format("Allow Claude to change an event in %@'s calendar?", account)
        case GoogleCalendarToolCatalog.deleteEvent:
            title = L10n.format("Allow Claude to delete an event from %@'s calendar?", account)
        default:
            let answer = switch text(input, "responseStatus") {
            case "accepted"?: L10n.string("Going")
            case "declined"?: L10n.string("Not going")
            default: L10n.string("Maybe")
            }
            lines.insert(L10n.format("Answer: %@", answer), at: min(1, lines.count))
            if let comment = text(input, "responseComment") { lines.append(L10n.format("Note: %@", comment)) }
            title = L10n.format("Allow Claude to answer an invitation as %@?", account)
        }
        if let description = text(input, "description") {
            return (title, lines.joined(separator: "\n") + "\n\n" + preview(description))
        }
        return (title, lines.joined(separator: "\n"))
    }

    private static func drive(_ tool: String, account: String, input: JSONValue) -> (title: String, detail: String) {
        var lines: [String] = []
        if let file = text(input, "fileId") { lines.append(L10n.format("File %@", file)) }
        if let title = text(input, "title") { lines.append(L10n.format("Title: %@", title)) }
        if let type = text(input, "contentMimeType") ?? text(input, "mimeType") { lines.append(L10n.format("Type: %@", type)) }
        if let folder = text(input, "parentId") { lines.append(L10n.format("Folder %@", folder)) }
        var detail = lines.joined(separator: "\n")
        if let content = input["textContent"]?.stringValue, !content.isEmpty {
            detail += (detail.isEmpty ? "" : "\n\n") + preview(content)
        } else if text(input, "base64Content") != nil {
            detail += (detail.isEmpty ? "" : "\n") + L10n.string("With content other than text.")
        }
        let title = switch tool {
        case GoogleDriveToolCatalog.createFile: L10n.format("Allow Claude to create a file in %@'s Drive?", account)
        case GoogleDriveToolCatalog.copyFile: L10n.format("Allow Claude to copy a file in %@'s Drive?", account)
        default: L10n.format("Allow Claude to change a file in %@'s Drive?", account)
        }
        return (title, detail)
    }
}
