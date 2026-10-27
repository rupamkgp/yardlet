import Foundation

// The markup the Codex app writes into a conversation and draws as something other than its text
// (Codex desktop app 26.1007, bundle `com.openai.codex`). The conversation projections read a
// provider's message through these rules, so the one renderer draws what the Codex app draws:
// - an automation's heartbeat, the message a scheduled task sends in the person's place, is its
//   instructions under "Sent by scheduled task" (`ConversationScheduledTaskMessage`);
// - the model's heartbeat reply shows its words to the person, not the XML around them
//   (`CodexHeartbeatReply`), and a run that skipped its update says so;
// - the directives the Codex app acts on rather than shows (`::inbox-item{…}`, `::git-commit{…}` and
//   the like) are left out of the message (`CodexDirectiveMarkup`).
// A Codex thread is read by the Codex app's rules. Any other harness's transcript is read by them only
// where a message is exactly one of these shapes.

/// A message a Codex app automation sent on its schedule in the person's place, a "heartbeat":
/// `<heartbeat><automation_id>…</automation_id><current_time_iso>…</current_time_iso>`
/// `<instructions>…</instructions></heartbeat>`. The Codex app draws its instructions in a sent bubble
/// clipped to two lines, under "Sent by scheduled task".
struct ConversationScheduledTaskMessage: Equatable, Sendable {
    /// What the automation asked for, which the bubble shows and "Copy message" copies.
    var instructions: String
    var automationID: String?
    var currentTimeISO: String
    /// Claude Code's own schedule sent it (`ClaudeScheduledPrompt`), which the Claude app draws as an
    /// event rather than a sent bubble. Nil for a Codex app automation's heartbeat.
    var claudeSchedule: ClaudeScheduledPrompt.Kind? = nil

    /// The Codex app's reading (`wae` in `app-shared`): the trimmed text is one `<heartbeat>` element
    /// from its first character to its last, holding `current_time_iso` and `instructions`;
    /// `automation_id` may be missing. Each element is its first occurrence, matched without regard
    /// to case and trimmed. Anything else, a heartbeat quoted inside other text included, is no
    /// heartbeat.
    static func parse(_ text: String) -> Self? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<heartbeat>"), trimmed.hasSuffix("</heartbeat>"),
              let time = CodexAutomationMarkup.firstElement("current_time_iso", in: trimmed),
              let instructions = CodexAutomationMarkup.firstElement("instructions", in: trimmed)
        else { return nil }
        return Self(
            instructions: instructions,
            automationID: CodexAutomationMarkup.firstElement("automation_id", in: trimmed),
            currentTimeISO: time
        )
    }
}

/// The model's answer to a heartbeat: words for the person, if any, then one `<heartbeat>` element
/// with its `decision` (`NOTIFY` or `DONT_NOTIFY`) and a short `message`.
struct CodexHeartbeatReply: Equatable, Sendable {
    enum Decision: Equatable, Sendable {
        case notify
        case dontNotify
    }

    let decision: Decision
    /// The text outside the heartbeat elements, trimmed.
    let visibleText: String
    /// The element's `message`, trimmed and out of its CDATA wrapper; nil when empty.
    let notificationMessage: String?

    /// The Codex app's reading of any agent message (`Sz`): the text holds a `<heartbeat>` element
    /// (bare or in an `xml` code fence) and its last one names a decision.
    static func parse(_ text: String) -> Self? {
        guard let visible = CodexAutomationMarkup.textOutsideHeartbeats(text),
              let element = CodexAutomationMarkup.lastHeartbeat(in: text),
              let decision = CodexAutomationMarkup.decision(in: element) else { return nil }
        let message = CodexAutomationMarkup.message(in: element)
        return Self(decision: decision, visibleText: visible, notificationMessage: message.isEmpty ? nil : message)
    }

