import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Both composers drawn in an unshown window, light and dark, in the states their shared editor
/// owns: attachment chips, a notice, the typed `/` and `@` lists, bash mode and the queue's chips.
/// Typing goes through the real field editor. Images and accessibility lists are written under
/// `.build/composer-editor-qa/<phase>/` (`COMPOSER_EDITOR_QA_PHASE`, `after` unless set), and an
/// `after` list is compared with the `before` list drawn from the code before the editor was
/// shared, when that run's files are present. No provider, CLI, app window or screen capture.
@MainActor
final class ComposerEditorRenderingTests: XCTestCase {
    private struct Scenario {
        let name: String
        let size: NSSize
        /// Typed into the focused editor before drawing.
        var typed: String?
        let view: () -> AnyView
    }

    private static var phase: String {
        ProcessInfo.processInfo.environment["COMPOSER_EDITOR_QA_PHASE"] ?? "after"
    }

    /// A fixed folder so file lists and project names read the same in every run.
    private static let workspace = FileManager.default.temporaryDirectory
        .appending(path: "composer-editor-qa-workspace", directoryHint: .isDirectory)

    private func makeWorkspace() throws {
        try? FileManager.default.removeItem(at: Self.workspace)
        for path in ["README.md", "Sources/App/Reader.swift", "Sources/App/Session.swift", "docs/release.md"] {
            let url = Self.workspace.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    private static let attachments: [CodexUserInput] = [
        .localImage(URL(filePath: "/tmp/composer-editor-qa/screenshot.png")),
        .mention(name: "Reader.swift", path: URL(filePath: "/tmp/composer-editor-qa/Sources/App/Reader.swift"))
    ]

    private static let commands = [
        ProviderComposerCommand(name: "review", description: "Review the working tree", argumentHint: ""),
        ProviderComposerCommand(name: "release-notes", description: "Draft release notes", argumentHint: "[version]"),
        ProviderComposerCommand(name: "context", description: "Show context usage", argumentHint: "")
    ]

    /// A draft longer than either composer's field shows.
    private static let longText = (1...14).map { "Line \($0) of a long request that runs past the composer's lines" }
        .joined(separator: "\n")

    private static func taskDraft(_ text: String, attachments: [CodexUserInput] = [], notice: String? = nil)
        -> TaskComposerDraft {
        let draft = TaskComposerDraft()
        draft.text = text
        draft.attachments = attachments
        draft.notice = notice
        return draft
    }

    private static var claudeCommands: ProviderCapabilityState {
        var state = ProviderCapabilityState()
        state.composerCommands = commands
        return state
    }

    private var taskScenarios: [Scenario] {
        let workspace = Self.workspace
        let shell = ClaudeShellCommandActions(isRunning: false, run: { _ in }, stop: {}, runForEntry: { _ in nil })
        return [
            Scenario(name: "task-claude-chips", size: NSSize(width: 760, height: 190)) {
                AnyView(PromptComposer(harness: .claudeCode,
                    composerDraft: Self.taskDraft("Fix the bug", attachments: Self.attachments,
                                                  notice: "Unsupported attachment type"),
                    isRunning: false, mentionRoots: [workspace]))
            },
            Scenario(name: "task-codex-queue", size: NSSize(width: 760, height: 220)) {
                AnyView(PromptComposer(harness: .codex, composerDraft: Self.taskDraft("", attachments: Self.attachments),
                    modelCatalog: ComposerUnificationFixtures.codexCatalog, isRunning: true, canSteer: true,
                    codexQueue: ComposerUnificationFixtures.queue, isCodexQueuePaused: true,
                    actions: ComposerUnificationFixtures.codexActions))
            },
            Scenario(name: "task-claude-slash", size: NSSize(width: 760, height: 330), typed: "/re") {
                AnyView(PromptComposer(harness: .claudeCode, composerDraft: Self.taskDraft(""),
                    providerCapabilities: Self.claudeCommands, isRunning: false, mentionRoots: [workspace]))
            },
            Scenario(name: "task-codex-slash", size: NSSize(width: 760, height: 420), typed: "/mo") {
                AnyView(PromptComposer(harness: .codex, composerDraft: Self.taskDraft(""),
                    modelCatalog: ComposerUnificationFixtures.codexCatalog, isRunning: false,
                    actions: ComposerUnificationFixtures.codexActions))
            },
            Scenario(name: "task-claude-mention", size: NSSize(width: 760, height: 330), typed: "Look at @read") {
                AnyView(PromptComposer(harness: .claudeCode, composerDraft: Self.taskDraft(""),
                    isRunning: false, mentionRoots: [workspace]))
            },
            Scenario(name: "task-claude-bash", size: NSSize(width: 760, height: 160), typed: "!git status") {
                AnyView(PromptComposer(harness: .claudeCode, composerDraft: Self.taskDraft(""),
                    isRunning: false, mentionRoots: [workspace])
                    .environment(\.claudeShellCommands, shell))
            },
            // Past the field's lines it scrolls inside (`ComposerEditorTests` drives the scrolling).
            Scenario(name: "task-claude-long", size: NSSize(width: 760, height: 260)) {
                AnyView(PromptComposer(harness: .claudeCode, composerDraft: Self.taskDraft(Self.longText),
                    isRunning: false, mentionRoots: [workspace]))
            }
        ]
    }

    private func homeScenarios(runtimes: RuntimeSelectionStore) -> [Scenario] {
        let project = Project(name: "composer-editor-qa", primaryRoot: Self.workspace)
        func home(_ harness: HarnessKind, text: String = "", attachments: [CodexUserInput] = [],
                  notice: String? = nil) -> AnyView {
            let draft = NewTaskDraft()
            draft.workspaceURL = Self.workspace
            draft.projectID = project.id
            draft.harness = harness
            draft.text = text
            draft.attachments = attachments
            draft.notice = notice
            return AnyView(NewTaskHome(recentSessions: [], projects: [project], draft: draft, runtimeSelections: runtimes,
                onSelectSession: { _ in }, onChooseWorkspace: { _ in }, onShowHarnesses: {},
                onCreate: { _ in nil }, onReadCommands: { _, _, _ in Self.commands }))
        }
        return [
            Scenario(name: "home-claude-chips", size: NSSize(width: 860, height: 420)) {
                home(.claudeCode, text: "Explain the build", attachments: Self.attachments,
                     notice: "Unsupported attachment type")
            },
            Scenario(name: "home-codex-chips", size: NSSize(width: 860, height: 420)) {
                home(.codex, text: "Explain the build", attachments: Self.attachments)
            },
            Scenario(name: "home-claude-slash", size: NSSize(width: 860, height: 520), typed: "/re") {
                home(.claudeCode)
            },
            Scenario(name: "home-claude-mention", size: NSSize(width: 860, height: 520), typed: "Explain @read") {
                home(.claudeCode)
            },
            Scenario(name: "home-claude-long", size: NSSize(width: 860, height: 520)) {
                home(.claudeCode, text: Self.longText)
            }
        ]
    }

    func testBothComposersDrawTheirEditorInBothAppearances() throws {
        try makeWorkspace()
        let suite = testDefaultsSuite("ComposerEditorQA")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let runtimes = RuntimeSelectionStore(defaults: defaults, discoversRuntimes: false, loadsPersistedSelections: false)
        for harness in [HarnessKind.claudeCode, .codex] { runtimes.select(URL(filePath: "/usr/bin/true"), for: harness) }

        let directory = try WindowlessRender.directory("composer-editor-qa/\(Self.phase)")
        let before = WindowlessRender.repositoryRoot.appending(path: ".build/composer-editor-qa/before")
        var compared = 0
        for scenario in taskScenarios + homeScenarios(runtimes: runtimes) {
            let elements = try render(scenario, into: directory)
            let text = elements.map(\.description).joined(separator: "\n")
            try text.write(to: directory.appending(path: "\(scenario.name)-ax.txt"), atomically: true, encoding: .utf8)
            guard Self.phase != "before",
                  let drawn = try? String(contentsOf: before.appending(path: "\(scenario.name)-ax.txt"), encoding: .utf8)
            else { continue }
            compared += 1
            XCTAssertEqual(text, Self.expected(after: drawn, scenario: scenario.name),
                           "\(scenario.name) exposes different accessibility elements than before")
        }
        if Self.phase != "before", compared == 0 {
            print("composer-editor-qa: no `before` lists to compare with")
        }
    }

    /// A `before` list as the shared editor should expose it. The one intended difference: the
    /// new-task field is named by its placeholder, as the task field always was.
    private static func expected(after before: String, scenario: String) -> String {
        guard scenario.hasPrefix("home-") else { return before }
        return before.replacingOccurrences(
            of: "AXTextField = ", with: "AXTextField “\(L10n.string("Describe a task…"))” = ")
    }

    private func render(_ scenario: Scenario, into directory: URL) throws -> [WindowlessRender.AccessibilityElement] {
        var elements: [WindowlessRender.AccessibilityElement] = []
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                scenario.view()
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: scenario.size.width, height: scenario.size.height, alignment: .bottom)
                    .background(ParityTheme.canvas),
                size: scenario.size, appearance: appearance)
            host.settle()
            if let typed = scenario.typed { try type(typed, in: host) }
            try WindowlessRender.writePNG(try host.capture().bitmap,
                to: directory.appending(path: "\(scenario.name)-\(appearance.suffix).png"))
            if appearance == .light { elements = host.accessibilityElements() }
            host.close()
        }
        return elements
    }

    /// Focuses the composer's field and types `text` through its field editor, one character
    /// at a time so each keystroke reaches the composer as typing does.
    private func type<Content: View>(_ text: String, in host: WindowlessRender.Host<Content>) throws {
        let field = try XCTUnwrap(views(NSTextField.self, in: host.hosting).first { $0.isEditable })
        XCTAssertTrue(host.window.makeFirstResponder(field))
        host.settle(passes: 4)
        let editor = try XCTUnwrap(host.window.firstResponder as? NSTextView)
        for character in text {
            editor.insertText(String(character), replacementRange: NSRange(location: (editor.string as NSString).length,
                                                                           length: 0))
            host.settle(passes: 2)
        }
        // The file search waits out a burst of keystrokes, then lists off the main thread.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.settle()
    }

    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ([root] + root.subviews.flatMap { views(NSView.self, in: $0) }).compactMap { $0 as? T }
    }
}
