import AppKit

/// Gives a window its button names back when a scroll left them held.
///
/// AppKit holds back every tooltip in a window while something in it scrolls: each scroll that starts adds one to a
/// count on the window, its end takes one away, and names show only while the count is zero
/// (`-[NSWindow _disableToolTipCreationAndDisplay]`, `_enableToolTipCreationAndDisplay`). Some ends never come. An
/// animated scroll (a SwiftUI `withAnimation` scroll such as the transcript's jump to the latest turn, a mouse wheel's
/// smooth scroll) adds its end only when it reaches its target, so one the person's own scrolling interrupts, or whose
/// scroll view leaves the window first, keeps its one; a list scrolled just before it leaves the window does the same.
/// From then on no `.help` in that window shows its name, however long the pointer rests, until the window closes
/// (2026-10-27: the browser panel's header buttons and the title bar's sidebar button).
///
/// A scroll's own hold ends within a second of its last movement. When the pointer moves over a window whose names
/// have stayed held for longer, with no scrolling since, Yardlet brings the count back to zero; AppKit then shows the
/// name where the pointer rests. Without these AppKit methods it does nothing.
@MainActor
enum WindowTooltipRelease {
    /// How long a window's names stay held, and how long since the person last scrolled, before the hold is taken
    /// as one a scroll never ended. AppKit's scroll animations and its hold after a wheel event end within a second.
    static let longestHold: TimeInterval = 1.5
    static let sinceScrolling: TimeInterval = 1
    private static let namesShowSelector = NSSelectorFromString("_isToolTipCreationAndDisplayEnabled")
    private static let endSelector = NSSelectorFromString("_enableToolTipCreationAndDisplay")
    private static let startSelector = NSSelectorFromString("_disableToolTipCreationAndDisplay")
    private static var monitor: Any?
    private static var lastScroll: TimeInterval = 0
    /// The window whose held names are being watched, and since when.
    private static weak var held: NSWindow?
    private static var heldSince: TimeInterval = 0
    private static var timer: Timer?

    static func start() {
        guard monitor == nil,
              [namesShowSelector, endSelector, startSelector].allSatisfy({ NSWindow.instancesRespond(to: $0) }) else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .scrollWheel]) { event in
            MainActor.assumeIsolated { observe(event) }
            return event
        }
    }

    /// Whether AppKit shows names in `window` now; true where it cannot say.
    static func namesShow(in window: NSWindow) -> Bool {
        guard window.responds(to: namesShowSelector) else { return true }
        typealias Read = @convention(c) (NSWindow, Selector) -> Bool
        return unsafeBitCast(window.method(for: namesShowSelector), to: Read.self)(window, namesShowSelector)
    }

    private static func observe(_ event: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if event.type == .scrollWheel {
            lastScroll = now
            return
        }
        guard let window = event.window, held !== window, !namesShow(in: window) else { return }
        held = window
        heldSince = now
        timer?.invalidate()
        // The default run loop mode: a scroller's knob, dragged in AppKit's own loop, holds names until it lets go.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
    }

    private static func check() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let window = held, window.isVisible, !namesShow(in: window) else { return stopWatching() }
        guard now - heldSince >= longestHold, now - lastScroll >= sinceScrolling else { return }
        release(window)
        stopWatching()
    }

    private static func stopWatching() {
        timer?.invalidate()
        timer = nil
        held = nil
    }

    /// Brings the window's count back to zero. AppKit says only whether the count is zero, and an end with no start
    /// takes it below zero, which holds names too; so the release steps one way until names show, and back and the
    /// other way if they never do.
    private static func release(_ window: NSWindow) {
        for (step, undo) in [(endSelector, startSelector), (startSelector, endSelector)] {
            for _ in 0..<64 {
                _ = window.perform(step)
                if namesShow(in: window) { return }
            }
            for _ in 0..<64 { _ = window.perform(undo) }
        }
    }
}
