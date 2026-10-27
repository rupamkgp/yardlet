import Foundation
import YardletAgentTools

/// Yardlet's own Gmail server: the tools it offers each signed-in Gmail account, named as the
/// claude.ai Gmail connector names them where they do the same thing (`search_threads`,
/// `get_thread`, `get_message`, `list_labels`, `create_draft`, `send_message`, `send_draft`), with
/// one `modify_labels` for the label changes it spreads over several tools. Each reaches a harness
/// under the account's slug (`gmail_search_threads`).
///
/// Every tool works with `gmail.modify` alone: Google lists it for reading, drafting, sending, and
/// changing labels, without the permanent deletion of `https://mail.google.com/`
/// (developers.google.com/workspace/gmail/api/auth/scopes). Sending and changing labels ask the
/// person before every call through the harness's own approval (`approvalRequired`).
enum GmailToolCatalog {
    static let searchThreads = "search_threads"
    static let getThread = "get_thread"
    static let getMessage = "get_message"
    static let listLabels = "list_labels"
    static let createDraft = "create_draft"
    static let sendDraft = "send_draft"
    static let sendMessage = "send_message"
    static let modifyLabels = "modify_labels"

    /// The one scope Yardlet asks Google for.
    static let scope = "https://www.googleapis.com/auth/gmail.modify"

    /// Asked about before every call, as the Claude app asks before its Gmail connector sends or
    /// labels: Claude Code's request card without "always allow", Codex `approval_mode = "prompt"`.
    static let approvalRequired: Set<String> = [sendDraft, sendMessage, modifyLabels]

    enum Format: String, CaseIterable {
        case minimal = "MINIMAL"
        case metadataOnly = "METADATA_ONLY"
        case plainText = "PLAIN_TEXT"
        case fullContent = "FULL_CONTENT"
    }

    static let tools: [ToolJSON] = [
        tool(searchThreads, "Search threads",
             "Searches the mailbox's threads with Gmail search syntax. Returns each thread's ID and its messages' "
                + "sender, recipients, date, subject, snippet, and labels, without bodies.",
             properties: [
                "query": string("Gmail search syntax, as in Gmail's search box: from:, to:, subject:, label:, is:unread, "
                    + "has:attachment, after:YYYY/MM/DD, before:YYYY/MM/DD, newer_than:2d, quoted phrases. Empty lists "
                    + "every thread outside spam and trash."),
                "pageSize": .object(["type": .string("integer"), "minimum": .integer(1), "maximum": .integer(50),
                                     "description": .string("Threads per page, 1 to 50. Defaults to 20.")]),
                "pageToken": string("nextPageToken from the previous page."),
                "includeTrash": .object(["type": .string("boolean"),
                                         "description": .string("Also search spam and trash. Defaults to false.")])
             ], readOnly: true),
        tool(getThread, "Get thread",
             "Gets one thread with its messages in order.",
             properties: [
                "threadId": string("The thread's ID."),
                "messageFormat": formatProperty
             ], required: ["threadId"], readOnly: true),
        tool(getMessage, "Get message",
             "Gets one message by its ID.",
             properties: [
                "messageId": string("The message's ID."),
                "messageFormat": formatProperty
             ], required: ["messageId"], readOnly: true),
        tool(listLabels, "List labels",
             "Lists the mailbox's labels, system and user, with the IDs the other tools take.",
             properties: [:], readOnly: true),
        tool(createDraft, "Create draft",
             "Creates a draft and returns its ID. With replyToMessageId it replies in that message's thread, to the "
                + "message's sender unless to is given.",
             properties: composeProperties, readOnly: false),
        tool(sendDraft, "Send draft",
             "Sends a draft by its ID.",
             properties: ["draftId": string("The draft's ID, as create_draft returned it.")],
             required: ["draftId"], readOnly: false, openWorld: true),
        tool(sendMessage, "Send message",
             "Sends a new email at once. The fields are create_draft's.",
             properties: composeProperties, readOnly: false, openWorld: true),
        tool(modifyLabels, "Modify labels",
             "Adds or removes labels on one thread or one message. Removing INBOX archives it; removing UNREAD marks "
                + "it read and adding UNREAD marks it unread.",
             properties: [
                "threadId": string("The thread to change, with all its messages. Give this or messageId."),
                "messageId": string("The one message to change. Give this or threadId."),
                "addLabelIds": stringArray("Label IDs to add, from list_labels (STARRED, UNREAD, IMPORTANT, or a user label's ID)."),
                "removeLabelIds": stringArray("Label IDs to remove (INBOX, UNREAD, or a user label's ID).")
             ], readOnly: false, destructive: true)
    ]

    static func definition(named name: String) -> ToolJSON? {
        tools.first { $0["name"]?.stringValue == name }
    }

    // MARK: Schema pieces

    private static var formatProperty: ToolJSON {
        .object([
            "type": .string("string"),
            "enum": .array(Format.allCases.map { .string($0.rawValue) }),
            "description": .string("PLAIN_TEXT (default): headers, snippet, the plain-text body, and attachments' names. "
                + "FULL_CONTENT: also the HTML body. MINIMAL: headers and snippet. METADATA_ONLY: sender, recipients, "
                + "date, and labels.")
        ])
    }

    private static var composeProperties: [String: ToolJSON] {
        [
            "to": stringArray("Recipients, as plain email addresses."),
            "cc": stringArray("Cc recipients, as plain email addresses."),
            "bcc": stringArray("Bcc recipients, as plain email addresses."),
            "subject": string("The subject line."),
            "body": string("The plain-text body, without Markdown."),
            "htmlBody": string("An HTML body, sent beside the plain-text one."),
            "replyToMessageId": string("The message this replies to.")
        ]
    }

    private static func string(_ description: String) -> ToolJSON {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func stringArray(_ description: String) -> ToolJSON {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                 "description": .string(description)])
    }

    private static func tool(_ name: String, _ title: String, _ description: String,
                             properties: [String: ToolJSON], required: [String] = [],
                             readOnly: Bool, destructive: Bool = false, openWorld: Bool = false) -> ToolJSON {
        var schema: [String: ToolJSON] = ["type": .string("object"), "properties": .object(properties),
                                          "additionalProperties": .bool(false)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object([
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object(schema),
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "openWorldHint": .bool(openWorld)
            ])
        ])
    }
}
