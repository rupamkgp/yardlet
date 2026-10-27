import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Claude's `AskUserQuestion` card as the conversation draws it: two questions, each choosing one
/// or more of four options with descriptions, under the window's monochrome tint (`MainWindow`
/// tints its shell `Color.primary`). The options and the buttons must read in light and dark,
/// waiting with nothing picked, waiting with picks (the first of two questions, as the card asks one
/// at a time), and answered (2026-10-16: the button's words did not show in light mode).
@MainActor
final class QuestionCardRenderingTests: XCTestCase {
    static let questions = [
        PermissionQuestion(
            question: "Which parts should the release notes cover?", header: "Scope",
            options: [
                PermissionQuestionOption(label: "Composer", description: "Return, ⌘Return and the queue"),
                PermissionQuestionOption(label: "Streaming", description: "The live line while a turn runs"),
                PermissionQuestionOption(label: "Question card", description: "Option and button text"),
                PermissionQuestionOption(label: "Subagents", description: "Harness and model on each card")
            ],
            allowsMultipleSelections: true),
        PermissionQuestion(
            question: "Who will read them?", header: "Audience",
            options: [
                PermissionQuestionOption(label: "The team", description: "Engineers who build Yardlet"),
                PermissionQuestionOption(label: "Reviewers", description: "People checking the change"),
                PermissionQuestionOption(label: "Everyone", description: "A short public summary"),
                PermissionQuestionOption(label: "Only me", description: "Notes to keep")
            ],
            allowsMultipleSelections: true)
    ]

    static func request(state: ConversationRequestState) -> ConversationRequest {
        let permission = PermissionRequest(
            id: "ask", title: "Claude has questions", detail: nil, command: nil,
            structured: .questions(questions), toolCallID: "ask-tool")
        let entry = TranscriptEntry(content: .permission(permission, state: state == .pending ? .pending : .allowed))
        // Answered, the card reads as the answers the provider recorded.
        let recorded = state == .pending ? nil : picked.answers(for: ConversationRequestForm.choices(questions).questionSteps)
        return ConversationRequest(
            id: "ask", title: permission.title, form: .choices(questions), state: state,
            responses: state == .pending ? ConversationRequestResponses.questions : [],
            toolCallID: "ask-tool", recordedAnswers: recorded, source: .transcript(entry))
    }

    static var picked: ConversationRequestFormInput {
        var input = ConversationRequestFormInput()
        input.selections[questions[0].question] = ["Composer", "Question card"]
        input.selections[questions[1].question] = ["The team"]
        return input
    }

    /// The card in the conversation's column, under the shell's tint as `MainWindow` sets it.
    static func card(_ request: ConversationRequest, input: ConversationRequestFormInput = .init(),
                     appearance: WindowlessRender.Appearance) -> some View {
        ConversationRequestCard(request: request,
                                actions: ConversationActions(answer: { _, _ in }), input: input)
            .padding(20)
            .frame(width: 640)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 640, height: 760, alignment: .top)
            .background(ParityTheme.canvas)
            .tint(Color.primary)
            // Drawn as in the key window, where a prominent button takes its tint.
            .environment(\.controlActiveState, .key)
            .environment(\.colorScheme, appearance.colorScheme)
    }

    /// A prominent button left with the shell's `Color.primary` tint draws its title in the color
    /// of its fill in light mode; each one takes the accent through `parityProminentButton()`.
    func testEveryProminentButtonTakesTheAccent() throws {
        let sources = WindowlessRender.repositoryRoot.appending(path: "Sources/NativeHarnessClient")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files where file.lastPathComponent != "ParityDesignSystem.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains(".buttonStyle(.borderedProminent)"),
                           "\(file.lastPathComponent) uses a prominent button without the accent")
        }
    }

    func testTheQuestionCardReadsInBothAppearances() throws {
        let directory = try WindowlessRender.directory("composer-stream-qa")
        let states: [(String, ConversationRequest, ConversationRequestFormInput)] = [
            ("pending", Self.request(state: .pending), .init()),
            ("pending-picked", Self.request(state: .pending), Self.picked),
            ("answered", Self.request(state: .answered), Self.picked)
        ]
        for (name, request, input) in states {
            try WindowlessRender.hostedInBothAppearances("question-card-\(name)", in: directory,
                                                         size: NSSize(width: 640, height: 760)) {
                Self.card(request, input: input, appearance: $0)
            }
        }
    }
}
