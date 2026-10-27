import Foundation

// The wire contract of the phone remote (docs/REMOTE_PROTOCOL.md): versioned JSON over a WebSocket.
// Client requests are `{id, type, ...}`, responses `{re, ok, error?, ...}`, events `{event, seq, ...}`.
// Everything here is plain data, so it encodes and decodes without a connection.

public enum RemoteProtocol {
    public static let version = 1
    /// The one fixed port the Mac listens on.
    public static let defaultPort: UInt16 = 47615
    /// The largest frame a client may send; a larger one closes the connection (1009).
    public static let maxClientFrameBytes = 65_536
    /// The longest message `sendMessage` takes, in characters.
    public static let maxMessageCharacters = 32_000
    /// The QR code's URL scheme.
    public static let pairingScheme = "yardlet-remote"
    /// Protocol v2: the same messages inside a Noise channel, over any path (§11).
    public static let secureVersion = 2
    /// The port the Mac's v2 listener tries first, on every interface.
    public static let securePort: UInt16 = 47616
    /// The Bonjour service a v2 listener advertises (§11.3).
    public static let bonjourType = "_yardlet._tcp"
    /// The largest message the Mac sends a phone over v2, before chunking (§13.2).
    public static let maxServerMessageBytes = 8 * 1024 * 1024
    /// Answers an approval item may offer beside `RemoteApprovalAnswer`'s, to v2 phones only (§15.2).
    public static let answerOption = "answer"
    public static let approvePlanOption = "approvePlan"
    public static let keepPlanningOption = "keepPlanning"
    /// The longest own-words answer or plan feedback a phone sends.
    public static let maxAnswerCharacters = 4_000
}

// MARK: - Errors

public enum RemoteErrorCode: String, Codable, Sendable, CaseIterable {
    case badRequest
    case unknownType
    case unsupportedVersion
    case unauthenticated
    case invalidToken
    case pairingUnavailable
    case pairingInvalid
    case notFound
    case notSubscribed
    case invalidCursor
    case tooManySubscriptions
    case requestNotFound
    case notAllowed
    case unavailable
    case notRunning
    case emptyMessage
    case tooLarge
    case unsupportedCommand
    case busy
    case rateLimited
    case `internal`
    /// v2 handshake: the phone's key is not paired, or the device was removed.
    case unknownDevice
    /// v2 handshake: a link request to a Mac that is not signed in to an account (§12.1).
    case linkUnavailable
}

public struct RemoteError: Error, Codable, Equatable, Sendable {
    public var code: RemoteErrorCode
    /// An English diagnostic for logs, not for the phone's UI.
    public var message: String

    public init(_ code: RemoteErrorCode, _ message: String = "") {
        self.code = code
        self.message = message.isEmpty ? code.rawValue : message
    }
}

/// WebSocket close codes the server uses (§8).
public enum RemoteCloseCode: UInt16, Sendable {
    case normal = 1000
    case unsupportedData = 1003
    case messageTooBig = 1009
    case unauthenticated = 4401
    case revoked = 4403
    case idle = 4408
    case macOffline = 4404
    case unsupportedVersion = 4426
    case replaced = 4409
    case rateLimited = 4429
    case unavailable = 4503
}

// MARK: - Tasks

/// A project the sidebar lists tasks under.
public struct RemoteProject: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case project
        case folder
        case chats
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// `createTask` may start a task here (v2, §15.1).
    public var canCreateTask: Bool?

    public init(id: String, name: String, kind: Kind, canCreateTask: Bool? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.canCreateTask = canCreateTask
    }
}

/// What a task the phone starts runs on: the Mac's new-task composer as it is now (§15.1).
public struct RemoteNewTask: Codable, Equatable, Sendable {
    public var harness: String
    public var harnessName: String

    public init(harness: String, harnessName: String) {
        self.harness = harness
        self.harnessName = harnessName
    }
}

