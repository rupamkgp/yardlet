import Foundation

/// The output a running command card holds while `item/commandExecution/outputDelta` streams.
/// A long-running command keeps its first output and its latest output, so the card never
/// stops at the beginning of a long log; `item/completed` replaces the whole value with the
/// provider's aggregated output.
enum CodexLiveCommandOutput {
    /// UTF-8 bytes kept from the start of the output once it outgrows the buffer.
    static let headLimit = 8 * 1_024
    /// UTF-8 bytes kept from the end of the output once it outgrows the buffer.
    static let tailLimit = 56 * 1_024
    static var limit: Int { headLimit + tailLimit }
    /// The Codex app marks output it dropped with the same words.
    static let truncationLine = "[output truncated]\n"

    static func append(_ delta: String, to command: inout CodexCommandItem) {
        let output = command.aggregatedOutput ?? ""
        let utf8 = output.utf8
        if let headBytes = command.liveOutputHeadByteCount,
           let headEnd = utf8.index(utf8.startIndex, offsetBy: headBytes, limitedBy: utf8.endIndex),
           let tailStart = utf8.index(
               headEnd, offsetBy: truncationLine.utf8.count, limitedBy: utf8.endIndex
           ) {
            let tail = String(output[tailStart...]) + delta
            command.aggregatedOutput = String(output[..<headEnd]) + truncationLine + keptTail(of: tail)
            return
        }
        let combined = output + delta
        guard combined.utf8.count > limit else {
            command.aggregatedOutput = combined
            command.liveOutputHeadByteCount = nil
            return
        }
        let headEnd = headEnd(of: combined)
        var head = String(combined[..<headEnd])
        if head.last?.isNewline == false { head += "\n" }
        command.aggregatedOutput = head + truncationLine + keptTail(of: String(combined[headEnd...]))
        command.liveOutputHeadByteCount = head.utf8.count
    }

    /// At most `headLimit` bytes, ending after the last line break in them when there is one.
    private static func headEnd(of text: String) -> String.Index {
        let utf8 = text.utf8
        let limit = utf8.index(utf8.startIndex, offsetBy: headLimit, limitedBy: utf8.endIndex) ?? utf8.endIndex
        let end = characterBoundary(atOrBefore: limit, in: text)
        if let newline = text[..<end].lastIndex(where: \.isNewline) {
            return text.index(after: newline)
        }
        return end
    }

    /// At most `tailLimit` bytes from the end, starting on the next line when a line break is
    /// close to the cut.
    private static func keptTail(of text: String) -> String {
        let utf8 = text.utf8
        guard utf8.count > tailLimit else { return text }
        var start = utf8.index(utf8.endIndex, offsetBy: -tailLimit)
        if start.samePosition(in: text) == nil {
            start = text.index(after: characterBoundary(atOrBefore: start, in: text))
        }
        let nearby = characterBoundary(
            atOrBefore: utf8.index(start, offsetBy: tailLimit / 8, limitedBy: utf8.endIndex) ?? utf8.endIndex,
            in: text
        )
        if start < nearby, let newline = text[start..<nearby].firstIndex(where: \.isNewline) {
            start = text.index(after: newline)
        }
        return String(text[start...])
    }

    private static func characterBoundary(atOrBefore index: String.Index, in text: String) -> String.Index {
        var index = index
        while index > text.startIndex, index.samePosition(in: text) == nil {
            index = text.utf8.index(before: index)
        }
        return index
    }
}
