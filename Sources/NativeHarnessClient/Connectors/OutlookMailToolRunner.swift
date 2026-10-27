import Foundation
import YardletAgentTools

/// Runs one Outlook mail tool call against Microsoft Graph and answers with compact JSON text.
/// Arguments are checked before any request; a mistake the model can fix is an error result.
/// Graph's errors and a sign-in that ended are thrown to the connector center, which words them.
struct OutlookMailToolRunner {
    let api: GraphAPI

    typealias Problem = ConnectorToolArguments.Problem
    private typealias Arguments = ConnectorToolArguments
    private typealias Catalog = OutlookMailToolCatalog

    /// A body is cut here, as Gmail's are.
    static let bodyLimit = 40_000

    private static let listFields = "id,conversationId,subject,from,toRecipients,ccRecipients,receivedDateTime,"
        + "bodyPreview,isRead,isDraft,hasAttachments,importance,categories,flag,parentFolderId,webLink"

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case Catalog.searchMessages: result = try await search(arguments)
            case Catalog.getMessage: result = try await message(arguments)
            case Catalog.listFolders: result = try await folders(arguments)
            case Catalog.createDraft: result = try await draft(arguments)
            case Catalog.sendDraft: result = try await sendDraft(arguments)
            case Catalog.sendMessage: result = try await send(arguments)
            case Catalog.updateMessage: result = try await update(arguments)
            default: return .error("Unknown tool: \(name)")
            }
            return .text(Arguments.text(result))
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        } catch GraphAPI.Failure.invalidID(let id) {
            return .error("Not an ID Outlook takes: \(id)")
        }
    }

    // MARK: Reading

    private func search(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let unreadOnly = Arguments.bool(arguments["unreadOnly"]) == true
        let query = Arguments.string(arguments, "query")
        let list: ToolJSON
        if let token = Arguments.string(arguments, "pageToken") {
            list = try await api.get(page: token)
        } else {
            var path = ["me", "messages"]
            if let folder = Arguments.string(arguments, "folderId") {
                path = ["me", "mailFolders", try GraphAPI.segment(folder), "messages"]
            }
            var items = [URLQueryItem(name: "$select", value: Self.listFields),
                         URLQueryItem(name: "$top", value: String(Arguments.pageSize(arguments, range: 1...50, fallback: 20)))]
            if let query {
                // Graph sorts search results newest first itself and takes no $orderby or $filter with them.
                items.append(URLQueryItem(name: "$search", value: "\"\(query.replacingOccurrences(of: "\"", with: "\\\""))\""))
            } else {
                items.append(URLQueryItem(name: "$orderby", value: "receivedDateTime desc"))
                if unreadOnly { items.append(URLQueryItem(name: "$filter", value: "isRead eq false")) }
            }
            list = try await api.get(path, items)
        }
        var result = GraphShape.page(list, key: "messages", Self.summary)
        if unreadOnly, query != nil, case .array(let messages)? = result["messages"] {
            var fields = result.objectValue ?? [:]
            fields["messages"] = .array(messages.filter { $0["isRead"] != .bool(true) })
            result = .object(fields)
        }
        return result
    }

    private func message(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try GraphAPI.segment(try Arguments.required(arguments, "messageId"))
        let html = Arguments.string(arguments, "format") == "html"
        let message = try await api.get(
            ["me", "messages", id],
            [URLQueryItem(name: "$select", value: Self.listFields + ",bccRecipients,replyTo,sentDateTime,body,internetMessageId"),
             URLQueryItem(name: "$expand", value: "attachments($select=id,name,contentType,size,isInline)")],
            headers: ["Prefer": "outlook.body-content-type=\"\(html ? "html" : "text")\""])
        var fields = Self.summary(message).objectValue ?? [:]
        fields["bcc"] = GraphShape.people(message["bccRecipients"])
        fields["replyTo"] = GraphShape.people(message["replyTo"])
        fields["sentDateTime"] = message["sentDateTime"]
        fields["bodyPreview"] = nil
        var body = message["body"]?["content"]?.stringValue ?? ""
        // A message Graph could not turn into text still reads as text.
        if !html, message["body"]?["contentType"]?.stringValue?.lowercased() == "html" {
            body = GmailText.plainText(fromHTML: body)
        }
        let (text, cut) = GraphShape.cut(body, Self.bodyLimit)
        fields[html ? "htmlBody" : "body"] = .string(text)
        if cut { fields["bodyTruncated"] = .bool(true) }
        let attachments = (message["attachments"]?.arrayValue ?? []).map {
            ToolJSON.object(Arguments.pick($0, ["id", "name", "contentType", "size", "isInline"]))
        }
        if !attachments.isEmpty { fields["attachments"] = .array(attachments) }
        return .object(fields)
    }

    private func folders(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let list: ToolJSON
        if let token = Arguments.string(arguments, "pageToken") {
            list = try await api.get(page: token)
        } else {
            var path = ["me", "mailFolders"]
            if let parent = Arguments.string(arguments, "parentFolderId") {
                path += [try GraphAPI.segment(parent), "childFolders"]
            }
            list = try await api.get(path, [URLQueryItem(name: "$top", value: "100")])
        }
        return GraphShape.page(list, key: "folders") {
            .object(Arguments.pick($0, ["id", "displayName", "parentFolderId", "unreadItemCount", "totalItemCount", "childFolderCount"]))
        }
    }

    static func summary(_ message: ToolJSON) -> ToolJSON {
        var fields = Arguments.pick(message, ["id", "conversationId", "subject", "receivedDateTime", "bodyPreview", "isRead",
                                              "isDraft", "hasAttachments", "categories", "parentFolderId", "webLink"])
        if let from = GraphShape.person(message["from"]) { fields["from"] = from }
        fields["to"] = GraphShape.people(message["toRecipients"])
        let cc = GraphShape.people(message["ccRecipients"])
        if cc.arrayValue?.isEmpty == false { fields["cc"] = cc }
        if let importance = message["importance"]?.stringValue, importance != "normal" { fields["importance"] = .string(importance) }
        if let flag = message["flag"]?["flagStatus"]?.stringValue, flag != "notFlagged" { fields["flag"] = .string(flag) }
        return .object(fields)
    }

    // MARK: Writing

    /// Graph's message fields for what the call gives: recipients, subject, and body.
    private func outgoing(_ arguments: [String: ToolJSON], body includeBody: Bool) throws -> [String: ToolJSON] {
        var message: [String: ToolJSON] = [:]
        for (argument, field) in [("to", "toRecipients"), ("cc", "ccRecipients"), ("bcc", "bccRecipients")] {
            let addresses = try Arguments.strings(arguments, argument)
            if !addresses.isEmpty { message[field] = try GraphShape.recipients(addresses, field: argument) }
        }
        if let subject = Arguments.string(arguments, "subject") { message["subject"] = .string(subject) }
        if includeBody, let content = try bodyContent(arguments) {
            message["body"] = .object(["contentType": .string(content.html ? "HTML" : "Text"), "content": .string(content.text)])
        }
        return message
    }

    private func bodyContent(_ arguments: [String: ToolJSON]) throws -> (text: String, html: Bool)? {
        if let html = arguments["htmlBody"]?.stringValue, !html.isEmpty { return (html, true) }
        if let text = arguments["body"]?.stringValue { return (text, false) }
        return nil
    }

    /// A reply's request: the text as a comment, which keeps the quoted original below it, or an
    /// HTML body in its place; recipients given replace the reply's own.
    private func replyBody(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        let content = try bodyContent(arguments)
        let message = try outgoing(arguments, body: content?.html == true)
        var body: [String: ToolJSON] = [:]
        if let content, !content.html { body["comment"] = .string(content.text) }
        if !message.isEmpty { body["message"] = .object(message) }
        return .object(body)
    }

    private func draft(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let draft: ToolJSON
        if let original = Arguments.string(arguments, "replyToMessageId") {
            let action = Arguments.bool(arguments["replyAll"]) == true ? "createReplyAll" : "createReply"
            draft = try await api.post(["me", "messages", try GraphAPI.segment(original), action], try replyBody(arguments))
        } else {
            draft = try await api.post(["me", "messages"], .object(try outgoing(arguments, body: true)))
        }
        var fields = Arguments.pick(draft, ["id", "conversationId", "subject", "webLink"])
        fields["to"] = GraphShape.people(draft["toRecipients"])
        return .object(fields)
    }

    private func sendDraft(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try Arguments.required(arguments, "draftId")
        _ = try await api.post(["me", "messages", try GraphAPI.segment(id), "send"], .object([:]))
        return .object(["sent": .bool(true), "draftId": .string(id)])
    }

    private func send(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        if let original = Arguments.string(arguments, "replyToMessageId") {
            let action = Arguments.bool(arguments["replyAll"]) == true ? "replyAll" : "reply"
            _ = try await api.post(["me", "messages", try GraphAPI.segment(original), action], try replyBody(arguments))
            return .object(["sent": .bool(true), "replyTo": .string(original)])
        }
        let message = try outgoing(arguments, body: true)
        guard message["toRecipients"] != nil || message["ccRecipients"] != nil || message["bccRecipients"] != nil else {
            throw Problem.missing("to")
        }
        _ = try await api.post(["me", "sendMail"], .object(["message": .object(message), "saveToSentItems": .bool(true)]))
        return .object(["sent": .bool(true)])
    }

    private func update(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let id = try Arguments.required(arguments, "messageId")
        var change: [String: ToolJSON] = [:]
        if let read = Arguments.bool(arguments["isRead"]) { change["isRead"] = .bool(read) }
        if let flag = Arguments.string(arguments, "flag") {
            guard Catalog.flags.contains(flag) else { throw Problem.invalid("flag is flagged, complete, or notFlagged.") }
            change["flag"] = .object(["flagStatus": .string(flag)])
        }
        if arguments["categories"] != nil { change["categories"] = .array(try Arguments.strings(arguments, "categories").map(ToolJSON.string)) }
        let destination = Arguments.string(arguments, "moveToFolderId")
        guard !change.isEmpty || destination != nil else {
            throw Problem.invalid("Give isRead, flag, categories, or moveToFolderId.")
        }
        var message: ToolJSON = .object([:])
        if !change.isEmpty { message = try await api.patch(["me", "messages", try GraphAPI.segment(id)], .object(change)) }
        if let destination {
            message = try await api.post(["me", "messages", try GraphAPI.segment(id), "move"],
                                         .object(["destinationId": .string(destination)]))
        }
        var fields = Arguments.pick(message, ["id", "isRead", "categories", "parentFolderId"])
        if let flag = message["flag"]?["flagStatus"] { fields["flag"] = flag }
        if fields["id"] == nil { fields["id"] = .string(id) }
        return .object(fields)
    }
}
