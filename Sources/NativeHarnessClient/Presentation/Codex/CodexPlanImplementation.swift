import Foundation

/// "Yes, implement this plan" after a Plan mode turn, as the Codex app offers it: the app leaves
/// Plan mode and sends its fixed request line followed by the plan.
enum CodexPlanImplementation {
    static let requestPrefix = "PLEASE IMPLEMENT THIS PLAN:"

    static func request(for plan: String) -> String {
        "\(requestPrefix)\n\(plan)"
    }

    static func isRequest(_ text: String) -> Bool {
        text.hasPrefix(requestPrefix)
    }

    /// The plan a finished turn offers to implement: its last plan item with text, once the turn
    /// completed. A stopped or failed turn offers nothing.
    static func offeredPlan(in turn: CodexTurnState) -> String? {
        guard turn.status == .completed else { return nil }
        for item in turn.items.reversed() {
            guard case let .plan(text) = item.content else { continue }
            let plan = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return plan.isEmpty ? nil : plan
        }
        return nil
    }
}
