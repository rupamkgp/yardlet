import Foundation

extension ConversationPlan {
    /// A provider's plan text read as steps, in the forms the adapters write it:
    /// - Claude Code's task list, one `☑ subject`, `◉ subject` or `☐ subject` a line
    ///   (`ClaudeTaskListProjection`);
    /// - ACP's plan entries, one `[status] content` a line, with `pending`, `in_progress` or
    ///   `completed` (`ACPProtocol`);
    /// - Codex's common event: an optional explanation, a blank line, then `[x]`, `[~]` or `[ ]`
    ///   steps (`CodexProtocol`).
    /// Anything else — Claude's "No tasks", a numbered list, a Markdown plan, a step whose text
    /// runs onto a second line — stays one text block, exactly as the provider wrote it: the
    /// explanation of a plan with no steps.
    /// `stepIDPrefix` names the steps as the Codex reducer does (`<prefix>:plan:<index>`).
    static func parse(_ text: String, stepIDPrefix: String = "plan") -> ConversationPlan {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let block = ConversationPlan(explanation: text, steps: [])
        var leading: [Substring] = []
        var steps: [Step] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if steps.isEmpty, step(trimmed) == nil {
                leading.append(line)
                continue
            }
            // Once the steps start, every line is a step; blank lines between them are allowed.
            if trimmed.isEmpty { continue }
            guard let (status, title) = step(trimmed) else { return block }
            steps.append(Step(id: "\(stepIDPrefix):plan:\(steps.count)", text: title, status: status))
        }
        guard !steps.isEmpty else { return block }
        let explanation = leading.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // An explanation is its own paragraph above the steps, as Codex writes it.
        if !explanation.isEmpty,
           leading.last?.trimmingCharacters(in: .whitespaces).isEmpty != true {
            return block
        }
        return ConversationPlan(explanation: explanation.isEmpty ? nil : explanation, steps: steps)
    }

    /// One step line's status and text, or nil when the line is not a step.
    private static func step(_ line: String) -> (StepStatus, String)? {
        guard let first = line.first else { return nil }
        let markerStatus: StepStatus? = switch first {
        case "☑": .completed
        case "◉": .inProgress
        case "☐": .pending
        default: nil
        }
        if let markerStatus {
            let rest = line.dropFirst()
            guard rest.first == " " else { return nil }
            let title = rest.trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : (markerStatus, title)
        }
        guard first == "[", let close = line.firstIndex(of: "]") else { return nil }
        let status = line[line.index(after: line.startIndex)..<close]
        let rest = line[line.index(after: close)...]
        guard rest.first == " ", status.count <= 24, !status.contains("[") else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (bracketStatus(String(status)), title)
    }

    private static func bracketStatus(_ status: String) -> StepStatus {
        switch status.trimmingCharacters(in: .whitespaces).lowercased() {
        case "completed", "x": .completed
        case "in_progress", "inprogress", "~": .inProgress
        case "pending", "": .pending
        default: .unknown(status)
        }
    }
}
