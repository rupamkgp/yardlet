import Foundation

/// What a window's sidebar and content show: the coding tasks, or the personal agents opened from the
/// task list's row below Scheduled tasks.
enum ShellSection: String, CaseIterable, Identifiable {
    case tasks, personalAgents
    var id: Self { self }
}

/// A cloud agent is not a coding task. Its account, profile and messaging room
/// remain provider-owned and are never inserted into the local session index.
struct PersonalAgentIdentity: Hashable, Codable, Sendable {
    let accountID: String
    let userID: String
    let agentID: String
    let roomID: String
}

struct PersonalAgent: Identifiable, Equatable, Sendable {
    let id: PersonalAgentIdentity
    let name: String
    let rootThreadID: String?
    let isPaused: Bool
    let isPrimary: Bool
    var avatar: PersonalAgentAvatar? = nil
}

/// A dot's static picture as its profile names it. The location is a signed provider URL: only the
/// transport reads it, and it never appears in a description, a log or a saved file.
struct PersonalAgentAvatar: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let location: String
    /// What tells one picture from the next: its snapshot's content hash when the profile has one.
    let version: String

    var description: String { "PersonalAgentAvatar(\(version))" }
    var debugDescription: String { description }
}

/// A dot's task in its Activity: running first, then by when it last changed.
struct PersonalAgentActivity: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case running, completed, unknown }
    enum Outcome: Equatable, Sendable { case succeeded, failed, interrupted, unknown }
    let id: String
    let title: String
    let status: Status
    let outcome: Outcome
    let updatedAt: Date?
    let preview: String?
}

struct PersonalAgentActivityPage: Equatable, Sendable {
    let items: [PersonalAgentActivity]
    let cursor: String?
}

/// One of a dot's schedules, as far as its list names it.
struct PersonalAgentSchedule: Identifiable, Equatable, Sendable {
    let id: String
    let title: String?
    let isEnabled: Bool?
}

/// A computer the dot's root thread can work on. Being attached is the dot's permission to use it;
/// whether it is reachable is a separate provider status, unknown when the provider gives none.
struct PersonalAgentComputer: Identifiable, Equatable, Sendable {
    enum Availability: Equatable, Sendable { case connected, disconnected, offline, unknown }
    let id: String
    let name: String
    let isCloud: Bool
    let isAttached: Bool
    let availability: Availability
}

struct PersonalAgentMessage: Identifiable, Equatable, Sendable {
    enum Author: Equatable, Sendable { case person, agent, other(String), unknown }
    let id: String
    let author: Author
    let text: String
    let createdAt: Date?
    let isDeleted: Bool
    let attachments: [PersonalAgentAttachment]
    var requestID: String? = nil
}

struct PersonalAgentAttachment: Equatable, Sendable {
    let fileID: String?
    let name: String
    let type: String
}

struct PersonalAgentSubmission: Codable, Equatable, Sendable {
    let requestID: String
    let text: String
    let timezoneOffsetMinutes: Int

    init(text: String, requestID: String = UUID().uuidString) {
        self.requestID = requestID
        self.text = text
        timezoneOffsetMinutes = -TimeZone.current.secondsFromGMT() / 60
    }
}

struct PersonalAgentDownload: Sendable {
    let data: Data
    let name: String
}

struct PersonalAgentPage: Equatable, Sendable {
    let messages: [PersonalAgentMessage]
    let before: String?
}

enum PersonalAgentFailure: Error, Equatable, Sendable {
    case runtimeUnavailable, signInRequired, accountChanged, accessDenied
    case unavailable, invalidResponse, network, stopped
    case deliveryUnknown, sendRejected, verificationRequired, draftStorage, attachmentUnavailable

    var message: String {
        switch self {
        case .runtimeUnavailable: L10n.string("Connect Codex in Accounts to use your dots.")
        case .signInRequired: L10n.string("Sign in with ChatGPT in Accounts to use your dots.")
        case .accountChanged: L10n.string("The ChatGPT account changed. Reconnect to load its dots.")
        case .accessDenied: L10n.string("Dots are not available for this ChatGPT account.")
        case .unavailable: L10n.string("Dots could not be reached. Try again.")
        case .invalidResponse: L10n.string("This Dots response cannot be displayed yet.")
        case .network: L10n.string("Could not connect to Dots. Check your connection and try again.")
        case .stopped: L10n.string("Disconnected")
        case .deliveryUnknown: L10n.string("Delivery could not be confirmed. Refresh the conversation or retry the same message.")
        case .sendRejected: L10n.string("The message was not accepted. Your draft is still here.")
        case .verificationRequired: L10n.string("ChatGPT requires verification before this message can be sent. Your draft is still here.")
        case .draftStorage: L10n.string("The draft could not be saved. Nothing new will be sent until it is saved.")
        case .attachmentUnavailable: L10n.string("This attachment cannot be opened here yet.")
        }
    }
}

