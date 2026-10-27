import XCTest
@testable import NativeHarnessClient

final class UnifiedDiffParserTests: XCTestCase {
    func testEmptyDiffIsCleanAndTrailingNewlineIsNotAContextLine() {
        XCTAssertTrue(UnifiedDiffParser().parse("").isEmpty)
        let result = UnifiedDiffParser().parse("diff --git a/a b/a\n@@ -8 +20 @@\n-x\n+y\n")
        XCTAssertEqual(result.lines.count, 4)
        XCTAssertEqual(result.lines[2].oldLine, 8)
        XCTAssertNil(result.lines[2].newLine)
        XCTAssertEqual(result.lines[3].newLine, 20)
        XCTAssertNil(result.lines[3].oldLine)
    }

    func testHunksCountBothSidesAndContentPrefixesAreNotFileHeaders() {
        let result = UnifiedDiffParser().parse("""
        diff --git a/a b/a
        --- a/a
        +++ b/a
        @@ -10,3 +30,3 @@
         same
        --- old text
        +++ new text
        \\ No newline at end of file
         same again
        @@ -90 +105 @@
        -last
        +replacement
        """)
        XCTAssertEqual(result.files.first?.path, "a")
        XCTAssertEqual(result.lines[4].oldLine, 10)
        XCTAssertEqual(result.lines[4].newLine, 30)
        XCTAssertEqual(result.lines[5].kind, .deletion)
        XCTAssertEqual(result.lines[6].kind, .addition)
        XCTAssertNil(result.lines[7].oldLine)
        XCTAssertEqual(result.lines[8].oldLine, 12)
        XCTAssertEqual(result.lines[8].newLine, 32)
        XCTAssertEqual(result.lines[10].oldLine, 90)
        XCTAssertEqual(result.lines[11].newLine, 105)
    }

    func testAddedDeletedRenamedBinaryAndQuotedPaths() throws {
        let result = UnifiedDiffParser().parse("""
        diff --git a/new file.txt b/new file.txt
        new file mode 100644
        --- /dev/null
        +++ b/new file.txt
        @@ -0,0 +1 @@
        +new
        diff --git a/gone b/gone
        deleted file mode 100644
        --- a/gone
        +++ /dev/null
        @@ -1 +0,0 @@
        -old
        diff --git a/old b/new
        similarity index 100%
        rename from old
        rename to new
        diff --git "a/line\\nname" "b/line\\nname"
        Binary files "a/line\\nname" and "b/line\\nname" differ
        """, isTruncated: true)
        XCTAssertEqual(result.files.count, 4)
        XCTAssertEqual(result.files[0].path, "new file.txt")
        XCTAssertNil(result.files[0].oldPath)
        XCTAssertNil(result.files[1].newPath)
        XCTAssertEqual(result.files[2].oldPath, "old")
        XCTAssertEqual(result.files[2].newPath, "new")
        XCTAssertEqual(result.files[3].path, "line\nname")
        XCTAssertTrue(result.files[3].isBinary)
        XCTAssertTrue(result.isTruncated)
    }

    func testMalformedHunkDoesNotInventLineNumbers() {
        let result = UnifiedDiffParser().parse("diff --git a/a b/a\n@@ - + @@\n+text")
        XCTAssertNil(result.lines.last?.newLine)
    }

    func testClassifiesUnifiedDiffLines() {
        let snapshot = UnifiedDiffParser().parse(
            """
            diff --git a/file.swift b/file.swift
            --- a/file.swift
            +++ b/file.swift
            @@ -1,2 +1,2 @@
            -old
            +new
             context
            """
        )

        XCTAssertEqual(snapshot.lines.map(\.kind), [
            .fileHeader,
            .fileHeader,
            .fileHeader,
            .hunkHeader,
            .deletion,
            .addition,
            .context
        ])
        XCTAssertEqual(snapshot.fileCount, 1)
        XCTAssertEqual(snapshot.additionCount, 1)
        XCTAssertEqual(snapshot.deletionCount, 1)
    }
}