/// The sidebar's one attention state (`TaskAttentionProjection.state` on the Mac).
public enum RemoteAttention: String, Codable, Sendable {
    case waiting
    case unread
    case active
    case idle
}

/// The mark a sidebar row ends with (`SidebarTaskIndicatorProjection.status` on the Mac).
public enum RemoteIndicator: String, Codable, Sendable {
    case awaitingApproval
    case needsInput
    case failed
    case usageLimit
    case running
    case unread
}

public enum RemotePendingRequest: String, Codable, Sendable {
    case approval
    case input
}

public struct RemoteTask: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var harness: String
    public var harnessName: String
    public var projectId: String?
    public var attention: RemoteAttention
    public var indicator: RemoteIndicator?
    public var pendingRequest: RemotePendingRequest?
    public var unread: Bool
    public var running: Bool
    public var pinned: Bool
    public var lastActivityAt: Int64
    public var parentTaskId: String?
    /// While `waiting`: the newest request's one line (as the `attention` event's `summary`) and its
    /// kind (`approval`, `question`, `planReview`, `form`), so a list can say what waits (§15.1).
    public var pendingSummary: String?
    public var pendingKind: String?

    public init(
        id: String, title: String, harness: String, harnessName: String, projectId: String?,
        attention: RemoteAttention, indicator: RemoteIndicator? = nil, pendingRequest: RemotePendingRequest? = nil,
        unread: Bool = false, running: Bool = false, pinned: Bool = false, lastActivityAt: Int64,
        parentTaskId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.harness = harness
        self.harnessName = harnessName
        self.projectId = projectId
        self.attention = attention
        self.indicator = indicator
        self.pendingRequest = pendingRequest
        self.unread = unread
        self.running = running
        self.pinned = pinned
        self.lastActivityAt = lastActivityAt
        self.parentTaskId = parentTaskId
    }
}

/// What `snapshot` answers, and what attention events are read from.
public struct RemoteSnapshot: Equatable, Sendable {
    public var projects: [RemoteProject]
    public var tasks: [RemoteTask]
    /// The newest request each waiting task waits on, so a second request in a waiting task is an
    /// attention event too. Not sent with the task.
    public var newestRequestIDs: [String: String]
    /// A one-line summary of that request for the attention event (`RemoteSummary.line`): what the
    /// call is or the question's first line, capped and with secrets masked. Not sent with the task.
    public var requestSummaries: [String: String]
    /// What `createTask` would start on, or nil when the Mac cannot start a task.
    public var newTask: RemoteNewTask?

    public init(projects: [RemoteProject] = [], tasks: [RemoteTask] = [], newestRequestIDs: [String: String] = [:],
                requestSummaries: [String: String] = [:], newTask: RemoteNewTask? = nil) {
        self.projects = projects
        self.tasks = tasks
        self.newestRequestIDs = newestRequestIDs
        self.requestSummaries = requestSummaries
        self.newTask = newTask
    }

    public static let empty = RemoteSnapshot()
}

// MARK: - Conversation items

/// One question of a pending question request, as the phone answers it (§15.2).
public struct RemoteQuestionStep: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var id: String
    public var header: String?
    public var text: String?
    public var options: [Option]
    public var multiple: Bool
    public var custom: Bool
    public var skippable: Bool

    public init(id: String, header: String? = nil, text: String? = nil, options: [Option], multiple: Bool = false,
                custom: Bool = false, skippable: Bool = false) {
        self.id = id
        self.header = header
        self.text = text
        self.options = options
        self.multiple = multiple
        self.custom = custom
        self.skippable = skippable
    }
}

/// A phone's answer to one question step (§15.3).
public struct RemoteQuestionAnswer: Codable, Equatable, Sendable {
    public var questionId: String
    public var options: [String]?
    public var text: String?
    public var skipped: Bool?

    public init(questionId: String, options: [String]? = nil, text: String? = nil, skipped: Bool? = nil) {
        self.questionId = questionId
        self.options = options
        self.text = text
        self.skipped = skipped
    }
}