enum PersonalAgentUpdate: Sendable {
    case changed, reconnecting, connected, failed(PersonalAgentFailure)
}

protocol PersonalAgentClient: Actor {
    func agents() async throws -> [PersonalAgent]
    func messages(for agent: PersonalAgent, before: String?) async throws -> PersonalAgentPage
    func updates(for agent: PersonalAgent) async -> AsyncStream<PersonalAgentUpdate>
    func send(_ submission: PersonalAgentSubmission, to agent: PersonalAgent) async throws -> PersonalAgentMessage
    func download(_ attachment: PersonalAgentAttachment, for agent: PersonalAgent) async throws -> PersonalAgentDownload
    /// The bytes of the dot's profile picture, bounded; never read with an account credential on storage hosts.
    func avatar(for agent: PersonalAgent) async throws -> Data
    func activity(for agent: PersonalAgent, cursor: String?) async throws -> PersonalAgentActivityPage
    func schedules(for agent: PersonalAgent) async throws -> [PersonalAgentSchedule]
    func computers(for agent: PersonalAgent) async throws -> [PersonalAgentComputer]
    func stop() async
}

enum DotsProjection {
    static func agents(catalog: JSONValue, primary: JSONValue, accountID: String, userID: String) throws -> [PersonalAgent] {
        guard case let .array(items)? = catalog["items"] else { throw PersonalAgentFailure.invalidResponse }
        let selected = primary["selection"]?["aeon_id"]?.stringValue ?? primary["profile"]?["id"]?.stringValue
        return try items.filter { $0["aeon_kind"]?.stringValue == "orbit" && $0["status"]?.stringValue != "deleting" }.map { item in
            guard let id = item["id"]?.stringValue, !id.isEmpty,
                  let room = item["messaging_room_id"]?.stringValue, !room.isEmpty else {
                throw PersonalAgentFailure.invalidResponse
            }
            return PersonalAgent(id: .init(accountID: accountID, userID: userID, agentID: id, roomID: room),
                name: item["display_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Dots",
                rootThreadID: item["active_root_thread_id"]?.stringValue,
                isPaused: item["is_paused"] == .bool(true), isPrimary: id == selected, avatar: avatar(item))
        }
    }

    /// The profile's static snapshot. `avatar_file_id` and the snapshot's `sediment://` pointer are
    /// provider asset pointers, not URLs; only an HTTPS `avatar_url` is a picture to read.
    static func avatar(_ profile: JSONValue) -> PersonalAgentAvatar? {
        guard let raw = profile["avatar_url"]?.stringValue, URL(string: raw)?.scheme == "https" else { return nil }
        let snapshot = profile["avatar_manifest"]?["snapshot"]
        let version = snapshot?["content_sha256"]?.stringValue ?? snapshot?["asset_pointer"]?.stringValue
            ?? profile["updated_at"]?.stringValue ?? ""
        return .init(location: raw, version: version)
    }

    static func activity(_ page: JSONValue) throws -> PersonalAgentActivityPage {
        guard case let .array(items)? = page["data"] else { throw PersonalAgentFailure.invalidResponse }
        let values = items.compactMap { item -> PersonalAgentActivity? in
            guard let id = item["thread_id"]?.stringValue, !id.isEmpty else { return nil }
            let status: PersonalAgentActivity.Status = switch item["status"]?.stringValue ?? "" {
            case "in_progress": .running
            case "completed": .completed
            default: .unknown
            }
            let outcome: PersonalAgentActivity.Outcome = switch item["outcome"]?.stringValue ?? "" {
            case "succeeded": .succeeded
            case "failed": .failed
            case "interrupted": .interrupted
            default: .unknown
            }
            return .init(id: id, title: item["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                            ?? L10n.string("Untitled task"),
                         status: status, outcome: outcome, updatedAt: epoch(item["updated_at"] ?? item["created_at"]),
                         preview: item["preview"]?["text"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        }
        return .init(items: sortedActivity(values), cursor: page["next_cursor"]?.stringValue)
    }

    /// The provider's order: running tasks first, interrupted ones after the rest, then the newest change.
    static func sortedActivity(_ items: [PersonalAgentActivity]) -> [PersonalAgentActivity] {
        func rank(_ item: PersonalAgentActivity) -> Int {
            item.status == .running ? 0 : item.outcome == .interrupted ? 2 : 1
        }
        return items.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            let (da, db) = (a.element.updatedAt ?? .distantPast, b.element.updatedAt ?? .distantPast)
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
    }

    static func schedules(_ page: JSONValue) throws -> [PersonalAgentSchedule] {
        guard case let .array(items)? = page["items"] else { throw PersonalAgentFailure.invalidResponse }
        return items.compactMap { item in
            guard let id = item["id"]?.stringValue, !id.isEmpty else { return nil }
            let enabled: Bool? = if case let .bool(value)? = item["is_enabled"] { value } else { nil }
            return .init(id: id, title: item["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }, isEnabled: enabled)
        }
    }

    /// The computers bound to the root thread the request named; a reply for another thread is not this dot's.
    static func computers(_ value: JSONValue, rootThreadID: String) throws -> [PersonalAgentComputer] {
        guard value["thread_id"]?.stringValue == rootThreadID, case let .array(items)? = value["computers"] else {
            throw PersonalAgentFailure.invalidResponse
        }
        return items.enumerated().map { index, item in
            let kind = item["kind"]?.stringValue ?? ""
            let attached = item["is_attached"] == .bool(true)
            let availability: PersonalAgentComputer.Availability = switch item["status"]?.stringValue ?? "" {
            case "offline": .offline
            case "connected": attached ? .connected : .disconnected
            default: .unknown
            }
            let name = item["display_name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            // The provider's own client treats `user` as a person's computer and every other kind as its cloud.
            let isCloud = kind != "user"
            return .init(id: item["environment_id"]?.stringValue ?? "\(index)-\(kind)",
                         name: name ?? (isCloud ? L10n.string("Cloud computer") : L10n.string("Computer")),
                         isCloud: isCloud, isAttached: attached, availability: availability)
        }
    }

    private static func epoch(_ value: JSONValue?) -> Date? {
        switch value {
        case let .integer(seconds)?: Date(timeIntervalSince1970: Double(seconds))
        case let .number(seconds)?: Date(timeIntervalSince1970: seconds)
        default: nil
        }
    }

    static func messages(_ page: JSONValue, room: JSONValue, agent: PersonalAgent) throws -> PersonalAgentPage {
        guard room["id"]?.stringValue == agent.id.roomID, room["aeon_id"]?.stringValue == agent.id.agentID,
              case let .array(members)? = room["members"], case let .array(items)? = page["items"] else {
            throw PersonalAgentFailure.invalidResponse
        }
        let messages = try items.map { item -> PersonalAgentMessage in
            guard let id = item["id"]?.stringValue, !id.isEmpty else { throw PersonalAgentFailure.invalidResponse }
            let sender = item["account_user_id"]?.stringValue
            let member = members.first { sender != nil && $0["account_user_id"]?.stringValue == sender }
            let author: PersonalAgentMessage.Author
            // Both a dot and a person can have role=user. Messaging membership
            // is distinct from the OAuth workspace-membership identifier.
            if member?["aeon_id"]?.stringValue == agent.id.agentID { author = .agent }
            else if sender == agent.id.userID { author = .person }
            else if let name = member?["name"]?.stringValue { author = .other(name) }
            else { author = .unknown }
            let deleted = item["deleted_at"] != nil && item["deleted_at"] != .null
            var text = item["content"]?["text"]?.stringValue ?? ""
            let attachments: [PersonalAgentAttachment]
            if case let .array(values)? = item["content"]?["attachments"] {
                attachments = values.map { value in
                    let fileID = value["file_id"]?.stringValue ?? value["file"]?["file_id"]?.stringValue ?? value["file"]?["id"]?.stringValue
                    return .init(fileID: fileID,
                          name: value["name"]?.stringValue ?? value["file"]?["name"]?.stringValue
                              ?? value["file"]?["file_name"]?.stringValue ?? value["filename"]?.stringValue ?? L10n.string("Attachment"),
                          type: value["type"]?.stringValue ?? (fileID == nil ? "unknown" : "file"))
                }
            } else { attachments = [] }
            if !deleted, text.isEmpty, attachments.isEmpty {
                text = L10n.string("This message cannot be displayed yet.")
            }
            return PersonalAgentMessage(id: id, author: author, text: deleted ? "" : text,
                createdAt: date(item["created_at"]?.stringValue), isDeleted: deleted, attachments: deleted ? [] : attachments,
                requestID: item["request_id"]?.stringValue)
        }
        guard Set(messages.map(\.id)).count == messages.count else { throw PersonalAgentFailure.invalidResponse }
        // The provider's room client also uses the oldest item when prev_cursor
        // is absent; an empty page ends backfill.
        return .init(messages: messages, before: messages.isEmpty ? nil : page["prev_cursor"]?.stringValue ?? messages.first?.id)
    }

    static func merge(_ existing: [PersonalAgentMessage], with incoming: [PersonalAgentMessage], older: Bool) -> [PersonalAgentMessage] {
        let replacements = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let known = Set(existing.map(\.id))
        let new = incoming.filter { !known.contains($0.id) }
        let updated = existing.map { replacements[$0.id] ?? $0 }
        return older ? new + updated : updated + new
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