    /// The reading in a turn a heartbeat opened (`n2t`): a bare `DONT_NOTIFY`, alone or in a padded
    /// CDATA section, is a quiet reply too.
    static func parseInHeartbeatTurn(_ text: String) -> Self? {
        let unwrapped = CodexAutomationMarkup.firstMatch(#"^<!\[CDATA\[ ([\s\S]*) \]\]>$"#, in: text, group: 1) ?? text
        if unwrapped.trimmingCharacters(in: .whitespacesAndNewlines) == "DONT_NOTIFY" {
            return Self(decision: .dontNotify, visibleText: "", notificationMessage: nil)
        }
        return parse(text)
    }

    /// What the Codex app shows for the reply (the `heartbeat` structured output of
    /// `sites-end-resource`): the words outside the XML, else the element's message, else, for a quiet
    /// reply, its fixed line. Nothing at all hides the message.
    func shownText(display: String) -> String? {
        let display = display.trimmingCharacters(in: .whitespacesAndNewlines)
        if !display.isEmpty { return display }
        if let message = notificationMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return message
        }
        // The Codex app's own words, which it does not translate (`gO`).
        return decision == .dontNotify ? L10n.string("Heartbeat completed quietly.") : nil
    }
}

/// How a provider's message reads once the Codex app's markup is taken out of it.
enum ConversationAutomationText {
    /// A provider message as the conversation shows it; nil leaves the message out.
    ///
    /// - Codex: a skipped run reads "No update from this run" once it ends; a heartbeat reply shows
    ///   what `CodexHeartbeatReply.shownText` gives, and in a heartbeat's turn a message being written
    ///   stops before its XML begins (`a2t`); the directives the app does not show are left out
    ///   (`CodexDirectiveMarkup`).
    /// - Any other harness: only a message that is exactly a skipped run or exactly one heartbeat
    ///   reply element reads as one; everything else is its own text.
    ///
    /// - Parameter inHeartbeatTurn: the turn's request is a heartbeat
    ///   (`ConversationScheduledTaskMessage`).
    static func agentMessage(
        _ text: String, harness: HarnessKind, inHeartbeatTurn: Bool, isStreaming: Bool
    ) -> String? {
        if CodexAutomationMarkup.isSkippedCompletion(text) {
            return isStreaming ? nil : L10n.string("No update from this run")
        }
        guard harness == .codex else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("<heartbeat>"), trimmed.hasSuffix("</heartbeat>"),
                  let reply = CodexHeartbeatReply.parse(trimmed) else { return text }
            return reply.shownText(display: reply.visibleText)
        }
        var display = text
        // The Codex app reads a message being written only in a heartbeat's turn.
        if !isStreaming || inHeartbeatTurn {
            let reply = inHeartbeatTurn ? CodexHeartbeatReply.parseInHeartbeatTurn(text) : CodexHeartbeatReply.parse(text)
            if let reply {
                display = reply.visibleText
            } else if inHeartbeatTurn {
                display = CodexAutomationMarkup.heartbeatFallback(text) ?? text
            }
            if inHeartbeatTurn, isStreaming { display = CodexAutomationMarkup.beforeStreamingHeartbeat(display) }
            if let reply {
                guard let shown = reply.shownText(display: display) else { return nil }
                display = shown
            }
        }
        // What is shown is Markdown, where the app draws its own directives as nothing.
        display = CodexDirectiveMarkup.displayText(display, isStreaming: isStreaming)
        guard display != text else { return text }
        return display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : display
    }
}

