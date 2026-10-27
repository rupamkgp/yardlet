import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

/// A conversation image opened over the window (`ImageViewer`), as the Codex and Claude apps open
/// one: fitted and never enlarged, zoomed by keys, moved between a message's images by the arrows,
/// put away by Esc, and named for assistive apps. Renders over a real conversation at window size go
/// to `.build/image-viewer-qa` in light and dark. No provider, CLI, app window or screen capture.
@MainActor
final class ImageViewerRenderingTests: XCTestCase {
    private var scratch: URL!
    private let size = NSSize(width: 1_280, height: 800)

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "image-viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAMessageImageOpensFittedOverTheConversationAndTheKeysMoveAndZoomIt() async throws {
        let screenshot = try write(Self.screenshot(), as: "Screen Shot 2026-10-27.png")
        let portrait = try write(Self.screenshot(width: 1_170, height: 2_532, dpiScale: 3), as: "phone.png")
        let small = try write(Self.screenshot(width: 300, height: 200, dpiScale: 1), as: "icon.png")
        let images = [screenshot, portrait, small].map { TranscriptImageAttachment(url: $0) }
        let request = ImageViewerRequest(
            items: images.map { ImageViewerItem(name: $0.name ?? "", source: .url($0.url!)) }, index: 0
        )
        let directory = try WindowlessRender.directory("image-viewer-qa")

