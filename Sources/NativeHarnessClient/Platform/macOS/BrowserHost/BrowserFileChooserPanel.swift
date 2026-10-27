import AppKit
import UniformTypeIdentifiers

/// Shows a page's file chooser to the person, over the panel that shows its tab.
@MainActor
protocol BrowserFileChooserPresenting: AnyObject {
    /// The chooser shown now, by its dialog's number.
    var presented: Int? { get }
    /// Opens `dialog` over `view`. `answer` gets the person's files, or nil for Cancel; it is not called when
    /// `dismiss()` takes the chooser away first.
    func present(_ dialog: BrowserFileDialog, over view: NSView, answer: @escaping @MainActor ([String]?) -> Void)
    /// Takes the chooser away unanswered: its tab is no longer shown, or the agent answered it.
    func dismiss()
}

/// The system's open or save panel, as Chrome's chooser, but over the panel that shows the tab and moving with its
/// window (a child window) rather than as a sheet: a sheet holds the whole window, every other task in it included,
/// and a panel off screen could only cancel it. The page's request waits in its tab (`BrowserTab.fileDialog`); this
/// panel goes when the tab stops showing and opens again when it shows again.
@MainActor
final class BrowserFileChooserPanel: BrowserFileChooserPresenting {
    private var panel: NSSavePanel?
    private(set) var presented: Int?

    func present(_ dialog: BrowserFileDialog, over view: NSView, answer: @escaping @MainActor ([String]?) -> Void) {
        guard presented != dialog.id, let window = view.window else { return }
        dismiss()
        let panel: NSSavePanel
        if dialog.mode == .save {
            panel = NSSavePanel()
            panel.nameFieldStringValue = (dialog.defaultPath as NSString).lastPathComponent
        } else {
            let open = NSOpenPanel()
            open.canChooseFiles = dialog.mode != .openFolder
            open.canChooseDirectories = dialog.mode == .openFolder
            open.allowsMultipleSelection = dialog.mode == .openMultiple
            panel = open
        }
        if !dialog.title.isEmpty { panel.message = dialog.title }
        let types = dialog.extensions.compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty, dialog.mode != .openFolder { panel.allowedContentTypes = types }
        self.panel = panel
        presented = dialog.id
        panel.begin { [weak self, weak panel] response in
            MainActor.assumeIsolated {
                // One taken away by `dismiss()` is no longer this presenter's, and answers nothing.
                guard let self, let panel, self.panel === panel else { return }
                self.panel = nil
                self.presented = nil
                guard response == .OK else { return answer(nil) }
                answer(((panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] } ?? []).map { $0.path(percentEncoded: false) })
            }
        }
        window.addChildWindow(panel, ordered: .above)
        // Over the panel's page, near its top, as Chrome's chooser hangs from the top of the browser window; kept on
        // the window's screen.
        let page = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: page.midX - panel.frame.width / 2, y: page.maxY - panel.frame.height - 12)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX), screen.maxX - panel.frame.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(origin)
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        presented = nil
        panel.parent?.removeChildWindow(panel)
        panel.cancel(nil)
    }
}