/// The directives (`::name{attributes}` on a line of their own) the Codex app acts on rather than
/// draws: its conversation Markdown renders each of these names as nothing (`Gol` in `app-initial`,
/// `codex-live-vis` in `Erl`), and while a message is being written it drops their lines before they
/// are whole (`sqn`). `code-comment` is dropped only while the message is written: once it is done, a
/// local conversation draws its comments as a card (`bb` in `sites-end-resource`,
/// `CodexMessageDirectives`). A directive the app does not know stays as its text, as it does in the app.
enum CodexDirectiveMarkup {
    /// `inbox-item` files the message in the app's inbox; `archive-thread` archives the thread; the
    /// `git-*` names refresh the app's view of the repository; `codex-live-vis` is a visualization the
    /// app keeps up to date elsewhere; the rest mark the thread for the app.
    static let hiddenNames: Set<String> = [
        "inbox-item", "archive-thread", "thread-purpose-changed", "created-thread",
        "git-stage", "git-commit", "git-create-branch", "git-push", "git-create-pr", "pr-auto-fix-progress",
        "codex-realtime-inline", "codex-live-vis"
    ]

    /// The names a message being written drops (`bqn`): the hidden ones, and review comments, whose
    /// card the app draws once the message is done.
    static let streamingHiddenNames: Set<String> = hiddenNames.union(["code-comment"])

    /// `text` without the hidden directives' lines. Lines inside a fenced code block are text. A
    /// finished message drops a whole directive line; one being written drops any line that begins a
    /// hidden directive, and a last line that may still become one (`::` and the start of a name).
    /// While it is written, a directive the app draws is left out until it is whole, as the app cuts one
    /// off the end of its text (`m6c`, `h6c`, `Drl`): a last line that may still become one, a citation
    /// or follow-up still open at the end, and the first line of a card whose closing `:::` has not come.
    static func displayText(_ text: String, isStreaming: Bool) -> String {
        guard text.contains("::") || (isStreaming && text.contains(":codex-")) else { return text }
        let lines = text.components(separatedBy: "\n")
        var kept: [String] = []
        var fence: (marker: Character, length: Int)?
        var removed = false
        // The kept lines that open a card still waiting for its closing line; -1 for any other container.
        var openCards: [Int] = []
        for (index, line) in lines.enumerated() {
            if let open = fence {
                if let marker = fenceMarker(line), marker.character == open.marker, marker.length >= open.length,
                   marker.rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fence = nil
                }
                kept.append(line)
                continue
            }
            if let marker = fenceMarker(line), marker.character == "~" || !marker.rest.contains("`") {
                fence = (marker.character, marker.length)
                kept.append(line)
                continue
            }
            let isLast = index == lines.count - 1
            let hides = isStreaming
                ? beginsHiddenDirective(line, isLast: isLast) || (isLast && mayBecomeDrawnDirective(line))
                : directiveName(ofWholeLine: line).map(hiddenNames.contains) ?? false
            if hides {
                removed = true
                continue
            }
            var shown = line
            if isStreaming {
                if let directive = CodexDirectiveSyntax.wholeLine(line, colons: 3),
                   CodexMessageDirectives.containerNames.contains(directive.name) {
                    openCards.append(kept.count)
                } else if CodexDirectiveSyntax.opensContainer(line) {
                    openCards.append(-1)
                } else if CodexDirectiveSyntax.isContainerClose(line), !openCards.isEmpty {
                    openCards.removeLast()
                }
                if isLast {
                    shown = beforeOpenInlineDirective(line)
                    if shown != line { removed = true }
                }
            }
            kept.append(shown)
        }
        for position in openCards.reversed() where position >= 0 {
            kept.remove(at: position)
            removed = true
        }
        guard removed else { return text }
        var result = kept.joined(separator: "\n")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last line of a message being written may still become a directive the app draws as a card:
    /// it holds `::` or `:::` and the start of such a name, or the name and a directive not yet whole.
    private static func mayBecomeDrawnDirective(_ line: String) -> Bool {
        let start = line.drop { $0 == " " }
        guard line.count - start.count <= 3, start.hasPrefix("::") else { return false }
        let colons = start.prefix { $0 == ":" }.count
        guard colons == 2 || colons == 3 else { return false }
        let names = colons == 2 ? CodexMessageDirectives.lineNames : CodexMessageDirectives.containerNames
        let afterColons = start.dropFirst(colons)
        let name = leadingName(afterColons, allowsLeadingDigit: true)
        if name.count == afterColons.count { return names.contains { $0.hasPrefix(name) } }
        return names.contains(name) && CodexDirectiveSyntax.wholeLine(line, colons: colons) == nil
    }

