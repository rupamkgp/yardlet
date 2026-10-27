import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient
@testable import YardletAgentTools

/// The session tools drawn by the one conversation renderer with no window on screen, into
/// `.build/session-tools-qa/`, light and dark:
///
/// - `received-message-*`: a message another task sent, under "Sent from {task}" (a link to it), then
///   the receiving task's answer.
/// - `subagents-running-*`: a running Claude Code turn with two `run_agent` cards: one working (its
///   latest step on one line, Stop) and one waiting for the person, whose request waits at the end of
///   the turn like every request.
/// - `subagent-done-*`: a finished Codex subagent's card with its model and answer.
/// - `approval-card-*`: `send_message_to_task` into another project waiting on the person's card.
@MainActor
final class SessionToolRenderingTests: XCTestCase {
    private static let workspace = URL(filePath: "/work/uploader", directoryHint: .isDirectory)
    private static let sender = UUID()

    func testAMessageFromAnotherTaskReadsAsThatTasksAndLinksToIt() throws {
        let message = TaskMessage(senderID: Self.sender.uuidString, senderName: "업로드 큐 재작성",
                                  body: "큐 재작성은 끝났어. 재시도 테스트를 이 브랜치에서 한 번 돌려 줄래?",
                                  quotes: [TaskMessage.Quote(text: "재시도 테스트까지 돌려 봐", sentAt: "2026-10-24T06:12:05+09:00")])
        let entries = transcript([
            .user(text: "업로드 한도 문서를 정리해 줘"),
            .assistant(text: "docs/uploads.md에 한도와 재시도 간격을 정리했습니다.", isStreaming: false),
            .user(text: message.text(in: .yardlet)),
            .activity(HarnessActivity(id: "toolu_test", kind: "Bash", title: "Bash", input: "swift test --filter RetryTests",
                                      output: "Executed 6 tests, with 0 failures"), state: .completed),
            .assistant(text: "재시도 테스트 6개가 모두 통과했습니다.", isStreaming: false)
        ])
        let drawings = try draw("received-message", height: 520) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .ready,
                                                     latestTurnIsComplete: true))
                .environment(\.taskSuggestionActions, TaskSuggestionActions(
                    resolution: { _ in nil }, start: { _ in }, dismiss: { _ in }, openTask: { _ in },
                    canOpenTask: { $0 == Self.sender }))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.format("Sent from %@", "업로드 큐 재작성")), texts)
            XCTAssertTrue(texts.contains("재시도 테스트를 이 브랜치에서"), texts)
            XCTAssertFalse(texts.contains("cross-session-message"), "The envelope never shows:\n\(texts)")
        }
    }

    func testRunningSubagentsShowTheirStepAndTheirRequestWaitsAtTheEndOfTheTurn() throws {
        let host = UUID()
        let working = AgentRun(callerID: host, hostTaskID: host, harness: .claudeCode, model: "sonnet",
                               prompt: "UploadQueue.swift의 동시성 버그를 찾아 줘", workspaceURL: Self.workspace, depth: 1)
        working.state = .running
        working.entries = [
            TranscriptEntry(content: .user(text: working.prompt)),
            TranscriptEntry(content: .activity(HarnessActivity(
                id: "c1", kind: "Read", title: "Read",
                input: #"{"file_path":"/work/uploader/Sources/Uploader/UploadQueue.swift"}"#), state: .running))
        ]
        let request = PermissionRequest(id: "perm-build", title: "Bash", detail: "Build the package",
                                        command: "swift build --build-tests")
        let asking = AgentRun(callerID: host, hostTaskID: host, harness: .openCode, model: "kimi-k2",
                              prompt: "빌드가 깨지는지 확인해 줘", workspaceURL: Self.workspace, depth: 1)
        asking.state = .waitingForApproval
        asking.entries = [
            TranscriptEntry(content: .user(text: asking.prompt)),
            TranscriptEntry(content: .permission(request, state: .pending))
        ]
        // One waits for room to start: it reads Pending and can be stopped.
        let queued = AgentRun(callerID: host, hostTaskID: host, harness: .codex, model: "gpt-5.5",
                              prompt: "업로드 재시도 문서를 갱신해 줘", workspaceURL: Self.workspace, depth: 1)
        queued.state = .queued
        let runs = [working, asking, queued]
        let entries = transcript([
            .user(text: "업로드 큐를 Codex와 Claude에게 나눠서 살펴봐 줘"),
            .activity(runAgent(harness: "claude-code", model: "sonnet", prompt: working.prompt), state: .running),
            .activity(runAgent(harness: "opencode", model: "kimi-k2", prompt: asking.prompt), state: .running),
            .activity(runAgent(harness: "codex", model: "gpt-5.5", prompt: queued.prompt), state: .running)
        ])
        let drawings = try draw("subagents-running", height: 760) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                     latestTurnIsComplete: false),
                                 actions: ConversationActions(heldRequests: asking.pendingRequests))
                .environment(\.agentRunActions, AgentRunActions(
                    run: { _, prompt in runs.first { $0.prompt == prompt } }, stop: { _ in }))
        }
        XCTAssertNotNil(working.progressLine)
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            // Each is named by what it was asked, with its harness and model, as the rail's Agents card names it.
            XCTAssertTrue(texts.contains(working.prompt) && texts.contains("Claude Code · sonnet"), texts)
            XCTAssertTrue(texts.contains(asking.prompt) && texts.contains("OpenCode · kimi-k2"), texts)
            XCTAssertTrue(texts.contains("UploadQueue.swift"), "The working one's step is its line:\n\(texts)")
            XCTAssertTrue(texts.contains(L10n.string("Needs approval")), texts)
            XCTAssertTrue(texts.contains("swift build --build-tests"), "The subagent's request is drawn:\n\(texts)")
            XCTAssertTrue(texts.contains(L10n.format("%@: %@", asking.prompt, "Bash")),
                          "Named for the subagent that asks, as its card names it:\n\(texts)")
            XCTAssertTrue(texts.contains(L10n.string("Stop task")), texts)
            XCTAssertTrue(texts.contains(queued.prompt) && texts.contains(L10n.string("Pending")), texts)
        }
    }

    func testAFinishedSubagentShowsItsModelAndAnswer() throws {
        let host = UUID()
        let run = AgentRun(callerID: host, hostTaskID: host, harness: .codex, model: "gpt-5.5",
                           prompt: "UploadQueue.swift의 동시성 버그를 찾아 줘", workspaceURL: Self.workspace, depth: 1)
        run.state = .completed
        run.answer = "`flush()`가 잠금 없이 `pending`을 읽습니다. 214행에서 `queue.sync`로 감싸면 됩니다."
        let result = AppModel.agentRunResultText(run)
        // The caller's turn goes on after its subagent answered; once it ends, the card folds into the
        // turn's work like any call.
        let entries = transcript([
            .user(text: "업로드 큐의 동시성 버그를 Codex에게 찾아보게 해 줘"),
            .activity(runAgent(harness: "codex", model: "gpt-5.5", prompt: run.prompt, result: result), state: .completed),
            .assistant(text: "Codex가 `flush()`의 잠금 누락을 찾았습니다. 고쳐 보겠습니다.", isStreaming: true)
        ])
        let drawings = try draw("subagent-done", height: 420) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                     latestTurnIsComplete: false))
                .environment(\.agentRunActions, AgentRunActions(run: { id, _ in id == run.id.uuidString ? run : nil },
                                                                 stop: { _ in }))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(run.prompt) && texts.contains("Codex · gpt-5.5"), texts)
            XCTAssertTrue(texts.contains(L10n.string("Open conversation")), texts)
            XCTAssertTrue(texts.contains("214행에서"), "The answer's first line is on the card:\n\(texts)")
            XCTAssertFalse(texts.contains(L10n.string("Stop task")), texts)
            XCTAssertFalse(texts.contains("mcp__yardlet__run_agent"), texts)
        }
    }

    func testAMessageIntoAnotherProjectWaitsOnTheCallersCard() throws {
        let caller = UUID()
        let approval = SessionToolApproval(
            id: SessionToolApproval.idPrefix + "render", taskID: caller,
            request: PermissionRequest(id: SessionToolApproval.idPrefix + "render",
                                       title: L10n.string("Send a message to another project's task"),
                                       detail: L10n.format("%@ → %@", "업로드 한도 문서", "결제 웹훅 재시도") + " · billing\n\n"
                                           + "업로드 재시도 간격을 3초로 바꿨어요. 웹훅 재시도도 같은 값을 쓰는지 확인해 줄래요?",
                                       command: nil))
        let entries = transcript([
            .user(text: "결제 쪽 작업에도 재시도 간격 바뀐 걸 알려 줘"),
            .activity(HarnessActivity(id: "toolu_send", kind: "mcp__yardlet__send_message_to_task",
                                      title: "mcp__yardlet__send_message_to_task",
                                      input: #"{"task_id":"5D0F…","message":"업로드 재시도 간격을 3초로 바꿨어요."}"#),
                      state: .running)
        ])
        let drawings = try draw("approval-card", height: 520) {
            ConversationTimeline(source: .transcript(entries: entries, harness: .claudeCode, status: .running,
                                                     latestTurnIsComplete: false),
                                 actions: ConversationActions(heldRequests: [approval.conversationRequest]))
        }
        for drawing in drawings {
            let texts = drawing.elements.map(\.description).joined(separator: "\n")
            XCTAssertTrue(texts.contains(L10n.string("Send a message to another project's task")), texts)
        }
    }

    // MARK: - Fixtures

    private func runAgent(harness: String, model: String, prompt: String, result: String? = nil) -> HarnessActivity {
        let arguments: JSONValue = .object(["harness": .string(harness), "model": .string(model), "prompt": .string(prompt)])
        return HarnessActivity(id: "toolu_\(harness)", kind: "mcp__yardlet__run_agent", title: "mcp__yardlet__run_agent",
                               input: arguments.readableText, output: result)
    }

    private func transcript(_ contents: [TranscriptEntryContent]) -> [TranscriptEntry] {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        return contents.enumerated().map { index, content in
            TranscriptEntry(createdAt: start.addingTimeInterval(Double(index) * 7), content: content)
        }
    }

    private func draw<Content: View>(_ name: String, height: CGFloat,
                                     _ content: () -> Content) throws -> [ConversationDrawing.Drawing] {
        let directory = try WindowlessRender.directory("session-tools-qa")
        return try WindowlessRender.Appearance.allCases.map { appearance in
            let drawing = try ConversationDrawing.draw(content(), size: NSSize(width: 760, height: height),
                                                      appearance: appearance)
            try WindowlessRender.writePNG(drawing.capture.bitmap,
                                          to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
            return drawing
        }
    }
}
