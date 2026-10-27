import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class InlineImageRenderingTests: XCTestCase {
    /// An inline image whose bytes do not decode keeps the compact name chip (one that decodes shows
    /// as a thumbnail, `ComposerImageChipTests`).
    func testRestoredImageUsesTheActualCompactChipInBothAppearances() async throws {
        let url = try XCTUnwrap(InlineImageInput.url(mimeType: "image/png", base64: Data([0x89, 0x50, 0x4e, 0x47]).base64EncodedString()))
        let directory = try WindowlessRender.directory("claude-image-edit-qa")
        for appearance in WindowlessRender.Appearance.allCases {
            TranscriptImageThumbnails.shared.discardCachedPreview(for: url)
            // Not read beforehand, and drawn in a window: the chip's own task finds that the bytes do
            // not decode, where `ImageRenderer` runs no task and draws whatever the cache holds.
            let host = WindowlessRender.Host(
                ComposerInputChip(input: .image(url, detail: .auto), onRemove: {})
                    .fixedSize().padding(12).background(ParityTheme.input)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(ParityTheme.canvas)
                    .environment(\.colorScheme, appearance.colorScheme),
                size: NSSize(width: 200, height: 72), appearance: appearance
            )
            defer { host.close() }
            // The name chip is 24 points tall, the thumbnail tile 48.
            await host.settle { host.hosting.fittingSize.height == 48 }
            XCTAssertLessThan(host.hosting.fittingSize.width, 150)
            let capture = try host.capture()
            try WindowlessRender.writePNG(capture.bitmap, to:
                directory.appending(path: "chip-\(appearance.suffix).png"))
        }
    }
}
