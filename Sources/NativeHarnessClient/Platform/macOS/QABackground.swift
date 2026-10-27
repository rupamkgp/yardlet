import AppKit

/// A QA run (`scripts/browser-host-qa/qa-launch.sh` sets YARDLET_QA_BACKGROUND=1) stays out of the way of
/// the person using the Mac: no Dock icon, menu bar or ⌘Tab entry, never the active app, and its windows
/// past every screen, so none can be taken for Yardlet, clicked or typed into. Before 2026-10-23 its
/// window sat on screen as "Yardlet" while the QA drove its browser. The browser host follows the same
/// variable for Chromium's own windows (`ChromiumWindows`).
@MainActor
enum QABackground {
    nonisolated static let isOn = ProcessInfo.processInfo.environment["YARDLET_QA_BACKGROUND"] == "1"
    /// The performance run (`run-perf.sh`) measures frames on a display, so its window stays on the screen
    /// it picks; it is still never active.
    private static let measuresOnScreen = CommandLine.arguments.contains { $0.hasPrefix("--ui-fixture-browser-perf=") }
    private static var observer: (any NSObjectProtocol)?

    static func start() {
        NSApp.setActivationPolicy(.accessory)
        guard !measuresOnScreen else { return }
        DispatchQueue.main.async { NSApp.windows.forEach(moveOffScreen) }
        // A window ordered in later (another Yardlet window, a sheet's parent) changes its occlusion.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.windows.forEach(moveOffScreen) }
        }
    }

    /// Below and left of every screen, and clear and click-through, since AppKit keeps a corner of a
    /// titled window on a screen. Pages still paint there (the QA passes
    /// `--ui-fixture-browser-ignore-occlusion`), and the checks capture the views, not the screen.
    static func moveOffScreen(_ window: NSWindow) {
        guard window.isVisible, window.sheetParent == nil else { return }
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        window.collectionBehavior.formUnion([.transient, .ignoresCycle])
        let screens = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let origin = NSPoint(x: screens.minX - window.frame.width - 4000, y: screens.minY - window.frame.height - 4000)
        guard window.frame.origin != origin else { return }
        window.setFrameOrigin(origin)
    }
}
