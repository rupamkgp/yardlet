import Foundation
import XCTest
@testable import NativeHarnessClient

/// Opt-in, read-only: reads the Codex user messages in the rollout files listed in
/// `NHC_PROMPT_LIVE_FILES` (one path a line; `.jsonl`, or `.jsonl.zst` read through `zstd -dc`) and
/// counts how many carry each context section, what the conversation draws of them, and any context
/// left in the request it shows. It prints counts only, never a message's words.
final class CodexPromptLiveShapesTests: XCTestCase {
    func testRealSentMessagesShowTheirRequest() throws {
        guard let list = ProcessInfo.processInfo.environment["NHC_PROMPT_LIVE_FILES"] else {
            throw XCTSkip("Set NHC_PROMPT_LIVE_FILES to a list of rollout files to read.")
        }
        let paths = try String(contentsOfFile: list, encoding: .utf8).split(separator: "\n").map(String.init)
        var counts: [String: Int] = [:]
        var seen = Set<Int>()
        for path in paths {
            try forEachLine(of: path) { line in
                guard let text = Self.userMessage(in: line), seen.insert(text.hashValue).inserted else { return }
                counts["messages", default: 0] += 1
                guard text.contains("## My request") else { return }
                counts["with marker", default: 0] += 1
                guard ConversationScheduledTaskMessage.parse(text) == nil else { return }
                guard let prompt = CodexUserPrompt.parse(text, harness: .codex) else {
                    counts["with marker, read as text", default: 0] += 1
                    return
                }
                count(prompt, text: text, into: &counts)
            }
        }
        print("codex prompt live shapes:", counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: " "))
        XCTAssertGreaterThan(counts["messages"] ?? 0, 0)
    }

    private func count(_ prompt: CodexUserPrompt, text: String, into counts: inout [String: Int]) {
        counts["read as prompt", default: 0] += 1
        if text.contains("## My request for Codex:") { counts["marker for Codex", default: 0] += 1 }
        // The sections the context holds, by their headers.
        for (name, header) in Self.sections where prompt.requestPrefix.contains(header) {
            counts["section \(name)", default: 0] += 1
        }
        // What the conversation draws of them.
        let drawn = prompt.attachments
        let drawnCounts: [(String, Int)] = [
            ("files", drawn.files.filter { !$0.isPasted }.count), ("pasted files", drawn.files.filter(\.isPasted).count),
            ("uploads", drawn.uploads.count), ("selections", drawn.selections.count),
            ("comments", drawn.comments.count), ("annotations", drawn.annotations.count + drawn.responseAnnotationCount),
            ("failing checks", drawn.failingChecks.count), ("merge conflicts", drawn.mergeConflict == nil ? 0 : 1),
            ("merge tasks", drawn.mergeTaskPullRequest == nil ? 0 : 1),
            ("previous context", drawn.referencesPriorConversation ? 1 : 0), ("modes", drawn.modes.count)
        ]
        for (name, value) in drawnCounts where value > 0 {
            counts["drawn \(name)", default: 0] += value
            counts["messages drawing \(name)", default: 0] += 1
        }
        if drawn.files.contains(where: { $0.lineInfo != nil }) { counts["messages drawing files with lines", default: 0] += 1 }
        if prompt.request.isEmpty { counts["empty request", default: 0] += 1 }
        // Context left in what the bubble shows.
        let request = prompt.request
        for (name, header) in Self.sections where request.split(separator: "\n").contains(where: { $0.hasPrefix(header) }) {
            counts["left raw \(name)", default: 0] += 1
        }
        if Self.markerLinesOutsideCode(request) > 0 { counts["left raw marker line", default: 0] += 1 }
        if request.split(separator: "\n").contains(where: { $0.hasPrefix("## My request") }) {
            counts["request quotes the marker in code", default: 0] += 1
        }
    }

    private static let sections: [(String, String)] = [
        ("files mentioned", "# Files mentioned by the user:"), ("files pasted", "# Files pasted by the user:"),
        ("ide context", "# Context from my IDE setup:"), ("ide active file", "## Active file:"),
        ("ide selection", "## Active selection of the file:"), ("ide open tabs", "## Open tabs:"),
        ("worktree", "# Worktree instructions:"), ("page comment", "<page-comment-context>"),
        ("diff comments", "# Diff comments:"), ("browser comments", "# Browser comments:"),
        ("selected text", "# Selected text:"), ("failing checks", "# Failing PR checks:"),
        ("user comment", "## User Comment"), ("requested annotation", "## Requested annotation"),
        ("mcp app context", "# MCP app context:"), ("merge conflict", "# Pull request merge conflict:"),
        ("in-app browser block", "<in-app-browser-context"), ("in-app browser", "# In app browser:"),
        ("chrome tabs", "# Chrome tabs:"), ("applications", "# Applications mentioned by the user:"),
        ("referenced chatgpt", "## Referenced ChatGPT conversation:"), ("prior conversation", "## Prior conversation with Codex:"),
        ("response annotations", "# Response annotations:"), ("review", "## Code review guidelines:")
    ]

    /// Lines that open a request, outside fenced code blocks.
    private static func markerLinesOutsideCode(_ text: String) -> Int {
        var inFence = false
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            if !inFence, CodexUserPrompt.markers.contains(where: { line.hasPrefix($0) }) { count += 1 }
        }
        return count
    }

    /// A user message's text: a completed `UserMessage` item's text parts, or a `user_message` event.
    private static func userMessage(in line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any] else { return nil }
        if payload["type"] as? String == "user_message" { return payload["message"] as? String }
        guard payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any],
              item["type"] as? String == "UserMessage", let content = item["content"] as? [[String: Any]] else { return nil }
        return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    /// Each line of a rollout that may hold a user message, read in pieces.
    private func forEachLine(of path: String, _ body: (Data) -> Void) throws {
        let handle: FileHandle
        var process: Process?
        if path.hasSuffix(".zst") {
            let zstd = Process()
            zstd.executableURL = URL(filePath: "/usr/bin/env")
            zstd.arguments = ["zstd", "-dcq", path]
            let pipe = Pipe()
            zstd.standardOutput = pipe
            zstd.standardError = FileHandle.nullDevice
            try zstd.run()
            process = zstd
            handle = pipe.fileHandleForReading
        } else {
            guard let file = FileHandle(forReadingAtPath: path) else { return }
            handle = file
        }
        defer {
            try? handle.close()
            process?.waitUntilExit()
        }
        let needles = [Data("UserMessage".utf8), Data("user_message".utf8)]
        var pending = Data()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            pending.append(chunk)
            var start = pending.startIndex
            while let newline = pending[start...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[start..<newline]
                if needles.contains(where: { line.range(of: $0) != nil }) { body(Data(line)) }
                start = pending.index(after: newline)
            }
            pending = Data(pending[start...])
        }
        if !pending.isEmpty { body(pending) }
    }
}
