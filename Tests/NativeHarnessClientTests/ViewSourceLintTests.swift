import Foundation
import XCTest

/// Rules the views' source keeps, checked by reading it, so `scripts/test-fast.sh` (which skips the
/// rendering tests) still runs them.
final class ViewSourceLintTests: XCTestCase {
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
}
