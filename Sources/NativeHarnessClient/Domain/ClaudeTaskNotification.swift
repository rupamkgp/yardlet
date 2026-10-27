import Foundation

/// The notice Claude Code writes as a `user` record to start a turn when a background command or
/// agent it ran ends (`origin.kind` "task-notification"): one `<task-notification>` block with the
/// task's id, status and a one-line summary. It is Claude's own, not the person's: its turn reads as
/// a turn of its own, opened by this notice rather than a request, so what Claude answered before it
/// stays that turn's answer, as the Claude app shows a notice's turn apart from the one before.
struct ClaudeTaskNotification: Equatable, Sendable {
    /// `<summary>`, or the status when the block has none.
    let summary: String
    let status: String?

    static let tag = "task-notification"

    /// The block, from the text's first character, and nothing else that is the person's.
    static func parse(_ text: String) -> Self? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<\(tag)>"), trimmed.hasSuffix("</\(tag)>") else { return nil }
        let status = element("status", in: trimmed)
        guard let summary = element("summary", in: trimmed) ?? status else { return nil }
        return Self(summary: summary, status: status)
    }

    private static func element(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
