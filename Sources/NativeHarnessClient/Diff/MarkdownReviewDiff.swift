import Foundation
import Markdown

/// A Markdown file's change read as the document reads: the review's rendered view. The Codex app's
/// diff offers "Rich preview" (`codex.review.richPreview.label`), which draws
/// the changed Markdown file as it now reads in place of its diff; this draws both sides of the change
/// in one column, the way a rendered diff reads: the document's blocks in order, a block the change
/// took out drawn where it was and marked removed, a block it put in marked added, and long runs of
/// unchanged blocks left out but for one on each side of a change.
///
/// The text before the change is made from the file the diff left and the diff itself (`oldText`), so
/// every scope reads it the same way, Last turn included, and a file that no longer matches the diff
/// says so rather than drawing a guess.
enum MarkdownReviewDiff {
    /// The file names the Codex app previews as Markdown (`aOr`).
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mdx", "mkd"]

    static func isMarkdown(_ path: String) -> Bool {
        extensions.contains(URL(filePath: path).pathExtension.lowercased())
    }

    // MARK: - The file before the change

    /// `new` with the changes of `sections` undone, last first: the file before them. `sections` are
    /// one file's parts of a diff in the order they were made (a Last turn lists a file once for each
    /// time the turn changed it). Nil when `new` is not what the hunks left: the file changed since
    /// the diff was read, or the diff is not whole.
    static func oldText(new: String, sections: [DiffFile]) -> String? {
        var lines = Lines(new)
        for section in sections.reversed() {
            for hunk in hunks(of: section).reversed() {
                // A hunk that adds nothing names the line after which its lines were taken out.
                let start = hunk.newSide.isEmpty ? hunk.newStart : hunk.newStart - 1
                guard start >= 0, start + hunk.newSide.count <= lines.items.count,
                      Array(lines.items[start..<(start + hunk.newSide.count)]) == hunk.newSide else { return nil }
                lines.items.replaceSubrange(start..<(start + hunk.newSide.count), with: hunk.oldSide)
            }
        }
        return lines.text
    }

    private struct Hunk {
        let newStart: Int
        var oldSide: [String] = []
        var newSide: [String] = []
    }

    private static func hunks(of section: DiffFile) -> [Hunk] {
        var hunks: [Hunk] = []
        for line in section.lines {
            if line.kind != .hunkHeader, hunks.isEmpty { continue }
            switch line.kind {
            case .hunkHeader:
                guard let start = UnifiedDiffParser.hunkStart(line.text).1 else { continue }
                hunks.append(Hunk(newStart: start))
            case .context:
                hunks[hunks.count - 1].oldSide.append(String(line.text.dropFirst()))
                hunks[hunks.count - 1].newSide.append(String(line.text.dropFirst()))
            case .deletion:
                hunks[hunks.count - 1].oldSide.append(String(line.text.dropFirst()))
            case .addition:
                hunks[hunks.count - 1].newSide.append(String(line.text.dropFirst()))
            case .fileHeader, .metadata:
                continue
            }
        }
        return hunks
    }

    /// A text as the diff counts it: lines without their line feed, and whether the last one had one.
    private struct Lines {
        var items: [String]
        let endsWithNewline: Bool

        init(_ text: String) {
            var items = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") || text.isEmpty { items.removeLast() }
            self.items = items
            // A file the change took out had its lines end as text files' do.
            endsWithNewline = text.hasSuffix("\n") || text.isEmpty
        }

        var text: String {
            items.isEmpty ? "" : items.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        }
    }

    // MARK: - What the view shows

    /// What the rendered view shows for one file: its rows, or why the line diff stays instead.
    enum Outcome: Equatable, Sendable {
        case rows([Row])
        case unavailable(String)
    }

    /// The change `sections` made, read against `new`, the file they left: nil when it could not be
    /// read (too large, not text). `afterTurn` says the diff is a turn's, which a refresh does not
    /// read again.
    static func outcome(new: String?, sections: [DiffFile], afterTurn: Bool) -> Outcome {
        guard let new else { return .unavailable(L10n.string("This change can’t be shown rendered.")) }
        guard let old = oldText(new: new, sections: sections) else {
            return .unavailable(L10n.string(afterTurn
                ? "The file changed after this turn, so its change can’t be shown rendered."
                : "The file changed after this diff was read. Refresh to see it rendered."))
        }
        return .rows(rows(old: old, new: new))
    }

