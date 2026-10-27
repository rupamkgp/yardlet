import Foundation
@testable import NativeHarnessClient

/// Claude Code conversations that reach the controls a task's conversation offers.
@MainActor
enum ClaudeConversationFixture {
    static let workspace = URL(filePath: "/tmp/yardlet-claude-fixture", directoryHint: .isDirectory)
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let runningShellID = UUID(uuidString: "5A5A5A5A-0000-4000-8000-0000000000B1")!

    /// Every action a Claude task's conversation can take, each doing nothing.
    static func actions() -> ConversationActions {
        let rewind = ConversationRewindActions(
            beginCodexEdit: { _ in }, beginClaudeEdit: { _ in }, cancelEdit: {}, loadFilePoints: { [] },
            previewFiles: { _ in throw CancellationError() }, restoreFiles: { _ in throw CancellationError() }
        )
        var actions = ConversationActions(
            chooseOption: { _, _ in }, answer: { _, _ in }, restoreDraft: { _ in }, rewind: rewind,
            showHarnessSettings: {},
            providerNotices: TaskProviderNotices(canContinue: true)
        )
        actions.subtaskControls = HarnessActivityActions(open: { _ in }, stop: { _ in }, isStopping: { _ in false },
                                                         error: { _ in nil })
        return actions
    }

    /// A bash-mode command still running, read from the task's shell.
    static func shellCommands() -> ClaudeShellCommandActions {
        let run = ClaudeShellCommandRun(id: runningShellID, sessionID: UUID(), command: "npm test")
        run.output = "> yardlet@1.0.0 test\n> jest\n\nPASS  src/a.test.ts"
        return ClaudeShellCommandActions(isRunning: true, run: { _ in }, stop: {},
                                         runForEntry: { $0 == runningShellID ? run : nil })
    }