public enum RemotePlanDecision: String, Codable, Sendable {
    case approve
    case keepPlanning
}

public struct RemotePlanStep: Codable, Equatable, Sendable {
    public var text: String
    public var status: String

    public init(text: String, status: String) {
        self.text = text
        self.status = status
    }
}

/// One item of a conversation as the phone draws it (§6). One shape for every kind; each kind fills
/// the fields its section of the protocol names and leaves the rest nil, which is not encoded.
public struct RemoteItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case turn
        case user
        case assistant
        case activity
        case approval
        case plan
        case error
        case notice
    }

    public var id: String
    public var turnId: String
    public var kind: Kind
    public var inWork: Bool?

    // turn
    public var status: String?
    public var startedAt: Int64?
    public var completedAt: Int64?
    public var durationMs: Int64?
    public var approximate: Bool?
    public var foldsWork: Bool?
    public var workCount: Int?
    public var progress: String?
    public var progressText: String?

    // text
    public var text: String?
    public var truncated: Bool?
    public var imageCount: Int?
    public var scheduled: Bool?
    public var shell: Bool?
    public var diffCommentCount: Int?
    /// A message waiting in the task's follow-up queue, not yet taken by the provider.
    public var queued: Bool?
    /// Sending the queued message failed; it waits on the Mac.
    public var queueFailed: Bool?
    public var role: String?
    public var streaming: Bool?

    // activity
    public var activity: String?
    public var title: String?
    public var detail: String?
    public var exitCode: Int64?
    public var additions: Int?
    public var deletions: Int?
    public var approved: Bool?
    /// `itemDetail` has more for this line: output or diffs (v2, §15.8).
    public var hasDetail: Bool?
    // suggested task (v2, §15.9)
    public var suggestionId: String?
    public var suggestionState: String?
    public var startedTaskId: String?

    // approval
    public var requestId: String?
    public var requestKind: String?
    public var command: String?
    public var questions: [String]?
    /// A pending question's steps, which a v2 phone answers (§15.2).
    public var questionSteps: [RemoteQuestionStep]?
    public var options: [String]?
    public var moreOnMac: Bool?

    // plan
    public var explanation: String?
    public var steps: [RemotePlanStep]?

    // error
    public var errorKind: String?
    public var message: String?
    public var recoverable: Bool?
    public var resetsAt: Int64?

    public init(id: String, turnId: String, kind: Kind) {
        self.id = id
        self.turnId = turnId
        self.kind = kind
    }
}

extension RemoteItem {
    /// The item as a v1 phone gets it (§15.12): only the answers v1 knows, `moreOnMac` for the rest, and
    /// none of v2's fields.
    public func forVersion1() -> RemoteItem {
        var item = self
        item.questionSteps = nil
        item.hasDetail = nil
        item.suggestionId = nil
        item.suggestionState = nil
        item.startedTaskId = nil
        guard let options else { return item }
        if kind == .approval {
            let known = options.filter { RemoteApprovalAnswer(rawValue: $0) != nil }
            if known.count != options.count { item.moreOnMac = true }
            item.options = known
        } else {
            item.options = nil
        }
        return item
    }
}

/// Text cut to what the protocol allows for a field.
public enum RemoteText {
    /// The text and whether it was cut. Cuts at a character boundary.
    public static func capped(_ text: String, _ limit: Int) -> (text: String, truncated: Bool) {
        guard text.count > limit else { return (text, false) }
        return (String(text.prefix(limit)), true)
    }

    /// Optional text cut to the limit, nil when empty.
    public static func short(_ text: String?, _ limit: Int) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return capped(text, limit).text
    }

    public static let userLimit = 16_000
    public static let assistantLimit = 32_000
    public static let titleLimit = 300
    public static let detailLimit = 500
    public static let requestDetailLimit = 1_000
    public static let commandLimit = 2_000
    public static let planTextLimit = 8_000
    public static let questionLimit = 500
    public static let errorLimit = 2_000
    public static let stepLimit = 500
    public static let stepCount = 50
}