    /// The last line of a message being written, up to a citation or follow-up that is not yet whole.
    private static func beforeOpenInlineDirective(_ line: String) -> String {
        var cut = line.endIndex
        for name in CodexMessageDirectives.inlineNames {
            guard let found = line.range(of: ":\(name)", options: .backwards) else { continue }
            if found.lowerBound > line.startIndex, line[line.index(before: found.lowerBound)] == ":" { continue }
            let next = found.upperBound
            guard next == line.endIndex || line[next] == "{" || line[next] == "[" else { continue }
            if CodexDirectiveSyntax.read(line, from: line.index(after: found.lowerBound)) == nil {
                cut = min(cut, found.lowerBound)
            }
        }
        return String(line[..<cut])
    }

    /// The name of the leaf directive a line is, from its `::` to its closing `}` with nothing but
    /// spaces after it: up to three spaces, `::name`, an optional `[label]` and `{attributes}`, whose
    /// quoted values may hold braces.
    static func directiveName(ofWholeLine line: String) -> String? {
        var rest = Substring(line)
        let indent = rest.prefix { $0 == " " }
        guard indent.count <= 3 else { return nil }
        rest = rest.dropFirst(indent.count)
        guard rest.hasPrefix("::"), !rest.hasPrefix(":::") else { return nil }
        rest = rest.dropFirst(2)
        let name = leadingName(rest)
        guard !name.isEmpty else { return nil }
        rest = rest.dropFirst(name.count)
        if rest.first == "[" {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            rest = rest[rest.index(after: close)...]
        }
        guard rest.first == "{" else { return nil }
        var inQuote = false
        var index = rest.index(after: rest.startIndex)
        while index < rest.endIndex {
            let character = rest[index]
            if character == "\"" {
                inQuote.toggle()
            } else if character == "}", !inQuote {
                let after = rest[rest.index(after: index)...]
                return after.allSatisfy(\.isWhitespace) ? name : nil
            }
            index = rest.index(after: index)
        }
        return nil
    }

    /// While a message is being written: the line begins a hidden directive, whole or not; or it is the
    /// last line and holds only `::` and the start of a hidden name.
    private static func beginsHiddenDirective(_ line: String, isLast: Bool) -> Bool {
        let start = line.drop { $0.isWhitespace }
        guard start.hasPrefix("::"), !start.hasPrefix(":::") else { return false }
        let afterColons = start.dropFirst(2)
        let name = leadingName(afterColons, allowsLeadingDigit: true)
        if isLast, name.count == afterColons.count {
            return streamingHiddenNames.contains { $0.hasPrefix(name) }
        }
        return streamingHiddenNames.contains(name)
    }

    private static func leadingName(_ text: Substring, allowsLeadingDigit: Bool = false) -> String {
        var name = ""
        for character in text {
            let isLetter = character.isASCII && character.isLetter
            let isNameCharacter = isLetter || (character.isASCII && character.isNumber) || character == "-" || character == "_"
            if name.isEmpty, !isLetter, !allowsLeadingDigit { break }
            guard isNameCharacter else { break }
            name.append(character)
        }
        return name
    }

    /// A code fence line: up to three spaces, then three or more backticks or tildes.
    private static func fenceMarker(_ line: String) -> (character: Character, length: Int, rest: Substring)? {
        let indent = line.prefix { $0 == " " }
        guard indent.count <= 3 else { return nil }
        let body = line.dropFirst(indent.count)
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let run = body.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        return (first, run.count, body.dropFirst(run.count))
    }
}

