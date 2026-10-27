import Foundation

/// Which of a turn's status lines and summaries start open. After that they keep
/// what the person chose: a line or summary the person opened or folded stays so, also when it moves
/// between the live line and the turn's listed work (`ConversationDisclosureChoices`).
///
/// 2026-10-16 user decisions: "명령 실행시에 기본 상태가 접힘이면 좋겠고", then "도구 줄이 너무 많이 쌓임"
/// and "현재 처리되고 있는 tool이라도 펼쳐서 보여주지 않으면 좋겠어". No call starts open, running or
/// not, and no run of calls opens because its turn runs: while a turn runs, its calls fold into
/// their summary lines and the call that runs now is the live line's (`ConversationLiveWork`), as
/// the Codex app keeps its activity group folded under the current item's words. What needs attention
/// still opens: a failed call opens on what went wrong, and so does the summary it is in. Waiting
/// requests stay pinned under the turn (D1), and a background command stays in the line above the
/// composer.
enum ConversationWorkDisclosure {
    /// A call's line, or the provider's thinking: a failed one opens on what went wrong; anything
    /// else starts folded, while it runs too, unless the person opened it (`choice`).
    static func lineStartsOpen(_ item: ConversationItem, choice: Bool? = nil) -> Bool {
        item.phase == .failed || choice == true
    }

    /// A run of calls opens when one of its calls failed, when the person opened it (`choice`), and
    /// when the person opened the finished turn's folded work to see it unless they folded the run.
    /// A running turn does not open it.
    static func groupStartsOpen(_ items: [ConversationItem], turnIsRunning: Bool, workWasOpened: Bool,
                                choice: Bool? = nil) -> Bool {
        groupHasFailure(items) || (choice ?? workWasOpened)
    }

    /// The live line starts folded, as the Codex app's activity header does, unless the person opened
    /// the run it stands for, or one of its calls failed.
    static func liveLineStartsOpen(_ items: [ConversationItem], choice: Bool?) -> Bool {
        groupHasFailure(items) || choice == true
    }

    /// A summary opens when a call in it fails, as the failed line does.
    static func groupHasFailure(_ items: [ConversationItem]) -> Bool {
        items.contains { $0.phase == .failed }
    }
}

/// The person's own open and fold choices in one turn. A line or run that moves between the live line
/// and the turn's listed work is drawn anew there, so it reads what the person chose here: a line by
/// its item's id, a run by its first item's (`runKey`), which stays the same as calls join the run.
@MainActor
final class ConversationDisclosureChoices {
    private var choices: [String: Bool] = [:]

    func choice(_ key: String?) -> Bool? {
        key.flatMap { choices[$0] }
    }

    func record(_ key: String?, isOpen: Bool) {
        guard let key else { return }
        choices[key] = isOpen
    }

    /// The key of a run of calls, single or grouped.
    static func runKey(_ items: [ConversationItem]) -> String? {
        items.first.map { "run:" + $0.id }
    }
}
