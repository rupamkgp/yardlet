import AppKit

/// `ApplicationAttention` for the running app: `NSApp`'s Dock tile and activation.
@MainActor
final class MacApplicationAttention: ApplicationAttention {
    var isActive: Bool { NSApp.isActive }

    func setDockBadge(_ label: String?) {
        NSApp.dockTile.badgeLabel = label
    }

    func requestAttention() {
        guard !QABackground.isOn else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    /// A notification click or the menu bar menu: Yardlet comes forward with its main window, opened
    /// again if it was closed.
    func bringForward() {
        guard !QABackground.isOn else { return }
        NSApp.activate(ignoringOtherApps: true)
        if !TaskResourceUsageWindow.bringMainWindowForward() {
            TaskResourceUsageWindow.reopenMainWindow?()
        }
    }
}
