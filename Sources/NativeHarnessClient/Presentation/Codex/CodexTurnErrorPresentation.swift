import Foundation

/// Reads a Codex `TurnError` the way the Codex app does: the provider's own message stays the
/// text, and only the categories a person acts on differently get a plain headline above it.
struct CodexTurnErrorPresentation: Equatable, Sendable {
    enum Category: Equatable, Sendable {
        case usageLimit
        case contextWindow
        case serverOverloaded
    }

    let message: String
    let category: Category?

    /// Accepts the `TurnError` object, or a bare message from an older runtime.
    init?(_ error: JSONValue?) {
        guard let error, error != .null else { return nil }
        let message = TranscriptRecoveryProjection.unwrappedErrorMessage(
            error.stringValue ?? error["message"]?.stringValue ?? ""
        )
        let category: Category? = switch error["codexErrorInfo"]?.stringValue {
        case "usageLimitExceeded": .usageLimit
        case "contextWindowExceeded": .contextWindow
        case "serverOverloaded": .serverOverloaded
        default: nil
        }
        guard !message.isEmpty || category != nil else { return nil }
        self.message = message
        self.category = category
    }

    var headline: String? {
        switch category {
        case .usageLimit: L10n.string("You've hit your usage limit.")
        case .contextWindow: L10n.string("This conversation exceeds the model's context window.")
        case .serverOverloaded: L10n.string("Server is busy.")
        case nil: nil
        }
    }

    /// One text for places that show a single line, such as a system notification. The headline
    /// is left out when the provider's message already opens with it.
    var text: String {
        guard let headline else { return message }
        if message.isEmpty { return headline }
        let lead = headline.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        return message.lowercased().hasPrefix(lead) ? message : "\(headline)\n\(message)"
    }

    /// The Codex errors of a request or response stream that never reached the server, after Codex's
    /// own retries (`CodexErrorInfo` 0.163): the connection ones among those the Codex app 26.1016
    /// offers Resume on (`b5e`), each with the HTTP status it got (`lot`), here none.
    static let connectionErrorInfos: Set<String> = [
        "httpConnectionFailed", "responseStreamConnectionFailed", "responseStreamDisconnected",
        "responseTooManyFailedAttempts",
    ]

    /// Whether a turn's `TurnError` says its connection was lost: one of `connectionErrorInfos` with no
    /// HTTP status. A status (a 429 or a 5xx) is the server's own answer, not a lost connection.
    static func isConnectionCut(_ error: JSONValue?) -> Bool {
        guard let info = error?["codexErrorInfo"] else { return false }
        if let name = info.stringValue { return connectionErrorInfos.contains(name) }
        guard let variant = info.objectValue, variant.count == 1, let (name, details) = variant.first,
              connectionErrorInfos.contains(name) else { return false }
        return details["httpStatusCode"] == nil || details["httpStatusCode"] == .null
    }

    /// `error` notification params are `{ error: TurnError, willRetry, threadId, turnId }`. A
    /// runtime that sent the older flat `{ message }` shape is read as the error itself.
    static func notificationError(_ params: JSONValue?) -> JSONValue? {
        guard let params else { return nil }
        return params["error"] ?? (params["message"] == nil ? nil : params)
    }

    /// The in-turn status while the provider retries its response stream, matching the Codex
    /// app's `Reconnecting 2/5` and `Server is busy, reconnecting` lines.
    static func reconnectStatus(_ error: JSONValue?) -> String? {
        guard let error, error != .null else { return nil }
        let message = (error.stringValue ?? error["message"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let progress = reconnectProgress(message).map { "\($0.attempt)/\($0.maxAttempts)" }
        if error["codexErrorInfo"]?.stringValue == "serverOverloaded" {
            return progress.map { L10n.format("Server is busy, reconnecting %@", $0) }
                ?? L10n.string("Server is busy, reconnecting")
        }
        if let progress { return L10n.format("Reconnecting %@", progress) }
        return message.isEmpty ? L10n.string("Reconnecting") : message
    }

    /// Codex reports retry progress as `Reconnecting... 2/5`.
    static func reconnectProgress(_ message: String) -> (attempt: Int, maxAttempts: Int)? {
        let pattern = /^Reconnecting(?:\.\.\.)?\s+(\d+)\/(\d+)$/
        guard let match = message.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: pattern),
              let attempt = Int(match.1), let maxAttempts = Int(match.2) else { return nil }
        return (attempt, maxAttempts)
    }
}
