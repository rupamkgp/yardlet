import Foundation
import YardletAgentTools

/// Yardlet's own Microsoft Teams server: the tools it offers each signed-in work or school Microsoft
/// account, over Microsoft Graph's Teams API (learn.microsoft.com/graph/teams-concept-overview).
/// Each reaches a harness under the account's slug (`teams_list_chats`). Personal Microsoft
/// accounts have no Teams in Graph.
///
/// Delegated permissions that need no administrator's consent: `Chat.Read`, `ChatMessage.Send`,
/// `Team.ReadBasic.All`, `Channel.ReadBasic.All`, and `ChannelMessage.Send`. Reading channel
/// messages needs `ChannelMessage.Read.All`, which only an administrator can grant, so it is left
/// out. Both sends ask the person before every call through the harness's own approval.
enum TeamsToolCatalog {
    static let listChats = "list_chats"
    static let listChatMessages = "list_chat_messages"
    static let sendChatMessage = "send_chat_message"
    static let listTeams = "list_teams"
    static let listChannels = "list_channels"
    static let sendChannelMessage = "send_channel_message"

    static let scopes = ["Chat.Read", "ChatMessage.Send", "Team.ReadBasic.All", "Channel.ReadBasic.All", "ChannelMessage.Send"]

    static let approvalRequired: Set<String> = [sendChatMessage, sendChannelMessage]

    private typealias Schema = ConnectorToolSchema

    static let tools: [ToolJSON] = [
        Schema.tool(listChats, "List chats",
                    "Lists the account's one-on-one, group, and meeting chats, most recently active first, with members.",
                    properties: [
                        "pageSize": Schema.integer("Chats per page, 1 to 50. Defaults to 20.", 1...50),
                        "pageToken": Schema.string("nextPageToken from the previous page.")
                    ], readOnly: true),
        Schema.tool(listChatMessages, "List chat messages",
                    "Reads a chat's messages, newest first, as text with sender and time.",
                    properties: [
                        "chatId": Schema.string("A chat's ID from list_chats."),
                        "pageSize": Schema.integer("Messages per page, 1 to 50. Defaults to 20.", 1...50),
                        "pageToken": Schema.string("nextPageToken from the previous page.")
                    ], required: ["chatId"], readOnly: true),
        Schema.tool(sendChatMessage, "Send chat message", "Sends a message to a chat as the account.",
                    properties: [
                        "chatId": Schema.string("A chat's ID from list_chats."),
                        "content": Schema.string("The message text.")
                    ], required: ["chatId", "content"], readOnly: false, openWorld: true),
        Schema.tool(listTeams, "List teams", "Lists the teams the account is a member of.",
                    properties: [:], readOnly: true),
        Schema.tool(listChannels, "List channels", "Lists a team's channels the account can see.",
                    properties: ["teamId": Schema.string("A team's ID from list_teams.")],
                    required: ["teamId"], readOnly: true),
        Schema.tool(sendChannelMessage, "Send channel message",
                    "Posts a message in a team's channel as the account, or replies in a thread with replyToMessageId.",
                    properties: [
                        "teamId": Schema.string("A team's ID from list_teams."),
                        "channelId": Schema.string("A channel's ID from list_channels."),
                        "content": Schema.string("The message text."),
                        "subject": Schema.string("A subject for a new post."),
                        "replyToMessageId": Schema.string("The post to reply to.")
                    ], required: ["teamId", "channelId", "content"], readOnly: false, openWorld: true)
    ]
}
