import Foundation

// Where a diff comment sits in a parsed diff, as the Codex app's diff places its local comments
// (`use-diff-annotations`, `code-diff`): an added or unchanged line is the new file's (right side), a
// deleted line the old file's (left side), and a comment shows under the last line of its range.

extension DiffLine {
    /// The side and line a comment on this line takes, or nil for a line that is not code.
    var commentAnchor: DiffComment.Anchor? {
        switch kind {
        case .addition, .context: newLine.map { DiffComment.Anchor(side: .right, line: $0) }
        case .deletion: oldLine.map { DiffComment.Anchor(side: .left, line: $0) }
        case .fileHeader, .hunkHeader, .metadata: nil
        }
    }
}

extension DiffFile {
    /// The range the lines `first` and `last` (line IDs, either order) make, or nil when either is not code.
    func commentRange(from first: Int, to last: Int) -> (start: DiffComment.Anchor, end: DiffComment.Anchor)? {
        guard let firstIndex = lines.firstIndex(where: { $0.id == first }),
              let lastIndex = lines.firstIndex(where: { $0.id == last }),
              let firstAnchor = lines[firstIndex].commentAnchor,
              let lastAnchor = lines[lastIndex].commentAnchor else { return nil }
        return firstIndex <= lastIndex
            ? DiffComment.range(from: firstAnchor, to: lastAnchor)
            : DiffComment.range(from: lastAnchor, to: firstAnchor)
    }

    /// A comment on the lines from `first` to `last` (line IDs, either order), quoting their hunks.
    func comment(from first: Int, to last: Int, workspaceRoot: String?, body: String) -> DiffComment? {
        guard let range = commentRange(from: first, to: last) else { return nil }
        return DiffComment(path: path, workspaceRoot: workspaceRoot, start: range.start, end: range.end,
                           diffHunk: hunkExcerpt(from: first, to: last), body: body)
    }

    /// The hunks from the one holding `first` to the one holding `last`, each its `@@` line and its
    /// lines, as the Codex app quotes a comment's place (`un`, `fn` in `code-diff`). A line the diff
    /// adds about the file (`\ No newline at end of file`) is not quoted.
    func hunkExcerpt(from first: Int, to last: Int) -> String? {
        guard let firstIndex = lines.firstIndex(where: { $0.id == first }),
              let lastIndex = lines.firstIndex(where: { $0.id == last }) else { return nil }
        let low = min(firstIndex, lastIndex), high = max(firstIndex, lastIndex)
        let headers = lines.indices.filter { lines[$0].kind == .hunkHeader }
        guard let start = headers.last(where: { $0 <= low }) else { return nil }
        let end = headers.first(where: { $0 > high }) ?? lines.endIndex
        let quoted = lines[start..<end].compactMap { line -> String? in
            switch line.kind {
            case .hunkHeader, .addition, .deletion, .context:
                line.text.hasSuffix("\r") ? String(line.text.dropLast()) : line.text
            case .fileHeader, .metadata:
                nil
            }
        }
        return quoted.joined(separator: "\n")
    }

    /// The line a comment shows under: the one its range ends on, when this diff shows it.
    func lineID(showing comment: DiffComment) -> Int? {
        guard comment.path == path else { return nil }
        return lines.first { $0.commentAnchor == comment.end }?.id
    }
}
