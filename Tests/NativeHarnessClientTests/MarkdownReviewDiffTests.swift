import XCTest
@testable import NativeHarnessClient

/// The review's rendered view of a Markdown change (`MarkdownReviewDiff`): the file
/// before the change is the file the diff left with the diff undone, never a guess, and the change is
/// read block by block.
final class MarkdownReviewDiffTests: XCTestCase {
    private static let before = """
    # Plan

    Intro paragraph.

    - first item
    - second item
    - third item

    | Name | State |
    | --- | --- |
    | Review | open |

    Closing words.
    """

    private static let after = """
    # Plan

    Intro paragraph, revised.

    - first item
    - second item, changed
    - third item

    | Name | State |
    | --- | --- |
    | Review | open |

    Closing words.

    ## Added section

    New text.
    """

    /// A diff of `old` to `new` as the review parses one: git's headers, hunks with three lines around.
    private static func sections(_ old: String, _ new: String, path: String = "docs/plan.md") -> [DiffFile] {
        func lines(_ text: String) -> [String] {
            var lines = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") || text.isEmpty { lines.removeLast() }
            return lines
        }
        let hunks = ConversationFileChangeProjection.hunks(old: lines(old), new: lines(new))
        let text = (["diff --git a/\(path) b/\(path)", "--- a/\(path)", "+++ b/\(path)"] + hunks).joined(separator: "\n")
        return UnifiedDiffParser().parse(text + "\n").files
    }

    func testTheFileBeforeTheChangeIsTheFileTheDiffLeftWithTheDiffUndone() throws {
        let after = Self.after + "\n"
        XCTAssertEqual(MarkdownReviewDiff.oldText(new: after, sections: Self.sections(Self.before + "\n", after)),
                       Self.before + "\n")

        // A turn that changed the file twice lists it twice; both are undone, the later first.
        let middle = Self.before.replacingOccurrences(of: "Intro paragraph.", with: "Intro paragraph, revised.") + "\n"
        let twice = Self.sections(Self.before + "\n", middle) + Self.sections(middle, after)
        XCTAssertEqual(twice.count, 2)
        XCTAssertEqual(MarkdownReviewDiff.oldText(new: after, sections: twice), Self.before + "\n")

        // A new file was nothing before; a deleted file leaves nothing.
        XCTAssertEqual(MarkdownReviewDiff.oldText(new: after, sections: Self.sections("", after)), "")
        XCTAssertEqual(MarkdownReviewDiff.oldText(new: "", sections: Self.sections(Self.before + "\n", "")),
                       Self.before + "\n")

        // A file changed since the diff was read is not what the diff left: nothing is drawn as its past.
        let since = after.replacingOccurrences(of: "New text.", with: "Newer text.")
        XCTAssertNil(MarkdownReviewDiff.oldText(new: since, sections: Self.sections(Self.before + "\n", after)))
        guard case .unavailable = MarkdownReviewDiff.outcome(new: since, sections: Self.sections(Self.before + "\n", after),
                                                             afterTurn: true) else {
            return XCTFail("a changed file shows the line diff with its reason")
        }
    }

    func testTheChangeIsReadBlockByBlockWithListItemsOnTheirOwn() throws {
        let rows = MarkdownReviewDiff.rows(old: Self.before, new: Self.after)
        let drawn = rows.flatMap { row -> [MarkdownReviewDiff.Block] in
            if case let .block(block) = row { return [block] }
            return []
        }
        let changed = drawn.filter { $0.change != .unchanged }.map { "\($0.change) \($0.source)" }
        XCTAssertEqual(changed, [
            "removed Intro paragraph.", "added Intro paragraph, revised.",
            "removed - second item", "added - second item, changed",
            "added ## Added section", "added New text."
        ], "a changed list item is its own block; the list around it is not redrawn")

        // One unchanged block on each side of a change; the table between two changes is folded.
        let folded = rows.compactMap { row -> [String]? in
            if case let .unchanged(_, blocks) = row { return blocks.map(\.source) }
            return nil
        }
        XCTAssertEqual(folded, [["| Name | State |\n| --- | --- |\n| Review | open |"]])
        XCTAssertEqual(drawn.first?.source, "# Plan")

        // An item of a numbered list drawn alone keeps its number, written as "1." or not.
        XCTAssertEqual(MarkdownReviewDiff.blocks("1. one\n1. two\n1. three"), ["1. one", "2. two", "3. three"])
        XCTAssertEqual(MarkdownReviewDiff.blocks("4) four\n5) five"), ["4) four", "5) five"])

        // A change only in white space at lines' ends draws no changed block.
        let unchanged = MarkdownReviewDiff.rows(old: "# Plan\n\nWords.", new: "# Plan  \n\nWords.")
        XCTAssertFalse(unchanged.contains { if case .block = $0 { true } else { false } })
    }

    func testOnlyMarkdownFilesAreOffered() {
        for path in ["README.md", "docs/plan.MARKDOWN", "a.mdx", "notes.mkd", "x.mdown"] {
            XCTAssertTrue(MarkdownReviewDiff.isMarkdown(path), path)
        }
        for path in ["Package.swift", "notes.txt", "md", "a.md.orig"] {
            XCTAssertFalse(MarkdownReviewDiff.isMarkdown(path), path)
        }
    }
}
