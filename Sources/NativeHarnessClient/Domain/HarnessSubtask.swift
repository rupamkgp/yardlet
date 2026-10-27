import Foundation

/// A task inside a provider session, not an independently resumable session. The enclosing
/// transcript owns the account/storage scope; neither ID may be used as a session ID.
struct HarnessSubtaskReference: Codable, Equatable, Hashable, Sendable {
    var taskID: String?
    var agentID: String?
    var toolUseID: String?
    var taskType: String?
    /// The task is a subagent's own work, not the session's (Claude Code's `owned_by_subagent`): a
    /// background command or agent a subagent started.
    var ownedBySubagent: Bool?
    /// The subagent's task that started this one, when the provider names it (Claude Code's
    /// `parent_task_id`).
    var parentTaskID: String?
    /// The model the provider reported the subagent runs on (Claude Code's `resolvedModel`, or
    /// the model its call asked for).
    var model: String?

    var hasConversation: Bool { taskType == "local_agent" || agentID != nil }

    /// A subagent's own work, which belongs under the subagent rather than in the session.
    var isSubagentWork: Bool { ownedBySubagent == true || parentTaskID != nil }

    var json: JSONValue {
        var value: [String: JSONValue] = [:]
        if let taskID { value["taskID"] = .string(taskID) }
        if let agentID { value["agentID"] = .string(agentID) }
        if let toolUseID { value["toolUseID"] = .string(toolUseID) }
        if let taskType { value["taskType"] = .string(taskType) }
        if let ownedBySubagent { value["ownedBySubagent"] = .bool(ownedBySubagent) }
        if let parentTaskID { value["parentTaskID"] = .string(parentTaskID) }
        if let model { value["model"] = .string(model) }
        return .object(value)
    }

    init(taskID: String? = nil, agentID: String? = nil, toolUseID: String? = nil,
         taskType: String? = nil, ownedBySubagent: Bool? = nil, parentTaskID: String? = nil,
         model: String? = nil) {
        self.taskID = taskID
        self.agentID = agentID
        self.toolUseID = toolUseID
        self.taskType = taskType
        self.ownedBySubagent = ownedBySubagent
        self.parentTaskID = parentTaskID
        self.model = model
    }

    init?(json: JSONValue?) {
        guard let json, case .object = json else { return nil }
        self.init(taskID: json["taskID"]?.stringValue, agentID: json["agentID"]?.stringValue,
                  toolUseID: json["toolUseID"]?.stringValue, taskType: json["taskType"]?.stringValue,
                  ownedBySubagent: json["ownedBySubagent"]?.boolValue, parentTaskID: json["parentTaskID"]?.stringValue,
                  model: json["model"]?.stringValue)
        guard taskID != nil || agentID != nil || toolUseID != nil else { return nil }
    }
}

struct HarnessSubtaskTranscript: Sendable {
    let entries: [TranscriptEntry]
    let isTruncated: Bool
    /// The read began inside the saved file and the conversation goes on before it, so a larger
    /// read shows earlier turns. False when the conversation was read from its start (or from a
    /// compaction), and when the entry limit is what cut it.
    var hasEarlierRecords = false
}

/// Task control stays with the already attached parent session. Implementations must resolve
/// the displayed activity against their live provider correlations instead of trusting a saved ID.
protocol HarnessSubtaskControlling: Actor {
    func stopSubtask(activityID: String, in session: HarnessSessionHandle) async throws
}
