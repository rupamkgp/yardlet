import Foundation

/// An invocation advertised by the session's provider. Selecting it edits the draft; only the
/// existing Send action submits it, and the provider owns expansion and execution.
///
/// A client-run command (the Codex app's own slash commands) also carries the title the app
/// shows in place of the `/name`, and the group heading it is listed under.
struct ProviderComposerCommand: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let description: String
    let argumentHint: String
    var aliases: [String]? = nil
    var builtin: Bool? = nil
    var title: String? = nil
    var group: String? = nil

    var id: String { name }
    var invocation: String { "/\(name)" }
    /// What a list row shows: the app's title when it has one, otherwise the invocation.
    var displayTitle: String { title ?? invocation }

    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/")
            && !name.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            }
    }
}

enum ComposerCommands {
    /// Only a leading, unfinished command opens suggestions. A space closes the list so the
    /// reader can write arguments; an absolute file path is never treated as a command.
    static func query(in text: String) -> String? {
        let content = text.drop(while: \.isWhitespace)
        guard content.first == "/" else { return nil }
        let query = String(content.dropFirst())
        guard query.isEmpty || ProviderComposerCommand.isValidName(query) else { return nil }
        return query
    }

    static func matching(_ commands: [ProviderComposerCommand], query: String) -> [ProviderComposerCommand] {
        guard !query.isEmpty else { return commands }
        let query = query.lowercased()
        func rank(_ command: ProviderComposerCommand) -> Int? {
            let name = command.name.lowercased()
            if name == query { return 0 }
            if name.hasPrefix(query) { return 1 }
            let aliases = (command.aliases ?? []).map { $0.lowercased() }
            if aliases.contains(query) { return 2 }
            if aliases.contains(where: { $0.hasPrefix(query) }) { return 3 }
            if let title = command.title?.lowercased() {
                // As in the Codex app, a titled command is found by its title, name and aliases,
                // not by its description.
                let words = title.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
                if title.hasPrefix(query) || words.contains(where: { $0.hasPrefix(query) }) { return 4 }
                if title.contains(query) || name.contains(query) { return 5 }
                return nil
            }
            if command.description.localizedCaseInsensitiveContains(query) { return 4 }
            return nil
        }
        // A match stays under its own group heading; the groups keep the catalog's order.
        var groupOrder: [String: Int] = [:]
        for command in commands where groupOrder[command.group ?? ""] == nil {
            groupOrder[command.group ?? ""] = groupOrder.count
        }
        return commands.enumerated().compactMap { index, command -> (Int, Int, Int, ProviderComposerCommand)? in
            rank(command).map { (groupOrder[command.group ?? ""] ?? 0, $0, index, command) }
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            return $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1
        }.map { $0.3 }
    }

    static func inserting(_ command: ProviderComposerCommand, in text: String) -> String {
        guard ProviderComposerCommand.isValidName(command.name) else { return text }
        let content = text.drop(while: \.isWhitespace)
        if content.first == "/" {
            let end = content.firstIndex(where: \.isWhitespace) ?? text.endIndex
            let name = String(content[content.index(after: content.startIndex)..<end])
            if name.isEmpty || ProviderComposerCommand.isValidName(name) {
                var result = text
                result.replaceSubrange(content.startIndex..<end, with: command.invocation)
                if end == text.endIndex { result.append(" ") }
                return result
            }
        }
        return command.invocation + " " + text
    }
}
