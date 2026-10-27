import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The Files panel drawn without a window on screen, light and dark, into `.build/file-preview-qa/`:
/// a small source file with its colors, a 3 MB one without colors or editing and its one line
/// saying so, and a 25 MB one shown from its beginning with the file's app and Finder. The large
/// files are written into `YARDLET_FILE_PREVIEW_QA_DIR` (a temporary folder without it) and removed.
@MainActor
final class WorkspaceFilePreviewRenderingTests: XCTestCase {
    private static let sample = """
        import Foundation

        /// Reads a file the way the Files panel shows it.
        struct Preview {
            let path: String
            var limit = 2_097_152 // 2 MB

            func title() -> String {
                guard !path.isEmpty else { return "Untitled" }
                return "File: \\(path)"
            }
        }

        """

    private func folder() throws -> URL {
        let base = ProcessInfo.processInfo.environment["YARDLET_FILE_PREVIEW_QA_DIR"].map { URL(filePath: $0) }
            ?? FileManager.default.temporaryDirectory
        let url = base.appending(path: "file-preview-render-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func render(_ path: String, in root: URL, name: String, check: (WorkspaceFilesState) throws -> Void) throws {
        let directory = try WindowlessRender.directory("file-preview-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let state = WorkspaceFilesState()
            let host = WindowlessRender.Host(
                FilesPane(workspaceURL: root, state: state, onClose: {})
                    .environment(\.colorScheme, appearance.colorScheme),
                size: NSSize(width: 620, height: 420), appearance: appearance)
            defer { host.close() }
            state.open(.init(relativePath: path), in: root)
            let deadline = Date().addingTimeInterval(20)
            while state.isLoading, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            host.settle(passes: 6)
            try check(state)
            let bitmap = try host.capture().bitmap
            // Text is drawn on the lines below the first too, not only where the view laid out first.
            XCTAssertGreaterThan(ink(in: bitmap, rows: 0.35...0.55), 0.01, "\(name) \(appearance)")
            try WindowlessRender.writePNG(bitmap, to: directory.appending(path: "\(name)-\(appearance.suffix).png"))
        }
    }

    /// The share of pixels in a band of rows, across the text, that differ from the background.
    private func ink(in bitmap: NSBitmapImageRep, rows: ClosedRange<Double>) -> Double {
        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat)? {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
            return (color.redComponent, color.greenComponent, color.blueComponent)
        }
        guard let background = rgb(bitmap.pixelsWide - 4, bitmap.pixelsHigh - 4) else { return 0 }
        var ink = 0, total = 0
        let top = Int(Double(bitmap.pixelsHigh) * rows.lowerBound), bottom = Int(Double(bitmap.pixelsHigh) * rows.upperBound)
        for y in stride(from: top, to: bottom, by: 2) {
            for x in stride(from: bitmap.pixelsWide / 8, to: bitmap.pixelsWide * 3 / 4, by: 2) {
                total += 1
                guard let pixel = rgb(x, y) else { continue }
                if abs(pixel.0 - background.0) + abs(pixel.1 - background.1) + abs(pixel.2 - background.2) > 0.3 { ink += 1 }
            }
        }
        return Double(ink) / Double(max(1, total))
    }

    func testFilesPanelAtEachSize() throws {
        let root = try folder()
        try Data(Self.sample.utf8).write(to: root.appending(path: "Preview.swift"))
        let repeated = String(repeating: Self.sample, count: 3 * 1_048_576 / Self.sample.utf8.count + 1)
        try Data(repeated.utf8).write(to: root.appending(path: "Large.swift"))
        let huge = String(repeating: Self.sample, count: 25 * 1_048_576 / Self.sample.utf8.count + 1)
        try Data(huge.utf8).write(to: root.appending(path: "Huge.swift"))

        try render("Preview.swift", in: root, name: "small-colored") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertFalse(document.tokens.isEmpty)
            XCTAssertTrue(state.canEdit)
        }
        try render("Large.swift", in: root, name: "large-plain") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertTrue(document.tokens.isEmpty)
            XCTAssertFalse(document.isPartial)
            XCTAssertFalse(state.canEdit)
        }
        try render("Huge.swift", in: root, name: "huge-beginning") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertTrue(document.isPartial)
            XCTAssertFalse(state.canEdit)
        }
    }
}
