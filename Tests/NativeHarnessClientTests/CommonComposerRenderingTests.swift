import AppKit
import SwiftUI
import XCTest
@testable import NativeHarnessClient

@MainActor
final class CommonComposerRenderingTests: XCTestCase {
    func testSharedOptionMenuRendersActualNativeChoicesInBothAppearances() throws {
        let selector = ProviderCapabilitySelector(id: "permissionMode", name: "권한 모드", description: nil,
            category: "mode", currentValue: "manual", choices: [
                .init(value: "manual", name: "수동", description: nil),
                .init(value: "plan", name: "계획", description: "이 하네스가 제공하는 계획 모드"),
                .init(value: "acceptEdits", name: "편집 자동 허용", description: nil),
                .init(value: "dontAsk", name: "묻지 않음", description: nil)
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
