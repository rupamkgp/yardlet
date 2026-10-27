import Foundation

/// A harness activity's file change (`HarnessActivityDiff`) as the Codex file change card lists it
/// (plan M12b, B11), and a shared transcript's latest turn as the review panel's Last turn (D8).
///
/// A provider's diff comes in one of three forms:
/// - hunks with their places in the file (`unified`: Claude Code's applied edit, a Pi patch), read
///   as Codex reads a `FileUpdateChange`, line numbers included;
/// - the text replaced and its replacement (`oldText`, `newText`: Claude Code's Edit call, an ACP
///   file's old and new contents), diffed line by line as an approval card diffs a requested edit
///   (`PermissionRequestPreviewProjection`); those lines have no numbers;
/// - only new contents (`newText`: Claude Code's Write, a new ACP file), every line added.
enum ConversationFileChangeProjection {
    // MARK: - Card rows

    /// The card's row for one activity's change. `workspaceURL` is nil for a shared transcript,
    /// which does not know the task's folder; the card places the row in it (`placed(in:)`).
    static func row(
        for diff: HarnessActivityDiff,
        phase: ConversationItemPhase,
        workspaceURL: URL?
    ) -> CodexFileChangeCardProjection.Row {
        let (status, isTurnFinished): (String, Bool) = switch phase {
        case .running: ("inProgress", false)
        case .stopped: ("inProgress", true)
        case .completed: ("completed", true)
        case .failed: ("failed", true)
        }
        if let change = hunkChange(for: diff),
           let row = CodexFileChangeCardProjection.rows(
               for: CodexFileChangeItem(changes: [change], status: status),
               isTurnFinished: isTurnFinished, workspaceURL: workspaceURL
           ).first {
            return row
        }

        let kind: CodexFileChangeCardProjection.Kind
        let lines: PermissionRequestPreviewProjection.Diff?
        let size = (diff.oldText?.utf8.count ?? 0) + (diff.newText?.utf8.count ?? 0)
        switch (diff.oldText, diff.newText) {
        case let (old?, new?):
            kind = .update
            lines = size > CodexFileChangeCardProjection.fileByteLimit ? nil : PermissionRequestPreviewProjection.diff(
                edits: [PermissionEditPreview(oldText: whole(old), newText: whole(new), replacesAll: false)]
            )
        case let (nil, new?):
            kind = .add
            lines = size > CodexFileChangeCardProjection.fileByteLimit
                ? nil : PermissionRequestPreviewProjection.content(whole(new))
        case let (old?, nil):
            kind = .delete
            lines = size > CodexFileChangeCardProjection.fileByteLimit ? nil : PermissionRequestPreviewProjection.diff(
                edits: [PermissionEditPreview(oldText: whole(old), newText: whole(""), replacesAll: false)]
            )
        case (nil, nil):
            kind = .update
            lines = nil
        }
        let availability: CodexFileChangeCardProjection.PreviewAvailability = if lines != nil {
            .available
        } else if diff.oldText != nil || diff.newText != nil {
            .tooLarge
        } else {
            .missing
        }
        let counts = lines.flatMap { lines in
            lines.additions == 0 && lines.deletions == 0
                ? nil : CodexFileChangeCardProjection.LineCounts(additions: lines.additions, deletions: lines.deletions)
        }
        let displayPath = CodexFileChangeDiff.displayPath(diff.path, workspaceURL: workspaceURL)
        return CodexFileChangeCardProjection.Row(
            id: diff.path,
            change: .object(["path": .string(diff.path), "kind": .object(["type": .string(kindName(kind))])]),
            displayPath: displayPath,
            fileName: URL(filePath: displayPath).lastPathComponent,
            kind: kind,
            state: CodexFileChangeCardProjection.state(for: status, isTurnFinished: isTurnFinished),
            lineCounts: counts,
            preview: availability,
            fileURL: workspaceURL.flatMap { CodexFileChangeCardProjection.openableURL(for: diff.path, workspaceURL: $0) },
            precomputedPreview: lines.map { lines in
                CodexFileChangeCardProjection.Preview(
                    lines: lines.lines, hiddenLineCount: lines.hiddenLineCount, firstChangedLine: nil
                )
            }
        )
    }

    // MARK: - Last turn

    /// Whether the transcript holds a file change a call reported, which is when the review panel
    /// offers Last turn for a harness other than Codex (D8).
    static func carriesFileChanges(_ entries: [TranscriptEntry]) -> Bool {
        entries.contains { entry in
            if case let .activity(activity, _) = entry.content { return activity.diff != nil }
            return false
        }
    }