/// A turn of a conversation as the bridge hands it to the server: its ID and its items in order.
public struct RemoteTurn: Equatable, Sendable {
    public var id: String
    public var items: [RemoteItem]

    public init(id: String, items: [RemoteItem]) {
        self.id = id
        self.items = items
    }
}

/// A task's conversation as loaded on the Mac.
public struct RemoteConversation: Equatable, Sendable {
    public var turns: [RemoteTurn]
    /// The provider holds turns before the loaded ones (a Codex cursor, a Claude file read from its end).
    public var hasEarlier: Bool

    public init(turns: [RemoteTurn], hasEarlier: Bool = false) {
        self.turns = turns
        self.hasEarlier = hasEarlier
    }
}

/// One change of a `conversation` event.
public struct RemoteChange: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable {
        case upsert
        case remove
    }

    public var op: Op
    /// `remove`: the item to drop.
    public var id: String?
    /// `upsert`: the item to insert after; nil inserts at the start.
    public var after: String?
    public var item: RemoteItem?

    public static func remove(_ id: String) -> RemoteChange { RemoteChange(op: .remove, id: id) }
    public static func upsert(_ item: RemoteItem, after: String?) -> RemoteChange {
        RemoteChange(op: .upsert, after: after, item: item)
    }
}

// MARK: - Requests

public enum RemoteApprovalAnswer: String, Codable, Sendable {
    case allowOnce
    case deny
}

public enum RemoteSuggestionAction: String, Codable, Sendable, CaseIterable {
    case start
    case here
    case dismiss
}

/// A request a client sends, after decoding.
public enum RemoteRequest: Equatable, Sendable {
    case pair(code: String, deviceName: String, protocolVersion: Int)
    case hello(token: String, protocolVersion: Int)
    case snapshot
    case subscribeTask(taskID: String)
    case loadOlder(taskID: String, cursor: String)
    case unsubscribeTask(taskID: String)
    case ping
    case sendMessage(taskID: String, text: String)
    case answerApproval(taskID: String, requestID: String, answer: RemoteApprovalAnswer)
    case stopTurn(taskID: String)
    case markRead(taskID: String)
    // v2 (§15)
    case answerQuestion(taskID: String, requestID: String, answers: [RemoteQuestionAnswer])
    case reviewPlan(taskID: String, requestID: String, decision: RemotePlanDecision, reason: String?)
    case createTask(projectID: String, text: String)
    case registerPush(provider: String, token: String)
    case unregisterPush
    case forgetDevice
    case itemDetail(taskID: String, itemID: String)
    case actOnSuggestion(taskID: String, suggestionID: String, action: RemoteSuggestionAction)
    case setPinned(taskID: String, pinned: Bool)
    case archiveTask(taskID: String)
    case answerLink(requestID: String, approve: Bool)

    public var type: String {
        switch self {
        case .pair: "pair"
        case .hello: "hello"
        case .snapshot: "snapshot"
        case .subscribeTask: "subscribeTask"
        case .loadOlder: "loadOlder"
        case .unsubscribeTask: "unsubscribeTask"
        case .ping: "ping"
        case .sendMessage: "sendMessage"
        case .answerApproval: "answerApproval"
        case .stopTurn: "stopTurn"
        case .markRead: "markRead"
        case .answerQuestion: "answerQuestion"
        case .reviewPlan: "reviewPlan"
        case .createTask: "createTask"
        case .registerPush: "registerPush"
        case .unregisterPush: "unregisterPush"
        case .forgetDevice: "forgetDevice"
        case .itemDetail: "itemDetail"
        case .actOnSuggestion: "actOnSuggestion"
        case .setPinned: "setPinned"
        case .archiveTask: "archiveTask"
        case .answerLink: "answerLink"
        }
    }

