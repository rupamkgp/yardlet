import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class CompletionSurfacesRenderingTests: XCTestCase {
    func testChangedCommandIntelligenceAndReviewControlsRenderInOneAppearance() throws {
        let session = SessionRecord(harness: .codex, workspaceURL: URL(filePath: "/tmp/qa"),
            runtimeExecutableURL: URL(filePath: "/tmp/codex"), title: "QA")
        let model = ProviderCapabilitySelector(id: "model", name: L10n.string("Model"), description: nil,
            category: "model", currentValue: "opus", choices: [.init(value: "opus", name: "Opus", description: nil)])
        let effort = ProviderCapabilitySelector(id: "effort", name: L10n.string("Reasoning effort"), description: nil,
            category: "thought_level", currentValue: "high", choices: [
                .init(value: "low", name: L10n.string("Low"), description: nil),
                .init(value: "high", name: L10n.string("High"), description: nil)])
        let view = VStack(alignment: .leading, spacing: 12) {
            ForEach(CodexComposerCommands.catalog(.init(hasThread: true, isGitRepository: true))
                .filter { ["compact", "review-mode"].contains($0.name) }) { ComposerCommandRow(command: $0) }
            Divider()
            HarnessIntelligencePicker(modelSelector: model, reasoningSelector: effort, isAttached: true,
                onSetOption: { _, _ in }, onDismiss: {})
            Divider()
            CodexReviewTargetSheet(request: .init(session: session, draft: .init(text: "/review")), onCancel: {}, onReview: { _ in })
        }.padding(12).frame(width: 470).background(ParityTheme.input).environment(\.colorScheme, .light)
        // ImageRenderer does not materialize the effort list's LazyVStack. Mount the
        // real view in an unshown test window so its native scroll content is rendered.
        let host = WindowlessRender.Host(view, size: NSSize(width: 470, height: 520))
        defer { host.close() }
        host.settle(passes: 1, interval: 0.1)
        let capture = try host.capture()
        let bitmap = capture.bitmap
        try WindowlessRender.writePNG(bitmap, to: WindowlessRender.directory("completion-ui-qa").appending(path: "controls.png"))
        XCTAssertEqual(bitmap.pixelsWide, Int(host.hosting.bounds.width * capture.backingScaleFactor))
        XCTAssertGreaterThan(bitmap.pixelsHigh, 200)
    }
}