    /// A Claude task waiting on its requests: a compaction before the first request, a finished
    /// turn whose settled work folds (an approved call, thinking, its plan), bash commands, a turn
    /// whose failed edit keeps its work open, an image-only request, and the latest turn with a
    /// running subagent and three requests (provider options, questions, a plan to review).
    static func waiting() -> [TranscriptEntry] {
        var offset = 0.0
        func entry(_ content: TranscriptEntryContent, id: UUID = UUID()) -> TranscriptEntry {
            offset += 7
            return TranscriptEntry(id: id, createdAt: start.addingTimeInterval(offset), content: content)
        }
        let bash: JSONValue = .object(["command": .string("python3 test_calc.py"),
                                       "description": .string("Run the calc tests")])
        let edit: JSONValue = .object([
            "file_path": .string(workspace.appending(path: "calc.py").path(percentEncoded: false)),
            "old_string": .string("return a - b"), "new_string": .string("return a + b")
        ])
        return [
            entry(.compaction(HarnessContextCompaction(phase: .completed, tokensBefore: 167_012, tokensAfter: 41_230))),
            entry(.user(text: "calc.py 테스트를 고쳐 줘")),
            entry(.reasoning(text: "The add function subtracts.", isStreaming: false)),
            entry(.assistant(text: "I'll run the tests first.", isStreaming: false)),
            entry(.activity(HarnessActivity(id: "toolu_bash", kind: "Bash", title: "Bash", input: "python3 test_calc.py",
                                            output: "Ran 3 tests\nFAILED (failures=1)"), state: .completed)),
            entry(.permission(PermissionRequest(id: "bash-1", title: "Bash", detail: "Run the calc tests",
                                                command: "python3 test_calc.py", toolCallID: "toolu_bash",
                                                preview: ClaudeProtocol.preview(toolName: "Bash", input: bash)),
                              state: .allowed)),
            entry(.plan("☑ Run the tests\n◉ Fix add\n☐ Run them again")),
            entry(.assistant(text: "`add` subtracts; the fix is one line.", isStreaming: false)),
            entry(.user(text: ClaudeBashMessage.text(command: "git status --short",
                                                     stdout: " M calc.py\n?? notes.md"))),
            entry(.user(text: "Apply the fix")),
            entry(.activity(HarnessActivity(id: "toolu_edit", kind: "Edit", title: "Edit", outcome: .failed,
                                            input: "calc.py", output: "String not found",
                                            diff: HarnessActivityDiff(path: "calc.py", oldText: "return a - b",
                                                                      newText: "return a + b")), state: .failed)),
            entry(.permission(PermissionRequest(id: "edit-1", title: "Edit", detail: "calc.py", command: nil,
                                                toolCallID: "toolu_other",
                                                preview: ClaudeProtocol.preview(toolName: "Edit", input: edit)),
                              state: .denied)),
            entry(.assistant(text: "The edit did not apply; I'll ask before retrying.", isStreaming: false)),
            entry(.user(text: "", images: [TranscriptImageAttachment(url: nil, name: "screen.png")])),
            entry(.assistant(text: "That screenshot shows the failing test.", isStreaming: false)),
            entry(.user(text: ClaudeBashMessage.inputText(command: "npm test")), id: runningShellID),
            entry(.user(text: "Continue with an agent and ask me what you need")),
            entry(.activity(HarnessActivity(id: "toolu_agent", kind: "Agent", title: "Review the fix",
                                            outcome: .failed, input: "Review calc.py",
                                            subtask: HarnessSubtaskReference(agentID: "agent-1",
                                                                             taskType: "local_agent")),
                            state: .failed)),
            entry(.permission(PermissionRequest(
                id: "options", title: "Run a command", detail: "execute", command: "swift test",
                actions: [
                    PermissionRequestAction(id: "allow-once", label: "Allow once", decision: .allow, kind: "allow_once"),
                    PermissionRequestAction(id: "allow-always", label: "Always allow", decision: .allow,
                                            kind: "allow_always"),
                    PermissionRequestAction(id: "reject-once", label: "Reject", decision: .deny, kind: "reject_once")
                ]
            ), state: .pending)),
            entry(.permission(PermissionRequest(
                id: "question", title: "AskUserQuestion", detail: nil, command: nil,
                structured: .questions([PermissionQuestion(
                    question: "Which tests should run?", header: "Tests",
                    options: [.init(label: "Only calc", description: "Fast"), .init(label: "All")]
                )])
            ), state: .pending)),
            entry(.permission(PermissionRequest(
                id: "plan", title: "ExitPlanMode", detail: nil, command: nil,
                structured: .plan("## Plan\n1. Fix `add`\n2. Rerun the tests")
            ), state: .pending))
        ]
    }

    /// A Claude task whose earlier turn hit a limit and whose latest turn failed: the limit card in
    /// the work of a turn that went on, and the error whose request can be edited.
    static func failed() -> [TranscriptEntry] {
        var offset = 0.0
        func entry(_ content: TranscriptEntryContent) -> TranscriptEntry {
            offset += 5
            return TranscriptEntry(createdAt: start.addingTimeInterval(offset), content: content)
        }
        let limit = HarnessRateLimit(status: .rejected, window: .session,
                                     message: "You've hit your session limit · resets 3pm (Asia/Seoul)")
        return [
            entry(.user(text: "Summarize the open issues")),
            entry(.assistant(text: "Reading the tracker.", isStreaming: false)),
            entry(.usageLimit(limit)),
            entry(.assistant(text: "There are three open issues.", isStreaming: false)),
            entry(.compaction(HarnessContextCompaction(phase: .failed, message: "Conversation too long to summarize"))),
            entry(.user(text: "Fix the first one")),
            entry(.activity(HarnessActivity(id: "toolu_read", kind: "Read", title: "Read", input: "Sources/App.swift",
                                            output: "import SwiftUI"), state: .completed)),
            entry(.error(message: "API Error: 500 {\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"Internal server error\"}}",
                         recoverable: true))
        ]
    }
}
