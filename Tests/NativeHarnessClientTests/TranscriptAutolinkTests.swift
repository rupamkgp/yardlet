import XCTest
@testable import NativeHarnessClient

/// GFM's extended autolinks, as the Codex app reads them (`gfmAutolinkLiteral`): a bare address in a
/// message is a link, its trailing punctuation is not, and code and existing links stay as they are.
final class TranscriptAutolinkTests: XCTestCase {
    private func links(_ markdown: String) -> [(text: String, url: String)] {
        let content = TranscriptInlineContent(stringLiteral: markdown)
        return content.attributed.runs.compactMap { run in
            run.link.map { (String(content.attributed[run.range].characters), $0.absoluteString) }
        }
    }

    func testABareAddressOnItsOwnLineAndInASentenceIsALink() {
        XCTAssertEqual(links("https://claude.ai/artifact/UxpAUa6dQghc2QHX29KqZR").map(\.url),
                       ["https://claude.ai/artifact/UxpAUa6dQghc2QHX29KqZR"])
        let sentence = links("시안은 https://claude.ai/artifact/abc 에 있습니다.")
        XCTAssertEqual(sentence.map(\.text), ["https://claude.ai/artifact/abc"])
    }

    func testTrailingPunctuationAndAnUnmatchedParenthesisStayOutside() {
        XCTAssertEqual(links("See https://example.com/a.").map(\.text), ["https://example.com/a"])
        XCTAssertEqual(links("(see https://example.com/a)").map(\.text), ["https://example.com/a"])
        XCTAssertEqual(links("https://en.wikipedia.org/wiki/Swift_(language)").map(\.text),
                       ["https://en.wikipedia.org/wiki/Swift_(language)"])
        XCTAssertEqual(links("Is it https://example.com/q?").map(\.text), ["https://example.com/q"])
    }

    func testWWWLocalhostAndEmail() {
        XCTAssertEqual(links("www.commonmark.org/help").map(\.url), ["http://www.commonmark.org/help"])
        XCTAssertEqual(links("open http://localhost:5173/admin/chat-history now").map(\.text),
                       ["http://localhost:5173/admin/chat-history"])
        XCTAssertEqual(links("mail developer@example.com.").map(\.url), ["mailto:developer@example.com"])
    }

    func testAnAddressCmarkSplitsAtUnderscoresIsOneLink() {
        XCTAssertEqual(links("https://example.com/a_b_c/d*e").map(\.text), ["https://example.com/a_b_c/d*e"])
    }

    func testCodeExistingLinksAndWordsGluedBeforeStayAsTheyAre() {
        XCTAssertTrue(links("`https://example.com/in-code`").isEmpty)
        XCTAssertEqual(links("[docs](https://example.com/docs) and https://example.com/bare").map(\.url),
                       ["https://example.com/docs", "https://example.com/bare"])
        XCTAssertEqual(links("[docs](https://example.com/docs)").map(\.text), ["docs"])
        XCTAssertTrue(links("abchttps://example.com").isEmpty)
        XCTAssertTrue(links("not.a.link and www.x").isEmpty)
    }

    func testABoldAddressKeepsItsWeightAndLinks() {
        let content = TranscriptInlineContent(stringLiteral: "**https://example.com/bold**")
        let run = try? XCTUnwrap(content.attributed.runs.first)
        XCTAssertEqual(run?.link?.absoluteString, "https://example.com/bold")
        XCTAssertEqual(run?.inlinePresentationIntent, .stronglyEmphasized)
    }

    func testANonASCIIPathIsEscapedForTheLink() {
        let found = links("https://example.com/문서/한글")
        XCTAssertEqual(found.map(\.text), ["https://example.com/문서/한글"])
        XCTAssertEqual(found.first?.url, "https://example.com/%EB%AC%B8%EC%84%9C/%ED%95%9C%EA%B8%80")
    }
}
