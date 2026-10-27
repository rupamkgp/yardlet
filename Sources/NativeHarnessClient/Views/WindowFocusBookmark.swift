import AppKit

/// A sheet may replace the window's shared field editor. Keep its owning control and selection,
/// rather than restoring whichever text field happens to use that editor after dismissal.
@MainActor
final class WindowFocusBookmark {
    private weak var window: NSWindow?
    private weak var control: NSView?
    private let text: String?
    private let selection: NSRange?

    init?(window: NSWindow?) {
        guard let window, let responder = window.firstResponder as? NSView else { return nil }
        self.window = window
        if let editor = responder as? NSTextView {
            control = editor.isFieldEditor ? editor.delegate as? NSView : editor
            text = editor.string
            selection = editor.selectedRange()
        } else {
            control = responder
            text = nil
            selection = nil
        }
        guard control != nil else { return nil }
    }

    @discardableResult
    func restore() -> Bool {
        guard let window, let control, control.window === window,
              !control.isHiddenOrHasHiddenAncestor,
              window.makeFirstResponder(control) else { return false }
        if let editor = window.firstResponder as? NSTextView, let selection {
            let length = editor.string.utf16.count
            editor.setSelectedRange(editor.string == text && NSMaxRange(selection) <= length
                ? selection : NSRange(location: length, length: 0))
        }
        return true
    }
}
