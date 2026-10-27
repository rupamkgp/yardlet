import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// The Files panel drawn without a window on screen, light and dark, into `.build/file-preview-qa/`:
/// a small source file with its colors, a 3 MB one without colors or editing and its one line
/// saying so, a 25 MB one shown from its beginning with the file's app and Finder, and, opened from a
/// link as a person clicks one, a file outside the task's folder (read-only), an image, a PDF and a
/// file it cannot show. The files are written into `YARDLET_FILE_PREVIEW_QA_DIR` (a temporary folder
/// without it) and removed.
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

    private func render(_ file: URL, in root: URL, name: String, minimumInk: Double = 0.01,
                        check: (WorkspaceFilesState) throws -> Void) throws {
        let directory = try WindowlessRender.directory("file-preview-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let state = WorkspaceFilesState()
            let host = WindowlessRender.Host(
                FilesPane(workspaceURL: root, state: state, onClose: {})
                    .environment(\.colorScheme, appearance.colorScheme),
                size: NSSize(width: 620, height: 420), appearance: appearance)
            defer { host.close() }
            state.open(file, in: root)
            let deadline = Date().addingTimeInterval(20)
            while state.isLoading, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            // An image is decoded after the panel shows it.
            host.settle(passes: state.media == nil ? 6 : 20)
            try check(state)
            let bitmap = try host.capture().bitmap
            // Text is drawn on the lines below the first too, not only where the view laid out first.
            XCTAssertGreaterThan(ink(in: bitmap, rows: 0.35...0.55), minimumInk, "\(name) \(appearance)")
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

        try render(root.appending(path: "Preview.swift"), in: root, name: "small-colored") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertFalse(document.tokens.isEmpty)
            XCTAssertTrue(state.canEdit)
        }
        try render(root.appending(path: "Large.swift"), in: root, name: "large-plain") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertTrue(document.tokens.isEmpty)
            XCTAssertFalse(document.isPartial)
            XCTAssertFalse(state.canEdit)
        }
        try render(root.appending(path: "Huge.swift"), in: root, name: "huge-beginning") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertTrue(document.isPartial)
            XCTAssertFalse(state.canEdit)
        }
    }

    /// What a person's click on a conversation's file link shows: a file outside the task's folder,
    /// read-only, through `~/Library/Application Support`'s space; an image and a PDF as themselves;
    /// and a file the panel cannot show, with its app and Finder under the reason.
    func testFilesPanelOpensWhatALinkNames() throws {
        let root = try folder(), outside = try folder()
        let notes = outside.appending(path: "Application Support/notes.swift")
        try FileManager.default.createDirectory(at: notes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.sample.utf8).write(to: notes)
        try render(URL(filePath: notes.path(percentEncoded: false) + ":3"), in: root, name: "outside-read-only") { state in
            let document = try XCTUnwrap(state.document)
            XCTAssertTrue(document.path.hasPrefix("/"))
            XCTAssertFalse(state.canEdit)
        }

        let image = root.appending(path: "screenshot.png")
        try Self.pngData().write(to: image)
        try render(image, in: root, name: "image") { state in
            XCTAssertEqual(state.media?.kind, .image)
            XCTAssertNil(state.fileError)
        }

        let pdf = outside.appending(path: "report.pdf")
        try Self.pdfData().write(to: pdf)
        try render(pdf, in: root, name: "pdf") { state in
            XCTAssertEqual(state.media?.kind, .pdf)
        }

        let binary = root.appending(path: "app-debug.apk")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0xFF]).write(to: binary)
        try render(binary, in: root, name: "unsupported", minimumInk: 0.001) { state in
            XCTAssertNil(state.media)
            XCTAssertEqual(state.fileError, WorkspaceFileError.unsupported.localizedDescription)
        }
    }

    /// A 1,600 by 1,000 pixel picture at 144 dpi: bands of color with dark bars across its middle.
    private static func pngData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1_600, pixelsHigh: 1_000, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 800, height: 500)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGradient(starting: .systemBlue, ending: .systemPurple)?.draw(in: NSRect(x: 0, y: 0, width: 800, height: 500), angle: 30)
        NSColor(white: 0.1, alpha: 1).setFill()
        for row in 0..<6 { NSRect(x: 80, y: 120 + row * 44, width: 640 - row * 60, height: 18).fill() }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    /// A one-page US Letter PDF with large lines of text down its page.
    private static func pdfData() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black]
        for line in 0..<14 { ("Quarterly report line \(line + 1)" as NSString).draw(at: NSPoint(x: 48, y: 720 - line * 50), withAttributes: attributes) }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
