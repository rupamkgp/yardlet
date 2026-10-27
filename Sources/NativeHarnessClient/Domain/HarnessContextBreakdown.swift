import Foundation

/// What fills a session's context window, as a harness that measures it reports it. Claude Code's
/// `get_context_usage` gives one category per kind of content (its `/context` rows), the token
/// count at which it compacts on its own, and whether it does. Other harnesses report only how
/// full the window is, and carry none.
struct HarnessContextBreakdown: Codable, Equatable, Sendable {
    struct Category: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            /// Content in the window: the system prompt, tools, memory files, messages.
            case used
            /// Room left.
            case free
            /// Room the harness keeps for compacting.
            case buffer
            /// Tools listed by name only, loaded when called. Not in the window.
            case deferred
        }

        /// The harness's own name for the row ("System prompt", "Messages"), shown as it is.
        var name: String
        var tokens: UInt64
        var kind: Kind
    }

    var categories: [Category]
    /// The window size the categories and the threshold are measured against.
    var windowTokens: UInt64?
    /// The token count at which the harness compacts the conversation on its own.
    var autoCompactThresholdTokens: UInt64?
    var isAutoCompactEnabled: Bool
    /// Claude Code's `autocompactSource`: `auto` where the API compacts by itself and keeps no
    /// buffer row.
    var autoCompactSource: String?

    init(
        categories: [Category],
        windowTokens: UInt64? = nil,
        autoCompactThresholdTokens: UInt64? = nil,
        isAutoCompactEnabled: Bool = false,
        autoCompactSource: String? = nil
    ) {
        self.categories = categories
        self.windowTokens = windowTokens
        self.autoCompactThresholdTokens = autoCompactThresholdTokens
        self.isAutoCompactEnabled = isAutoCompactEnabled
        self.autoCompactSource = autoCompactSource
    }

    /// Claude Code's rule for a category the CLI sent without a kind.
    static func kind(forName name: String) -> Category.Kind {
        switch name {
        case "Free space": .free
        case "Autocompact buffer", "Compact buffer": .buffer
        default: name.hasSuffix("(deferred)") ? .deferred : .used
        }
    }
}
