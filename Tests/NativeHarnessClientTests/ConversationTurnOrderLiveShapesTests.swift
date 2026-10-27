import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A saved conversation drawn in the order it happened, read from copies the run is pointed at and
/// never from the provider's own files: `NHC_TURN_ORDER_CODEX_TURNS` names App Server turns made from a
/// Codex rollout (each turn's completed items in the rollout's order), and `NHC_TURN_ORDER_CLAUDE_CONFIG`
/// with `NHC_TURN_ORDER_CLAUDE_SESSION` a Claude config folder holding a copy of a transcript. Each test
/// lists the turns as the person reads them and draws them in both appearances under
/// `.build/turn-order-qa/<NHC_TURN_ORDER_PHASE>/`; without its variables it is skipped.
@MainActor
final class ConversationTurnOrderLiveShapesTests: XCTestCase {
    private static let workspace = URL(filePath: "/tmp/turn-order", directoryHint: .isDirectory)
    private let environment = ProcessInfo.processInfo.environment

    func testACodexRolloutReadsInTheOrderItHappened() throws {
        guard let path = environment["NHC_TURN_ORDER_CODEX_TURNS"] else {
            throw XCTSkip("Set NHC_TURN_ORDER_CODEX_TURNS to App Server turns made from a Codex rollout")
        }
        let directory = try outputDirectory()
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(filePath: path)))
        let decoder = CodexTaskDecoder()
        var thread = try XCTUnwrap(decoder.thread(from: .object(["id": value["threadId"] ?? .string("thread")])))
        thread.turns = (value["turns"]?.arrayValue ?? []).enumerated().compactMap { index, turn in
            decoder.turn(from: turn, fallbackID: "turn-\(index)")
        }
        XCTAssertFalse(thread.turns.isEmpty)

        var report = ""
        let presentation = CodexConversationProjection.presentation(
            CodexTaskState(thread: thread), workspaceURL: Self.workspace, historySelection: nil
        )
        for (index, turn) in presentation.turns.enumerated() {
            report += "## Turn \(index + 1), finished, folded\n" + ConversationDrawOrder.listing(turn, harness: .codex)
            report += "\n\n## Turn \(index + 1), finished, opened\n"
                + ConversationDrawOrder.listing(turn, harness: .codex, folded: false) + "\n\n"
            report += outOfOrder(turn, recordOrder: thread.turns[index].items.map(\.id))
        }

        // The second turn while it ran: cut after what the person saw arrive, its last item still going.
        let second = thread.turns[min(1, thread.turns.count - 1)]
        var moments: [(name: String, turn: CodexTurnState)] = [("finished", second)]
        for (name, marker, throughNextMessage) in [("after-question", "직접 다시 로그인한 뒤", false),
                                                   ("after-reply", "잘 돼있는디", true),
                                                   ("after-second-reply", "아니 로그인 돼있다구", true)] {
            guard let moment = running(second, through: marker, throughNextMessage: throughNextMessage) else { continue }
            moments.append((name, moment))
        }
        for (name, turn) in moments {
            var single = thread
            single.turns = [turn]
            let state = CodexTaskState(thread: single)
            let projected = try XCTUnwrap(CodexConversationProjection.presentation(
                state, workspaceURL: Self.workspace, historySelection: nil
            ).turns.first)
            report += "## Second turn, \(name)\n" + ConversationDrawOrder.listing(projected, harness: .codex) + "\n\n"
            if name == "finished" {
                report += "## Second turn, finished, opened\n"
                    + ConversationDrawOrder.listing(projected, harness: .codex, folded: false) + "\n\n"
            }
            for appearance in WindowlessRender.Appearance.allCases {
                let drawing = try ConversationDrawing.draw(
                    ConversationTimeline(source: .codex(state, workspaceURL: Self.workspace, historySelection: nil)),
                    size: NSSize(width: 760, height: 2_400), appearance: appearance
                )
                try WindowlessRender.writePNG(drawing.capture.bitmap,
                                              to: directory.appending(path: "codex-\(name)-\(appearance.suffix).png"))
            }
        }
        try report.write(to: directory.appending(path: "codex-turns.txt"), atomically: true, encoding: .utf8)
        print(report)
    }

    func testAClaudeTranscriptReadsInTheOrderItHappened() throws {
        guard let config = environment["NHC_TURN_ORDER_CLAUDE_CONFIG"],
              let session = environment["NHC_TURN_ORDER_CLAUDE_SESSION"] else {
            throw XCTSkip("Set NHC_TURN_ORDER_CLAUDE_CONFIG and NHC_TURN_ORDER_CLAUDE_SESSION to a copied transcript")
        }
        let directory = try outputDirectory()
        let reader = ClaudeSubagentTranscriptReader(configDirectory: URL(filePath: config, directoryHint: .isDirectory))
        let bytes = environment["NHC_TURN_ORDER_CLAUDE_BYTES"].flatMap(Int.init) ?? ClaudeTranscriptTail.initialBytes
        let read = try XCTUnwrap(reader.readNewest(sessionID: session, bytes: bytes))
        // The copy was taken while its last turn ran.
        let presentation = TranscriptConversationProjection.presentation(
            from: read.entries, harness: .claudeCode, status: .running, latestTurnIsComplete: false
        )
        var report = "\(read.entries.count) entries, \(presentation.turns.count) turns\n\n"
        // The last turns, and the latest ones that took messages into their running turn.
        let shown = presentation.turns.suffix(3)
        let readInto = presentation.turns.dropLast(3).filter { turn in
            turn.work.contains { $0.sentText != nil }
        }.suffix(3)
        for turn in readInto + shown {
            let joined = turn.work.filter { $0.sentText != nil }.count
            let inWorkAnswers = turn.work.filter { if case .answer = $0.kind { true } else { false } }.count
            report += "## Turn \(turn.id) \(turn.status), \(turn.work.count) work items, \(joined) messages read in, "
                + "\(inWorkAnswers) answers in the work\n"
            report += ConversationDrawOrder.listing(turn, harness: .claudeCode) + "\n\n"
            if turn.foldsWork {
                report += "## opened\n" + ConversationDrawOrder.listing(turn, harness: .claudeCode, folded: false) + "\n\n"
            }
            report += outOfOrder(turn, recordOrder: turn.recordOrder)
        }
        try report.write(to: directory.appending(path: "claude-turns.txt"), atomically: true, encoding: .utf8)
        print(report)

        // The latest turn's end and the one before it, each drawn from its own entries: the request and
        // the last entries, so the messages read in near its end are on screen.
        let entryIDs = Dictionary(read.entries.enumerated().map { ($1.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        for (name, turn) in [("previous", shown.dropLast().last), ("latest", shown.last)] {
            guard let turn, let first = entryIDs[turn.id] else { continue }
            let last = turn.recordOrder.compactMap { entryIDs[$0] }.max() ?? first
            let tail = Array(read.entries[max(first + 1, last - 24)...last])
            let entries = [read.entries[first]] + tail
            let isLatest = name == "latest"
            for appearance in WindowlessRender.Appearance.allCases {
                let drawing = try ConversationDrawing.draw(
                    ConversationTimeline(source: .transcript(
                        entries: entries, harness: .claudeCode, status: isLatest ? .running : .ready,
                        latestTurnIsComplete: !isLatest
                    )),
                    size: NSSize(width: 760, height: 2_400), appearance: appearance
                )
                try WindowlessRender.writePNG(drawing.capture.bitmap,
                                              to: directory.appending(path: "claude-\(name)-\(appearance.suffix).png"))
            }
        }
    }

    // MARK: - Helpers

    private func outputDirectory() throws -> URL {
        try WindowlessRender.directory("turn-order-qa/\(environment["NHC_TURN_ORDER_PHASE"] ?? "after")")
    }

    /// The items drawn before an item the record holds earlier: each reads out of the order it happened.
    private func outOfOrder(_ turn: ConversationTurn, recordOrder: [String]) -> String {
        let position = Dictionary(recordOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let drawn = ConversationDrawOrder.rows(turn, harness: .codex, folded: false).filter { position[$0.id] != nil }
        // The row the record holds latest of those drawn so far.
        var latest: (row: ConversationDrawOrder.Row, at: Int)?
        var lines: [String] = []
        for row in drawn {
            let at = position[row.id] ?? 0
            if let previous = latest, at < previous.at {
                lines.append("  drawn after \(previous.row.shape) “\(previous.row.text)”: \(row.shape) “\(row.text)”")
            } else {
                latest = (row, at)
            }
        }
        return lines.isEmpty ? "In record order.\n\n" : "Out of record order (\(lines.count)):\n" + lines.joined(separator: "\n") + "\n\n"
    }

    /// `turn` while it ran: through the item whose words hold `marker` (and, with
    /// `throughNextMessage`, through the next message the provider wrote), that last item going.
    private func running(_ turn: CodexTurnState, through marker: String, throughNextMessage: Bool) -> CodexTurnState? {
        func words(_ item: CodexItemState) -> String {
            switch item.content {
            case let .agentMessage(message): message.text
            case let .userMessage(message): message.sentContent.text
            default: ""
            }
        }
        guard var end = turn.items.firstIndex(where: { words($0).contains(marker) }) else { return nil }
        if throughNextMessage {
            guard let next = turn.items[(end + 1)...].firstIndex(where: {
                if case .agentMessage = $0.content { true } else { false }
            }) else { return nil }
            end = next
        } else {
            end = min(end + 2, turn.items.count - 1)
        }
        var cut = turn
        cut.items = Array(turn.items[...end])
        cut.status = .inProgress
        cut.completedAt = nil
        cut.durationMilliseconds = nil
        cut.items[end].lifecycle = .inProgress
        return cut
    }
}
