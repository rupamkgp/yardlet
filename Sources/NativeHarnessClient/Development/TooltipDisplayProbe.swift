#if DEBUG
import AppKit
import ObjectiveC

/// AppKit's own path from a resting pointer to a shown name, run in a QA app that never has the pointer.
/// SwiftUI answers `.help` through AppKit's dynamic tooltips (`NSViewDynamicToolTipManager`, the owner
/// of the hosting view's tooltip tracking area): once the pointer enters, the manager polls where it
/// is, asks for the name there, and hands it to `NSToolTipManager`, which shows it after its delay.
/// The manager shows names only while the window does (`-[NSWindow _showToolTip]`: the app is active)
/// and AppKit holds none back in it (`WindowTooltipRelease`). The probe reads the pointer at a point it
/// sets (`NSEvent.mouseLocation`, the window's `mouseLocationOutsideOfEventStream`, the window under
/// it), takes the window as one of an active app, and records each step without putting the tooltip
/// window on screen; everything else is AppKit's own reading.
@MainActor
enum TooltipDisplayProbe {
    struct Step { let time: Double; let name: String; let stack: [String] }
    private(set) static var steps: [Step] = []
    private static var started = Date()
    private static var installed = false
    /// The pointer, in `window`'s coordinates; nil leaves AppKit's own readings.
    static var point: NSPoint?
    static weak var window: NSWindow?
    /// Steps worth their call stack: what stops or starts the wait again.
    private static let traced: Set<String> = ["_restartMovementTracking", "_abortAndRestartTracking:",
                                               "_cancelCurrentToolTipWindowImmediately:", "_viewVisibleBoundsChanged",
                                               "_removeAllTrackingRects", "abortToolTip", "windowChangedKeyState",
                                               "detatchFromView", "_setupForWindow:"]

    private static func note(_ name: String) {
        let base = name.split(separator: " ").first.map(String.init) ?? name
        let stack = traced.contains(base) && point != nil ? Array(Thread.callStackSymbols.dropFirst(2).prefix(18)) : []
        steps.append(Step(time: Date().timeIntervalSince(started), name: name, stack: stack))
    }

