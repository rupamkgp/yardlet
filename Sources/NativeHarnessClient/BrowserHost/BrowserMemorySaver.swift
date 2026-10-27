import Foundation

/// Chrome's Memory Saver for the tasks' browser tabs (docs/BROWSER_HOST.md §3 "Memory saver"): a tab no one has seen
/// for a while is discarded, keeping its address, title, icon, place and history, and its page loads again when the
/// tab is shown or the agent uses it. The times and the pages kept are Chrome's (Chromium's MemorySaverModePolicy,
/// DiscardEligibilityPolicy and UrgentPageDiscardingPolicy); the host checks what only the engine knows
/// (`BrowserHostCommand.discard`).
enum BrowserMemorySaver {
    struct Timing: Equatable, Sendable {
        /// Chrome's Balanced mode, the one it recommends: a tab hidden this long is discarded (kMedium, 4 hours).
        var hiddenBeforeDiscard: Duration = .seconds(4 * 3600)
        /// While the Mac's memory is critical Chrome discards one tab at a time this often (its urgent discarding's
        /// repeating timer), never one hidden more recently than `urgentProtection` (kNonVisiblePagesUrgentProtectionTime).
        var urgentInterval: Duration = .seconds(5)
        var urgentProtection: Duration = .seconds(10 * 60)
        /// How often Yardlet looks for tabs past `hiddenBeforeDiscard`.
        var sweepInterval: Duration = .seconds(60)
        /// A tab the host kept (its page was one Chrome keeps) is not asked about again before this.
        var retryAfter: Duration = .seconds(30 * 60)
    }

    /// How many tabs one sweep asks the host about.
    static let discardsPerSweep = 4
    /// A page's title or icon that changes while it is hidden, later than this after its document began, is the
    /// page working in the background (a chat's unread count), which Chrome keeps.
    static let backgroundActivityGrace: Duration = .seconds(5)
    /// How long the agent's tools wait for a discarded page to load again before they go on.
    static let restoreWait: Duration = .seconds(30)

    /// What Yardlet knows of one hidden tab.
    struct Candidate: Equatable {
        var tab: BrowserTabID
        /// How long the tab has been hidden, not counting the Mac's sleep (Chrome's elapsed_not_suspended).
        var hidden: Duration
        /// A reason Chrome keeps the page whatever the memory: shown, in use, asking the person, typed into …
        var isProtected: Bool
        /// A reason Chrome keeps the page only from the discards that are not urgent: it worked in the background.
        var isProtectedFromProactive: Bool
        /// The host kept the tab within `Timing.retryAfter`.
        var refusedRecently: Bool
    }

    /// The tabs to ask the host to discard now, longest hidden first: when memory is critical one tab hidden past
    /// `urgentProtection`, else up to `discardsPerSweep` hidden past `hiddenBeforeDiscard`.
    static func picks(_ candidates: [Candidate], urgent: Bool, timing: Timing = Timing()) -> [BrowserTabID] {
        let eligible = candidates.filter { candidate in
            !candidate.isProtected && !candidate.refusedRecently
                && (urgent ? candidate.hidden >= timing.urgentProtection
                    : candidate.hidden >= timing.hiddenBeforeDiscard && !candidate.isProtectedFromProactive)
        }
        let order = eligible.sorted { $0.hidden > $1.hidden }.map(\.tab)
        return Array(order.prefix(urgent ? 1 : discardsPerSweep))
    }

    /// Chrome keeps pages that are not on the web: an empty address, about:, file:, the PDF viewer … (kNotWebOrInternal
    /// and kInvalidURL: Chrome discards http, https, data and its own chrome: pages, which Yardlet's tabs never show).
    static func isWebPage(_ address: String?) -> Bool {
        guard let address, let scheme = URL(string: address)?.scheme?.lowercased() else { return false }
        return ["http", "https", "data"].contains(scheme)
    }
}