    /// The latest turn's applied file changes as one unified diff, in the order they were made, or
    /// nil before the first request. The latest turn starts at the latest message the person sent
    /// (a Claude bash command runs no turn of the model's). A Claude Code edit counts once its
    /// result names the hunks it applied, or when it wrote a whole file; the text an Edit call
    /// replaced alone does not say where in the file it was.
    static func lastTurnDiff(
        entries: [TranscriptEntry],
        harness: HarnessKind,
        isRunning: Bool,
        workspaceURL: URL
    ) -> CodexLastTurnDiff? {
        // The turn starts at the request that opened it: a message read into the running turn
        // belongs to that turn (D13), as a Codex turn keeps a steered message.
        guard let start = entries.lastIndex(where: { entry in
            guard case let .user(text, _) = entry.content, entry.joinsRunningTurn != true else { return false }
            return harness != .claudeCode || ClaudeBashMessage.parse(text) == nil
        }) else { return nil }
        let text = entries[start...].compactMap { entry -> String? in
            guard case let .activity(activity, .completed) = entry.content, activity.subtask == nil,
                  let diff = activity.diff else { return nil }
            if harness == .claudeCode, hunkChange(for: diff) == nil, diff.oldText != nil { return nil }
            return unifiedDiff(for: diff, workspaceURL: workspaceURL)
        }.joined()
        return CodexLastTurnDiff(turnID: entries[start].id.uuidString, text: text, isRunning: isRunning)
    }

    /// One change as a git-style unified diff, with `diff --git` headers, for the review panel.
    /// Old and new contents without hunks are diffed into hunks numbered from the top of the file.
    static func unifiedDiff(for diff: HarnessActivityDiff, workspaceURL: URL?) -> String? {
        let change: JSONValue
        if let hunks = hunkChange(for: diff) {
            change = hunks
        } else {
            switch (diff.oldText, diff.newText) {
            case let (old?, new?):
                let body = hunks(old: lines(old), new: lines(new))
                guard !body.isEmpty else { return nil }
                change = .object(["path": .string(diff.path), "kind": .object(["type": .string("update")]),
                                  "diff": .string(body.joined(separator: "\n") + "\n")])
            case let (nil, new?):
                change = .object(["path": .string(diff.path), "kind": .object(["type": .string("add")]),
                                  "diff": .string(new)])
            case let (old?, nil):
                change = .object(["path": .string(diff.path), "kind": .object(["type": .string("delete")]),
                                  "diff": .string(old)])
            case (nil, nil):
                return nil
            }
        }
        return CodexFileChangeDiff.unifiedDiff(for: change, workspaceURL: workspaceURL)
    }

    /// Hunks numbered from the first line, with three unchanged lines around each change, as
    /// `diff -u` writes them.
    static func hunks(old: [String], new: [String], context: Int = 3) -> [String] {
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in new.difference(from: old) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        // Each line with the old and new lines read before it.
        var script: [(marker: Character, old: Int, new: Int, text: String)] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, removed.contains(oldIndex) {
                script.append(("-", oldIndex, newIndex, old[oldIndex]))
                oldIndex += 1
            } else if newIndex < new.count, inserted.contains(newIndex) {
                script.append(("+", oldIndex, newIndex, new[newIndex]))
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                script.append((" ", oldIndex, newIndex, new[newIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                break
            }
        }
        var ranges: [ClosedRange<Int>] = []
        for index in script.indices where script[index].marker != " " {
            let range = max(0, index - context)...min(script.count - 1, index + context)
            if let last = ranges.last, range.lowerBound <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        var result: [String] = []
        for range in ranges {
            let slice = script[range]
            guard let first = slice.first else { continue }
            let oldCount = slice.count(where: { $0.marker != "+" })
            let newCount = slice.count(where: { $0.marker != "-" })
            let oldStart = oldCount == 0 ? first.old : first.old + 1
            let newStart = newCount == 0 ? first.new : first.new + 1
            result.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            result += slice.map { "\($0.marker)\($0.text)" }
        }
        return result
    }

    // MARK: - Parts

    /// A diff that carries hunks, as the change Codex reads: its body from the first hunk on.
    private static func hunkChange(for diff: HarnessActivityDiff) -> JSONValue? {
        guard let unified = diff.unified, !unified.isEmpty else { return nil }
        let body: Substring
        if unified.hasPrefix("@@ ") {
            body = unified[...]
        } else if let range = unified.range(of: "\n@@ ") {
            body = unified[unified.index(after: range.lowerBound)...]
        } else {
            return nil
        }
        return .object(["path": .string(diff.path), "kind": .object(["type": .string("update")]),
                        "diff": .string(String(body))])
    }

    private static func whole(_ text: String) -> PermissionPreviewText {
        PermissionPreviewText(text: text, omittedLineCount: 0)
    }

    private static func kindName(_ kind: CodexFileChangeCardProjection.Kind) -> String {
        switch kind {
        case .add: "add"
        case .delete: "delete"
        case .update: "update"
        }
    }

    /// Lines as an editor numbers them: a final newline ends the last line.
    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

extension CodexFileChangeCardProjection.Row {
    /// The row read against the task's folder: its path shown relative to the folder when it lies
    /// inside, and the file it opens. A shared transcript projects its rows without the folder.
    func placed(in workspaceURL: URL?) -> Self {
        let target = change["kind"]?["move_path"]?.stringValue ?? id
        let displayPath = CodexFileChangeDiff.displayPath(target, workspaceURL: workspaceURL)
        return Self(
            id: id, change: change, displayPath: displayPath, fileName: URL(filePath: displayPath).lastPathComponent,
            kind: kind, state: state, lineCounts: lineCounts, preview: preview,
            fileURL: workspaceURL.flatMap { CodexFileChangeCardProjection.openableURL(for: target, workspaceURL: $0) },
            precomputedPreview: precomputedPreview
        )
    }
}
