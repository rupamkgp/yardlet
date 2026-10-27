import SwiftUI
import Foundation
import Observation

/// The sidebar's width, which the person sets by dragging the line between the sidebar and the
/// window's content, kept across launches.
///
/// The bounds are the Codex app's (ChatGPT.app `app.asar`, `tb`: at least 240 and at most 520,
/// saved under `sidebar-width`); the Claude app keeps 200 to 420 (`dframe-store`). A sidebar
/// nobody has dragged keeps Yardlet's 240, so it looks as it did. However wide it is set, the
/// window's content keeps one split pane's minimum width (`SplitLayoutMetrics.minimumPaneWidth`),
/// as the Codex app keeps 240 and the Claude app 330 for its content.
enum SidebarWidth {
    static let minimum: CGFloat = 240
    static let maximum: CGFloat = 520
    /// The width before the person drags the line.
    static let standard: CGFloat = ParityTheme.sidebarWidth
    /// What the content beside the sidebar keeps at least.
    static let minimumContentWidth: CGFloat = SplitLayoutMetrics.minimumPaneWidth
    static let defaultsKey = "Yardlet.sidebarWidth"
    /// How far one step of the accessibility adjust action moves the line.
    static let adjustmentStep: CGFloat = 20

    /// `width` within the sidebar's bounds; the standard width for a value that is not a width.
    static func clamped(_ width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return standard }
        return min(maximum, max(minimum, width.rounded()))
    }

    /// The width the sidebar takes in a window `windowWidth` wide: the set width, narrowed so the
    /// content keeps its minimum, never below the sidebar's own minimum. Without a window width
    /// yet, the set width.
    static func fitting(_ width: CGFloat, windowWidth: CGFloat?) -> CGFloat {
        let set = clamped(width)
        guard let windowWidth, windowWidth.isFinite, windowWidth > 0 else { return set }
        // The 1 pt line between the sidebar and the content.
        let room = windowWidth - 1 - minimumContentWidth
        return max(minimum, min(set, room.rounded(.down)))
    }

    /// The width the person last set, or the standard width.
    static func stored(in defaults: UserDefaults = .yardlet) -> CGFloat {
        guard let value = defaults.object(forKey: defaultsKey) as? Double else { return standard }
        return clamped(CGFloat(value))
    }

    /// Keeps `width`, within the bounds, for the next launch.
    static func store(_ width: CGFloat, in defaults: UserDefaults = .yardlet) {
        defaults.set(Double(clamped(width)), forKey: defaultsKey)
    }
}

/// The width the person sets, observed only by the views that size themselves with it (the sidebar's
/// column and the title bar's sidebar part), so dragging the line does not rebuild the whole window.
@MainActor
@Observable
final class SidebarWidthState {
    /// The width set, within `SidebarWidth`'s bounds.
    private(set) var width: CGFloat
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .yardlet) {
        self.defaults = defaults
        width = SidebarWidth.stored(in: defaults)
    }

    /// The width the sidebar takes in a window `windowWidth` wide (`SidebarWidth.fitting`).
    func shown(inWindowWidth windowWidth: CGFloat?) -> CGFloat {
        SidebarWidth.fitting(width, windowWidth: windowWidth)
    }

    /// Follows the line as it is dragged.
    func resize(to proposed: CGFloat) {
        let clamped = SidebarWidth.clamped(proposed)
        if clamped != width { width = clamped }
    }

    /// Keeps the width for the next launch, once the drag ends.
    func commit() {
        SidebarWidth.store(width, in: defaults)
    }
}
