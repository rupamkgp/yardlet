import Foundation
import YardletAgentTools

/// A schedule an agent created with Yardlet's `create_scheduled_task`, drawn where the call happened
/// as one compact row — its name, when it runs next, and Open, which shows it in Scheduled tasks
/// (`ScheduledTaskCreatedRow`). The row reads the schedule itself from the app as it draws, so a
/// later change, pause or delete shows; the call keeps only what identifies it.
struct ConversationScheduleCreation: Equatable, Sendable {
    var scheduleID: UUID
    /// The name the call gave, shown when the schedule is gone.
    var name: String
}

/// Which calls created a schedule, whatever the harness. Claude Code records the call as
/// `mcp__yardlet__create_scheduled_task`, Codex as an MCP call to the `yardlet` server, an ACP agent as
/// a tool call in its own words. What they share is Yardlet's answer, which names the schedule with
/// words only Yardlet's answer has (`ScheduleToolCatalog.scheduleID(inCreatedResult:)`), so the Claude
/// app's own `create_scheduled_task`, in a conversation imported from it, stays a tool line.
enum ConversationScheduleProjection {
    /// A shared-transcript call (Claude Code, ACP).
    static func creation(from activity: HarnessActivity) -> ConversationScheduleCreation? {
        guard activity.outcome != .failed, activity.subtask == nil, activity.diff == nil else { return nil }
        return creation(result: activity.output)
    }

    /// A Codex MCP call to the `yardlet` server's `create_scheduled_task`.
    static func creation(from tool: CodexMCPToolItem) -> ConversationScheduleCreation? {
        guard tool.server == AgentToolEnvironment.serverName, tool.tool == ScheduleToolCatalog.create,
              tool.error == nil || tool.error == .null else { return nil }
        let result = CodexMCPResultProjection(result: tool.result).blocks.compactMap { block -> String? in
            if case let .text(_, text) = block { return text }
            return nil
        }.joined(separator: "\n")
        return creation(result: result)
    }

    static func creation(result: String?) -> ConversationScheduleCreation? {
        guard let created = ScheduleToolCatalog.created(inResult: result),
              let id = UUID(uuidString: created.scheduleID) else { return nil }
        return ConversationScheduleCreation(scheduleID: id, name: created.name)
    }
}
