import Foundation

/// What a host app adds to a Claude Code conversation in the person's place. The Claude app puts
/// `<system-reminder>` and `<side-sessions-event>` blocks before the person's text when a session
/// it started finishes a turn, and sends such a block alone to wake the parent; its own screen
/// shows neither. They are context for the model, so the conversation shows the person's text
/// without them and leaves a message that is only a notice out, like Claude's other notices.
enum ClaudeHostNotice {
    private static let blockPattern = try! NSRegularExpression(
        pattern: #"<(system-reminder|side-sessions-event)>[\s\S]*?</\1>"#
    )

    /// The text without the host's blocks, trimmed; unchanged when it has none.
    static func stripped(_ text: String) -> String {
        guard text.contains("<system-reminder>") || text.contains("<side-sessions-event>") else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return blockPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the text was the host's blocks and nothing of the person's.
    static func isOnlyNotice(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != stripped(trimmed) && stripped(trimmed).isEmpty
    }
}