        for appearance in WindowlessRender.Appearance.allCases {
            var closed = false
            let host = WindowlessRender.Host(
                ZStack {
                    conversation(images: images)
                    ImageViewer(request: request) { closed = true }
                }
                .environment(\.colorScheme, appearance.colorScheme)
                .frame(width: size.width, height: size.height),
                size: size, appearance: appearance
            )
            defer { host.close() }
            let first = try await canvas(in: host, showing: NSSize(width: 1_440, height: 900))
            // Fitted between the name and the zoom controls, below its own size.
            XCTAssertLessThan(first.magnification, 1)
            XCTAssertEqual(first.magnification, first.fitMagnification, accuracy: 0.001)
            XCTAssertTrue(first.fitsWindow)
            XCTAssertTrue(host.window.firstResponder === first, "The viewer holds the keyboard, not the composer behind it")
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "after-sent-image-\(appearance.suffix).png"))

            // ⌘= steps up from the fitted zoom to the image's own size, then on; ⌘0 fits again.
            XCTAssertTrue(first.performKeyEquivalent(with: key(24, "=", modifiers: .command)))
            XCTAssertEqual(first.magnification, 1, accuracy: 0.001)
            XCTAssertFalse(first.fitsWindow)
            await settle(host)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "after-sent-image-100-\(appearance.suffix).png"))
            first.keyDown(with: key(24, "=", modifiers: .command))
            XCTAssertEqual(first.magnification, 1.5, accuracy: 0.001)
            XCTAssertTrue(first.performKeyEquivalent(with: key(29, "0", modifiers: .command)))
            XCTAssertEqual(first.magnification, first.fitMagnification, accuracy: 0.001)

            // → shows the message's next image; ← at the first one stays.
            first.keyDown(with: key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)))
            let second = try await canvas(in: host, showing: NSSize(width: 390, height: 844))
            XCTAssertNotIdentical(second, first)
            second.keyDown(with: key(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)))
            // A small image keeps its own size.
            let third = try await canvas(in: host, showing: NSSize(width: 300, height: 200))
            XCTAssertEqual(third.magnification, 1, accuracy: 0.001)
            await settle(host)
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "after-small-image-\(appearance.suffix).png"))
            if appearance == .light {
                let labels = host.accessibilityElements().map(\.label)
                for label in ["Close image preview", "Copy Image", "Save Image…", "Previous image", "Next image",
                              "Zoom Out", "Zoom In"] {
                    XCTAssertTrue(labels.contains(L10n.string(label)), "\(label) in \(labels)")
                }
                XCTAssertTrue(labels.contains("icon.png"), "The image by its name, in \(labels)")
            }
            XCTAssertFalse(closed)
            third.keyDown(with: key(53, "\u{1b}"))
            XCTAssertTrue(closed, "Esc puts the viewer away")
        }
    }

    func testAComposerImageOpensWithItsMarkupAndTheHostPutsItAwayWithEsc() async throws {
        let screenshot = try write(Self.screenshot(), as: "Screen Shot 2026-10-27.png")
        var markedUp = false
        let request = ImageViewerRequest(items: [ImageViewerItem(name: L10n.string("Image"), source: .url(screenshot))],
                                         index: 0, markUp: { markedUp = true })
        let directory = try WindowlessRender.directory("image-viewer-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            let host = WindowlessRender.Host(
                ImageViewerProbe(request: request)
                    .imageViewerHost()
                    .environment(\.colorScheme, appearance.colorScheme)
                    .frame(width: size.width, height: size.height)
                    .background(ParityTheme.canvas),
                size: size, appearance: appearance
            )
            defer { host.close() }
            let canvas = try await canvas(in: host, showing: NSSize(width: 1_440, height: 900))
            try WindowlessRender.writePNG(host.capture().bitmap,
                                          to: directory.appending(path: "after-composer-image-\(appearance.suffix).png"))
            if appearance == .light {
                XCTAssertTrue(host.accessibilityElements().map(\.label).contains(L10n.string("Mark Up")))
                XCTAssertFalse(host.accessibilityElements().map(\.label).contains(L10n.string("Next image")),
                               "One image has no arrows")
            }
            canvas.keyDown(with: key(53, "\u{1b}"))
            await host.settle { Self.canvases(in: host.hosting).isEmpty }
        }
        XCTAssertFalse(markedUp)
    }

    func testASavedImageKeepsItsNameAndTypeAndCopyPutsTheOriginalOnThePasteboard() async throws {
        XCTAssertEqual(ImageViewerModel.fileName(for: "Screen Shot.png", type: .png), "Screen Shot.png")
        XCTAssertEqual(ImageViewerModel.fileName(for: "photo.JPG", type: .jpeg), "photo.JPG")
        XCTAssertEqual(ImageViewerModel.fileName(for: "Image", type: .png), "Image.png")
        XCTAssertEqual(ImageViewerModel.fileName(for: "v1.2", type: .jpeg), "v1.2.jpeg")

        let data = try Self.screenshot(width: 40, height: 30, dpiScale: 1)
        let model = ImageViewerModel(items: [ImageViewerItem(name: "shot", source: .data(data))], index: 0)
        await model.load()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("yardlet-image-viewer-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(model.copy(to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), data)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    // MARK: - Helpers

    private func conversation(images: [TranscriptImageAttachment]) -> some View {
        let entries = [
            TranscriptEntry(content: .user(text: "The settings window clips its last row. Why?", images: images)),
            TranscriptEntry(content: .assistant(text: "The list keeps a fixed height while the rows grow.", isStreaming: false))
        ]
        return TaskConversationView(harness: .claudeCode, workspaceURL: URL(filePath: "/Users/me/yardlet"),
                                    entries: entries, actions: ConversationActions())
            .background(ParityTheme.canvas)
    }

    /// The canvas once it shows an image of `imageSize` points.
    private func canvas<Content: View>(in host: WindowlessRender.Host<Content>, showing imageSize: NSSize) async throws
        -> ImageViewerCanvasView {
        var found: ImageViewerCanvasView?
        await host.settle {
            found = Self.canvases(in: host.hosting).first { $0.documentView?.frame.size == imageSize }
            return found != nil && host.window.firstResponder === found
        }
        await settle(host)
        return try XCTUnwrap(found)
    }

    /// Settles giving the main actor back between passes, so the zoom the canvas reports reaches the
    /// footer before a capture.
    private func settle<Content: View>(_ host: WindowlessRender.Host<Content>) async {
        for _ in 0..<4 {
            host.settle(passes: 1)
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func canvases(in view: NSView) -> [ImageViewerCanvasView] {
        view.subviews.flatMap { ($0 as? ImageViewerCanvasView).map { [$0] } ?? canvases(in: $0) }
    }

    private func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: code)!
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = scratch.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// A Retina screenshot: by default 2,880 by 1,800 pixels at 144 dpi, as macOS saves one, of a
    /// settings window whose small text needs zooming to read.
    static func screenshot(width: Int = 2_880, height: Int = 1_800, dpiScale: CGFloat = 2) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let unit = CGFloat(min(width, height)) / 900
        NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.52, blue: 0.86, alpha: 1),
                   ending: NSColor(calibratedRed: 0.62, green: 0.38, blue: 0.70, alpha: 1))?.draw(in: bounds, angle: 30)
        let window = bounds.insetBy(dx: CGFloat(width) * 0.14, dy: CGFloat(height) * 0.12)
        NSColor(white: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: window, xRadius: 12 * unit, yRadius: 12 * unit).fill()
        NSColor(white: 0.90, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: window.minX, y: window.maxY - 52 * unit, width: window.width, height: 40 * unit)).fill()
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: window.minX + (20 + CGFloat(index) * 22) * unit, y: window.maxY - 32 * unit,
                                        width: 14 * unit, height: 14 * unit)).fill()
        }
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 17 * unit), .foregroundColor: NSColor.black]
        ("General" as NSString).draw(at: NSPoint(x: window.minX + 110 * unit, y: window.maxY - 35 * unit), withAttributes: title)
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11 * unit), .foregroundColor: NSColor.darkGray]
        let rows = ["Appearance: System", "Interface size: Standard", "Follow-up messages: Steer",
                    "Notifications: When a task needs you", "Browser: Ask before opening files outside the task",
                    "Updates: Check automatically"]
        for (index, row) in rows.enumerated() {
            let y = window.maxY - (95 + CGFloat(index) * 48) * unit
            guard y > window.minY + 20 * unit else { break }
            (row as NSString).draw(at: NSPoint(x: window.minX + 40 * unit, y: y), withAttributes: body)
            NSColor(white: 0.86, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: window.minX + 40 * unit, y: y - 13 * unit, width: window.width - 80 * unit, height: unit)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: CGFloat(width) / dpiScale, height: CGFloat(height) / dpiScale)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

/// Opens `request` through the environment, as a thumbnail's click does.
private struct ImageViewerProbe: View {
    let request: ImageViewerRequest
    @Environment(\.openImageViewer) private var openImageViewer

    var body: some View {
        Color.clear.onAppear { openImageViewer(request) }
    }
}