    /// The task a request names.
    public var taskID: String? {
        switch self {
        case let .subscribeTask(id), let .loadOlder(id, _), let .unsubscribeTask(id), let .sendMessage(id, _),
             let .answerApproval(id, _, _), let .stopTurn(id), let .markRead(id), let .answerQuestion(id, _, _),
             let .reviewPlan(id, _, _, _), let .itemDetail(id, _), let .actOnSuggestion(id, _, _), let .setPinned(id, _),
             let .archiveTask(id): id
        case .pair, .hello, .snapshot, .ping, .createTask, .registerPush, .unregisterPush, .forgetDevice, .answerLink: nil
        }
    }

    /// A command acts on a task through the Mac's own controls; its rate is limited apart and it is
    /// written to the audit log.
    public var isCommand: Bool {
        switch self {
        case .sendMessage, .answerApproval, .stopTurn, .markRead, .answerQuestion, .reviewPlan, .createTask,
             .actOnSuggestion, .setPinned, .archiveTask, .answerLink: true
        default: false
        }
    }

    /// Only a v2 connection may send it (§15.12).
    public var isSecureOnly: Bool {
        switch self {
        case .answerQuestion, .reviewPlan, .createTask, .registerPush, .unregisterPush, .forgetDevice, .itemDetail,
             .actOnSuggestion, .setPinned, .archiveTask, .answerLink: true
        default: false
        }
    }
}

public struct RemoteRequestEnvelope: Equatable, Sendable {
    public var id: String
    public var request: RemoteRequest

    public init(id: String, request: RemoteRequest) {
        self.id = id
        self.request = request
    }

    /// A request that could not be read: its `id` when one was readable, and why.
    public struct DecodingFailure: Error, Equatable, Sendable {
        public var id: String?
        public var error: RemoteError
    }

    private struct Wire: Codable {
        var id: String?
        var type: String?
        var protocolVersion: Int?
        var token: String?
        var code: String?
        var deviceName: String?
        var taskId: String?
        var cursor: String?
        var text: String?
        var requestId: String?
        var answer: String?
        var answers: [RemoteQuestionAnswer]?
        var decision: String?
        var reason: String?
        var projectId: String?
        var provider: String?
        var itemId: String?
        var suggestionId: String?
        var action: String?
        var pinned: Bool?
        var approve: Bool?
    }

