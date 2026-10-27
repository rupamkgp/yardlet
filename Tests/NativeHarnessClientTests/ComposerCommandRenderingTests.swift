import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// Render only the app's own SwiftUI content. No app window, screen capture or computer-use
/// connection is involved. Native menu/focus interaction remains a separate acceptance check.
@MainActor
final class ComposerCommandRenderingTests: XCTestCase {
    func testOffscreenCommandRowsContainTextWithinTheMenuWidth() throws {
        let commands = [
            ProviderComposerCommand(name: "context", description: "Show context usage", argumentHint: ""),
            ProviderComposerCommand(name: "code-review", description: "Review the current changes or the files you name.", argumentHint: "[low|medium|high|xhigh|max] [--fix] [<target>]"),
            ProviderComposerCommand(name: "plugin:check", description: "A skill from the project and its plugins. A long description still keeps to two lines. " + String(repeating: "Long description. ", count: 20), argumentHint: "<file>"),
            ProviderComposerCommand(name: "프로젝트-검사", description: "한글 이름과 이모지 👩🏽‍💻", argumentHint: "<대상>")
        ]
        let directory = try WindowlessRender.directory("claude-commands-qa")
        for appearance in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 2) {
                ForEach(commands) { ComposerCommandRow(command: $0) }
            }
                .padding(8).frame(width: 340, height: 256)
                .background(ParityTheme.input)
                .environment(\.colorScheme, appearance)
            let cgImage = try WindowlessRender.image(view)
            XCTAssertEqual(cgImage.width, 680)
            XCTAssertEqual(cgImage.height, 512)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 7, from: 10),
                          "The renderer must include content, not just the background")
            let name = appearance == .dark ? "commands-dark.png" : "commands-light.png"
            try WindowlessRender.writePNG(bitmap, to: directory.appending(path: name))
        }
    }
}
