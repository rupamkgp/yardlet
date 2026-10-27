import Foundation

/// The app outside its window: the Dock icon's badge, one bounce, and coming forward. Injected so
/// tests never touch the real Dock or bring the test runner forward.
@MainActor
protocol ApplicationAttention: AnyObject {
    /// Yardlet is the frontmost app.
    var isActive: Bool { get }
    /// The Dock icon's badge; nil clears it.
    func setDockBadge(_ label: String?)
    /// Bounces the Dock icon once (`NSApp.requestUserAttention(.informationalRequest)`).
    func requestAttention()
    /// Brings Yardlet and its main window forward, out of the Dock if it was minimized.
    func bringForward()
}

/// The Dock's part in task attention. The badge counts the tasks that need the person, as the
/// Claude app's Dock badge counts sessions blocked on the user and the Codex app sets its badge
/// count; it shows only while macOS allows Yardlet badges. A new approval that arrives while
/// Yardlet is behind other apps bounces the icon once, as the Claude app's `requestUserAttention`
/// does, and never again for the same request.
@MainActor
final class DockAttention {
    private let application: any ApplicationAttention
    private(set) var badgesAllowed = false
    private(set) var count = 0
    private var shownLabel: String?
    /// Approvals already announced, as "<task>:<request>".
    private var announcedApprovals = Set<String>()

    init(application: any ApplicationAttention) {
        self.application = application
    }

    func setBadgesAllowed(_ allowed: Bool) {
        badgesAllowed = allowed
        render()
    }

    func show(count: Int) {
        self.count = max(0, count)
        render()
    }

    /// Bounces the Dock icon for an approval it has not announced, when Yardlet is not
    /// frontmost. An approval that arrived while Yardlet was in front is announced already.
    /// Returns whether it bounced.
    @discardableResult
    func announceApproval(_ requestID: String, in sessionID: UUID) -> Bool {
        guard announcedApprovals.insert(Self.key(requestID, sessionID)).inserted,
              !application.isActive else { return false }
        application.requestAttention()
        return true
    }

    /// Forgets a task's announced approvals once it no longer waits, so a provider that reuses
    /// a request ID in a later turn is announced again.
    func forgetApprovals(in sessionID: UUID) {
        let prefix = "\(sessionID.uuidString):"
        announcedApprovals = announcedApprovals.filter { !$0.hasPrefix(prefix) }
    }

    private static func key(_ requestID: String, _ sessionID: UUID) -> String {
        "\(sessionID.uuidString):\(requestID)"
    }

    private func render() {
        let label = badgesAllowed && count > 0 ? String(count) : nil
        guard label != shownLabel else { return }
        shownLabel = label
        application.setDockBadge(label)
    }
}
