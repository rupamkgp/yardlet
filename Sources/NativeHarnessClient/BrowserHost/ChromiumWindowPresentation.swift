import Foundation

/// How Chromium's own window (the passkey dialog, a window of the browser host rather than of the
/// panel) reaches the person, who must be able to see it and close it: the page's request waits
/// until someone does. When Yardlet is in front, the host gets Yardlet's activation and the window
/// takes the keyboard (Escape cancels). When Yardlet is not (the agent pressed the button, or the
/// person was elsewhere), the next time Yardlet comes to the front does the same. After that, each
/// time Yardlet comes to the front the window is raised over it without taking the keyboard back.
struct ChromiumWindowPresentation: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        /// Bring the host's windows over Yardlet's, leaving Yardlet active.
        case raise
        /// Hand Yardlet's activation to the host, so the window becomes key.
        case handOver
    }

    private(set) var isShown = false
    private var handedOver = false

    mutating func windowChanged(isShown: Bool, appIsActive: Bool) -> [Step] {
        self.isShown = isShown
        handedOver = false
        return isShown && appIsActive ? appCameToFront() : []
    }

    mutating func appCameToFront() -> [Step] {
        guard isShown else { return [] }
        guard !handedOver else { return [.raise] }
        handedOver = true
        return [.raise, .handOver]
    }
}