    public static func decode(_ data: Data) -> Result<RemoteRequestEnvelope, DecodingFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
            return .failure(DecodingFailure(id: nil, error: RemoteError(.badRequest, "Not a JSON object")))
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            let id = (object as? [String: Any])?["id"] as? String
            return .failure(DecodingFailure(id: id, error: RemoteError(.badRequest, "A field has the wrong type")))
        }
        guard let id = wire.id, !id.isEmpty, id.count <= 64 else {
            return .failure(DecodingFailure(id: nil, error: RemoteError(.badRequest, "Missing or invalid id")))
        }
        func fail(_ code: RemoteErrorCode, _ message: String) -> Result<RemoteRequestEnvelope, DecodingFailure> {
            .failure(DecodingFailure(id: id, error: RemoteError(code, message)))
        }
        func required(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        guard let type = wire.type else { return fail(.badRequest, "Missing type") }
        let request: RemoteRequest
        switch type {
        case "pair":
            guard let code = required(wire.code) else { return fail(.badRequest, "Missing code") }
            guard let version = wire.protocolVersion else { return fail(.badRequest, "Missing protocolVersion") }
            let name = wire.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            request = .pair(code: code, deviceName: String(name.prefix(64)), protocolVersion: version)
        case "hello":
            guard let token = required(wire.token) else { return fail(.badRequest, "Missing token") }
            guard let version = wire.protocolVersion else { return fail(.badRequest, "Missing protocolVersion") }
            request = .hello(token: token, protocolVersion: version)
        case "snapshot":
            request = .snapshot
        case "ping":
            request = .ping
        case "subscribeTask", "unsubscribeTask", "stopTurn", "markRead", "loadOlder", "sendMessage", "answerApproval":
            guard let taskID = required(wire.taskId) else { return fail(.badRequest, "Missing taskId") }
            switch type {
            case "subscribeTask": request = .subscribeTask(taskID: taskID)
            case "unsubscribeTask": request = .unsubscribeTask(taskID: taskID)
            case "stopTurn": request = .stopTurn(taskID: taskID)
            case "markRead": request = .markRead(taskID: taskID)
            case "loadOlder":
                guard let cursor = required(wire.cursor) else { return fail(.badRequest, "Missing cursor") }
                request = .loadOlder(taskID: taskID, cursor: cursor)
            case "sendMessage":
                guard let text = wire.text else { return fail(.badRequest, "Missing text") }
                request = .sendMessage(taskID: taskID, text: text)
            default:
                guard let requestID = required(wire.requestId) else {
                    return fail(.badRequest, "Missing requestId")
                }
                guard let answer = wire.answer.flatMap(RemoteApprovalAnswer.init(rawValue:)) else {
                    return fail(.badRequest, "answer must be allowOnce or deny")
                }
                request = .answerApproval(taskID: taskID, requestID: requestID, answer: answer)
            }
        case "answerQuestion", "reviewPlan":
            guard let taskID = required(wire.taskId) else { return fail(.badRequest, "Missing taskId") }
            guard let requestID = required(wire.requestId) else { return fail(.badRequest, "Missing requestId") }
            if type == "answerQuestion" {
                guard let answers = wire.answers else { return fail(.badRequest, "Missing answers") }
                request = .answerQuestion(taskID: taskID, requestID: requestID, answers: answers)
            } else {
                guard let decision = wire.decision.flatMap(RemotePlanDecision.init(rawValue:)) else {
                    return fail(.badRequest, "decision must be approve or keepPlanning")
                }
                request = .reviewPlan(taskID: taskID, requestID: requestID, decision: decision, reason: wire.reason)
            }
        case "createTask":
            guard let projectID = required(wire.projectId) else { return fail(.badRequest, "Missing projectId") }
            guard let text = wire.text else { return fail(.badRequest, "Missing text") }
            request = .createTask(projectID: projectID, text: text)
        case "registerPush":
            guard let provider = required(wire.provider), let token = required(wire.token) else {
                return fail(.badRequest, "Missing provider or token")
            }
            request = .registerPush(provider: provider, token: token)
        case "unregisterPush":
            request = .unregisterPush
        case "forgetDevice":
            request = .forgetDevice
        case "itemDetail":
            guard let taskID = required(wire.taskId), let itemID = required(wire.itemId) else {
                return fail(.badRequest, "Missing taskId or itemId")
            }
            request = .itemDetail(taskID: taskID, itemID: itemID)
        case "actOnSuggestion":
            guard let taskID = required(wire.taskId), let suggestionID = required(wire.suggestionId) else {
                return fail(.badRequest, "Missing taskId or suggestionId")
            }
            guard let action = wire.action.flatMap(RemoteSuggestionAction.init(rawValue:)) else {
                return fail(.badRequest, "action must be start, here or dismiss")
            }
            request = .actOnSuggestion(taskID: taskID, suggestionID: suggestionID, action: action)
        case "setPinned":
            guard let taskID = required(wire.taskId), let pinned = wire.pinned else {
                return fail(.badRequest, "Missing taskId or pinned")
            }
            request = .setPinned(taskID: taskID, pinned: pinned)
        case "archiveTask":
            guard let taskID = required(wire.taskId) else { return fail(.badRequest, "Missing taskId") }
            request = .archiveTask(taskID: taskID)
        case "answerLink":
            guard let requestID = required(wire.requestId), let approve = wire.approve else {
                return fail(.badRequest, "Missing requestId or approve")
            }
            request = .answerLink(requestID: requestID, approve: approve)
        default:
            return fail(.unknownType, "Unknown type \(type)")
        }
        return .success(RemoteRequestEnvelope(id: id, request: request))
    }

    /// The request as a client writes it.
    public func encoded() -> Data {
        var wire = Wire(id: id, type: request.type)
        switch request {
        case let .pair(code, deviceName, version):
            wire.code = code
            wire.deviceName = deviceName
            wire.protocolVersion = version
        case let .hello(token, version):
            wire.token = token
            wire.protocolVersion = version
        case .snapshot, .ping:
            break
        case let .subscribeTask(taskID), let .unsubscribeTask(taskID), let .stopTurn(taskID), let .markRead(taskID):
            wire.taskId = taskID
        case let .loadOlder(taskID, cursor):
            wire.taskId = taskID
            wire.cursor = cursor
        case let .sendMessage(taskID, text):
            wire.taskId = taskID
            wire.text = text
        case let .answerApproval(taskID, requestID, answer):
            wire.taskId = taskID
            wire.requestId = requestID
            wire.answer = answer.rawValue
        case let .answerQuestion(taskID, requestID, answers):
            wire.taskId = taskID
            wire.requestId = requestID
            wire.answers = answers
        case let .reviewPlan(taskID, requestID, decision, reason):
            wire.taskId = taskID
            wire.requestId = requestID
            wire.decision = decision.rawValue
            wire.reason = reason
        case let .createTask(projectID, text):
            wire.projectId = projectID
            wire.text = text
        case let .registerPush(provider, token):
            wire.provider = provider
            wire.token = token
        case .unregisterPush, .forgetDevice:
            break
        case let .itemDetail(taskID, itemID):
            wire.taskId = taskID
            wire.itemId = itemID
        case let .actOnSuggestion(taskID, suggestionID, action):
            wire.taskId = taskID
            wire.suggestionId = suggestionID
            wire.action = action.rawValue
        case let .setPinned(taskID, pinned):
            wire.taskId = taskID
            wire.pinned = pinned
        case let .archiveTask(taskID):
            wire.taskId = taskID
        case let .answerLink(requestID, approve):
            wire.requestId = requestID
            wire.approve = approve
        }
        return (try? RemoteJSON.encoder.encode(wire)) ?? Data()
    }
}

