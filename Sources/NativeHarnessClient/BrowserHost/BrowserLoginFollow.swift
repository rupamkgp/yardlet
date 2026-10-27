import Foundation

/// Finds the sign-ins made in tasks' tabs, so every task follows the person's and keeps its own
/// (docs/BROWSER_SESSION_ISOLATION.md 11). A sign-in shows as a moment a page asks for one, then a change in the
/// site's cookies: the moment takes a digest of them (`BrowserHostClient.cookieDigest`, no value leaves the host)
/// and, for three minutes, the tab's next pages on the site, the pop-up or passkey window closing, or the form's
/// submission take another. A changed digest is a sign-in:
/// - the person's, when the person drove the tab last (used it in the last three minutes, after the agent), also on a
///   page the agent handed over (`browser_handoff`): it goes to the default profile and the tasks that follow the
///   site (`BrowserTaskProfiles.personSignedIn`);
/// - the task's own, when its agent drove the tab to a password or code field or filled one from the password
///   manager: the site stays the task's.
///
/// The moments: the page's password field took focus, or a one-time code field showed in a panel (a code by mail or
/// an app); Chromium's passkey window showed over the tab (the host says whose it is); the page opened a pop-up (a "Sign in with …" window); the tab left the site for another (a single
/// sign-on's round trip). Browsing alone takes no digest, so a site that renews its cookies as it is used (Google)
/// is not copied over and over, and a page nobody drives (one that goes through its sign-in site on its own) signs
/// nobody in.
@MainActor
final class BrowserLoginFollow {
    enum Moment: Equatable {
        case passwordField, codeField, passkey, popup, leftSite

        /// A field the agent too signs in with: its change is the agent's sign-in when the agent drove the tab.
        var isSignInField: Bool { self == .passwordField || self == .codeField }
    }

    private struct Watch {
        var session: UUID
        var moment: Moment
        var digest: String?
        /// The agent drove the tab (or the one that opened this pop-up).
        var byAgent: Bool
        /// The person used the tab (or the one that opened this pop-up) in the last three minutes, after the agent.
        var byPerson: Bool
        /// The agent had handed the page over to the person.
        var handedOver: Bool
        var until: ContinuousClock.Instant
    }

    private struct WatchKey: Hashable {
        var tab: BrowserTabID
        var site: String
    }

    static let window: Duration = .seconds(180)

    private let client: BrowserHostClient
    private let profiles: BrowserTaskProfiles
    private var watches: [WatchKey: Watch] = [:]
    /// Each tab's site and session as its pages last showed them.
    private var tabSites: [BrowserTabID: (session: UUID, site: String)] = [:]
    /// Pop-ups and the tabs that opened them, while open.
    private var openers: [BrowserTabID: BrowserTabID] = [:]
    /// Chromium's passkey windows shown now and the tab each is over.
    private var passkeyWindows: [Int: BrowserTabID] = [:]
    private var fillObserver: NSObjectProtocol?

    init(client: BrowserHostClient, profiles: BrowserTaskProfiles) {
        self.client = client
        self.profiles = profiles
    }

    /// Starts following the client's tabs; the password manager's agent fills mark the task's own sign-ins.
    func start() {
        client.onTabEvent = { [weak self] tab, event in self?.tabEvent(tab, event) }
        let closed = client.onTabClosed
        client.onTabClosed = { [weak self] tab in
            closed?(tab)
            self?.tabGone(tab)
        }
        let windowsChanged = client.onChromiumWindowsChange
        client.onChromiumWindowsChange = { [weak self] in
            windowsChanged?()
            self?.chromiumWindowsChanged()
        }
        fillObserver = NotificationCenter.default.addObserver(forName: .vaultFilled, object: nil, queue: .main) { [weak self] note in
            let tab = note.userInfo?[VaultFillNotice.tabKey] as? BrowserTabID
            MainActor.assumeIsolated { self?.agentFilled(tab: tab) }
        }
    }

