import Foundation
import XCTest
@testable import NativeHarnessClient

/// Opt-in, read-only: reads the Codex `commandExecution` items in `NHC_COMMAND_LIVE_ITEMS` (a JSON
/// line each, `{"command", "status", "commandActions"}`, as `codex app-server` `thread/read` returns
/// them) and counts how the conversation words them: each parsed kind, the commands without
/// actions, and the lines that still show a shell wrapper — only ones whose wrapper is not the exact
/// shape may. It prints counts only, never a command's text.
final class CodexCommandWordingLiveShapesTests: XCTestCase {
    func testRealCommandsReadWithoutTheirWrapper() throws {
        guard let path = ProcessInfo.processInfo.environment["NHC_COMMAND_LIVE_ITEMS"] else {
            throw XCTSkip("Set NHC_COMMAND_LIVE_ITEMS to a file of commandExecution items to read.")
        }
        // Codex's own login-shell wrapper, and any shell's `-c`.
        let codexWrapper = try NSRegularExpression(pattern: #"^(?:/bin/zsh|/bin/bash|zsh|bash) -lc "#)
        let anyShell = try NSRegularExpression(pattern: #"^(?:/bin/|/usr/bin/)?(?:zsh|bash|sh) -l?c "#)
        func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        let en: ConversationLineWording.Localize = { L10n.string($0, languageCode: "en") }
        let ko: ConversationLineWording.Localize = { L10n.string($0, languageCode: "ko") }
        var counts: [String: Int] = [:]
        var notExact = true
        let text = try String(contentsOfFile: path, encoding: .utf8)
        for line in text.split(separator: "\n") {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
            guard let commandText = value["command"]?.stringValue else { continue }
            let actions = ConversationCommandAction.actions(from: value["commandActions"]?.arrayValue ?? [])
            let command = ConversationCommand(command: commandText, status: value["status"]?.stringValue ?? "",
                                              actions: actions)
            counts["commands", default: 0] += 1
            if matches(codexWrapper, commandText) { counts["commands with Codex's wrapper", default: 0] += 1 }
            if actions.isEmpty { counts["commands without actions", default: 0] += 1 }
            if actions.count > 1 { counts["commands of several actions", default: 0] += 1 }
            for action in actions {
                switch action {
                case .read: counts["action read", default: 0] += 1
                case .listFiles: counts["action listFiles", default: 0] += 1
                case .search: counts["action search", default: 0] += 1
                case let .unknown(inner):
                    counts["action unknown", default: 0] += 1
                    if matches(anyShell, inner) { counts["unknown actions the model wrapped itself", default: 0] += 1 }
                }
            }
            let unknownCommands = actions.isEmpty ? [commandText]
                : actions.compactMap { if case let .unknown(inner) = $0 { inner } else { nil } }
            for (language, localize) in [("en", en), ("ko", ko)] {
                let words = ConversationLineWording.command(command, phase: .completed, harness: .codex, localize: localize)
                for shown in words.flatMap({ [$0.leading, $0.trailing] }) where !shown.isEmpty {
                    if matches(codexWrapper, shown) {
                        counts["\(language) lines still showing Codex's wrapper", default: 0] += 1
                        // Only a command whose wrapper is not the exact shape keeps it.
                        if unknownCommands.contains(where: { CodexShellCommand.innerScript(of: $0) != nil }) {
                            notExact = false
                        }
                    } else if matches(anyShell, shown) {
                        counts["\(language) lines showing another shell -c", default: 0] += 1
                    }
                }
            }
        }
        print("codex command wording live shapes:", counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: " "))
        XCTAssertGreaterThan(counts["commands"] ?? 0, 0)
        XCTAssertTrue(notExact, "a command in the exact wrapper shape still shows it")
    }
}
