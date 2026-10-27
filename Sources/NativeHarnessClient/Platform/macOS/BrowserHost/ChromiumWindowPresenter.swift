import AppKit

/// Shows Chromium's own windows (the passkey dialog, a site's sign-in window) where the person sees their tab, as
/// Chrome draws a tab's dialog over the tab: each window over the panel that shows its tab on screen, just above that
/// panel's window (`presentChromiumWindows`). A window over a tab no panel shows waits past the screens; one whose tab
/// is not known (the print dialog) stays where it is, above Yardlet's front window. Placing it again whenever Yardlet
/// comes to the front, one of its windows becomes key or is clicked, or a panel moves keeps the window over its tab:
/// a click in Yardlet's window brings that window in front of every other app's, the host's too. The window is never
/// held over other apps' windows (no floating level). `ChromiumWindowPresentation` hands Yardlet's activation over
/// once a window is placed.
@MainActor
final class ChromiumWindowPresenter {
    private final class Panel {
        weak var view: BrowserHostView?
        init(_ view: BrowserHostView) { self.view = view }
    }

    /// Chromium's windows now, with their tabs (`BrowserHostClient.chromiumWindows`).
    var windows: () -> [BrowserChromiumWindow] = { [] }
    var send: (BrowserHostCommand) -> Void = { _ in }
    /// The browser host's process, which takes Yardlet's activation.
    var hostProcessID: () -> Int32? = { nil }
    private var panels: [BrowserTabID: Panel] = [:]
    private var presentation = ChromiumWindowPresentation()
    private var placed: [BrowserChromiumWindowPlacement] = []
    /// The placements last sent, and how many times they were.
    var placements: [BrowserChromiumWindowPlacement] { placed }
    private(set) var presentCount = 0
    private var observers: [any NSObjectProtocol] = []
    private var clickMonitor: Any?

    /// A panel shows the tab now.
    func panelShows(_ tab: BrowserTabID, in view: BrowserHostView) {
        panels[tab] = Panel(view)
        present()
    }

    func panelStopsShowing(_ tab: BrowserTabID, in view: BrowserHostView) {
        guard panels[tab]?.view === view || panels[tab]?.view == nil else { return }
        panels[tab] = nil
        present()
    }

    /// Where each window goes now; sent whenever something may have moved it behind or away from its tab.
    func present() {
        let windows = windows()
        let front = NSApp.orderedWindows.first { $0.isVisible && !($0 is NSPanel) }
        let placements = windows.compactMap { window -> BrowserChromiumWindowPlacement? in
            guard let tab = window.tab else { return BrowserChromiumWindowPlacement(window: window.id, above: front?.windowNumber) }
            guard let view = panels[tab]?.view, view.tabID == tab, !view.isOccluded, let panelWindow = view.window else { return nil }
            let rect = panelWindow.convertToScreen(view.convert(view.bounds, to: nil))
            return BrowserChromiumWindowPlacement(
                window: window.id, frame: BrowserRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                above: panelWindow.windowNumber)
        }
        if !windows.isEmpty || !placed.isEmpty {
            send(.presentChromiumWindows(placements: placements))
            presentCount += 1
        }
        let before = Set(placed.map(\.window)), now = Set(placements.map(\.window))
        placed = placements
        // A newly placed window takes the keyboard when Yardlet is in front; once none is placed, nothing to hand over.
        if !now.isSubset(of: before) || (now.isEmpty && !before.isEmpty) {
            perform(presentation.windowChanged(isShown: !now.isEmpty, appIsActive: NSApp.isActive))
        }
        watch(!windows.isEmpty)
    }

    /// A click in one of Yardlet's windows, which brought it in front of the host's (the event monitor's call).
    func yardletWasClicked() {
        // After AppKit has ordered the clicked window in front.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.present() } }
    }

    private func perform(_ steps: [ChromiumWindowPresentation.Step]) {
        for step in steps {
            switch step {
            case .raise:
                break  // `present` placed and raised the windows.
            case .handOver:
                guard !QABackground.isOn, let pid = hostProcessID() else { continue }
                NSRunningApplication(processIdentifier: pid)?.activate(from: .current, options: [])
            }
        }
    }

    /// While a window is open: what puts Yardlet's windows in front of it, or moves the panel under it.
    private func watch(_ isOn: Bool) {
        guard isOn != !observers.isEmpty else { return }
        guard isOn else {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
            return
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.present()
                self.perform(self.presentation.appCameToFront())
            }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didMoveNotification,
                     NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.present() }
            })
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.yardletWasClicked() }
            return event
        }
    }
}
