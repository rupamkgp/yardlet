import Foundation

enum SessionTitleProjection {
    static let maximumLength = 72

    static func provisionalTitle(from prompt: String) -> String {
        let firstLine = prompt
            .split(whereSeparator: \Character.isNewline)
            .first
            .map(String.init) ?? ""
        let normalized = collapsedWhitespace(firstLine)
        return normalized.isEmpty
            ? L10n.string("New task")
            : String(normalized.prefix(maximumLength))
    }

    static func normalizedProviderTitle(_ title: String?) -> String? {
        guard var title = title.map(collapsedWhitespace), !title.isEmpty else { return nil }
        title = removingBalancedQuotes(from: title)
        let lowercased = title.lowercased()
        let placeholders = ["new task", "new session", "untitled", "imported codex task"]
        guard !placeholders.contains(lowercased),
              !lowercased.hasPrefix("new task - "),
              !lowercased.hasPrefix("new session - ") else { return nil }
        return String(title.prefix(maximumLength))
    }

    /// Providers without title metadata still receive a stable, local title after the first turn.
    /// This is deliberately deterministic: title generation must not consume a hidden model turn.
    static func fallbackTitle(firstUserMessage: String, workspaceURL: URL) -> String {
        let provisional = provisionalTitle(from: firstUserMessage)
        let workspace = collapsedWhitespace(workspaceURL.lastPathComponent)
        let cleaned = cleanedRequest(provisional)

        if containsKoreanOperationQuestion(cleaned), !workspace.isEmpty {
            return String("\(workspace) \(koreanOperationCheck)".prefix(maximumLength))
        }
        if !cleaned.isEmpty, cleaned.caseInsensitiveCompare(provisional) != .orderedSame {
            return String(cleaned.prefix(maximumLength))
        }
        guard !workspace.isEmpty, provisional != L10n.string("New task") else {
            return provisional
        }
        return String("\(workspace) · \(provisional)".prefix(maximumLength))
    }

    /// The title a row shows under a project it already names. Only a title Yardlet made itself
    /// (`automatic` or `provisional`) loses the leading folder name `fallbackTitle` gives it; a
    /// provider's, the user's, or an older title shows as stored. The stored title is unchanged
    /// and keeps the project for the window title and anywhere else without the project row.
    static func titleUnderProject(_ session: SessionRecord, projectNames: [String]) -> String {
        guard session.titleOrigin == .automatic || session.titleOrigin == .provisional else {
            return session.title
        }
        let title = session.title
        var seen = Set<String>()
        let names = projectNames.map(collapsedWhitespace)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
        for name in names {
            if title.hasPrefix(name + " · ") {
                let rest = title.dropFirst(name.count + 3).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { return rest }
            }
            if title == "\(name) \(koreanOperationCheck)" { return koreanOperationCheck }
        }
        return title
    }

    private static let koreanOperationCheck = "작동 상태 확인"

    private static func collapsedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func removingBalancedQuotes(from value: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("‘", "’")]
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              pairs.contains(where: { $0.0 == first && $0.1 == last }) else { return value }
        return collapsedWhitespace(String(value.dropFirst().dropLast()))
    }

    private static func cleanedRequest(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let markdownPrefixes = ["- ", "* ", "> ", "# ", "## ", "### "]
        for prefix in markdownPrefixes where cleaned.hasPrefix(prefix) {
            cleaned.removeFirst(prefix.count)
            break
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "`\"' "))

        let politePrefixes = [
            "could you ", "can you ", "would you ", "will you ", "please ",
            "could you please ", "can you please "
        ]
        let lowercased = cleaned.lowercased()
        if let prefix = politePrefixes.sorted(by: { $0.count > $1.count }).first(where: {
            lowercased.hasPrefix($0)
        }) {
            cleaned.removeFirst(prefix.count)
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "?.! "))
        guard let first = cleaned.first else { return cleaned }
        return first.uppercased() + cleaned.dropFirst()
    }

    private static func containsKoreanOperationQuestion(_ value: String) -> Bool {
        let hasOperationWord = ["작동", "동작", "잘 돼", "잘되", "괜찮"].contains {
            value.localizedCaseInsensitiveContains($0)
        }
        let hasQuestionEnding = ["니", "나", "까", "어", "지", "?"]
            .contains { value.hasSuffix($0) }
        return hasOperationWord && hasQuestionEnding
    }
}