// MARK: - Responses and events

public struct RemoteServerInfo: Codable, Equatable, Sendable {
    public var name: String
    public var app: String
    public var appVersion: String
    public var protocolVersion: Int

    public init(name: String, app: String = "Yardlet", appVersion: String, protocolVersion: Int = RemoteProtocol.version) {
        self.name = name
        self.app = app
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
    }
}

/// A response to one request. Each request fills the result fields its section names.
public struct RemoteResponse: Codable, Equatable, Sendable {
    public var re: String
    public var ok: Bool
    public var error: RemoteError?

    public var deviceId: String?
    public var token: String?
    public var server: RemoteServerInfo?
    public var projects: [RemoteProject]?
    public var tasks: [RemoteTask]?
    public var taskId: String?
    public var items: [RemoteItem]?
    public var cursor: String?
    public var hasOlder: Bool?
    public var pong: Bool?
    public var serverTime: Int64?
    /// `snapshot` on v2 (§15.1).
    public var newTask: RemoteNewTask?
    /// `registerPush` (§15.6).
    public var pushKey: String?
    public var pushKeyId: String?
    /// `itemDetail` (§15.8).
    public var itemId: String?
    public var output: String?
    public var outputTruncated: Bool?
    public var diffs: [RemoteDiff]?

    public init(re: String, ok: Bool = true, error: RemoteError? = nil) {
        self.re = re
        self.ok = ok
        self.error = error
    }

    public static func failure(_ id: String, _ error: RemoteError) -> RemoteResponse {
        RemoteResponse(re: id, ok: false, error: error)
    }
}

