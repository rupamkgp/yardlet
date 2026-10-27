import Foundation

/// How a long sent message is clipped, as the Codex app clips one (`collapsible-user-message-content`
/// in its bundle): a message whose text runs taller than `lineCount` lines shows its first lines,
/// an ellipsis line, and "Show more" inside the bubble; "Show less" folds it again. A message the
/// person sent clips at 20 lines, one a scheduled task sent at 2 (`zv` in `sites-end-resource`).
/// Every harness's sent messages clip the same way.
struct ConversationMessageClip: Equatable, Sendable {
    /// The lines a message may run to before it clips (the app's `collapsedLineCount`).
    let lineCount: Int

    /// A message the person sent.
    static let sentMessage = Self(lineCount: 20)
    /// A message a scheduled task sent in the person's place.
    static let scheduledTaskMessage = Self(lineCount: 2)

    /// The characters a clipped message lays out per line it may show, so a long message is not laid
    /// out whole while it is folded: more than one line holds at any bubble width.
    static let charactersPerLine = 400

    /// A clipped message ends on a line of its own reading "…" when it clips at more than two lines,
    /// and shows one line fewer of its text to make room for it.
    var showsEllipsisLine: Bool { lineCount > 2 }

    /// The lines of text a clipped message shows.
    var visibleLineCount: Int { showsEllipsisLine ? lineCount - 1 : lineCount }

    /// The start of `text` a folded message lays out: its first `lineCount` lines, at most
    /// `lineCount × charactersPerLine` characters of them. `isWhole` when the rest is only spaces.
    func prefix(of text: String) -> (text: String, isWhole: Bool) {
        let limit = lineCount * Self.charactersPerLine
        var lines = 1
        var count = 0
        var end = text.startIndex
        for index in text.indices {
            if count == limit { break }
            if text[index].isNewline {
                if lines == lineCount { break }
                lines += 1
            }
            count += 1
            end = text.index(after: index)
        }
        let isWhole = text[end...].allSatisfy(\.isWhitespace)
        return (isWhole ? text : String(text[..<end]), isWhole)
    }

    /// Whether a message clips: there is text past its prefix, or its prefix laid out runs taller than
    /// the same text limited to `lineCount` lines by more than a point (the app's rule).
    ///
    /// - Parameters:
    ///   - height: the prefix's height laid out whole.
    ///   - heightAtLineCount: its height limited to `lineCount` lines; zero before it is measured.
    func clips(isWhole: Bool, height: CGFloat, heightAtLineCount: CGFloat) -> Bool {
        !isWhole || (heightAtLineCount > 0 && height > heightAtLineCount + 1)
    }
}