    /// A page's site: its registrable domain, an IP address or a single-label host (localhost) as it is.
    nonisolated static func site(of address: String?) -> String? {
        guard let address, let url = URL(string: address), ["http", "https"].contains(url.scheme ?? ""),
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) || !host.contains(".") { return host }
        return PublicSuffixList.bundled.registrableDomain(of: host) ?? host
    }

    // MARK: Moments

    private func tabEvent(_ tab: BrowserTab, _ event: BrowserHostEvent) {
        guard profiles.storage == .perTask else { return }
        switch event {
        case .passwordField(_, true):
            begin(.passwordField, on: tab)
        case .openedTab(_, let popup?, _):
            openers[popup] = tab.id
            begin(.popup, on: tab)
        case .newDocument(_, let url):
            guard let session = tab.session, let site = Self.site(of: url) else { return }
            let left = tabSites[tab.id]
            tabSites[tab.id] = (session, site)
            guard let left, left.site != site else { return }
            // The site's sign-in may be done (its cookies set before the page moved on); a round trip back is watched.
            check(WatchKey(tab: tab.id, site: left.site), after: [.seconds(1)])
            begin(.leftSite, on: tab, site: left.site)
        case .loadEnd(_, let url, _):
            guard let site = Self.site(of: url) else { return }
            check(WatchKey(tab: tab.id, site: site), after: [.seconds(1)])
        case .closed:
            tabGone(tab.id)
        default:
            break
        }
    }

    /// The person submitted a sign-in form in the panel (the password manager's watch): the site is checked as the
    /// site sets its cookies, after its redirects and once more for one that sets them late.
    func signInSubmitted(on tab: BrowserTab) {
        guard let site = Self.site(of: tab.currentURL) else { return }
        let key = WatchKey(tab: tab.id, site: site)
        if watches[key] == nil { begin(.passwordField, on: tab) }
        check(key, after: [.seconds(4), .seconds(12)])
    }

    /// The panel's page showed a one-time code field (the password manager's watch).
    func codeFieldShown(on tab: BrowserTab) {
        begin(.codeField, on: tab)
    }

    /// The person filled a sign-in from the key button: its submission is the next moment to watch.
    func personFilling(on tab: BrowserTab) {
        begin(.passwordField, on: tab)
    }

    private func begin(_ moment: Moment, on tab: BrowserTab, site given: String? = nil) {
        guard profiles.storage == .perTask, let session = tab.session,
              let site = given ?? Self.site(of: tab.currentURL) else { return }
        // A pop-up is driven as the tab that opened it was.
        let opener = openers[tab.id].flatMap { opener in watches.first { $0.key.tab == opener }?.value }
        let byAgent = tab.isDrivenByAgent || opener?.byAgent == true
        let byPerson = !byAgent && (tab.lastPersonInput.map { ContinuousClock.now - $0 < Self.window } ?? false
                                    || opener?.byPerson == true)
        let handedOver = tab.handoff != nil || opener?.handedOver == true
        // A page nobody drives (one that redirects on its own) signs nobody in, and the agent's browsing alone is no
        // sign-in: only its password fields are watched.
        if !byAgent, !byPerson, !handedOver { return }
        if byAgent, !handedOver, !moment.isSignInField { return }
        let key = WatchKey(tab: tab.id, site: site)
        let until = ContinuousClock.now + Self.window
        watches = watches.filter { $0.value.until > .now }
        if var watch = watches[key] {
            watch.until = until
            watch.byAgent = watch.byAgent || byAgent
            watch.byPerson = watch.byPerson || byPerson
            watch.handedOver = watch.handedOver || handedOver
            if moment.isSignInField { watch.moment = moment }
            watches[key] = watch
            return
        }
        watches[key] = Watch(session: session, moment: moment, digest: nil, byAgent: byAgent, byPerson: byPerson,
                             handedOver: handedOver, until: until)
        let profile = profiles.key(for: session)
        Task { @MainActor [weak self] in
            guard let digest = await self?.client.cookieDigest(profile: profile, site: site) else {
                self?.watches[key] = nil
                return
            }
            if self?.watches[key]?.digest == nil { self?.watches[key]?.digest = digest }
        }
    }

    /// A passkey window over a tab starts a sign-in there; once it closes, the tab's sites are checked. A window whose
    /// tab the host does not know is left out.
    private func chromiumWindowsChanged() {
        var shown: [Int: BrowserTabID] = [:]
        for window in client.chromiumWindows where window.kind == .passkey {
            if let tab = window.tab { shown[window.id] = tab }
        }
        for (window, id) in shown where passkeyWindows[window] == nil {
            if let tab = tabFor(id) { begin(.passkey, on: tab) }
        }
        for (window, tab) in passkeyWindows where shown[window] == nil {
            for key in watches.keys where key.tab == tab { check(key, after: [.seconds(2), .seconds(8)]) }
        }
        passkeyWindows = shown
    }

    private func tabGone(_ id: BrowserTabID) {
        guard tabSites[id] != nil || openers[id] != nil || watches.keys.contains(where: { $0.tab == id }) else { return }
        // A pop-up closing ends its sign-in: the opener's site is checked, and the pop-up's own.
        if let opener = openers.removeValue(forKey: id) {
            for key in watches.keys where key.tab == opener { check(key, after: [.seconds(2), .seconds(8)]) }
        }
        for key in watches.keys where key.tab == id { check(key, after: [.seconds(1)], last: true) }
        tabSites[id] = nil
    }

    // MARK: Checks

    private func check(_ key: WatchKey, after waits: [Duration], last: Bool = false) {
        guard watches[key] != nil else { return }
        Task { @MainActor [weak self] in
            for wait in waits {
                try? await Task.sleep(for: wait)
                await self?.compare(key)
            }
            if last { self?.watches[key] = nil }
        }
    }

    private func compare(_ key: WatchKey) async {
        guard let watch = watches[key], ContinuousClock.now < watch.until, let before = watch.digest else {
            if let watch = watches[key], ContinuousClock.now >= watch.until { watches[key] = nil }
            return
        }
        let profile = profiles.key(for: watch.session)
        guard let after = await client.cookieDigest(profile: profile, site: key.site), after != before,
              watches[key]?.digest == before else { return }
        watches[key]?.digest = after
        // Whoever drove the tab last signed in: the person (on a page the agent handed over too) or the agent. A tab gone
        // (a pop-up that closed) is taken as it was driven when the sign-in began.
        let tab = client.tabs(forSession: watch.session).first { $0.id == key.tab }
        let personLast: Bool, agentLast: Bool
        if let tab {
            agentLast = tab.isDrivenByAgent
            personLast = !agentLast && (tab.lastPersonInput.map { ContinuousClock.now - $0 < Self.window } ?? false)
        } else {
            agentLast = watch.byAgent
            personLast = watch.byPerson || watch.handedOver
        }
        if personLast {
            signedIn(session: watch.session, site: key.site)
        } else if agentLast, watch.moment.isSignInField {
            // The task's own: its agent's password or code sign-in, perhaps with an account for this task alone.
            profiles.signedInItself(to: key.site, in: profile)
        }
    }

    /// The person signed in to `site` in the session's tab: the default profile and the tasks open now that follow
    /// the site take its cookies in place of theirs; the others when their tab next opens. `fromDefault`: the sign-in
    /// is in the default profile already (imported from another browser), which the open tasks take it from.
    func signedIn(session: UUID, site: String, fromDefault: Bool = false) {
        guard profiles.storage == .perTask else { return }
        let key = profiles.key(for: session)
        let open = Set(client.sessionsWithTabs.map(profiles.key(for:)))
        for target in profiles.personSignedIn(to: site, in: key, open: open) {
            if fromDefault {
                if let target { client.copyCookies(from: nil, to: target, site: site) }
            } else {
                client.copyCookies(from: key, to: target, site: site)
            }
        }
    }

    private func agentFilled(tab id: BrowserTabID?) {
        guard profiles.storage == .perTask, let id, let known = tabSites[id] ?? tabFor(id).flatMap({ tab in
            tab.session.flatMap { session in Self.site(of: tab.currentURL).map { (session, $0) } }
        }) else { return }
        profiles.signedInItself(to: known.site, in: profiles.key(for: known.session))
    }

    private func tabFor(_ id: BrowserTabID) -> BrowserTab? {
        client.sessionsWithTabs.lazy.flatMap { self.client.tabs(forSession: $0) }.first { $0.id == id }
    }
}