/// One file's change for `itemDetail` (§15.8).
public struct RemoteDiff: Codable, Equatable, Sendable {
    public var path: String
    public var patch: String
    public var additions: Int?
    public var deletions: Int?
    public var truncated: Bool?

    public init(path: String, patch: String, additions: Int? = nil, deletions: Int? = nil, truncated: Bool? = nil) {
        self.path = path
        self.patch = patch
        self.additions = additions
        self.deletions = deletions
        self.truncated = truncated
    }
}

/// What `itemDetail` answers with.
public struct RemoteItemDetail: Equatable, Sendable {
    public var output: String?
    public var outputTruncated = false
    public var diffs: [RemoteDiff] = []

    public init(output: String? = nil, outputTruncated: Bool = false, diffs: [RemoteDiff] = []) {
        self.output = output
        self.outputTruncated = outputTruncated
        self.diffs = diffs
    }

    public static let outputLimit = 64_000
    public static let diffLimit = 100_000
    public static let diffCount = 50
}

/// An event the server pushes.
public struct RemoteEvent: Codable, Equatable, Sendable {
    public enum Name: String, Codable, Sendable {
        case tasksChanged
        case attention
        case conversation
        case conversationReset
        case conversationEnded
        case revoked
        case closing
        // v2 (§12.1, §15.11)
        case linked
        case linkRefused
        case linkRequest
        case linkResolved
    }

    public var event: Name
    public var seq: Int?

    // tasksChanged
    public var tasks: [RemoteTask]?
    public var removedTaskIds: [String]?
    public var projects: [RemoteProject]?

    // attention
    public var taskId: String?
    public var title: String?
    public var projectName: String?
    public var harnessName: String?
    public var state: RemoteAttention?
    public var previousState: RemoteAttention?
    public var indicator: RemoteIndicator?
    public var pendingRequest: RemotePendingRequest?
    public var requestId: String?
    /// One line about the request waited on (≤ 120 characters, secrets masked), for a notification.
    public var summary: String?

    // conversation
    public var changes: [RemoteChange]?
    public var items: [RemoteItem]?
    public var cursor: String?
    public var hasOlder: Bool?
    public var reason: String?

    // links
    public var deviceId: String?
    public var name: String?
    public var platform: String?
    public var code: String?
    public var expiresAt: Int64?
    public var approved: Bool?
    /// Push payloads (§16): the Mac's name and when the push was sent.
    public var macName: String?
    public var sentAt: Int64?

    public init(_ event: Name) {
        self.event = event
    }
}

public enum RemoteJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func string<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - v2 handshake payloads (§13.1)

/// Message 1's payload.
public struct RemoteHandshakeHello: Codable, Equatable, Sendable {
    public var v: Int
    public var name: String?
    public var platform: String?
    public var appVersion: String?
    /// The pairing secret from the QR code.
    public var pair: String?
    /// Asks to link through the account (§12.1).
    public var link: Bool?

    public init(v: Int = RemoteProtocol.secureVersion, name: String? = nil, platform: String? = nil,
                appVersion: String? = nil, pair: String? = nil, link: Bool? = nil) {
        self.v = v
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
        self.pair = pair
        self.link = link
    }
}

/// Message 2's payload.
public struct RemoteHandshakeReply: Codable, Equatable, Sendable {
    public struct Relay: Codable, Equatable, Sendable {
        public var url: String
        public var room: String

        public init(url: String, room: String) {
            self.url = url
            self.room = room
        }
    }

    public var ok: Bool
    public var error: RemoteError?
    public var deviceId: String?
    public var serverTime: Int64?
    public var paired: Bool?
    public var pending: Bool?
    public var code: String?
    public var server: RemoteServerInfo?
    public var direct: [String]?
    public var relay: Relay?

    public init(ok: Bool, error: RemoteError? = nil) {
        self.ok = ok
        self.error = error
    }
}