    private static func replace<Block>(_ cls: AnyClass, _ name: String, _ make: (IMP, Selector) -> Block) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector) else { return note("missing \(name)") }
        method_setImplementation(method, imp_implementationWithBlock(make(method_getImplementation(method), selector)))
    }

    private static func void(_ cls: AnyClass, _ name: String, callThrough: Bool = true) {
        replace(cls, name) { imp, selector in
            let original = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> Void).self)
            let block: @convention(block) (AnyObject) -> Void = { me in
                MainActor.assumeIsolated { note(name) }
                if callThrough { original(me, selector) }
            }
            return block as AnyObject
        }
    }

    private static func object(_ cls: AnyClass, _ name: String, callThrough: Bool = true) {
        replace(cls, name) { imp, selector in
            let original = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, AnyObject?) -> Void).self)
            let block: @convention(block) (AnyObject, AnyObject?) -> Void = { me, argument in
                MainActor.assumeIsolated { note("\(name) \(argument.map { String(cString: object_getClassName($0)) } ?? "nil")") }
                if callThrough { original(me, selector, argument) }
            }
            return block as AnyObject
        }
    }

    private static func flag(_ cls: AnyClass, _ name: String) {
        replace(cls, name) { imp, selector in
            let original = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, Bool) -> Void).self)
            let block: @convention(block) (AnyObject, Bool) -> Void = { me, value in
                MainActor.assumeIsolated { note("\(name) \(value)") }
                original(me, selector, value)
            }
            return block as AnyObject
        }
    }

    /// A yes-or-no answer, logged; `forced` replaces it while the probe holds the pointer.
    private static func answer(_ cls: AnyClass, _ name: String, forced: Bool? = nil) {
        replace(cls, name) { imp, selector in
            let original = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            let block: @convention(block) (AnyObject) -> Bool = { me in
                let real = original(me, selector)
                return MainActor.assumeIsolated {
                    let value = point == nil ? real : forced ?? real
                    note("\(name) -> \(real)\(value != real ? " (taken as \(value))" : "")")
                    return value
                }
            }
            return block as AnyObject
        }
    }

    static func install() {
        guard !installed, let dynamic = NSClassFromString("NSViewDynamicToolTipManager"),
              let manager = NSClassFromString("NSToolTipManager") else { return }
        installed = true
        for name in ["_restartMovementTracking", "_cancelMovementTrackingTimer", "abortToolTip", "_viewVisibleBoundsChanged",
                     "_removeAllTrackingRects", "_removeToolTipTrackingRectIfNecessary", "windowChangedKeyState",
                     "detatchFromView"] {
            void(dynamic, name)
        }
        for name in ["mouseEntered:", "mouseExited:", "_setupForWindow:", "_appActivationChanged:"] { object(dynamic, name) }
        flag(dynamic, "_abortAndRestartTracking:")
        flag(dynamic, "_cancelCurrentToolTipWindowImmediately:")
        answer(dynamic, "_canShowToolTip")
        answer(dynamic, "_shouldRestartMovementTracking")
        // The QA app is never active, which alone keeps names from showing.
        answer(NSWindow.self, "_showToolTip", forced: true)
        void(manager, "abortToolTip")
        object(manager, "displayToolTip:", callThrough: false)

        // The pointer's readings.
        replace(object_getClass(NSEvent.self)!, "mouseLocation") { imp, selector in
            let original = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> NSPoint).self)
            let block: @convention(block) (AnyObject) -> NSPoint = { me in
                MainActor.assumeIsolated {
                    guard let point, let window else { return original(me, selector) }
                    return window.convertPoint(toScreen: point)
                }
            }
            return block as AnyObject
        }
        replace(NSWindow.self, "mouseLocationOutsideOfEventStream") { imp, selector in
            let original = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector) -> NSPoint).self)
            let block: @convention(block) (AnyObject) -> NSPoint = { me in
                MainActor.assumeIsolated {
                    guard let point, me === window else { return original(me, selector) }
                    return point
                }
            }
            return block as AnyObject
        }
        replace(object_getClass(NSWindow.self)!, "windowNumberAtPoint:belowWindowWithWindowNumber:") { imp, selector in
            let original = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, NSPoint, Int) -> Int).self)
            let block: @convention(block) (AnyObject, NSPoint, Int) -> Int = { me, at, below in
                MainActor.assumeIsolated {
                    guard point != nil, let window else { return original(me, selector, at, below) }
                    return window.windowNumber
                }
            }
            return block as AnyObject
        }
    }

    /// An entered or exited event for `area`, which an event names by its address.
    private static func crossing(_ type: NSEvent.EventType, _ area: NSTrackingArea, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0,
                               trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil)
    }

    /// Brings the pointer to `point` (window coordinates) over the hosting view whose tooltip owner is `owner`, and
    /// rests it there for up to `wait`: whether AppKit came to show a name, and the steps on the way.
    static func rest(at point: NSPoint, in window: NSWindow, owner: NSObject, wait: Duration) async -> (shown: Bool, steps: [Step]) {
        install()
        self.window = window
        guard let view = owner.perform(NSSelectorFromString("view"))?.takeUnretainedValue() as? NSView else {
            return (false, [])
        }
        // The pointer arriving, as the hosting view sees it: SwiftUI's hover (a button's hover fill) and pointer style.
        let own = view.trackingAreas.filter { ($0.owner as AnyObject?) === view }
        for area in own {
            if let entered = crossing(.mouseEntered, area, at: point, in: window) { view.mouseEntered(with: entered) }
        }
        for offset in [CGFloat(6), 3, 0] {
            let location = NSPoint(x: point.x - offset, y: point.y)
            self.point = location
            if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                view.mouseMoved(with: moved)
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
        steps = []
        started = Date()
        // Into the manager's own area, which marks the pointer inside, and resting.
        let tooltipArea = view.trackingAreas.first { ($0.owner as AnyObject?) === owner }
        if let tooltipArea, let entered = crossing(.mouseEntered, tooltipArea, at: point, in: window) {
            _ = owner.perform(NSSelectorFromString("mouseEntered:"), with: entered)
        }
        _ = owner.perform(NSSelectorFromString("_restartMovementTracking"))
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline, !steps.contains(where: { $0.name.hasPrefix("displayToolTip:") }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let result = (shown: steps.contains { $0.name.hasPrefix("displayToolTip:") }, steps: steps)
        self.point = nil
        if let tooltipArea, let exited = crossing(.mouseExited, tooltipArea, at: .zero, in: window) {
            _ = owner.perform(NSSelectorFromString("mouseExited:"), with: exited)
        }
        for area in own {
            if let exited = crossing(.mouseExited, area, at: .zero, in: window) { view.mouseExited(with: exited) }
        }
        _ = (NSClassFromString("NSToolTipManager") as AnyObject).perform(NSSelectorFromString("sharedToolTipManager"))?
            .takeUnretainedValue().perform(NSSelectorFromString("abortToolTip"))
        try? await Task.sleep(for: .milliseconds(100))
        return result
    }
}
#endif
