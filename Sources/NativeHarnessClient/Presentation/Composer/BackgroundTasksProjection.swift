import Foundation

/// The quiet line above a task's composer while its background agents and tasks run, in the place
/// of the Codex app's background agents line (`composer.backgroundSubagents`, a disclosure row on
/// the composer rail that lists them and stops them all).
///
/// The rows are the provider's own background tasks still running in the conversation: Claude
/// Code's `task_started` with `is_backgrounded` (a background agent or shell) until its
/// `task_notification` or terminal `task_updated`, the same cards the conversation shows. A
/// subagent's own background task, which the conversation does not show, is listed under its
/// subagent's row when that runs too (2026-10-16). Codex's subagents are not listed: Yardlet's Codex
/// timeline has only the spawning call's snapshot of each child's state, and stopping one needs the
/// child thread's own turn.
struct BackgroundTasksProjection: Equatable {
    struct Row: Identifiable, Equatable {
        let activity: HarnessActivity
        /// When the conversation first showed the task, which its elapsed time counts from.
        let startedAt: Date
        /// 1 for a subagent's own task listed under its subagent's row.
        var depth = 0
        var id: String { activity.id }
        /// An agent's row names its harness and model (`HarnessModelLabel`); a shell has no model.
        var showsHarnessModel: Bool { opensConversation }
        var title: String { activity.title }
        /// A background agent has a conversation the subtask panel reads; a shell has none.
        var opensConversation: Bool { activity.subtask?.hasConversation == true }
        /// The provider can stop it by its task ID (Claude's `stop_task`).
        var canStop: Bool { activity.subtask?.taskID != nil }
    }

    let rows: [Row]

    /// - Parameters:
    ///   - includesAgents: lists background agents; the session rail lists them in its Agents card
    ///     (`SessionRailAgents`) and its Background tasks card keeps the real tasks alone.
    ///   - includesTasks: lists shells, monitors and the provider's other tasks.
    init(entries: [TranscriptEntry], includesAgents: Bool = true, includesTasks: Bool = true) {
        var seen = Set<String>()
        let running = entries.compactMap { entry -> Row? in
            guard case let .activity(activity, .running) = entry.content,
                  let subtask = activity.subtask, activity.isBackground == true,
                  subtask.isAgent ? includesAgents : includesTasks,
                  seen.insert(activity.id).inserted else { return nil }
            return Row(activity: activity, startedAt: entry.createdAt)
        }
        // Each subagent's own tasks follow its row; one whose subagent is not listed keeps its place.
        let listedTaskIDs = Set(running.compactMap { $0.activity.subtask?.taskID })
        func isChild(_ row: Row) -> Bool {
            row.activity.subtask?.parentTaskID.map(listedTaskIDs.contains) == true
        }
        var ordered: [Row] = []
        func append(_ row: Row, depth: Int) {
            var row = row
            row.depth = depth
            ordered.append(row)
            guard let taskID = row.activity.subtask?.taskID, depth == 0 else { return }
            for child in running where child.activity.subtask?.parentTaskID == taskID {
                append(child, depth: 1)
            }
        }
        for row in running where !isChild(row) { append(row, depth: 0) }
        rows = ordered
    }

    /// The line shows only while something runs.
    var isShown: Bool { !rows.isEmpty }

    /// The Claude app's words for its running background tasks ("# running tasks").
    var countText: String {
        rows.count == 1 ? L10n.string("1 running task") : L10n.format("%lld running tasks", rows.count)
    }

    /// How long a task has run, as both apps show beside a running task ("42s", "3m 12s", "1h 5m").
    static func elapsedText(since start: Date, now: Date) -> String {
        let seconds = max(0, Int64(now.timeIntervalSince(start)))
        if seconds < 60 { return L10n.format("%llds", seconds) }
        if seconds < 3_600 { return L10n.format("%lldm %llds", seconds / 60, seconds % 60) }
        return L10n.format("%lldh %lldm", seconds / 3_600, seconds % 3_600 / 60)
    }

    /// What "Stop all" stops: every task the provider can stop that is not already stopping, each
    /// through the task's own stop route. The conversation's turn is not interrupted.
    func stopAllTargets(isStopping: (String) -> Bool) -> [HarnessActivity] {
        rows.filter { $0.canStop && !isStopping($0.id) }.map(\.activity)
    }
}

/// "Stop all" asks first. Nothing stops until the person confirms; then each listed task is stopped
/// as its own stop control would.
struct BackgroundTasksStopAll: Equatable {
    private(set) var isConfirming = false

    mutating func request() { isConfirming = true }

    mutating func cancel() { isConfirming = false }

    /// Stops the tasks "Stop all" names and returns their IDs.
    @MainActor
    @discardableResult
    mutating func confirm(_ projection: BackgroundTasksProjection, actions: HarnessActivityActions) -> [String] {
        isConfirming = false
        guard let stop = actions.stop else { return [] }
        let targets = projection.stopAllTargets(isStopping: actions.isStopping)
        for activity in targets { stop(activity) }
        return targets.map(\.id)
    }
}