/// The Codex app's readings of heartbeat XML, each matching its JavaScript.
enum CodexAutomationMarkup {
    /// `<name>…</name>`'s content, its first occurrence, without regard to case, trimmed (`Eae`).
    static func firstElement(_ name: String, in text: String) -> String? {
        firstMatch("<\(name)>([\\s\\S]*?)</\(name)>", in: text, group: 1, options: [.caseInsensitive])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The trimmed text without its heartbeat elements and the `xml` fences around them; nil when it
    /// held none (`r2t`).
    static func textOutsideHeartbeats(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unfenced = replacing(#"```(?:xml)?\s*<heartbeat>[\s\S]*?</heartbeat>\s*```"#, in: trimmed)
        let outside = replacing(#"<heartbeat>[\s\S]*?</heartbeat>"#, in: unfenced)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return outside == trimmed ? nil : outside
    }

    /// The last whole heartbeat element of the trimmed text (`o2t`).
    static func lastHeartbeat(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expression = try? NSRegularExpression(pattern: #"<heartbeat>[\s\S]*?</heartbeat>"#,
                                                        options: [.caseInsensitive]) else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let last = expression.matches(in: trimmed, range: range).last,
              let found = Range(last.range, in: trimmed) else { return nil }
        return String(trimmed[found])
    }

    static func decision(in element: String) -> CodexHeartbeatReply.Decision? {
        firstMatch(#"<decision>\s*(NOTIFY|DONT_NOTIFY)\s*</decision>"#, in: element, group: 1, options: [.caseInsensitive])
            .map { $0.uppercased() == "NOTIFY" ? .notify : .dontNotify }
    }

    /// The element's `message`, trimmed and taken out of a CDATA section (`s2t`); empty when missing.
    static func message(in element: String) -> String {
        let message = (firstMatch(#"<message>\s*([\s\S]*?)\s*</message>"#, in: element, group: 1,
                                  options: [.caseInsensitive]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return firstMatch(#"^<!\[CDATA\[([\s\S]*)\]\]>$"#, in: message, group: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? message
    }

    /// In a heartbeat's turn, a message with heartbeat XML but no decision (`i2t`): its words outside
    /// the XML, or else the last element's message; nil when it holds no heartbeat element.
    static func heartbeatFallback(_ text: String) -> String? {
        guard let outside = textOutsideHeartbeats(text) else { return nil }
        if !outside.isEmpty { return outside }
        return lastHeartbeat(in: text).map(message(in:)) ?? ""
    }

    /// A heartbeat reply being written, up to where its XML begins (`a2t`): before `<heartbeat>`, or
    /// before a last `<` that may be its start, and before an `xml` fence opened for it.
    static func beforeStreamingHeartbeat(_ text: String) -> String {
        var cut = text.range(of: "<heartbeat>", options: .caseInsensitive)?.lowerBound
        if cut == nil, let lastOpen = text.lastIndex(of: "<"),
           "<heartbeat>".hasPrefix(text[lastOpen...].lowercased()) {
            cut = lastOpen
        }
        guard let cut else {
            // No XML yet; a fence opened at the very end may be the one around it.
            guard let fence = text.range(of: #"```(?:x(?:m(?:l)?)?)?\s*$"#, options: [.regularExpression, .caseInsensitive])
            else { return text }
            let before = text[..<fence.lowerBound]
            guard before.components(separatedBy: "```").count % 2 == 1 else { return text }
            return before.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return replacing(#"```(?:xml)?\s*$"#, in: String(text[..<cut]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A run of an automation that had nothing to report: `::SKIP_COMPLETION::` (`Xmn`), which the Codex
    /// app shows as "No update from this run" once the turn has written it.
    static func isSkippedCompletion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("::"), trimmed.hasSuffix("::"), trimmed.count > 4 else { return false }
        return trimmed.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines) == "SKIP_COMPLETION"
    }

    // MARK: - Expressions

    static func firstMatch(
        _ pattern: String, in text: String, group: Int, options: NSRegularExpression.Options = []
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }

    private static func replacing(_ pattern: String, in text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
    }
}
