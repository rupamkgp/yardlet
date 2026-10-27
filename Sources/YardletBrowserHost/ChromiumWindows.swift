import AppKit
import Foundation

/// Windows Chromium opens in the host on its own: the passkey dialog (a phone's QR code, a security
/// key and its PIN), the sign-in window for a site's HTTP authentication, and the system's print dialog.
/// The host never activates for the windowless pages (`.prohibited`), so such a
/// window would sit over Yardlet without keyboard focus, and a click on it could not make it key.
/// While one is on screen the host may be activated: it tells Yardlet (`chromiumWindow`, with the
/// windows' titles and kinds), which hands its activation over when it is the active app or the next time it
/// is, and the window becomes key. Yardlet coming to the front again raises the windows over its own
/// (`raise`); the agent's tools can close them (`close`). When the last one goes, the host hands
/// activation back to Yardlet and is not activatable again.
@MainActor
final class ChromiumWindows {
    private let send: ([String: Any]) -> Void
    private var isShowing = false
    /// The titles and kinds last told to Yardlet.
    private var told: [String] = []
    private var observers: [any NSObjectProtocol] = []
    private var timer: Timer?

    init(send: @escaping ([String: Any]) -> Void) {
        self.send = send
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // A closing window is still in the list; look once it has gone.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.update() } }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.focus() }
        })
        // A window Chromium orders in behind other apps' windows posts none of the notifications above
        // (it is not main, and its occlusion stays "not visible"), so the host also looks once a
        // second, with room for the system to batch the wake-up with others.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Chromium's windows ordered in now (the host has no other windows).
    private var shown: [NSWindow] {
        NSApp.windows.filter(\.isVisible)
    }

    /// A QA run (YARDLET_QA_BACKGROUND, inherited from the QA app): Chromium's windows open past every
    /// screen and the host never becomes activatable, so the person using the Mac never sees or types
    /// into them.
    private let isQABackground = ProcessInfo.processInfo.environment["YARDLET_QA_BACKGROUND"] == "1"

    /// What a window of Chromium's own is, for the agent's tools: Views draws the passkey dialog and the sign-in
    /// window for HTTP authentication, which Chromium titles with its own "Sign in" (IDS_LOGIN_DIALOG_TITLE; the
    /// host ships its en and ko locales). The print dialog is AppKit's, run modal (`NSPrintPanel`).
    static func kind(of window: NSWindow) -> String {
        let className = NSStringFromClass(type(of: window))
        if className.contains("NativeWidgetMac") {
            return ["Sign in", "로그인"].contains(window.title) ? "signIn" : "passkey"
        }
        return NSApp.modalWindow != nil || className.localizedCaseInsensitiveContains("print") ? "print" : "other"
    }

    private func update() {
        let showing = !shown.isEmpty
        if isQABackground {
            let screens = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
            for window in shown where window.frame.intersects(screens) || window.alphaValue != 0 {
                window.setFrameOrigin(NSPoint(x: screens.minX - window.frame.width - 4000,
                                              y: screens.minY - window.frame.height - 4000))
                window.alphaValue = 0
                window.ignoresMouseEvents = true
            }
        }
        let titles = shown.map(\.title), kinds = shown.map(Self.kind(of:))
        // Another window in place of one (the passkey sheet's next step, a sign-in after a passkey) is told too.
        if showing, isShowing, titles + kinds != told {
            told = titles + kinds
            send(["chromiumWindow": ["isShown": true, "titles": titles, "kinds": kinds]])
        }
        guard showing != isShowing else { return }
        isShowing = showing
        told = showing ? titles + kinds : []
        if isQABackground {
            let window: [String: Any] = showing ? ["isShown": true, "titles": titles, "kinds": kinds] : ["isShown": false]
            send(["chromiumWindow": window])
            return
        }
        if showing {
            NSApp.setActivationPolicy(.accessory)
            send(["chromiumWindow": ["isShown": true, "titles": titles, "kinds": kinds]])
            if NSApp.isActive { focus() }
        } else {
            send(["chromiumWindow": ["isShown": false]])
            if NSApp.isActive, let yardlet = NSRunningApplication(processIdentifier: getppid()) {
                yardlet.activate(from: .current, options: [])
            }
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    /// Over the windows of the app in front (Yardlet), without taking the keyboard from it.
    func raise() {
        guard !isQABackground else { return }
        for window in shown { window.orderFrontRegardless() }
    }

    /// Escape, as a person would press it: Chromium's passkey dialog cancels and the page's request
    /// ends with NotAllowedError (its "Close" on a sheet that says no passkey is available does the
    /// same); the sign-in window and the print dialog cancel. A window still open half a second later is closed.
    func close() {
        for window in shown {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let escape = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { continue }
                window.sendEvent(escape)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { for window in self.shown { window.performClose(nil) } }
        }
    }

    /// The newest Chromium window takes the keyboard (a security key's PIN, Escape to cancel).
    private func focus() {
        guard isShowing, !isQABackground, let window = shown.last else { return }
        window.makeKeyAndOrderFront(nil)
    }
}
