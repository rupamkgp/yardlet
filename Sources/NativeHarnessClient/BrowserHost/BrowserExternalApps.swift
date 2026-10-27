import Foundation

/// What opens other apps' addresses (mailto:, tel:, zoommtg:, slack: …) on this platform: LaunchServices on
/// macOS (`MacBrowserHost`); nothing in tests and on a platform without it (`NoExternalApps`).
@MainActor
protocol BrowserExternalApps: AnyObject {
    /// The app that opens `url`, by the name Chrome shows in "Open ‹app›?"; nil when none does.
    func appName(for url: URL) -> String?
    func open(_ url: URL)
}

@MainActor
final class NoExternalApps: BrowserExternalApps {
    func appName(for url: URL) -> String? { nil }
    func open(_ url: URL) {}
}

/// Another app's address a page asked to open, waiting for the person's answer in the tab's panel.
struct BrowserExternalAppQuestion: Equatable, Sendable {
    var url: String
    /// Who asked, as Chrome names it: the requesting document's origin, empty when it has none.
    var origin: String
    /// The app that opens it ("FaceTime").
    var app: String
    /// Chrome's "Always allow ‹site› to open links of this type in the associated app" is offered.
    var offersAlwaysAllow: Bool
    /// The agent's input led to it. The answer is the person's, as for every question, and such a request
    /// never opens without one.
    var byAgent: Bool
}

/// Chrome's rules for other apps' addresses (chrome/browser/external_protocol/external_protocol_handler.cc,
/// Chromium 154), and Yardlet's one addition for the agent.
enum BrowserExternalAppPolicy {
    /// A mail link opens without asking ("because of its ubiquity on the web and because every platform
    /// provides a default handler for it"), as does a site the person always allowed for that kind of link.
    /// What the agent's input led to never does: opening another app on the person's Mac, and taking the
    /// screen there (a mail draft, a call, a meeting), is the person's to start.
    static func opensWithoutAsking(scheme: String, remembered: Bool, byAgent: Bool) -> Bool {
        !byAgent && (scheme == "mailto" || remembered)
    }

    /// Chrome offers and keeps "Always allow" only for a potentially trustworthy origin
    /// (`MayRememberAllowDecisionsForThisOrigin`): https, or http on this Mac's own loopback addresses.
    static func mayRemember(origin: String) -> Bool {
        guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased()
        else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]"
            || host.split(separator: ".").first == "127"
    }
}
