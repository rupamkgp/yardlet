import AppKit
import QuartzCore
import SwiftUI

/// A small live view of a task's browser tab: the frames the host sends for the tab, put into a
/// layer of the rail by the event pipe's queue as the panel's are (`BrowserFrameRouter.route`), and
/// fit into the layer by Core Animation. It sends nothing to the host and draws nothing on the main
/// thread; while the tab paints no frames (no one shows it and the agent left it), the last one stays.
struct BrowserFramePreview: NSViewRepresentable {
    let tab: BrowserTabID

    func makeNSView(context: Context) -> BrowserFramePreviewView {
        let view = BrowserFramePreviewView()
        view.tab = tab
        return view
    }

    func updateNSView(_ view: BrowserFramePreviewView, context: Context) {
        view.tab = tab
    }

    static func dismantleNSView(_ view: BrowserFramePreviewView, coordinator: ()) {
        view.tab = nil
    }
}

final class BrowserFramePreviewView: NSView {
    private let contentLayer = CALayer()
    private lazy var display = BrowserFrameDisplay(layer: contentLayer, sizesLayer: false)
    private var shownTab: BrowserTabID?

    var tab: BrowserTabID? {
        didSet { if tab != oldValue { attach() } }
    }

    /// A frame is on the preview's layer (QA).
    var hasFrame: Bool { contentLayer.contents != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentLayer.contentsGravity = .resizeAspect
        contentLayer.minificationFilter = .linear
        contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(contentLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        display.setScale(window?.backingScaleFactor ?? 2)
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    /// Follows the tab while the view is in a window; away from one it holds no frame.
    private func attach() {
        let target = window == nil ? nil : tab
        guard target != shownTab else { return }
        if let shownTab { MacBrowserHost.shared.stopShowingPreviewFrames(of: shownTab, in: display) }
        display.clear()
        shownTab = target
        if let target { MacBrowserHost.shared.showPreviewFrames(of: target, in: display) }
    }
}
