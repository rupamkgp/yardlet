import Foundation
import XCTest

/// Keeps the conversation and composer views free of harness comparisons (plan M11, A1): what
/// differs between harnesses is decided in their projections (`ComposerSessionOptionsProjection`
/// for the composer) and read by the views. Existing comparisons are listed per file and may
/// only shrink.
final class HarnessBranchLintTests: XCTestCase {
    /// The view folders that read projections instead of comparing harnesses.
    private static let folders = ["Views/Composer/", "Views/Conversation/", "Views/HarnessSettings/"]

    /// Existing comparisons, by file and count. Lower a count or remove the entry when a file
    /// loses one; never add one.
    private static let allowed: [String: Int] = [:]

    private static let patterns = [
        // `harness == .codex`, `session.harness != .claudeCode`, `$0.harness == x`
        #"\bharness\s*(?:==|!=)"#,
        // `.codex == harness`, `kind != session.harness`
        #"(?:==|!=)\s*[\w.$]*\bharness\b"#,
        // `switch harness`, `switch session.harness`
        #"\bswitch\s+[\w.$]*\bharness\b"#
    ]

    func testComposerAndConversationViewsDoNotCompareHarnesses() throws {
        let sources = try Self.sources()
        XCTAssertTrue(sources.keys.contains("Views/Composer/PromptComposer.swift"), "The composer was not scanned")
        for (path, text) in sources.sorted(by: { $0.key < $1.key }) {
            let found = try Self.comparisons(in: text)
            let allowed = Self.allowed[path] ?? 0
            XCTAssertLessThanOrEqual(found.count, allowed,
                "\(path) compares harnesses: \(found.joined(separator: " | ")). "
                    + "Read the harness's options from its projection instead.")
        }
    }

    func testAllowedComparisonsOnlyShrink() throws {
        let sources = try Self.sources()
        for (path, count) in Self.allowed.sorted(by: { $0.key < $1.key }) {
            guard let text = sources[path] else {
                XCTFail("\(path) is gone; remove it from the allowed comparisons")
                continue
            }
            XCTAssertEqual(try Self.comparisons(in: text).count, count,
                           "\(path) has fewer comparisons now; lower its allowance")
        }
    }

    func testTheScannerCatchesEachForm() throws {
        let sample = """
        if harness == .codex { }
        guard session.harness != .claudeCode else { return }
        let codex = sessions.filter { $0.harness == .codex }
        if .codex == draft.harness { }
        switch session.harness { default: break }
        // harness == .codex in a comment is not a comparison
        let options = Projection.make(harness: harness, session: session)
        """
        XCTAssertEqual(try Self.comparisons(in: sample).count, 5)
    }

    private static func comparisons(in source: String) throws -> [String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let expressions = try patterns.map { try NSRegularExpression(pattern: $0) }
        return lines.filter { line in
            let range = NSRange(line.startIndex..., in: line)
            return expressions.contains { $0.firstMatch(in: line, range: range) != nil }
        }.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func sources() throws -> [String: String] {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/NativeHarnessClient", directoryHint: .isDirectory).standardizedFileURL
        let rootPath = root.path(percentEncoded: false)
        var sources: [String: String] = [:]
        for folder in folders {
            let directory = root.appending(path: folder, directoryHint: .isDirectory)
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let path = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(rootPath.count))
                sources[path] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return sources
    }
}
