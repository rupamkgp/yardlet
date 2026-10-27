import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class CommonComposerRenderingTests: XCTestCase {
    func testSharedOptionMenuRendersActualNativeChoicesInBothAppearances() throws {
        let selector = ProviderCapabilitySelector(id: "permissionMode", name: "Permission mode", description: nil,
            category: "mode", currentValue: "manual", choices: [
                .init(value: "manual", name: "Manual", description: nil),
                .init(value: "plan", name: "Plan", description: "The plan mode this harness provides"),
                .init(value: "acceptEdits", name: "Accept edits automatically", description: nil),
                .init(value: "dontAsk", name: "Don't ask", description: nil)
            ])
        let directory = try WindowlessRender.directory("common-composer-qa")
        for appearance in [ColorScheme.light, .dark] {
            let view = ComposerProviderOptionMenu(selector: selector, isEnabled: true,
                onSelect: { _, _ in }, onDismiss: {})
                .frame(width: 264).environment(\.colorScheme, appearance)
            let image = try WindowlessRender.image(view)
            XCTAssertEqual(image.width, 528)
            XCTAssertGreaterThan(image.height, 200)
            let bitmap = NSBitmapImageRep(cgImage: image)
            XCTAssertTrue(WindowlessRender.drawsContent(bitmap, step: 5, from: 10))
            try WindowlessRender.writePNG(bitmap,
                to: directory.appending(path: appearance == .dark ? "menu-dark.png" : "menu-light.png"))
        }
    }

    func testNestedProviderControlsWrapWithoutClippingAtNarrowComposerWidth() throws {
        func view(_ width: CGFloat) -> some View {
            ControlRowLayout(pinsTrailingActions: true) {
                ControlRowLayout {
                    ParityComposerControl(title: "Long provider model name", showsChevron: true)
                    ParityComposerControl(title: "Provider work mode", showsChevron: true)
                    ParityComposerControl(title: "Provider permission mode", showsChevron: true)
                }
                Image(systemName: "arrow.up.circle.fill").frame(width: 30, height: 30)
            }
            .frame(width: width).background(ParityTheme.input)
        }
        let narrowImage = try WindowlessRender.image(view(280)), wideImage = try WindowlessRender.image(view(740))
        XCTAssertEqual(narrowImage.width, 560)
        XCTAssertGreaterThan(narrowImage.height, wideImage.height,
            "Nested wrapping height must be reserved before the send control is placed")
    }
}
