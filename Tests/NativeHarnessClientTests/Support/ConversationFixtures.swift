#if DEBUG
import Foundation
import XCTest
@testable import NativeHarnessClient

/// The conversations rendering and equivalence tests draw, built by the same DEBUG fixtures the
/// app's `--ui-fixture` launches use. Nothing here starts a provider, reads an account, or reads
/// or writes the workspace it names.
enum ConversationFixtures {
    /// The workspace the fixtures name in commands, paths and file changes. Nothing reads it.
    static let workspace = URL(filePath: "/tmp/yardlet-conversation-fixture", directoryHint: .isDirectory)

    /// A typed Codex timeline built through the provider decoder and reducer: earlier turns, an
    /// active stream, plan and usage updates, approvals, a subagent, and an unknown item.
    static func codexTimeline(workspaceURL: URL = workspace) -> CodexTaskState {
        VisualFixtureScenario.makeCodexPresentationState(workspaceURL: workspaceURL)
    }

    /// The `--ui-fixture=conversation` tasks: a populated Codex task (its timeline is
    /// `codexTimeline`), common-transcript tasks, queues, capabilities and usage.
    static func conversation(workspaceURL: URL = workspace) -> VisualFixtureScenario {
        VisualFixtureScenario.makeConversation(workspaceURL: workspaceURL, initialTaskSurface: nil)
    }

    /// The `--ui-fixture=harness-transcripts` tasks: one per non-Codex harness, each with a
    /// completed common transcript.
    static func harnessTranscripts(workspaceURL: URL = workspace) -> VisualFixtureScenario {
        VisualFixtureScenario.makeHarnessTranscripts(workspaceURL: workspaceURL)
    }

    /// The completed common transcript `harnessTranscripts` gives `harness`'s task.
    static func completedTranscript(
        for harness: HarnessKind, file: StaticString = #filePath, line: UInt = #line
    ) throws -> [TranscriptEntry] {
        let descriptor = try XCTUnwrap(HarnessCatalog.builtIns.first { $0.id == harness },
                                       "\(harness) is not a built-in harness", file: file, line: line)
        return VisualFixtureScenario.completedHarnessTranscript(for: descriptor)
    }
}
#endif