    // MARK: - Blocks

    enum Change: Equatable, Sendable {
        case unchanged, added, removed
    }

    /// One block of the document as its own Markdown, which the conversation's renderer draws.
    struct Block: Identifiable, Equatable, Sendable {
        let id: Int
        let source: String
        let change: Change
    }

    enum Row: Identifiable, Equatable, Sendable {
        case block(Block)
        /// Unchanged blocks left out between changes, which the view draws when asked.
        case unchanged(id: Int, blocks: [Block])

        var id: Int {
            switch self {
            case let .block(block): block.id
            case let .unchanged(id, _): id
            }
        }
    }

    /// The change from `old` to `new`, block by block: what a change took out before what it put in,
    /// and runs of unchanged blocks longer than `context` on each side of a change folded into one row.
    /// A document whose blocks did not change (a change in white space or a link definition) is one
    /// folded row.
    static func rows(old: String, new: String, context: Int = 1) -> [Row] {
        let before = blocks(old)
        let after = blocks(new)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in after.map(comparable).difference(from: before.map(comparable)) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var merged: [(source: String, change: Change)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < before.count || newIndex < after.count {
            if oldIndex < before.count, removed.contains(oldIndex) {
                merged.append((before[oldIndex], .removed))
                oldIndex += 1
            } else if newIndex < after.count, inserted.contains(newIndex) {
                merged.append((after[newIndex], .added))
                newIndex += 1
            } else if newIndex < after.count {
                merged.append((after[newIndex], .unchanged))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        let shown = Set(merged.indices.filter { merged[$0].change != .unchanged }.flatMap { index in
            max(0, index - context)...min(merged.count - 1, index + context)
        })
        var rows: [Row] = []
        var folded: [Block] = []
        for (index, block) in merged.enumerated() {
            let item = Block(id: index, source: block.source, change: block.change)
            if shown.contains(index) {
                if !folded.isEmpty { rows.append(.unchanged(id: folded[0].id, blocks: folded)) }
                folded = []
                rows.append(.block(item))
            } else {
                folded.append(item)
            }
        }
        if !folded.isEmpty { rows.append(.unchanged(id: folded[0].id, blocks: folded)) }
        return rows
    }

    /// The document's blocks as their own Markdown, in order: each block at the top of the document,
    /// and each item of a list there, so a changed item does not redraw its whole list. An item of a
    /// numbered list keeps its number.
    static func blocks(_ source: String) -> [String] {
        let document = Document(parsing: source, options: [.disableSmartOpts])
        // CommonMark counts lines at CR, LF and CRLF, as `TranscriptMarkdownDocument` reads them.
        let lines = source.split(omittingEmptySubsequences: false) { $0 == "\r" || $0 == "\n" || $0 == "\r\n" }
        func text(_ range: SourceRange?) -> String? {
            guard let range else { return nil }
            let first = max(0, range.lowerBound.line - 1)
            let last = min(lines.count - 1, range.upperBound.line - 1)
            guard first <= last else { return nil }
            return lines[first...last].joined(separator: "\n")
        }
        var blocks: [String] = []
        for child in document.children {
            if let list = child as? OrderedList {
                for (offset, item) in list.listItems.enumerated() {
                    guard let source = text(item.range) else { continue }
                    blocks.append(renumbered(source, to: Int(list.startIndex) + offset))
                }
            } else if let list = child as? UnorderedList {
                blocks += list.listItems.compactMap { text($0.range) }
            } else if let source = text(child.range) {
                blocks.append(source)
            }
        }
        return blocks
    }

    /// An item of a numbered list drawn alone starts its list, which reads its number from the item.
    private static func renumbered(_ item: String, to number: Int) -> String {
        guard let digits = item.firstRange(of: /^ {0,3}\d{1,9}(?=[.)])/) else { return item }
        let indent = item[digits].prefix { $0 == " " }
        return String(indent) + String(number) + String(item[digits.upperBound...])
    }

    /// Two blocks are the same when they differ only in white space at their lines' ends.
    private static func comparable(_ block: String) -> String {
        block.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacing(/[ \t\r]+$/, with: "") }
            .joined(separator: "\n")
    }
}
