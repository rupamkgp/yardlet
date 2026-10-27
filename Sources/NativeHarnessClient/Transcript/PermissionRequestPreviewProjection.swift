import Foundation

/// A requested change in the lines the file change card draws for an applied one. The tool sends
/// the text it replaces rather than where that text sits in the file, so the lines carry no
/// numbers, and unchanged lines away from a change fold into a rule as between hunks.
enum PermissionRequestPreviewProjection {
    typealias Line = CodexFileChangeCardProjection.Preview.Line

    /// Unchanged lines kept on each side of a change.
    static let contextRadius = 3
    /// Lines one preview draws; the rest are counted.
    static let lineLimit = 400

    struct Diff: Equatable {
        let lines: [Line]
        let additions: Int
        let deletions: Int
        /// Lines not drawn: past `lineLimit`, or past the bound the request was built with.
        let hiddenLineCount: Int
        let omittedEditCount: Int
    }

    /// Each edit's removed and added lines with nearby unchanged ones. When the request holds
    /// several edits, or replaces every occurrence, a caption row says so above the edit.
    static func diff(edits: [PermissionEditPreview], omittedEditCount: Int = 0) -> Diff {
        var rows: [(kind: Line.Kind, text: String)] = []
        var omitted = 0
        let total = edits.count + omittedEditCount
        for (index, edit) in edits.enumerated() {
            var caption: [String] = []
            if total > 1 { caption.append(L10n.format("Edit %lld of %lld", Int64(index + 1), Int64(total))) }
            if edit.replacesAll { caption.append(L10n.string("Replaces every occurrence")) }
            if !caption.isEmpty { rows.append((.separator, caption.joined(separator: " · "))) }
            rows += changedLines(from: lines(edit.oldText.text), to: lines(edit.newText.text))
            omitted += edit.oldText.omittedLineCount + edit.newText.omittedLineCount
        }
        return diff(rows, omitted: omitted, omittedEditCount: omittedEditCount)
    }

    /// A file's new contents, every line added.
    static func content(_ text: PermissionPreviewText) -> Diff {
        diff(lines(text.text).map { (.addition, $0) }, omitted: text.omittedLineCount, omittedEditCount: 0)
    }

    private static func diff(
        _ rows: [(kind: Line.Kind, text: String)], omitted: Int, omittedEditCount: Int
    ) -> Diff {
        let limit = CodexFileChangeCardProjection.lineCharacterLimit
        return Diff(
            lines: rows.prefix(lineLimit).enumerated().map { index, row in
                Line(
                    id: index,
                    kind: row.kind,
                    number: nil,
                    text: row.text.count > limit ? String(row.text.prefix(limit)) + "…" : row.text
                )
            },
            additions: rows.count(where: { $0.kind == .addition }),
            deletions: rows.count(where: { $0.kind == .deletion }),
            hiddenLineCount: max(0, rows.count - lineLimit) + omitted,
            omittedEditCount: omittedEditCount
        )
    }

    /// Old lines a change removes come before the new lines it adds, as in a unified diff.
    static func changedLines(from old: [String], to new: [String]) -> [(kind: Line.Kind, text: String)] {
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in new.difference(from: old) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        var rows: [(kind: Line.Kind, text: String)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                rows.append((.deletion, old[oldIndex]))
                oldIndex += 1
            } else if newIndex < new.count, inserted.contains(newIndex) {
                rows.append((.addition, new[newIndex]))
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                rows.append((.context, new[newIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }

        let changes = rows.indices.filter { rows[$0].kind != .context }
        var kept = Array(repeating: false, count: rows.count)
        for index in changes {
            for near in max(0, index - contextRadius)...min(rows.count - 1, index + contextRadius) {
                kept[near] = true
            }
        }
        var trimmed: [(kind: Line.Kind, text: String)] = []
        var skipped = false
        for (index, row) in rows.enumerated() {
            guard kept[index] else {
                skipped = true
                continue
            }
            if skipped, !trimmed.isEmpty { trimmed.append((.separator, "")) }
            skipped = false
            trimmed.append(row)
        }
        return trimmed
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
