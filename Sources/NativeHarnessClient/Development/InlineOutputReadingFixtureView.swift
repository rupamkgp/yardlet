#if DEBUG
import SwiftUI

/// Provider-free interaction checks using the same transcript and output views as real tasks.
struct InlineOutputReadingFixtureView: View {
    @State private var output = Self.lines(1...300)
    @State private var mode = "Codex"
    @State private var secondWorkspace = false
    @State private var openedLink = ""
    @State private var draft = ""
    @State private var submissions = 0

    private static func lines(_ range: ClosedRange<Int>) -> String {
        range.map { "Output line \($0): 한글 👩🏽‍💻 · selection remains readable." }.joined(separator: "\n")
    }

    private static let inline = #"""
        ## Inline reading

        Literal \*plain\* and ``let `key` = 1``. **Bold `code`**, ***both***, and ~~old~~.

        Read [review](<Notes/한글 draft.md>) and [web](https://example.com/review).
        """#

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Harness", selection: $mode) {
                    Text("Codex").tag("Codex")
                    Text("Grok Build").tag("Grok Build")
                    Text("Code").tag("Code")
                }.pickerStyle(.segmented)
                Button("Grow output") { output += "\n" + Self.lines(301...340) + "\nOUTPUT-END" }
                Button("Switch workspace") { secondWorkspace.toggle() }
            }.padding(12)
            Divider()
            Group {
                if mode == "Grok Build" {
                    TranscriptConversationView(
                        harness: .grokBuild,
                        entries: [TranscriptEntry(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, content: .activity(
                            HarnessActivity(id: "reading-output", kind: "Read", title: "Read command output", detail: output),
                            state: .completed
                        )), TranscriptEntry(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, content: .assistant(text: Self.inline, isStreaming: false))],
                        latestTurnIsComplete: true, sessionStatus: .ready
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            TranscriptMarkdownText(text: Self.inline)
                            if mode == "Code" {
                                TranscriptCodeBlock(language: "text", text: output) { output }
                            } else {
                                CodexBoundedOutput(text: output)
                            }
                        }.padding(20)
                    }
                }
            }
            .environment(\.transcriptWorkspaceURL, URL(fileURLWithPath: secondWorkspace ? "/tmp/task-two" : "/tmp/task-one", isDirectory: true))
            .environment(\.openURL, OpenURLAction { url in
                openedLink = url.absoluteString
                return .handled
            })
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Workspace: \(secondWorkspace ? "two" : "one") · Submissions: \(submissions)").font(.caption)
                TextField("Draft", text: $draft).textFieldStyle(.roundedBorder)
                    .onSubmit { submissions += 1 }
                Text(verbatim: openedLink).font(.caption).textSelection(.enabled)
            }.padding(12)
        }
        .background(ParityTheme.canvas)
    }
}
#endif
