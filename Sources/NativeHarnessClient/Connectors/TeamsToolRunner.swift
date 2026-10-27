import Foundation
import YardletAgentTools

/// Runs one Microsoft Teams tool call against Microsoft Graph and answers with compact JSON text.
/// Message bodies come as HTML and are read as text. Arguments are checked before any request;
/// Graph's errors and a sign-in that ended are thrown to the connector center.
struct TeamsToolRunner {
    let api: GraphAPI

    typealias Problem = ConnectorToolArguments.Problem
    private typealias Arguments = ConnectorToolArguments
    private typealias Catalog = TeamsToolCatalog

    /// A message is cut here.
    static let messageLimit = 8_000

    func call(_ name: String, _ arguments: ToolJSON) async throws -> AgentToolResult {
        let arguments = arguments.objectValue ?? [:]
        do {
            let result: ToolJSON
            switch name {
            case Catalog.listChats: result = try await chats(arguments)
            case Catalog.listChatMessages: result = try await chatMessages(arguments)
            case Catalog.sendChatMessage: result = try await sendToChat(arguments)
            case Catalog.listTeams: result = try await teams()
            case Catalog.listChannels: result = try await channels(arguments)
            case Catalog.sendChannelMessage: result = try await sendToChannel(arguments)
            default: return .error("Unknown tool: \(name)")
            }
            return .text(Arguments.text(result))
        } catch let problem as Problem {
            return .error(problem.localizedDescription)
        } catch GraphAPI.Failure.invalidID(let id) {
            return .error("Not an ID Teams takes: \(id)")
        }
    }

    private func chats(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let list: ToolJSON
        if let token = Arguments.string(arguments, "pageToken") {
            list = try await api.get(page: token)
        } else {
            list = try await api.get(["me", "chats"], [
                URLQueryItem(name: "$expand", value: "members"),
                URLQueryItem(name: "$top", value: String(Arguments.pageSize(arguments, range: 1...50, fallback: 20)))
            ])
        }
        var page = GraphShape.page(list, key: "chats") { chat in
            var fields = Arguments.pick(chat, ["id", "topic", "chatType", "lastUpdatedDateTime", "webUrl"])
            let members = (chat["members"]?.arrayValue ?? []).compactMap { $0["displayName"]?.stringValue }
            if !members.isEmpty { fields["members"] = .array(members.map(ToolJSON.string)) }
            return .object(fields)
        }.objectValue ?? [:]
        // Most recently active first within the page.
        if case .array(let items)? = page["chats"] {
            page["chats"] = .array(items.sorted { ($0["lastUpdatedDateTime"]?.stringValue ?? "") > ($1["lastUpdatedDateTime"]?.stringValue ?? "") })
        }
        return .object(page)
    }

    private func chatMessages(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let list: ToolJSON
        if let token = Arguments.string(arguments, "pageToken") {
            list = try await api.get(page: token)
        } else {
            let chat = try GraphAPI.segment(try Arguments.required(arguments, "chatId"))
            list = try await api.get(["chats", chat, "messages"], [
                URLQueryItem(name: "$top", value: String(Arguments.pageSize(arguments, range: 1...50, fallback: 20))),
                URLQueryItem(name: "$orderby", value: "createdDateTime desc")
            ])
        }
        return GraphShape.page(list, key: "messages", Self.message)
    }

    private func sendToChat(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let chat = try GraphAPI.segment(try Arguments.required(arguments, "chatId"))
        let sent = try await api.post(["chats", chat, "messages"], .object(["body": try body(arguments)]))
        return .object(Arguments.pick(sent, ["id", "createdDateTime", "webUrl"]))
    }

    private func teams() async throws -> ToolJSON {
        GraphShape.page(try await api.get(["me", "joinedTeams"]), key: "teams") {
            .object(Arguments.pick($0, ["id", "displayName", "description"]))
        }
    }

    private func channels(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let team = try GraphAPI.segment(try Arguments.required(arguments, "teamId"))
        let list = try await api.get(["teams", team, "channels"],
                                     [URLQueryItem(name: "$select", value: "id,displayName,description,membershipType,webUrl")])
        return GraphShape.page(list, key: "channels") {
            .object(Arguments.pick($0, ["id", "displayName", "description", "membershipType", "webUrl"]))
        }
    }

    private func sendToChannel(_ arguments: [String: ToolJSON]) async throws -> ToolJSON {
        let team = try GraphAPI.segment(try Arguments.required(arguments, "teamId"))
        let channel = try GraphAPI.segment(try Arguments.required(arguments, "channelId"))
        var message: [String: ToolJSON] = ["body": try body(arguments)]
        var path = ["teams", team, "channels", channel, "messages"]
        if let parent = Arguments.string(arguments, "replyToMessageId") {
            path += [try GraphAPI.segment(parent), "replies"]
        } else if let subject = Arguments.string(arguments, "subject") {
            message["subject"] = .string(subject)
        }
        let sent = try await api.post(path, .object(message))
        return .object(Arguments.pick(sent, ["id", "createdDateTime", "webUrl"]))
    }

    private func body(_ arguments: [String: ToolJSON]) throws -> ToolJSON {
        guard let content = arguments["content"]?.stringValue, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Problem.missing("content")
        }
        return .object(["contentType": .string("text"), "content": .string(content)])
    }

    static func message(_ message: ToolJSON) -> ToolJSON {
        var fields = ConnectorToolArguments.pick(message, ["id", "createdDateTime", "lastEditedDateTime", "subject", "webUrl"])
        if let type = message["messageType"]?.stringValue, type != "message" { fields["messageType"] = .string(type) }
        let from = message["from"]?["user"]?["displayName"] ?? message["from"]?["application"]?["displayName"]
        if let from, from != .null { fields["from"] = from }
        var text = message["body"]?["content"]?.stringValue ?? ""
        if message["body"]?["contentType"]?.stringValue?.lowercased() == "html" { text = GmailText.plainText(fromHTML: text) }
        let (cut, truncated) = GraphShape.cut(text, Self.messageLimit)
        fields["text"] = .string(cut)
        if truncated { fields["textTruncated"] = .bool(true) }
        let attachments = (message["attachments"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        if !attachments.isEmpty { fields["attachments"] = .array(attachments.map(ToolJSON.string)) }
        if message["deletedDateTime"] != nil, message["deletedDateTime"] != .null { fields["deleted"] = .bool(true) }
        return .object(fields)
    }
}
